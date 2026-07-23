#!/bin/bash

set -o pipefail

readonly SERVICE="mosdns.service"
readonly BIN="/usr/local/bin/mosdns"
readonly CONFIG_DIR="/etc/mosdns"
readonly CONFIG_FILE="${CONFIG_DIR}/config.yaml"
readonly RULE_DIR="${CONFIG_DIR}/rule"
readonly RESOLV_CONF="/etc/resolv.conf"
readonly PUBLIC_DNS=$'nameserver 8.8.8.8\nnameserver 1.1.1.1\n'
CUSTOM_DNS=""
ECS_REGION="TYO"
ECS_IP=""
IP_PRIORITY="prefer_ipv4"
UNINSTALL=0
INSTALL_ARGS=0

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
  bash mosdns.sh [--install] [--dns DNS] [--ecs HK|TYO|LA|OR|SEA] [--ipv4|--ipv6]
  bash mosdns.sh --uninstall
参数：
  -i, --install           显式安装 MosDNS，可省略
  -d, --dns DNS           自定义 DNS 服务器
  -e, --ecs REGION        ECS 区域：HK、TYO、LA、OR、SEA；默认 TYO
  -4, --ipv4              IPv4 优先，默认模式
  -6, --ipv6              IPv6 优先
  -u, --uninstall         卸载 MosDNS
  -h, --help              显示帮助
无参数时使用默认配置安装 MosDNS。
EOF
}

parse_args() {
    local -A address_by_region=(
        [HK]="42.2.2.2"
        [TYO]="106.152.210.210"
        [LA]="107.119.53.53"
        [OR]="12.75.216.200"
        [SEA]="68.86.93.93"
    )
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
            -i|--install)
                INSTALL_ARGS=1
                shift
                ;;
            -d|--dns)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    fail "--dns 缺少服务器地址"
                fi
                [[ "$2" =~ ^[][A-Za-z0-9.:-]+$ ]] || fail "无效的 DNS 服务器地址：$2"
                CUSTOM_DNS="$2"
                INSTALL_ARGS=1
                shift 2
                ;;
            -e|--ecs)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    fail "--ecs 缺少区域"
                fi
                ECS_REGION="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
                INSTALL_ARGS=1
                shift 2
                ;;
            -4|--ipv4)
                IP_PRIORITY="prefer_ipv4"
                INSTALL_ARGS=1
                shift
                ;;
            -6|--ipv6)
                IP_PRIORITY="prefer_ipv6"
                INSTALL_ARGS=1
                shift
                ;;
            *)
                fail "未知参数：$1"
                ;;
        esac
    done
    if [ "$UNINSTALL" -eq 1 ]; then
        [ "$INSTALL_ARGS" -eq 0 ] || fail "卸载参数不能与安装参数混用"
        return 0
    fi
    ECS_IP="${address_by_region[$ECS_REGION]:-}"
    [ -n "$ECS_IP" ] || fail "无效的 ECS 区域：$ECS_REGION"
}

require_environment() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || fail "此操作必须以 root 权限运行"
    command -v apt-get >/dev/null 2>&1 || fail "仅支持 Debian/Ubuntu apt-get 环境"
    command -v systemctl >/dev/null 2>&1 || fail "未检测到 systemd"
}

ensure_dependencies() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v unzip >/dev/null 2>&1 || missing+=(unzip)
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    command -v diff >/dev/null 2>&1 || missing+=(diffutils)
    [ -e /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)
    [ "${#missing[@]}" -gt 0 ] || return 0
    log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || fail "软件包索引更新失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    log_info "已安装依赖：${missing[*]}"
}

download() {
    if curl -fSsL --connect-timeout 10 --max-time 120 --retry 2 -o "$2" "$1" && [ -s "$2" ]; then
        return 0
    fi
    rm -f "$2"
    return 1
}

udp53_listeners() {
    ss -H -lun 2>/dev/null |
        awk '$4 ~ /(^|\[::\]|0\.0\.0\.0|127\.0\.0\.1|\*):53$/ { print }'
}

