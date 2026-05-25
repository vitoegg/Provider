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

has_pkg() {
  case "$1" in
    iproute2) command -v ss >/dev/null 2>&1 ;;
    nftables) command -v nft >/dev/null 2>&1 ;;
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
  log "deps: installed=${missing[*]}"
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

port_ready() {
  ss -tulpen 2>/dev/null | grep -Eq ":${1}\\b"
}

provider_run() {
  local label="$1" script="$2" path
  shift 2
  path="$(script_path "$script")"
  run_quiet "$label" bash "$path" "$@"
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
  log "hostname: ${target}"
}

proxy_meta() {
  case "$1" in
    ss2022) printf 'shadowsocks.service|/etc/shadowsocks/config.json|-u|-p' ;;
    anytls) printf 'sing-box.service|/etc/sing-box/config.json|--uninstall|--port' ;;
    reality) printf 'xray.service|/usr/local/etc/xray/config.json|--uninstall|--reality-port' ;;
    snell) printf 'snell.service|/etc/snell/snell.conf|-u|-p' ;;
    *) return 1 ;;
  esac
}

service_usable() {
  local service="$1" config="$2" port="$3"
  service_active "$service" && [ -e "$config" ] && port_ready "$port"
}

step_proxy() {
  local type="$1" script="$2" service config uninstall port_key port
  shift 2
  IFS='|' read -r service config uninstall port_key <<< "$(proxy_meta "$type")" || fail "未知代理类型: $type"
  port="$(arg_value "$port_key" "$@")" || fail "${type} 缺少端口参数: ${port_key}"

  if service_usable "$service" "$config" "$port"; then
    log "proxy: skipped | type=${type} | port=${port}"
    return 0
  fi

  if service_exists "$service" || [ -e "$config" ]; then
    provider_run "proxy uninstall ${type}" "$script" "$uninstall" || fail "${type} 卸载失败"
    log "proxy: stale removed | type=${type}"
  fi

  provider_run "proxy install ${type}" "$script" "$@" || fail "${type} 安装失败"
  service_usable "$service" "$config" "$port" || fail "${type} 安装后不可用"
  log "proxy: installed | type=${type} | port=${port}"
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
    log "kernel: stale removed"
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

step_dns() {
  local type="$1" script="$2" service config uninstall port binary
  shift 2
  IFS='|' read -r service config uninstall port binary <<< "$(dns_meta "$type")" || fail "未知 DNS 类型: $type"

  if service_usable "$service" "$config" "$port"; then
    log "dns: skipped | type=${type}"
    return 0
  fi

  if service_exists "$service" || [ -e "$config" ] || [ -e "$binary" ]; then
    provider_run "dns uninstall ${type}" "$script" "$uninstall" || fail "${type} 卸载失败"
    log "dns: stale removed | type=${type}"
  fi

  provider_run "dns install ${type}" "$script" "$@" || fail "${type} 安装失败"
  service_usable "$service" "$config" "$port" || fail "${type} 安装后不可用"
  log "dns: installed | type=${type}"
}

forwardaws_exists() {
  [ -s /etc/forwardaws/rules.db ] && return 0
  [ -f /etc/forwardaws/config.env ] && return 0
  [ -s /etc/nftables.d/forwardaws.nft ] && return 0
  command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'forwardaws'
}

step_traffic() {
  local mode="$1" script="$2"
  shift 2
  ensure_packages nftables
  case "$mode" in
    forward)
      if forwardaws_exists; then
        provider_run "nftables replace" "$script" -r "$@" || fail "nftables 替换失败"
        log "traffic: forward replaced"
      else
        provider_run "nftables add" "$script" -a "$@" || fail "nftables 配置失败"
        log "traffic: forward added"
      fi
      ;;
    protect)
      if forwardaws_exists; then
        log "traffic: protect skipped"
      else
        provider_run "nftables protect" "$script" --protect on || fail "nftables 防护配置失败"
        log "traffic: protect enabled"
      fi
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
  log "done"
}

main "$@"
