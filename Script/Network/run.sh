#!/usr/bin/env bash
set -Eeuo pipefail

PROVIDER_SCRIPT_DIR="/root"
PLAN_FILE=""
TMP_DIR=""
LOG_FILE=""

log() { printf '[RUN] %s\n' "$*" >&2; }
fail() { printf '[RUN] FAIL %s\n' "$*" >&2; exit 1; }

cleanup_tmp() {
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}
trap cleanup_tmp EXIT HUP INT TERM

tmpdir() {
  if [ -z "$TMP_DIR" ]; then
    TMP_DIR="$(mktemp -d /tmp/cloud-run.XXXXXX)"
    LOG_FILE="${TMP_DIR}/run.log"
  fi
}

run_quiet() {
  local label="$1" status
  shift
  tmpdir
  set +e
  "$@" >>"$LOG_FILE" 2>&1
  status=$?
  set -e
  [ "$status" -eq 0 ] && return 0
  log "FAIL ${label} | log=${LOG_FILE}"
  return "$status"
}

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || fail "需要 root 权限执行"
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || fail "仅支持 Debian/Ubuntu apt 环境"
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
  run_quiet "deps install" install_packages "${missing[@]}" || fail "依赖安装失败: ${missing[*]}"
  log "deps: installed | packages=${missing[*]}"
}

script_path() {
  local path="${PROVIDER_SCRIPT_DIR}/${1}"
  [ -s "$path" ] || fail "缺少 Provider 脚本: $path"
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
  local label="$1" script="$2" path
  shift 2
  path="$(script_path "$script")"
  run_quiet "$label" bash "$path" "$@"
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
  local script="$1" allowlist="${2:-}" public_key="${3:-}" allow_count key_success="" key_failed=""
  local -a args
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail "step_ssh_guard 需要脚本、白名单和可选公钥"
  [ -n "$allowlist" ] || fail "SSH 白名单为空"

  ensure_packages openssh-server nftables
  args=(--reset config=ssh "allow=${allowlist}")
  if [ -n "$public_key" ]; then
    args+=("key=${public_key}")
    key_success=" | key=applied"
    key_failed=" | key=failed"
  fi

  allow_count="$(allowlist_count "$allowlist")"
  log "ssh: applying | allow=${allow_count}"
  provider_run "ssh guard" "$script" "${args[@]}" || fail "SSH 防护配置失败 | allow=${allow_count}${key_failed}"
  log "ssh: applied | allow=${allow_count}${key_success}"
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
    log "hostname: skipped | target=${target}"
    return 0
  fi
  run_quiet "hostname" hostnamectl set-hostname "$target" || fail "hostname 设置失败"
  run_quiet "hosts" update_hosts "$target" || fail "/etc/hosts 更新失败"
  log "hostname: applied | target=${target}"
}

current_timezone() {
  timedatectl show --property=Timezone --value 2>/dev/null || true
}

step_time_sync() {
  local timezone="${1:-}" service="${2:-}" old_service
  local old_services=(systemd-timesyncd.service ntp.service ntpsec.service openntpd.service)
  [ "$#" -eq 2 ] || fail "step_time_sync 需要时区和时间同步服务"
  [ "$service" = "chrony" ] || fail "不支持的时间同步服务: ${service}"

  ensure_packages chrony
  if [ "$(current_timezone)" != "$timezone" ]; then
    run_quiet "timezone" timedatectl set-timezone "$timezone" || fail "时区设置失败: ${timezone}"
  fi

  for old_service in "${old_services[@]}"; do
    systemctl disable --now "$old_service" >/dev/null 2>&1 || true
  done

  run_quiet "chrony enable" systemctl enable --now chrony || fail "chrony 启动失败"
  [ "$(current_timezone)" = "$timezone" ] || fail "时区校验失败: ${timezone}"
  service_active chrony || fail "chrony 未运行"
  for old_service in "${old_services[@]}"; do
    service_active "$old_service" && fail "旧时间同步服务仍在运行: ${old_service}"
  done
  log "time: applied | timezone=${timezone} | sync=chrony"
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
  IFS='|' read -r service config uninstall port_key <<< "$(proxy_meta "$type")" || fail "未知代理类型: $type"

  if [ "$type" = "singbox" ]; then
    protocol="$(arg_value --protocol "$@" || true)"
    anytls_port="$(arg_value --anytls-port "$@" || true)"
    ss_port="$(arg_value --ss-port "$@" || true)"
    port="${anytls_port:-$ss_port}"
    [ -n "$port" ] || fail "singbox 缺少端口参数: --anytls-port 或 --ss-port"
    detail="protocol=${protocol:-unknown}"
    [ -z "$anytls_port" ] || detail="${detail} | anytls=${anytls_port}"
    [ -z "$ss_port" ] || detail="${detail} | ss=${ss_port}"
    provider_run "proxy apply ${type}" "$script" "$@" || fail "${type} 配置失败"
    [ -z "$anytls_port" ] || service_usable "$service" "$config" "$anytls_port" || fail "${type} AnyTLS 配置后不可用"
    [ -z "$ss_port" ] || service_usable "$service" "$config" "$ss_port" || fail "${type} Shadowsocks 配置后不可用"
    log "proxy: applied | type=${type} | ${detail}"
    return 0
  elif [ "$type" = "shadss" ]; then
    port="$(arg_value "$port_key" "$@")" || fail "${type} 缺少端口参数: ${port_key}"
    detail="port=${port}"
    provider_run "proxy apply ${type}" "$script" "$@" || fail "${type} 配置失败"
    service_usable "$service" "$config" "$port" || fail "${type} 配置后不可用"
    log "proxy: applied | type=${type} | ${detail}"
    return 0
  else
    port="$(arg_value "$port_key" "$@")" || fail "${type} 缺少端口参数: ${port_key}"
    detail="port=${port}"
  fi

  if service_usable "$service" "$config" "$port"; then
    log "proxy: skipped | type=${type} | ${detail}"
    return 0
  fi

  if service_port_mismatch "$service" "$config" "$port"; then
    provider_run "proxy uninstall ${type}" "$script" "$uninstall" || fail "${type} 卸载失败"
    log "proxy: service removed | type=${type} | reason=port-mismatch | port=${port}"
  elif service_exists "$service" || [ -e "$config" ]; then
    provider_run "proxy uninstall ${type}" "$script" "$uninstall" || fail "${type} 卸载失败"
    log "proxy: service removed | type=${type} | reason=stale"
  fi

  provider_run "proxy install ${type}" "$script" "$@" || fail "${type} 安装失败"
  service_usable "$service" "$config" "$port" || fail "${type} 安装后不可用"
  log "proxy: installed | type=${type} | ${detail}"
}

