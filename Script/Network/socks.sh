#!/bin/bash

set -o pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly CONFIG_FILE="/etc/danted.conf"
readonly SERVICE_NAME="danted.service"
readonly NFT_CONFIG_FILE="/etc/nftables.conf"
readonly NFT_RULES_FILE="/etc/nftables.d/socks.nft"
readonly NFT_TABLE="socks_guard"
readonly DEFAULT_PORT_START=20000
readonly DEFAULT_PORT_END=30000

PORT=""
UNINSTALL=0
ALLOW_IPS=()

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
else
    RED=''; GREEN=''; NC=''
fi
readonly RED GREEN NC

log_info()  { printf '%b\n' "${GREEN}[INFO]${NC} $1"; }
log_error() { printf '%b\n' "${RED}[ERROR]${NC} $1" >&2; }
fail() { log_error "$1"; exit 1; }

usage() {
    cat <<'EOF'
用法：
  bash socks.sh [--port PORT] --allow-ip IP[,IP...]
  bash socks.sh --uninstall

参数：
  --port PORT             监听端口；未提供时自动生成
  --allow-ip IP[,IP...]   允许访问的 IPv4；必填，可重复使用
  -u, --uninstall         卸载 Dante
  -h, --help              显示帮助
EOF
}

validate_ipv4() {
    local ip="$1" octet
    local IFS='.'
    local -a octets
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    read -ra octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$octet" -le 255 ] || return 1
    done
}

add_allow_list() {
    local value="$1" ip existing
    local -a ips
    [ -n "$value" ] || fail "--allow-ip 不能为空"
    case "$value" in ,*|*,|*,,*) fail "--allow-ip 包含空值" ;; esac
    IFS=',' read -ra ips <<< "$value"
    for ip in "${ips[@]}"; do
        validate_ipv4 "$ip" || fail "无效的白名单 IPv4: $ip"
        for existing in "${ALLOW_IPS[@]}"; do
            [ "$existing" = "$ip" ] && continue 2
        done
        ALLOW_IPS+=("$ip")
    done
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -u|--uninstall) UNINSTALL=1; shift ;;
            --port)
                [ -n "${2:-}" ] || fail "--port 缺少参数"
                [ -z "$PORT" ] || fail "--port 不能重复提供"
                PORT="$2"; shift 2
                ;;
            --allow-ip)
                [ -n "${2:-}" ] || fail "--allow-ip 缺少参数"
                add_allow_list "$2"; shift 2
                ;;
            *) fail "未知参数: $1" ;;
        esac
    done
    if [ "$UNINSTALL" -eq 1 ]; then
        [ -z "$PORT" ] && [ "${#ALLOW_IPS[@]}" -eq 0 ] || fail "--uninstall 不能与配置参数同时使用"
        return 0
    fi
    [ "${#ALLOW_IPS[@]}" -gt 0 ] || fail "必须提供至少一个 --allow-ip"
    [ -z "$PORT" ] || { [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; } ||
        fail "端口必须是 1-65535 的整数"
}

require_environment() {
    [ "$(id -u)" = "0" ] || fail "此操作必须以 root 权限运行"
    command -v apt-get >/dev/null 2>&1 || fail "仅支持 Debian/Ubuntu apt 环境"
    command -v systemctl >/dev/null 2>&1 || fail "未检测到 systemd"
}

ensure_environment() {
    require_environment
    if [ ! -x /usr/sbin/danted ] || [ ! -x /usr/sbin/nft ] ||
        ! command -v ip >/dev/null 2>&1 || ! command -v ss >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || fail "apt-get update 失败"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dante-server iproute2 nftables >/dev/null 2>&1 ||
            fail "安装 Dante 依赖失败"
        log_info "已安装 Dante 依赖"
    fi
    [ -x /usr/sbin/danted ] || fail "未检测到 danted"
    [ -x /usr/sbin/nft ] || fail "未检测到 nft"
    command -v shuf >/dev/null 2>&1 || fail "未检测到 shuf"
}

ensure_nft_include() {
    mkdir -p "$(dirname "$NFT_RULES_FILE")" || fail "无法创建 NFT 规则目录"
    touch "$NFT_CONFIG_FILE" || fail "无法访问 nftables 主配置"
    grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/(\*|socks)\.nft"?[[:space:]]*$' "$NFT_CONFIG_FILE" && return 0
    printf '\ninclude "/etc/nftables.d/socks.nft"\n' >> "$NFT_CONFIG_FILE" || fail "无法写入 nftables include"
}

dante_present() {
    dpkg-query -W -f='${db:Status-Abbrev}' dante-server 2>/dev/null | grep -q '^ii ' && return 0
    systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 && return 0
    if [ -e "$CONFIG_FILE" ] || [ -e "$NFT_RULES_FILE" ] || [ -x /usr/sbin/danted ]; then
        return 0
    fi
    [ -x /usr/sbin/nft ] && /usr/sbin/nft list table inet "$NFT_TABLE" >/dev/null 2>&1
}

