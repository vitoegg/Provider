#!/bin/bash

set -o pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly CONFIG_FILE="/etc/danted.conf"
readonly SERVICE_NAME="danted.service"
readonly NFT_CONFIG_FILE="/etc/nftables.conf"
readonly NFT_RULES_FILE="/etc/nftables.d/socks.nft"
readonly NFT_TABLE="socks_guard"
PORT=""
UNINSTALL=0
ALLOW_IPS=()

log_info() {
    printf '[INFO] %s\n' "$*"
}

log_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

fail() {
    log_error "$*"
    exit 1
}

show_help() {
    cat <<'EOF'
用法：
  bash socks.sh [--port PORT] --allow-ip IP[,IP...]
参数：
  --port PORT             监听端口；未提供时自动生成
  --allow-ip IP[,IP...]   允许访问的 IPv4；必填，可重复使用
  -u, --uninstall         卸载 Dante
  -h, --help              显示帮助
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -u|--uninstall)
                UNINSTALL=1
                shift
                ;;
            --port)
                [ -n "${2:-}" ] || fail "--port 缺少参数"
                [ -z "$PORT" ] || fail "--port 不能重复提供"
                PORT="$2"
                shift 2
                ;;
            --allow-ip)
                [ -n "${2:-}" ] || fail "--allow-ip 缺少参数"
                add_allow_list "$2"
                shift 2
                ;;
            *)
                fail "未知参数：$1"
                ;;
        esac
    done
    if [ "$UNINSTALL" -eq 1 ]; then
        [ -z "$PORT" ] || fail "卸载参数不能与配置参数混用"
        [ "${#ALLOW_IPS[@]}" -eq 0 ] || fail "卸载参数不能与配置参数混用"
        return 0
    fi
    [ "${#ALLOW_IPS[@]}" -gt 0 ] || fail "必须提供至少一个 --allow-ip"
    if [ -n "$PORT" ]; then
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            fail "端口必须是 1-65535 的整数"
        fi
    fi
}

validate_ipv4() {
    local IFS='.' ip="$1" octet octets
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        [ "$octet" -le 255 ] || return 1
    done
}

add_allow_list() {
    local value="$1" ip ips
    if [[ "$value" == ,* || "$value" == *, || "$value" == *,,* || "$value" == *$'\n'* ]]; then
        fail "--allow-ip 包含空值"
    fi
    IFS=',' read -ra ips <<< "$value"
    for ip in "${ips[@]}"; do
        validate_ipv4 "$ip" || fail "无效的白名单 IPv4：$ip"
        if [[ " ${ALLOW_IPS[*]} " == *" $ip "* ]]; then
            continue
        fi
        ALLOW_IPS+=("$ip")
    done
}

ensure_dependencies() {
    local missing=()
    [ -x /usr/sbin/danted ] || missing+=(dante-server)
    [ -x /usr/sbin/nft ] || missing+=(nftables)
    if ! command -v ip >/dev/null 2>&1 || ! command -v ss >/dev/null 2>&1; then
        missing+=(iproute2)
    fi
    [ "${#missing[@]}" -gt 0 ] || return 0
    log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || fail "软件包索引更新失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    log_info "已安装依赖：${missing[*]}"
}

enable_service_if_needed() {
    systemctl is-enabled --quiet "$1" 2>/dev/null && return 0
    systemctl enable "$1" >/dev/null 2>&1 || fail "无法启用服务：$1"
    log_info "已启用服务：$1"
}

prepare_port() {
    local candidate listeners
    [ -n "$PORT" ] && return 0
    while true; do
        candidate=$((RANDOM % 10001 + 20000))
        if [[ "$candidate" == *4* ]]; then
            continue
        fi
        listeners="$(ss -H -lntu "sport = :$candidate" 2>/dev/null)" || fail "无法读取当前监听端口"
        if [ -z "$listeners" ]; then
            PORT="$candidate"
            return 0
        fi
    done
}

