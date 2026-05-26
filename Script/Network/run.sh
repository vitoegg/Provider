#!/usr/bin/env bash
set -Eeuo pipefail

PROVIDER_SCRIPT_DIR="/root"
PLAN_FILE=""
TMP_DIR=""
LOG_FILE=""
SSH_HARDENING_CONF="/etc/ssh/sshd_config.d/00-cloudserver-hardening.conf"
SSH_MAIN_CONFIG="/etc/ssh/sshd_config"
SSH_NFT_CONF="/etc/nftables.d/cloudserver-ssh.nft"
SSH_NFT_TABLE="cloudserver_ssh_guard"
NFT_MAIN_CONFIG="/etc/nftables.conf"
NFT_INCLUDE_DIR="/etc/nftables.d"

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

port_ready() {
  ss -tulpen 2>/dev/null | grep -Eq ":${1}\\b"
}

provider_run() {
  local label="$1" script="$2" path
  shift 2
  path="$(script_path "$script")"
  run_quiet "$label" bash "$path" "$@"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

normalize_block() {
  printf '%s\n' "$1" | sed 's/[[:space:]]*$//' | awk 'NF > 0'
}

normalize_sshd_value() {
  local key value
  key="$(lower "$1")"
  value="$(lower "$2")"
  case "${key}:${value}" in
    permitrootlogin:without-password) printf 'prohibit-password' ;;
    *) printf '%s' "$value" ;;
  esac
}

content_matches_file() {
  local file="$1" content="$2" tmp
  [ -f "$file" ] || return 1
  tmpdir
  tmp="${TMP_DIR}/content.$$"
  printf '%s\n' "$content" > "$tmp"
  cmp -s "$tmp" "$file"
}

install_content_file() {
  local file="$1" mode="$2" content="$3" tmp
  tmpdir
  tmp="${TMP_DIR}/install.$$"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$content" > "$tmp"
  install -m "$mode" "$tmp" "$file"
}

sshd_config_has_dropin_include() {
  [ -f "$SSH_MAIN_CONFIG" ] || return 1
  grep -Eiq '^[[:space:]]*Include[[:space:]]+"?/etc/ssh/sshd_config\.d/\*\.conf"?([[:space:]]|$)' "$SSH_MAIN_CONFIG"
}

sshd_effective_config() {
  local sshd
  sshd="$(sshd_cmd)" || return 1
  mkdir -p /run/sshd
  "$sshd" -T 2>/dev/null
}

sshd_config_valid() {
  local sshd
  sshd="$(sshd_cmd)" || return 1
  mkdir -p /run/sshd
  "$sshd" -t >/dev/null 2>&1
}

sshd_effective_config_mismatch() {
  local target="$1" effective_file line key value actual
  tmpdir
  effective_file="${TMP_DIR}/sshd-effective.$$"
  sshd_effective_config > "$effective_file" || return 1

  while IFS= read -r line; do
    line="$(trim "$line")"
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    key="${line%%[[:space:]]*}"
    value="$(trim "${line#"$key"}")"
    [ -n "$key" ] && [ -n "$value" ] || return 1
    actual="$(
      awk -v k="$(lower "$key")" '
        $1 == k {
          $1 = ""
          sub(/^[[:space:]]+/, "")
          print
          exit
        }
      ' "$effective_file"
    )"
    if [ "$(normalize_sshd_value "$key" "$actual")" != "$(normalize_sshd_value "$key" "$value")" ]; then
      printf '%s expected=%s actual=%s; ' "$(lower "$key")" "$value" "${actual:-missing}"
    fi
  done <<EOF
$target
EOF
}

sshd_effective_config_matches() {
  local mismatch
  mismatch="$(sshd_effective_config_mismatch "$1")" || return 1
  [ -z "$mismatch" ]
}

ssh_hardening_ready() {
  local target="$1"
  content_matches_file "$SSH_HARDENING_CONF" "$target" &&
    sshd_config_valid &&
    sshd_effective_config_matches "$target"
}

restore_ssh_hardening() {
  local backup="$1" had_old="$2"
  if [ "$had_old" = "1" ]; then
    install -m 644 "$backup" "$SSH_HARDENING_CONF" >/dev/null 2>&1 || true
  else
    rm -f "$SSH_HARDENING_CONF"
  fi
}