uninstall_dante() {
    local nft_config_tmp="${NFT_CONFIG_FILE}.socks.tmp"
    require_environment
    if ! dante_present; then
        log_info "Dante 已不存在"
        return 0
    fi
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq dante-server >/dev/null 2>&1 || fail "卸载 Dante 失败"
    rm -f "$CONFIG_FILE" "${CONFIG_FILE}.tmp" || fail "删除 Dante 配置失败"
    if [ -x /usr/sbin/nft ]; then
        if /usr/sbin/nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
            /usr/sbin/nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || fail "删除 SOCKS NFT 表失败"
        fi
    fi
    rm -f "$NFT_RULES_FILE" "${NFT_RULES_FILE}.tmp" || fail "删除 SOCKS NFT 规则失败"
    if [ -f "$NFT_CONFIG_FILE" ]; then
        awk '$0 !~ /^[[:space:]]*include[[:space:]]*"\/etc\/nftables[.]d\/socks[.]nft"[[:space:]]*$/' \
            "$NFT_CONFIG_FILE" > "$nft_config_tmp" && mv -f "$nft_config_tmp" "$NFT_CONFIG_FILE" || {
                rm -f "$nft_config_tmp"
                fail "清理 socks.nft include 失败"
            }
    fi
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && fail "Dante 服务仍在运行"
    [ ! -x /usr/sbin/danted ] && [ ! -e "$CONFIG_FILE" ] && [ ! -e "$NFT_RULES_FILE" ] || fail "Dante 卸载不完整"
    log_info "Dante 已卸载"
}

port_in_use() {
    ss -H -ltn 2>/dev/null | awk -v port="$1" '
        { address = $4; sub(/^.*:/, "", address); if (address == port) found = 1 }
        END { exit !found }
    '
}

prepare_port() {
    local candidate
    [ -n "$PORT" ] && return 0
    while true; do
        candidate="$(shuf -i "${DEFAULT_PORT_START}-${DEFAULT_PORT_END}" -n 1)" || fail "生成随机端口失败"
        [[ "$candidate" == *4* ]] && continue
        port_in_use "$candidate" || { PORT="$candidate"; return 0; }
    done
}

apply_config() {
    local interface ip allowed_ips
    local config_tmp="${CONFIG_FILE}.tmp" nft_tmp="${NFT_RULES_FILE}.tmp"
    interface="$(ip -4 route show default | awk '$1 == "default" { for (i=1; i<NF; i++) if ($i == "dev") { print $(i+1); exit } }')"
    [ -n "$interface" ] || fail "无法确定默认 IPv4 出口网卡"
    allowed_ips="${ALLOW_IPS[*]}"
    allowed_ips="${allowed_ips// /, }"

    cat > "$config_tmp" <<EOF
logoutput: /dev/null

internal: 0.0.0.0 port = ${PORT}
external: ${interface}

user.privileged: root
user.notprivileged: nobody

clientmethod: none
socksmethod: none
EOF

    for ip in "${ALLOW_IPS[@]}"; do
        cat >> "$config_tmp" <<EOF

client pass {
    from: ${ip}/32 to: 0.0.0.0/0
}

socks pass {
    from: ${ip}/32 to: 0.0.0.0/0
    command: connect
    protocol: tcp
    proxyprotocol: socks_v5
}
EOF
    done

    ensure_nft_include

    cat > "$nft_tmp" <<EOF
#!/usr/sbin/nft -f

table inet ${NFT_TABLE}
delete table inet ${NFT_TABLE}

table inet ${NFT_TABLE} {
    set allowed_ipv4 {
        type ipv4_addr
        elements = { ${allowed_ips} }
    }

    chain input {
        type filter hook input priority -20; policy accept;
        meta nfproto ipv4 tcp dport ${PORT} ip saddr @allowed_ipv4 accept
        tcp dport ${PORT} drop
        udp dport ${PORT} drop
    }
}
EOF

    /usr/sbin/danted -V -f "$config_tmp" || { rm -f "$config_tmp" "$nft_tmp"; fail "Dante 配置校验失败"; }
    /usr/sbin/nft -c -f "$nft_tmp" >/dev/null 2>&1 || { rm -f "$config_tmp" "$nft_tmp"; fail "SOCKS NFT 规则校验失败"; }
    systemctl enable nftables.service >/dev/null 2>&1 || fail "无法启用 nftables 服务"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || fail "无法停止旧 Dante 服务"
    fi
    /usr/sbin/nft -f "$nft_tmp" >/dev/null 2>&1 || fail "无法应用 SOCKS NFT 规则"
    mv -f "$nft_tmp" "$NFT_RULES_FILE" || fail "无法持久化 SOCKS NFT 规则"
    mv -f "$config_tmp" "$CONFIG_FILE" || fail "无法覆盖 Dante 配置"
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || fail "无法启用 Dante 服务"
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || fail "无法启动 Dante 服务"
    systemctl is-active --quiet "$SERVICE_NAME" || fail "Dante 服务未运行"
}

main() {
    parse_args "$@"
    if [ "$UNINSTALL" -eq 1 ]; then
        uninstall_dante
        exit 0
    fi
    ensure_environment
    prepare_port
    apply_config
    log_info "Dante 配置已应用：端口 ${PORT}，白名单 ${#ALLOW_IPS[@]} 个"
}

main "$@"