install_binary() {
    local arch machine tmp_dir url
    local -A arch_by_machine=(
        [x86_64]="amd64"
        [aarch64]="arm64"
    )
    machine="$(uname -m)"
    arch="${arch_by_machine[$machine]:-}"
    [ -n "$arch" ] || fail "不支持的系统架构：$machine"
    url="https://github.com/IrineSistiana/mosdns/releases/latest/download/mosdns-linux-${arch}.zip"
    tmp_dir="$(mktemp -d)" || fail "无法创建 MosDNS 临时目录"
    if ! download "$url" "${tmp_dir}/mosdns.zip" ||
        ! unzip -q "${tmp_dir}/mosdns.zip" -d "$tmp_dir" ||
        ! chmod 755 "${tmp_dir}/mosdns" ||
        ! "${tmp_dir}/mosdns" version >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        fail "MosDNS 下载或解包失败"
    fi
    if ! mkdir -p "$(dirname "$BIN")" || ! install -m 755 "${tmp_dir}/mosdns" "$BIN"; then
        rm -rf "$tmp_dir"
        fail "无法发布 MosDNS 程序"
    fi
    rm -rf "$tmp_dir"
}

download_domain_rules() {
    local stage name
    local base_url="https://mirror.1991991.xyz/RuleSet/Extra/MosDNS"
    RULES_CHANGED=0
    if [ -z "$CUSTOM_DNS" ]; then
        if [ -d "$RULE_DIR" ]; then
            rm -rf "$RULE_DIR" || fail "无法删除 MosDNS 自定义规则"
            RULES_CHANGED=1
        fi
        return 0
    fi
    mkdir -p "$CONFIG_DIR" || fail "无法创建 MosDNS 配置目录"
    stage="$(mktemp -d "${CONFIG_DIR}/rule.tmp.XXXXXX")" || fail "无法创建规则候选目录"
    for name in google reddit; do
        download "${base_url}/${name}.txt" "${stage}/${name}.txt" || {
            rm -rf "$stage"
            fail "域名规则下载失败：${name}.txt"
        }
    done
    if [ -d "$RULE_DIR" ] && diff -qr "$stage" "$RULE_DIR" >/dev/null 2>&1; then
        rm -rf "$stage"
        return 0
    fi
    if ! rm -rf "$RULE_DIR" || ! mv "$stage" "$RULE_DIR"; then
        rm -rf "$stage"
        fail "无法发布 MosDNS 域名规则"
    fi
    RULES_CHANGED=1
}

render_config() {
    {
        cat <<EOF
log:
  level: error
  file: "${CONFIG_DIR}/mosdns.log"

plugins:
  - tag: cache
    type: cache
    args:
      size: 8192
      lazy_cache_ttl: 86400
      dump_file: "${CONFIG_DIR}/cache.dump"
      dump_interval: 1800

EOF
        if [ -n "$CUSTOM_DNS" ]; then
            cat <<'EOF'
  - tag: custom_domains
    type: domain_set
    args:
      files:
EOF
            printf '        - "%s"\n' "${RULE_DIR}/google.txt" "${RULE_DIR}/reddit.txt"
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
    } > "$1"
}

write_config() {
    local candidate
    mkdir -p "$CONFIG_DIR" || fail "无法创建 MosDNS 配置目录"
    candidate="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || fail "无法创建 MosDNS 候选配置"
    if ! render_config "$candidate" || [ ! -s "$candidate" ]; then
        rm -f "$candidate"
        fail "无法生成 MosDNS 配置"
    fi
    CONFIG_CHANGED=0
    if cmp -s "$candidate" "$CONFIG_FILE" 2>/dev/null; then
        rm -f "$candidate"
        return 0
    fi
    if ! chmod 644 "$candidate" || ! mv -f "$candidate" "$CONFIG_FILE"; then
        rm -f "$candidate"
        fail "无法发布 MosDNS 配置"
    fi
    CONFIG_CHANGED=1
}