reload_ssh_service() {
  local unit
  if command -v systemctl >/dev/null 2>&1; then
    for unit in ssh.service sshd.service; do
      systemctl is-active --quiet "$unit" >/dev/null 2>&1 || continue
      systemctl reload "$unit" >/dev/null 2>&1 && return 0
    done
    systemctl reload ssh.service >/dev/null 2>&1 && return 0
    systemctl reload sshd.service >/dev/null 2>&1 && return 0
  fi
  if command -v service >/dev/null 2>&1; then
    service ssh reload >/dev/null 2>&1 && return 0
    service sshd reload >/dev/null 2>&1 && return 0
  fi
  pkill -HUP -x sshd >/dev/null 2>&1
}

apply_ssh_hardening_config() {
  local target="$1" backup had_old=0 mismatch
  sshd_config_has_dropin_include || fail "sshd 主配置未启用 /etc/ssh/sshd_config.d/*.conf"
  mkdir -p "$(dirname "$SSH_HARDENING_CONF")"

  if ssh_hardening_ready "$target"; then
    log "ssh: skipped"
    return 0
  fi

  tmpdir
  backup="${TMP_DIR}/ssh-hardening.backup"
  if [ -f "$SSH_HARDENING_CONF" ]; then
    cp "$SSH_HARDENING_CONF" "$backup"
    had_old=1
  fi

  install_content_file "$SSH_HARDENING_CONF" 644 "$target" || fail "SSH 独立配置写入失败"
  if ! sshd_config_valid; then
    restore_ssh_hardening "$backup" "$had_old"
    fail "SSH 配置语法校验失败"
  fi
  mismatch="$(sshd_effective_config_mismatch "$target")" || {
    restore_ssh_hardening "$backup" "$had_old"
    fail "SSH 有效配置读取失败"
  }
  if [ -n "$mismatch" ]; then
    restore_ssh_hardening "$backup" "$had_old"
    fail "SSH 配置未生效: ${mismatch}"
  fi
  if ! run_quiet "ssh reload" reload_ssh_service; then
    restore_ssh_hardening "$backup" "$had_old"
    fail "SSH 服务重载失败"
  fi
  log "ssh: applied"
}

detect_ssh_ports() {
  local ports
  ports="$(
    sshd_effective_config |
      awk '$1=="port" && $2 ~ /^[0-9]+$/ && $2 >= 1 && $2 <= 65535 { print $2 }' |
      sort -un |
      tr '\n' ',' |
      sed 's/,$//'
  )"
  [ -n "$ports" ] || return 1
  printf '%s' "$ports"
}