step_proxy_remove() {
  local type="$1" script="$2"
  shift 2
  [ "$#" -gt 0 ] || fail "step_proxy_remove 缺少卸载参数: ${type}"
  provider_run "proxy remove ${type}" "$script" "$@" || fail "${type} 删除失败"
  if [ -e "${PROVIDER_SCRIPT_DIR}/${script}" ]; then
    rm -f "${PROVIDER_SCRIPT_DIR}/${script}" || fail "代理辅助脚本清理失败: ${script}"
    log "proxy: script removed | script=${script} | reason=unused"
  fi
  log "proxy: removed | type=${type}"
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
    log "kernel: skipped"
    return 0
  fi
  if [ -f "$file" ]; then
    provider_run "kernel uninstall" "$script" -u || fail "kernel 旧配置清理失败"
    log "kernel: removed | reason=stale"
  fi
  provider_run "kernel apply" "$script" "$@" || fail "kernel 配置失败"
  kernel_config_matches "$@" || fail "kernel 配置后校验失败"
  log "kernel: applied"
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
    rm -f "${PROVIDER_SCRIPT_DIR}/${script}" || fail "DNS 辅助脚本清理失败: ${script}"
    log "dns: script removed | script=${script} | reason=unused"
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
    provider_run "dns uninstall ${other}" "$other_script" "$other_uninstall" || fail "${other} 卸载失败"
    log "dns: service removed | type=${other} | reason=conflict"
  fi
}

step_dns() {
  local type="$1" script="$2" service config uninstall port binary
  shift 2
  IFS='|' read -r service config uninstall port binary <<< "$(dns_meta "$type")" || fail "未知 DNS 类型: $type"

  if service_usable "$service" "$config" "$port"; then
    cleanup_other_dns_script "$type"
    log "dns: skipped | type=${type}"
    return 0
  fi

  if service_port_mismatch "$service" "$config" "$port"; then
    provider_run "dns uninstall ${type}" "$script" "$uninstall" || fail "${type} 卸载失败"
    log "dns: service removed | type=${type} | reason=port-mismatch | port=${port}"
  elif service_exists "$service" || [ -e "$config" ] || [ -e "$binary" ]; then
    provider_run "dns uninstall ${type}" "$script" "$uninstall" || fail "${type} 卸载失败"
    log "dns: service removed | type=${type} | reason=stale"
  fi

  remove_other_dns "$type"
  provider_run "dns install ${type}" "$script" "$@" || fail "${type} 安装失败"
  service_usable "$service" "$config" "$port" || fail "${type} 安装后不可用"
  cleanup_other_dns_script "$type"
  log "dns: installed | type=${type}"
}

step_traffic() {
  local mode="$1" script="$2"
  shift 2
  ensure_packages nftables
  case "$mode" in
    forward)
      provider_run "nftables replace" "$script" -r "$@" || fail "nftables 替换失败"
      log "traffic: applied | mode=forward | action=replace"
      ;;
    protect)
      provider_run "nftables protect" "$script" --protect on || fail "nftables 防护配置失败"
      log "traffic: applied | mode=protect"
      ;;
    *)
      fail "未知 traffic 模式: $mode"
      ;;
  esac
}

run_plan() {
  [ -r "$PLAN_FILE" ] || fail "无法读取 plan: $PLAN_FILE"
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
  log "workflow: done"
}

main "$@"
