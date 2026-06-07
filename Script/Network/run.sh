#!/usr/bin/env bash
set -Eeuo pipefail

PROVIDER_SCRIPT_DIR="/root"
PLAN_FILE=""
LOG_FILE=""

log() { printf '[RUN] %s\n' "$*" >&2; }
fail() {
  if [ -n "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
    printf '[RUN] FAIL %s | log=%s\n' "$*" "$LOG_FILE" >&2
  else
    printf '[RUN] FAIL %s\n' "$*" >&2
  fi
  exit 1
}

run_quiet() {
  [ -n "$LOG_FILE" ] || LOG_FILE="$(mktemp /tmp/cloud-run.XXXXXX)"
  "$@" >>"$LOG_FILE" 2>&1
}

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || fail "root required"
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || fail "Debian/Ubuntu apt required"
}

sshd_cmd() {
  local path
  path="$(command -v sshd 2>/dev/null || true)"
  [ -n "$path" ] || path="/usr/sbin/sshd"
  [ -x "$path" ] || return 1
  printf '%s' "$path"
}

has_pkg() {
  case "$1" in
    chrony) command -v chronyc >/dev/null 2>&1 ;;
    iproute2) command -v ss >/dev/null 2>&1 ;;
    nftables) command -v nft >/dev/null 2>&1 ;;
    openssh-server) sshd_cmd >/dev/null 2>&1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}

install_packages() {
  env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

ensure_packages() {
  local missing=() package
  for package in "$@"; do
    has_pkg "$package" || missing+=("$package")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  run_quiet install_packages "${missing[@]}" || fail "dependency install failed | packages=${missing[*]}"
}

script_path() {
  local path="${PROVIDER_SCRIPT_DIR}/${1}"
  [ -s "$path" ] || fail "provider script missing | path=${path}"
  chmod +x "$path"
  printf '%s' "$path"
}

arg_value() {
  local key="$1" arg
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      "$key")
        [ -n "${2:-}" ] || return 1
        printf '%s' "$2"
        return 0
        ;;
      "$key="*)
        printf '%s' "${arg#*=}"
        return 0
        ;;
    esac
    shift
  done
  return 1
}

service_active() {
  systemctl is-active --quiet "$1" >/dev/null 2>&1
}

service_exists() {
  systemctl cat "$1" >/dev/null 2>&1 && return 0
  systemctl list-unit-files "$1" 2>/dev/null | awk -v unit="$1" '$1==unit { found=1 } END { exit !found }'
}

service_port_ready() {
  local service="$1" port="$2" cgroup line pid
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  cgroup="$(systemctl show "$service" --property=ControlGroup --value 2>/dev/null || true)"
  [ -n "$cgroup" ] || return 1

  while IFS= read -r line; do
    while IFS= read -r pid; do
      [ -r "/proc/${pid}/cgroup" ] || continue
      grep -Fq "$cgroup" "/proc/${pid}/cgroup" && return 0
    done < <(printf '%s\n' "$line" | grep -oE 'pid=[0-9]+' | cut -d= -f2)
  done < <(ss -H -tulpen 2>/dev/null | awk -v port="$port" '
    function port_matches(addr) {
      return addr ~ (":" port "$") || addr ~ ("\\." port "$")
    }
    port_matches($5)
  ')
  return 1
}

provider_run() {
  local script="$1" path
  shift
  path="$(script_path "$script")"
  run_quiet bash "$path" "$@"
}

allowlist_count() {
  printf '%s\n' "$1" | awk -F, '
    {
      for (i = 1; i <= NF; i++) {
        item = $i
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
        if (item == "") continue
        total++
      }
      printf "%d", total
    }'
}

step_ssh_guard() {
  local script="$1" allowlist="${2:-}" public_key="${3:-}" allow_count key_detail=""
  local -a args
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail "step_ssh_guard requires script, allowlist, and optional public key"
  [ -n "$allowlist" ] || fail "ssh allowlist empty"

  ensure_packages openssh-server nftables
  args=(--reset config=ssh "allow=${allowlist}")
  if [ -n "$public_key" ]; then
    args+=("key=${public_key}")
    key_detail=" | root_key=installed"
  fi

  allow_count="$(allowlist_count "$allowlist")"
  provider_run "$script" "${args[@]}" || fail "ssh guard failed | trusted_sources=${allow_count}"
  log "ssh guard enabled | trusted_sources=${allow_count}${key_detail}"
}

update_hosts() {
  if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${1}/" /etc/hosts
  else
    printf '127.0.1.1 %s\n' "$1" >> /etc/hosts
  fi
}

step_hostname() {
  local target="$1" current
  current="$(hostname 2>/dev/null || true)"
  if [ "$current" = "$target" ] && grep -Eq "^127\\.0\\.1\\.1[[:space:]]+${target}$" /etc/hosts 2>/dev/null; then
    log "hostname configured | name=${target}"
    return 0
  fi
  run_quiet hostnamectl set-hostname "$target" || fail "hostname configuration failed | name=${target}"
  run_quiet update_hosts "$target" || fail "hosts file update failed | name=${target}"
  log "hostname configured | name=${target}"
}

current_timezone() {
  timedatectl show --property=Timezone --value 2>/dev/null || true
}

step_time_sync() {
  local timezone="${1:-}" service="${2:-}" old_service
  local old_services=(systemd-timesyncd.service ntp.service ntpsec.service openntpd.service)
  [ "$#" -eq 2 ] || fail "step_time_sync requires timezone and service"
  [ "$service" = "chrony" ] || fail "unsupported time sync service | service=${service}"

  ensure_packages chrony
  if [ "$(current_timezone)" != "$timezone" ]; then
    run_quiet timedatectl set-timezone "$timezone" || fail "timezone configuration failed | timezone=${timezone}"
  fi

  for old_service in "${old_services[@]}"; do
    systemctl disable --now "$old_service" >/dev/null 2>&1 || true
  done

  run_quiet systemctl enable --now chrony || fail "time sync start failed | service=chrony"
  [ "$(current_timezone)" = "$timezone" ] || fail "timezone verification failed | timezone=${timezone}"
  service_active chrony || fail "time sync inactive | service=chrony"
  for old_service in "${old_services[@]}"; do
    service_active "$old_service" && fail "old time sync still active | service=${old_service}"
  done
  log "time sync active | timezone=${timezone} | service=chrony"
}

proxy_meta() {
  case "$1" in
    shadss) printf 'shadowsocks.service|/etc/shadowsocks/config.json|-u|-p' ;;
    singbox) printf 'sing-box.service|/etc/sing-box/config.json|--uninstall|' ;;
    reality) printf 'xray.service|/usr/local/etc/xray/config.json|--uninstall|--reality-port' ;;
    snell) printf 'snell.service|/etc/snell/snell.conf|-u|-p' ;;
    *) return 1 ;;
  esac
}

