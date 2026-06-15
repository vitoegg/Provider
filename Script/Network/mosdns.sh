#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE="mosdns.service"
BIN="/usr/local/bin/mosdns"
CONFIG_DIR="/etc/mosdns"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
RULE_DIR="${CONFIG_DIR}/rule"
RESOLV_CONF="/etc/resolv.conf"
PUBLIC_DNS=$'nameserver 8.8.8.8\nnameserver 1.1.1.1\n'

ARCH=""
CUSTOM_DNS=""
ECS_REGION="TYO"
ECS_IP=""
IP_PRIORITY="prefer_ipv4"
UNINSTALL=0
INSTALL_ARGS=0
RULE_FILES=()

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
用法:
  $0 --install [--dns DNS服务器地址] [--ecs HK|TYO|LA|OR|SEA] [--ipv4|--ipv6]
  $0 --uninstall

参数:
  -i, --install           安装 mosdns
  -d, --dns DNS           自定义 DNS 服务器
  -e, --ecs REGION        ECS 区域: HK, TYO, LA, OR, SEA
  -4, --ipv4              IPv4 优先
  -6, --ipv6              IPv6 优先
  -u, --uninstall         卸载 mosdns
  -h, --help              显示帮助
EOF
}

DOMAIN_RULES=(
  "https://mirror.1991991.xyz/RuleSet/Extra/MosDNS/google.txt|google.txt"
  "https://mirror.1991991.xyz/RuleSet/Extra/MosDNS/reddit.txt|reddit.txt"
)

ecs_ip() {
  case "$1" in
    HK) printf '42.2.2.2' ;;
    TYO) printf '106.152.210.210' ;;
    LA) printf '107.119.53.53' ;;
    OR) printf '12.75.216.200' ;;
    SEA) printf '68.86.93.93' ;;
    *) return 1 ;;
  esac
}

parse_args() {
  [ "$#" -gt 0 ] || { usage >&2; exit 1; }

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -u|--uninstall) UNINSTALL=1; shift ;;
      -i|--install) INSTALL_ARGS=1; shift ;;
      -d|--dns)
        [ -n "${2:-}" ] && [[ "${2:-}" != -* ]] || fail "使用 -d 选项需要提供DNS服务器地址"
        INSTALL_ARGS=1
        CUSTOM_DNS="$2"
        shift 2
        ;;
      -e|--ecs)
        [ -n "${2:-}" ] && [[ "${2:-}" != -* ]] || fail "使用 -e 选项需要提供ECS位置 (HK/TYO/LA/OR/SEA)"
        INSTALL_ARGS=1
        ECS_REGION="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
        shift 2
        ;;
      -4|--ipv4) INSTALL_ARGS=1; IP_PRIORITY="prefer_ipv4"; shift ;;
      -6|--ipv6) INSTALL_ARGS=1; IP_PRIORITY="prefer_ipv6"; shift ;;
      *) usage >&2; fail "未知参数: $1" ;;
    esac
  done

  if [ "$UNINSTALL" -eq 1 ]; then
    [ "$INSTALL_ARGS" -eq 0 ] || fail "不能混用安装参数和卸载参数"
    return 0
  fi

  ECS_IP="$(ecs_ip "$ECS_REGION")" || fail "无效的ECS位置: $ECS_REGION"
}

require_root_systemd() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || fail "此脚本必须以root用户运行"
  command -v systemctl >/dev/null 2>&1 || fail "此脚本需要 systemd/systemctl"
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || fail "此脚本仅支持 Debian/Ubuntu apt 环境"
}

ensure_dependencies() {
  local missing=()
  command -v wget >/dev/null 2>&1 || missing+=(wget)
  command -v unzip >/dev/null 2>&1 || missing+=(unzip)
  command -v ss >/dev/null 2>&1 || missing+=(iproute2)
  [ -e /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)

  [ "${#missing[@]}" -eq 0 ] && return 0
  log "安装依赖: ${missing[*]}"
  env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null || fail "依赖包索引更新失败"
  env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null || fail "依赖安装失败"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) fail "不支持的系统架构: $(uname -m)" ;;
  esac
}

download_url() {
  printf 'https://github.com/IrineSistiana/mosdns/releases/latest/download/mosdns-linux-%s.zip' "$ARCH"
}

download() {
  wget -q -O "$2" "$1"
}

service_exists() {
  systemctl cat "$SERVICE" >/dev/null 2>&1 && return 0
  systemctl list-unit-files "$SERVICE" 2>/dev/null |
    awk -v unit="$SERVICE" '$1==unit { found=1 } END { exit !found }'
}

mosdns_exists() {
  service_exists || [ -x "$BIN" ] || [ -e "$CONFIG_DIR" ]
}

udp53_listeners() {
  ss -H -lunp 2>/dev/null | awk '
    function is_local_dns(addr) {
      return addr == "*:53" ||
             addr == "0.0.0.0:53" ||
             addr == "127.0.0.1:53" ||
             addr == "[::]:53" ||
             addr == "[::1]:53"
    }
    {
      for (i = 1; i <= NF; i++) {
        if (is_local_dns($i)) {
          print
          next
        }
      }
    }
  ' || true
}

port_53_free() {
  [ -z "$(udp53_listeners)" ]
}

service_owns_udp53() {
  local cgroup line pid
  cgroup="$(systemctl show "$SERVICE" --property=ControlGroup --value 2>/dev/null || true)"
  [ -n "$cgroup" ] || return 1

  while IFS= read -r line; do
    while IFS= read -r pid; do
      [ -r "/proc/${pid}/cgroup" ] || continue
      grep -Fq "$cgroup" "/proc/${pid}/cgroup" && return 0
    done < <(printf '%s\n' "$line" | grep -oE 'pid=[0-9]+' | cut -d= -f2 || true)
  done < <(udp53_listeners)
  return 1
}