validate_ipv4_cidr() {
  local value="$1" addr prefix a b c d
  [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || return 1
  addr="${value%%/*}"
  prefix=""
  [ "$addr" = "$value" ] || prefix="${value#*/}"
  local IFS=.
  read -r a b c d <<< "$addr"
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ ]] && [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
  if [ -n "$prefix" ]; then
    [[ "$prefix" =~ ^[0-9]+$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
  fi
}

render_ssh_allowed_elements() {
  local block="$1" line first=1
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [ -n "$line" ] || continue
    validate_ipv4_cidr "$line" || fail "SSH allowlist 包含无效 IPv4: $line"
    if [ "$first" = "1" ]; then
      printf '            %s' "$line"
      first=0
    else
      printf ',\n            %s' "$line"
    fi
  done <<EOF
$block
EOF
  [ "$first" = "0" ] || fail "SSH allowlist 为空"
  printf '\n'
}

render_ssh_nft_config() {
  local allowed_ipv4="$1" ports="$2"
  cat <<EOF
#!/usr/sbin/nft -f
# generated by run.sh

table inet ${SSH_NFT_TABLE}
delete table inet ${SSH_NFT_TABLE}

table inet ${SSH_NFT_TABLE} {
    set allowed_ipv4 {
        type ipv4_addr
        flags interval
        elements = {
$(render_ssh_allowed_elements "$allowed_ipv4")        }
    }

    chain input {
        type filter hook input priority -20; policy accept;
        ct state established,related accept
        iifname "lo" accept
        meta nfproto ipv4 tcp dport { ${ports} } ip saddr @allowed_ipv4 accept
        meta nfproto ipv4 tcp dport { ${ports} } drop
        meta nfproto ipv6 tcp dport { ${ports} } drop
    }
}
EOF
}

nft_main_config_has_ssh_include() {
  [ -f "$NFT_MAIN_CONFIG" ] || return 1
  grep -Eq '^[[:space:]]*include[[:space:]]+"?(/etc/nftables\.d/\*\.nft|/etc/nftables\.d/cloudserver-ssh\.nft)"?' "$NFT_MAIN_CONFIG"
}

ensure_nft_main_config_ssh_include() {
  mkdir -p "$NFT_INCLUDE_DIR"
  touch "$NFT_MAIN_CONFIG" || return 1
  nft_main_config_has_ssh_include && return 0
  printf '\ninclude "/etc/nftables.d/cloudserver-ssh.nft"\n' >> "$NFT_MAIN_CONFIG"
}

ssh_nft_live_ready() {
  nft list table inet "$SSH_NFT_TABLE" >/dev/null 2>&1
}

ssh_nft_config_valid() {
  local file="$1"
  nft -c -f "$file" >/dev/null 2>&1
}

ssh_nft_ready() {
  local target="$1"
  content_matches_file "$SSH_NFT_CONF" "$target" &&
    nft_main_config_has_ssh_include &&
    ssh_nft_config_valid "$SSH_NFT_CONF" &&
    ssh_nft_live_ready
}

apply_ssh_nft_config() {
  local target="$1" ports="$2" tmp
  tmpdir
  tmp="${TMP_DIR}/cloudserver-ssh.nft"
  printf '%s\n' "$target" > "$tmp"
  nft -c -f "$tmp" >/dev/null 2>&1 || fail "SSH nft 配置预检失败"

  if ssh_nft_ready "$target"; then
    log "ssh-nft: skipped | ports=${ports}"
    return 0
  fi

  install_content_file "$SSH_NFT_CONF" 600 "$target" || fail "SSH nft 独立配置写入失败"
  ensure_nft_main_config_ssh_include || fail "nftables 主配置 include 写入失败"
  nft -f "$SSH_NFT_CONF" >/dev/null 2>&1 || fail "SSH nft 配置应用失败"
  ssh_nft_live_ready || fail "SSH nft live table 校验失败"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable nftables.service >/dev/null 2>&1 || true
  fi
  log "ssh-nft: applied | ports=${ports}"
}

step_ssh_hardening() {
  local ssh_config allowed_ipv4 ports nft_config
  [ "$#" -eq 2 ] || fail "step_ssh_hardening 需要 SSH config 和 allowlist"
  ssh_config="$(normalize_block "$1")"
  allowed_ipv4="$(normalize_block "$2")"
  [ -n "$ssh_config" ] || fail "SSH config 为空"
  [ -n "$allowed_ipv4" ] || fail "SSH allowlist 为空"

  ensure_packages openssh-server nftables
  apply_ssh_hardening_config "$ssh_config"
  ports="$(detect_ssh_ports)" || fail "无法识别 SSH 端口"
  nft_config="$(render_ssh_nft_config "$allowed_ipv4" "$ports")"
  apply_ssh_nft_config "$nft_config" "$ports"
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
    log "proxy: removed | type=${type} | reason=stale"
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
    log "dns: cleaned | script=${script} | reason=unused"
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
    log "dns: removed | type=${other} | reason=conflict"
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

  if service_exists "$service" || [ -e "$config" ] || [ -e "$binary" ]; then
    provider_run "dns uninstall ${type}" "$script" "$uninstall" || fail "${type} 卸载失败"
    log "dns: removed | type=${type} | reason=stale"
  fi

  remove_other_dns "$type"
  provider_run "dns install ${type}" "$script" "$@" || fail "${type} 安装失败"
  service_usable "$service" "$config" "$port" || fail "${type} 安装后不可用"
  cleanup_other_dns_script "$type"
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
        log "traffic: applied | mode=forward | action=replace"
      else
        provider_run "nftables add" "$script" -a "$@" || fail "nftables 配置失败"
        log "traffic: applied | mode=forward | action=add"
      fi
      ;;
    protect)
      if forwardaws_exists; then
        log "traffic: skipped | mode=protect"
      else
        provider_run "nftables protect" "$script" --protect on || fail "nftables 防护配置失败"
        log "traffic: applied | mode=protect"
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
  log "workflow: done"
}

main "$@"