set_dns() {
    local mode="$1" candidate content message
    candidate="$(mktemp "${RESOLV_CONF}.tmp.XXXXXX")" || fail "无法创建 DNS 候选配置"
    if [ "$mode" = "local" ]; then
        content=$'nameserver 127.0.0.1\n'
        message="已将系统 DNS 设置为 127.0.0.1"
    else
        content="$PUBLIC_DNS"
        message="已恢复公共 DNS：8.8.8.8、1.1.1.1"
    fi
    printf '%s' "$content" > "$candidate" || fail "无法生成 DNS 候选配置"
    chattr -i "$RESOLV_CONF" 2>/dev/null || true
    if cmp -s "$candidate" "$RESOLV_CONF" 2>/dev/null; then
        rm -f "$candidate"
        [ "$mode" != "local" ] || chattr +i "$RESOLV_CONF" 2>/dev/null || true
        return 0
    fi
    if ! chmod 644 "$candidate" || ! mv -f "$candidate" "$RESOLV_CONF"; then
        rm -f "$candidate"
        fail "无法更新系统 DNS"
    fi
    [ "$mode" != "local" ] || chattr +i "$RESOLV_CONF" 2>/dev/null || true
    log_info "$message"
}

apply_mosdns() {
    local restart_needed=0 service_exists=0
    ensure_dependencies
    systemctl cat "$SERVICE" >/dev/null 2>&1 && service_exists=1
    if [ "$service_exists" -eq 0 ]; then
        [ -z "$(udp53_listeners)" ] || fail "53 端口已被其他 DNS 服务占用"
    fi
    if [ "$service_exists" -eq 0 ] || [ ! -x "$BIN" ]; then
        log_info "正在安装 MosDNS"
        install_binary
        restart_needed=1
    fi
    download_domain_rules
    write_config
    if [ "$CONFIG_CHANGED" -eq 1 ] || [ "$RULES_CHANGED" -eq 1 ] ||
        ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        restart_needed=1
    fi
    if [ "$service_exists" -eq 1 ]; then
        if [ "$restart_needed" -eq 1 ]; then
            systemctl restart "$SERVICE" >/dev/null 2>&1 ||
                fail "MosDNS 启动失败，请执行：journalctl -u ${SERVICE} --no-pager"
        fi
    else
        "$BIN" service install -d "$CONFIG_DIR" -c "$CONFIG_FILE" >/dev/null 2>&1 || fail "MosDNS 服务安装失败"
        "$BIN" service start >/dev/null 2>&1 || fail "MosDNS 服务启动失败"
    fi
    if ! systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
        systemctl enable "$SERVICE" >/dev/null 2>&1 || fail "无法启用 MosDNS 服务"
        log_info "已启用系统服务：${SERVICE}"
    fi
    systemctl is-active --quiet "$SERVICE" || fail "MosDNS 服务未运行"
    set_dns local
    if [ "$restart_needed" -eq 1 ]; then
        log_info "MosDNS 已启动，服务地址：127.0.0.1:53"
    else
        log_info "MosDNS 配置未变化，无需重新应用"
    fi
}

uninstall_mosdns() {
    if ! systemctl cat "$SERVICE" >/dev/null 2>&1 && [ ! -x "$BIN" ] && [ ! -e "$CONFIG_DIR" ]; then
        log_info "MosDNS 已不存在，无需卸载"
        return 0
    fi
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        systemctl stop "$SERVICE" >/dev/null 2>&1 || fail "无法停止 MosDNS 服务"
        log_info "已停止系统服务：${SERVICE}"
    fi
    if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
        systemctl disable "$SERVICE" >/dev/null 2>&1 || fail "无法禁用 MosDNS 服务"
        log_info "已禁用系统服务：${SERVICE}"
    fi
    rm -f "/etc/systemd/system/$SERVICE" "/lib/systemd/system/$SERVICE" "/usr/lib/systemd/system/$SERVICE" ||
        fail "无法删除 MosDNS service 文件"
    rm -f "$BIN" || fail "无法删除 MosDNS 程序"
    rm -rf "$CONFIG_DIR" || fail "无法删除 MosDNS 配置目录"
    systemctl daemon-reload >/dev/null 2>&1 || fail "systemd 配置刷新失败"
    systemctl is-active --quiet "$SERVICE" 2>/dev/null && fail "MosDNS 服务仍在运行"
    set_dns public
    log_info "MosDNS 已卸载，并恢复公共 DNS"
}

main() {
    parse_args "$@"
    require_environment
    if [ "$UNINSTALL" -eq 1 ]; then
        uninstall_mosdns
    else
        apply_mosdns
    fi
}

main "$@"