service_usable() {
  local service="$1" config="$2" port="$3"
  service_active "$service" && [ -e "$config" ] && service_port_ready "$service" "$port"
}

service_port_mismatch() {
  local service="$1" config="$2" port="$3"
  service_active "$service" && [ -e "$config" ] && ! service_port_ready "$service" "$port"
}

step_proxy() {
  local type="$1" script="$2" service config uninstall port_key port detail
  local protocol anytls_port ss_port
  shift 2
  IFS='|' read -r service config uninstall port_key <<< "$(proxy_meta "$type")" || fail "unknown proxy type | type=${type}"

  if [ "$type" = "singbox" ]; then
    protocol="$(arg_value --protocol "$@" || true)"
    anytls_port="$(arg_value --anytls-port "$@" || true)"
    ss_port="$(arg_value --ss-port "$@" || true)"
    port="${anytls_port:-$ss_port}"
    [ -n "$port" ] || fail "proxy port missing | service=sing-box"
    detail="protocols=${protocol:-unknown}"
    if [ -n "$anytls_port" ] && [ -n "$ss_port" ]; then
      detail="${detail} | ports=anytls:${anytls_port},shadowsocks:${ss_port}"
    elif [ -n "$anytls_port" ]; then
      detail="${detail} | ports=anytls:${anytls_port}"
    else
      detail="${detail} | ports=shadowsocks:${ss_port}"
    fi
    provider_run "$script" "$@" || fail "proxy configuration failed | service=sing-box"
    [ -z "$anytls_port" ] || service_usable "$service" "$config" "$anytls_port" || fail "proxy inactive | service=sing-box | protocol=anytls"
    [ -z "$ss_port" ] || service_usable "$service" "$config" "$ss_port" || fail "proxy inactive | service=sing-box | protocol=shadowsocks"
    log "proxy active | service=${service%.service} | ${detail}"
    return 0
  elif [ "$type" = "shadss" ]; then
    port="$(arg_value "$port_key" "$@")" || fail "proxy port missing | service=${service%.service}"
    provider_run "$script" "$@" || fail "proxy configuration failed | service=${service%.service}"
    service_usable "$service" "$config" "$port" || fail "proxy inactive | service=${service%.service}"
    log "proxy active | service=${service%.service} | port=${port}"
    return 0
  else
    port="$(arg_value "$port_key" "$@")" || fail "proxy port missing | service=${service%.service}"
  fi

  provider_run "$script" "$@" || fail "proxy configuration failed | service=${service%.service}"
  service_usable "$service" "$config" "$port" || fail "proxy inactive | service=${service%.service}"
  log "proxy active | service=${service%.service} | port=${port}"
}

step_proxy_remove() {
  local type="$1" script="$2" service config uninstall port_key
  shift 2
  [ "$#" -gt 0 ] || fail "step_proxy_remove requires removal arguments | type=${type}"
  IFS='|' read -r service config uninstall port_key <<< "$(proxy_meta "$type")" || fail "unknown proxy type | type=${type}"
  provider_run "$script" "$@" || fail "proxy removal failed | service=${service%.service}"
  if [ -e "${PROVIDER_SCRIPT_DIR}/${script}" ]; then
    rm -f "${PROVIDER_SCRIPT_DIR}/${script}" || fail "proxy script cleanup failed | script=${script}"
  fi
  log "proxy cleared | service=${service%.service}"
}