set_dns() {
  chattr -i "$RESOLV_CONF" 2>/dev/null || true
  rm -f "$RESOLV_CONF"

  if [ "$1" = "local" ]; then
    printf 'nameserver 127.0.0.1\n' > "$RESOLV_CONF"
    chattr +i "$RESOLV_CONF" 2>/dev/null || true
  else
    printf '%s' "$PUBLIC_DNS" > "$RESOLV_CONF"
  fi
}

install_binary() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"

  if ! (
    cd "$tmp_dir"
    download "$(download_url)" mosdns.zip
    unzip -q mosdns.zip
    chmod 755 mosdns
    mv mosdns "$BIN"
  ); then
    rm -rf "$tmp_dir"
    fail "mosdns 下载或安装失败"
  fi

  rm -rf "$tmp_dir"
}

download_domain_rules() {
  local item url file
  [ -n "$CUSTOM_DNS" ] || return 0

  mkdir -p "$RULE_DIR"
  RULE_FILES=()
  for item in "${DOMAIN_RULES[@]}"; do
    url="${item%%|*}"
    file="${RULE_DIR}/${item##*|}"
    download "$url" "$file" || fail "域名列表下载失败: ${file##*/}"
    RULE_FILES+=("$file")
  done
}

write_config() {
  mkdir -p "$CONFIG_DIR"
  {
    cat <<'EOF'
log:
  level: error
  file: "/etc/mosdns/mosdns.log"

plugins:
  - tag: cache
    type: cache
    args:
      size: 8192
      lazy_cache_ttl: 86400
      dump_file: "/etc/mosdns/cache.dump"
      dump_interval: 1800

EOF

    if [ -n "$CUSTOM_DNS" ]; then
      cat <<'EOF'
  - tag: custom_domains
    type: domain_set
    args:
      files:
EOF
      printf '        - "%s"\n' "${RULE_FILES[@]}"
      cat <<EOF

  - tag: custom_dns
    type: forward
    args:
      upstreams:
        - addr: "udp://${CUSTOM_DNS}"

EOF
    fi

    cat <<'EOF'
  - tag: main_dns
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "udp://8.8.8.8"
        - addr: "udp://94.140.14.140"

  - tag: fallback_dns
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "udp://1.1.1.1"
        - addr: "udp://45.11.45.11"

  - tag: core_resolve
    type: fallback
    args:
      primary: main_dns
      secondary: fallback_dns
      threshold: 100
      always_standby: true

  - tag: main_sequence
    type: sequence
    args:
      - matches:
        - qtype 65
        exec: reject 3

      - exec: $cache
      - matches: has_resp
        exec: accept

EOF

    printf '      - exec: %s\n' "$IP_PRIORITY"
    printf '      - exec: ecs %s\n' "$ECS_IP"

    if [ -n "$CUSTOM_DNS" ]; then
      cat <<'EOF'

      - matches:
        - qname $custom_domains
        exec: $custom_dns
      - matches: has_resp
        exec: accept

EOF
    fi

    cat <<'EOF'
      - exec: $core_resolve

  - tag: udp_server
    type: udp_server
    args:
      entry: main_sequence
      listen: "127.0.0.1:53"
EOF
  } > "$CONFIG_FILE"
}

start_and_verify() {
  "$BIN" service install -d "$CONFIG_DIR" -c "$CONFIG_FILE" >/dev/null 2>&1 || fail "服务安装失败"
  "$BIN" service start >/dev/null || fail "服务启动失败"
  sleep 2

  systemctl is-active --quiet "$SERVICE" || fail "mosdns 服务未处于 active 状态"
  service_owns_udp53 || fail "mosdns 服务未监听 53 端口"
}

install_mosdns() {
  mosdns_exists && fail "mosdns 已存在或有残留，请先执行卸载操作"

  detect_arch
  require_apt
  ensure_dependencies
  port_53_free || fail "53 端口已被占用，请先停止其它 DNS 服务"

  install_binary
  download_domain_rules
  write_config
  start_and_verify

  set_dns local
  grep -qx 'nameserver 127.0.0.1' "$RESOLV_CONF" || fail "系统DNS配置失败"
  log "mosdns 安装完成"
}

uninstall_mosdns() {
  set_dns public
  grep -qx 'nameserver 8.8.8.8' "$RESOLV_CONF" || fail "DNS配置还原失败"
  grep -qx 'nameserver 1.1.1.1' "$RESOLV_CONF" || fail "DNS配置还原失败"

  if ! mosdns_exists; then
    warn "mosdns 未安装"
    return 0
  fi

  if [ -x "$BIN" ]; then
    "$BIN" service stop >/dev/null 2>&1 || true
    "$BIN" service uninstall >/dev/null 2>&1 || true
  else
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  fi

  systemctl disable "$SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$SERVICE" "/lib/systemd/system/$SERVICE" "/usr/lib/systemd/system/$SERVICE"
  rm -f "$BIN"
  rm -rf "$CONFIG_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl is-active --quiet "$SERVICE" 2>/dev/null && fail "mosdns 服务仍处于 active 状态"
  log "mosdns 卸载完成"
}

main() {
  parse_args "$@"
  require_root_systemd

  if [ "$UNINSTALL" -eq 1 ]; then
    uninstall_mosdns
  else
    install_mosdns
  fi
}

main "$@"