apply_config() (
    local IFS=, interface ip config_candidate nft_candidate nft_changed=0
    interface="$(ip -4 route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)"
    [ -n "$interface" ] || fail "无法确定默认 IPv4 出口网卡"
    mkdir -p "$(dirname "$CONFIG_FILE")" "$(dirname "$NFT_RULES_FILE")" || fail "无法创建 SOCKS 配置目录"
    config_candidate="$(mktemp "${CONFIG_FILE}.XXXXXX")" || fail "无法创建 Dante 配置候选"
    trap 'rm -f "$config_candidate" "$nft_candidate"' EXIT
    nft_candidate="$(mktemp "${NFT_RULES_FILE}.XXXXXX")" || fail "无法创建 SOCKS NFT 规则候选"
    cat > "$config_candidate" <<EOF
logoutput: /dev/null

internal: 0.0.0.0 port = ${PORT}
external: ${interface}

user.privileged: root
user.notprivileged: nobody

clientmethod: none
socksmethod: none
EOF
    for ip in "${ALLOW_IPS[@]}"; do
        cat >> "$config_candidate" <<EOF

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
    cat > "$nft_candidate" <<EOF
#!/usr/sbin/nft -f

table inet ${NFT_TABLE}
delete table inet ${NFT_TABLE}

table inet ${NFT_TABLE} {
    set allowed_ipv4 {
        type ipv4_addr
        elements = { ${ALLOW_IPS[*]} }
    }

    chain input {
        type filter hook input priority -20; policy accept;
        meta nfproto ipv4 tcp dport ${PORT} ip saddr @allowed_ipv4 accept
        tcp dport ${PORT} drop
        udp dport ${PORT} drop
    }
}
EOF
    /usr/sbin/danted -V -f "$config_candidate" >/dev/null 2>&1 || fail "Dante 配置预检失败"
    /usr/sbin/nft -c -f "$nft_candidate" >/dev/null 2>&1 || fail "SOCKS NFT 规则预检失败"
    if ! grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nftables[.]d/([*]|socks)[.]nft"?[[:space:]]*$' \
        "$NFT_CONFIG_FILE" 2>/dev/null; then
        printf '\ninclude "/etc/nftables.d/socks.nft"\n' >> "$NFT_CONFIG_FILE" || fail "无法写入 nftables include"
        log_info "已添加 SOCKS nftables 持久化规则"
    fi
    enable_service_if_needed nftables.service
    if ! cmp -s "$nft_candidate" "$NFT_RULES_FILE" 2>/dev/null; then
        mv -f "$nft_candidate" "$NFT_RULES_FILE" || fail "无法发布 SOCKS NFT 规则"
        nft_changed=1
    fi
    if [ "$nft_changed" -eq 1 ] || ! /usr/sbin/nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        /usr/sbin/nft -f "$NFT_RULES_FILE" >/dev/null 2>&1 ||
            fail "无法应用 SOCKS NFT 规则，请检查：nft list table inet ${NFT_TABLE}"
    fi
    enable_service_if_needed "$SERVICE_NAME"
    if ! cmp -s "$config_candidate" "$CONFIG_FILE" 2>/dev/null; then
        mv -f "$config_candidate" "$CONFIG_FILE" || fail "无法发布 Dante 配置"
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 ||
            fail "Dante 重启失败，请执行：journalctl -u ${SERVICE_NAME} --no-pager"
    elif ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || fail "Dante 启动失败"
    fi
    systemctl is-active --quiet "$SERVICE_NAME" || fail "Dante 服务未运行"
)

uninstall_dante() {
    local nft_present=0
    if [ -x /usr/sbin/nft ] && /usr/sbin/nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        nft_present=1
    elif [ -x /usr/sbin/nft ] && ! /usr/sbin/nft list tables >/dev/null 2>&1; then
        fail "无法读取 nftables 状态，卸载未完成"
    fi
    if ! systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null &&
        ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null &&
        ! dpkg-query -W -f='${db:Status-Abbrev}' dante-server 2>/dev/null | grep -q '^ii ' &&
        [ ! -e "$CONFIG_FILE" ] && [ ! -e "$NFT_RULES_FILE" ] &&
        ! grep -Eq '/etc/nftables[.]d/socks[.]nft' "$NFT_CONFIG_FILE" 2>/dev/null &&
        [ "$nft_present" -eq 0 ]; then
        log_info "Dante SOCKS 已不存在，无需卸载"
        return 0
    fi
    [ -x /usr/sbin/nft ] || fail "无法读取 nftables 状态，卸载未完成"
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null ||
        systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || fail "无法停止并禁用 Dante 服务"
        log_info "已停止并禁用服务：${SERVICE_NAME}"
    fi
    if dpkg-query -W -f='${db:Status-Abbrev}' dante-server 2>/dev/null | grep -q '^ii '; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq dante-server >/dev/null 2>&1 ||
            fail "卸载 Dante 失败"
        log_info "已卸载软件包：dante-server"
    fi
    if [ "$nft_present" -eq 1 ]; then
        /usr/sbin/nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || fail "删除 SOCKS NFT 表失败"
    fi
    rm -f "$CONFIG_FILE" "$NFT_RULES_FILE" || fail "删除 Dante 配置失败"
    if [ -f "$NFT_CONFIG_FILE" ] && grep -Eq '/etc/nftables[.]d/socks[.]nft' "$NFT_CONFIG_FILE"; then
        sed -i.bak '\|/etc/nftables[.]d/socks[.]nft|d' "$NFT_CONFIG_FILE" || fail "清理 socks.nft include 失败"
        rm -f "${NFT_CONFIG_FILE}.bak"
    fi
    log_info "Dante SOCKS 已卸载"
}

main() {
    parse_args "$@"
    [ "$(id -u)" = "0" ] || fail "此操作必须以 root 权限运行"
    command -v apt-get >/dev/null 2>&1 || fail "仅支持 Debian/Ubuntu apt-get 环境"
    command -v systemctl >/dev/null 2>&1 || fail "未检测到 systemd"
    if [ "$UNINSTALL" -eq 1 ]; then
        uninstall_dante
        return 0
    fi
    ensure_dependencies
    prepare_port
    apply_config || return 1
    log_info "Dante SOCKS 已运行，端口：${PORT}，白名单：${#ALLOW_IPS[@]} 个地址"
}

main "$@"