kernel_needs_ipv6_disabled() {
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "-6" ]; then
      [ "${2:-}" = "no" ] && return 0
      return 1
    fi
    shift
  done
  return 1
}

kernel_config_matches() {
  local file="/etc/sysctl.d/99-network-kernel.conf"
  [ -f "$file" ] || return 1
  if kernel_needs_ipv6_disabled "$@"; then
    grep -q '^net\.ipv6\.conf\.all\.disable_ipv6 = 1$' "$file"
  else
    ! grep -q '^net\.ipv6\.conf\.all\.disable_ipv6 = 1$' "$file"
  fi
}

step_kernel() {
  local script="$1" file="/etc/sysctl.d/99-network-kernel.conf"
  shift
  if kernel_config_matches "$@"; then
    log "kernel tuning configured"
    return 0
  fi
  if [ -f "$file" ]; then
    provider_run "$script" -u || fail "kernel tuning cleanup failed"
  fi
  provider_run "$script" "$@" || fail "kernel tuning configuration failed"
  kernel_config_matches "$@" || fail "kernel tuning verification failed"
  log "kernel tuning configured"
}

dns_meta() {
  case "$1" in
    mosdns) printf 'mosdns.service|/etc/mosdns|-u|53|/usr/local/bin/mosdns' ;;
    smartdns) printf 'smartdns.service|/etc/smartdns/smartdns.conf|-u|53|/usr/sbin/smartdns' ;;
    *) return 1 ;;
  esac
}

other_dns_script() {
  case "$1" in
    mosdns) printf 'smartdns.sh' ;;
    smartdns) printf 'mosdns.sh' ;;
    *) return 1 ;;
  esac
}

cleanup_other_dns_script() {
  local script
  script="$(other_dns_script "$1")" || return 0
  if [ -e "${PROVIDER_SCRIPT_DIR}/${script}" ]; then
    rm -f "${PROVIDER_SCRIPT_DIR}/${script}" || fail "dns script cleanup failed | script=${script}"
  fi
}

remove_other_dns() {
  local target="$1" other other_script other_service other_config other_uninstall other_port other_binary
  case "$target" in
    mosdns)
      other="smartdns"
      ;;
    smartdns)
      other="mosdns"
      ;;
    *)
      return 0
      ;;
  esac
  other_script="$(other_dns_script "$target")" || return 0

  IFS='|' read -r other_service other_config other_uninstall other_port other_binary <<< "$(dns_meta "$other")" || return 0
  if service_exists "$other_service" || [ -e "$other_config" ] || [ -e "$other_binary" ]; then
    provider_run "$other_script" "$other_uninstall" || fail "dns resolver removal failed | service=${other_service%.service}"
  fi
}

step_dns() {
  local type="$1" script="$2" service config uninstall port binary
  shift 2
  IFS='|' read -r service config uninstall port binary <<< "$(dns_meta "$type")" || fail "unknown dns resolver | service=${type}"

  if service_usable "$service" "$config" "$port"; then
    cleanup_other_dns_script "$type"
    log "dns resolver active | service=${service%.service}"
    return 0
  fi

  if service_port_mismatch "$service" "$config" "$port"; then
    provider_run "$script" "$uninstall" || fail "dns resolver removal failed | service=${service%.service}"
  elif service_exists "$service" || [ -e "$config" ] || [ -e "$binary" ]; then
    provider_run "$script" "$uninstall" || fail "dns resolver removal failed | service=${service%.service}"
  fi

  remove_other_dns "$type"
  provider_run "$script" "$@" || fail "dns resolver installation failed | service=${service%.service}"
  service_usable "$service" "$config" "$port" || fail "dns resolver inactive | service=${service%.service}"
  cleanup_other_dns_script "$type"
  log "dns resolver active | service=${service%.service}"
}

step_traffic() {
  local mode="$1" script="$2"
  shift 2
  ensure_packages nftables
  case "$mode" in
    forward)
      provider_run "$script" -r "$@" || fail "traffic rules load failed | mode=forward"
      log "traffic rules loaded | mode=forward"
      ;;
    protect)
      provider_run "$script" --protect on || fail "traffic rules load failed | mode=protect"
      log "traffic rules loaded | mode=protect"
      ;;
    *)
      fail "unknown traffic mode | mode=${mode}"
      ;;
  esac
}

run_plan() {
  [ -r "$PLAN_FILE" ] || fail "plan unreadable | file=${PLAN_FILE}"
  # shellcheck disable=SC1090
  source "$PLAN_FILE"
}

main() {
  case "${1:-}" in
    -h|--help)
      printf 'Usage: bash run.sh /path/to/cloudserver.plan\n'
      exit 0
      ;;
  esac
  [ -n "${1:-}" ] || { printf 'Usage: bash run.sh /path/to/cloudserver.plan\n' >&2; exit 1; }
  PLAN_FILE="$1"
  require_root
  require_apt
  ensure_packages iproute2
  run_plan
  [ -z "$LOG_FILE" ] || rm -f "$LOG_FILE"
}

main "$@"
