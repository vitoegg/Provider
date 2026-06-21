#!/usr/bin/env bash
set -Eeuo pipefail

PROVIDER_SCRIPT_DIR="/root"
PLAN_FILE=""
LOG_FILE=""

log() { printf '[RUN] %s\n' "$*" >&2; }
fail() {
  printf '[RUN] FAIL %s\n' "$*" >&2
  exit 1
}

cleanup_runtime() {
  [ -z "$LOG_FILE" ] || rm -f "$LOG_FILE" || true
}
trap cleanup_runtime EXIT

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
    systemd-timesyncd) dpkg-query -W -f='${db:Status-Abbrev}' systemd-timesyncd 2>/dev/null | grep -q '^ii ' ;;
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
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail "step_ssh_guard requires script, allowlist, and optional public key"
  local script="$1" allowlist="$2" public_key="${3:-}" allow_count key_detail=""
  local -a args
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
  [ "$#" -eq 1 ] || fail "step_hostname requires hostname"
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
  local timezone="${1:-}" service="${2:-}" synced="" i
  [ "$#" -eq 2 ] || fail "step_time_sync requires timezone and service"
  [ "$service" = "systemd-timesyncd" ] || fail "unsupported time sync service | service=${service}"

  ensure_packages systemd-timesyncd
  if [ "$(current_timezone)" != "$timezone" ]; then
    run_quiet timedatectl set-timezone "$timezone" || fail "timezone configuration failed | timezone=${timezone}"
  fi

  run_quiet systemctl enable --now systemd-timesyncd || fail "time sync start failed | service=systemd-timesyncd"
  [ "$(current_timezone)" = "$timezone" ] || fail "timezone verification failed | timezone=${timezone}"
  systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null || fail "time sync not enabled | service=systemd-timesyncd"
  service_active systemd-timesyncd || fail "time sync inactive | service=systemd-timesyncd"

  for i in $(seq 1 30); do
    synced="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)"
    [ "$synced" = "yes" ] && break
    sleep 2
  done
  [ "$synced" = "yes" ] || fail "time sync not synchronized | service=systemd-timesyncd"

  log "time sync active | timezone=${timezone} | service=systemd-timesyncd | synchronized=yes"
}

proxy_meta() {
  case "$1" in
    socks) printf 'danted.service|/etc/danted.conf|--port' ;;
    ssrust) printf 'shadowsocks.service|/etc/shadowsocks/config.json|-p' ;;
    ssgo) printf 'sing-box.service|/etc/sing-box/config.json|' ;;
    anytls) printf 'sing-box.service|/etc/sing-box/config.json|' ;;
    reality) printf 'xray.service|/usr/local/etc/xray/config.json|--reality-port' ;;
    snell) printf 'snell.service|/etc/snell/snell.conf|-p' ;;
    *) return 1 ;;
  esac
}

service_usable() {
  local service="$1" config="$2" port="$3"
  service_active "$service" && [ -e "$config" ] && service_port_ready "$service" "$port"
}

step_proxy() {
  [ "$#" -ge 3 ] || fail "step_proxy requires type, script, and configuration arguments"
  local type="$1" script="$2" service config port_key port detail
  local protocol anytls_port ss_port
  shift 2
  IFS='|' read -r service config port_key <<< "$(proxy_meta "$type")" || fail "unknown proxy type | type=${type}"

  if [ "$type" = "anytls" ] || [ "$type" = "ssgo" ]; then
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
  elif [ "$type" = "ssrust" ]; then
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
  [ "$#" -ge 3 ] || fail "step_proxy_remove requires type, script, and removal arguments"
  local type="$1" script="$2"
  shift 2
  provider_run "$script" "$@" || fail "proxy removal failed | type=${type}"
  log "proxy cleared | type=${type}"
}

step_kernel() {
  [ "$#" -ge 1 ] || fail "step_kernel requires script"
  local script="$1"
  shift
  provider_run "$script" "$@" || fail "kernel tuning configuration failed"
  log "kernel tuning configured"
}

dns_meta() {
  case "$1" in
    mosdns) printf 'mosdns.service|/etc/mosdns|53' ;;
    smartdns) printf 'smartdns.service|/etc/smartdns/smartdns.conf|53' ;;
    *) return 1 ;;
  esac
}

step_dns_remove() {
  [ "$#" -ge 3 ] || fail "step_dns_remove requires type, script, and removal arguments"
  local type="$1" script="$2"
  shift 2
  provider_run "$script" "$@" || fail "dns resolver removal failed | service=${type}"
  log "dns resolver cleared | service=${type}"
}

step_dns() {
  [ "$#" -ge 2 ] || fail "step_dns requires type and script"
  local type="$1" script="$2" service config port
  shift 2
  IFS='|' read -r service config port <<< "$(dns_meta "$type")" || fail "unknown dns resolver | service=${type}"
  provider_run "$script" "$@" || fail "dns resolver installation failed | service=${service%.service}"
  service_usable "$service" "$config" "$port" || fail "dns resolver inactive | service=${service%.service}"
  log "dns resolver active | service=${service%.service}"
}

step_traffic() {
  [ "$#" -ge 2 ] || fail "step_traffic requires mode and script"
  local mode="$1" script="$2"
  shift 2
  ensure_packages nftables
  case "$mode" in
    forward)
      provider_run "$script" -r "$@" || fail "traffic rules load failed | mode=forward"
      log "traffic rules loaded | mode=forward"
      ;;
    protect)
      provider_run "$script" --protect on "$@" || fail "traffic rules load failed | mode=protect"
      log "traffic rules loaded | mode=protect"
      ;;
    off)
      [ "$#" -eq 0 ] || fail "traffic off does not accept arguments"
      provider_run "$script" -u || fail "traffic rules removal failed"
      log "traffic rules cleared"
      ;;
    *)
      fail "unknown traffic mode | mode=${mode}"
      ;;
  esac
}

step_telegram() {
  [ "$#" -eq 2 ] || fail "step_telegram requires script and action"
  local script="$1" action="$2"
  provider_run "$script" "$action" || fail "telegram optimization failed | action=${action}"
  log "telegram optimization configured | action=${action}"
}

step_cleanup_scripts() {
  local script removed=0
  for script in "$@"; do
    case "$script" in
      ""|*/*) fail "invalid cleanup script | name=${script}" ;;
    esac
    if [ -e "${PROVIDER_SCRIPT_DIR}/${script}" ]; then
      rm -f "${PROVIDER_SCRIPT_DIR}/${script}" || fail "provider script cleanup failed | script=${script}"
      removed=$((removed + 1))
    fi
  done
  log "provider scripts cleaned | count=${removed}"
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
}

main "$@"
