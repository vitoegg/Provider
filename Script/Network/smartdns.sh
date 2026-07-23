#!/bin/bash

set -o pipefail

readonly API_URL="https://api.github.com/repos/pymumu/smartdns/releases/latest"
readonly CONFIG_DIR="/etc/smartdns"
readonly CONFIG_FILE="${CONFIG_DIR}/smartdns.conf"
readonly INSTALLER_CACHE="${CONFIG_DIR}/install"
readonly RESOLV_CONF="/etc/resolv.conf"
readonly SERVICE="smartdns.service"

DOWNLOAD_URL=""
ECS_REGION=""
IPV6_MODE=""
UNINSTALL=0

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
  bash smartdns.sh [--ecs REGION] [-6|--ipv6 yes|no] [-u|--uninstall]
参数：
  -e, --ecs REGION        ECS 区域：HK、TYO、LA、OR、SEA
  -6, --ipv6 MODE         IPv6 模式：yes、no；未提供时沿用 SmartDNS 默认行为
  -u, --uninstall         卸载 SmartDNS 并恢复公共 DNS
  -h, --help              显示帮助
无参数时安装 SmartDNS，或更新现有配置。
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
            -e|--ecs)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    fail "--ecs 缺少区域"
                fi
                ECS_REGION="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
                ecs_ip "$ECS_REGION" >/dev/null || fail "无效的 ECS 区域：$2"
                shift 2
                ;;
            -6|--ipv6)
                if [ "${2:-}" != "yes" ] && [ "${2:-}" != "no" ]; then
                    fail "无效的 IPv6 模式：${2:-}"
                fi
                IPV6_MODE="$2"
                shift 2
                ;;
            *)
                fail "未知参数：$1"
                ;;
        esac
    done
    if [ "$UNINSTALL" -eq 1 ] && [ -n "$ECS_REGION$IPV6_MODE" ]; then
        fail "卸载参数不能与配置参数混用"
    fi
}

ecs_ip() {
    local -A addresses=(
        [HK]="42.2.2.2"
        [TYO]="106.152.210.210"
        [LA]="107.119.53.53"
        [OR]="12.75.216.200"
        [SEA]="68.86.93.93"
    )
    [ -n "${addresses[$1]:-}" ] || return 1
    printf '%s' "${addresses[$1]}"
}

require_environment() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || fail "此操作必须以 root 权限运行"
    command -v systemctl >/dev/null 2>&1 || fail "未检测到 systemd"
}

ensure_dependencies() {
    local missing=()
    command -v apt-get >/dev/null 2>&1 || fail "仅支持 Debian/Ubuntu apt-get 环境"
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v tar >/dev/null 2>&1 || missing+=(tar)
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v cmp >/dev/null 2>&1 || missing+=(diffutils)
    [ -e /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)
    [ "${#missing[@]}" -gt 0 ] || return 0
    log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 ||
        fail "软件包索引更新失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    log_info "已安装依赖：${missing[*]}"
}

select_release_asset() {
    local arch json
    arch="$(uname -m)"
    case "$arch" in
        x86_64|aarch64)
            ;;
        *)
            fail "不支持的系统架构：$arch"
            ;;
    esac
    json="$(curl -fSsL --connect-timeout 5 --max-time 15 --retry 2 "$API_URL")" ||
        fail "无法获取 SmartDNS release 信息"
    [ -n "$json" ] || fail "SmartDNS release 信息为空"
    DOWNLOAD_URL="$(printf '%s' "$json" | jq -r --arg arch "$arch" '
        .assets[] | select(.name | test("^smartdns\\..*\\." + $arch + "-linux-all\\.tar\\.gz$"))
        | .browser_download_url' |
        head -n 1)" || fail "无法解析 SmartDNS 下载地址"
    [ -n "$DOWNLOAD_URL" ] || fail "未找到适用于 ${arch} 的 SmartDNS 安装包"
}

udp53_listeners() {
    ss -H -lun 2>/dev/null |
        awk '$4 ~ /(^|\[::\]|0\.0\.0\.0|127\.0\.0\.1|\*):53$/ { print }'
}

run_installer() {
    local action="$1" tmp_dir status
    tmp_dir="$(mktemp -d)" || fail "无法创建 SmartDNS 临时目录"
    (
        cd "$tmp_dir" || exit 1
        curl -fSsL --connect-timeout 10 --max-time 120 --retry 2 -o smartdns.tar.gz "$DOWNLOAD_URL" || exit 1
        [ -s smartdns.tar.gz ] || exit 1
        tar -xzf smartdns.tar.gz || exit 1
        cd smartdns || exit 1
        sh -n ./install >/dev/null 2>&1 || exit 1
        chmod +x ./install || exit 1
        ./install "$action" >/dev/null 2>&1 || exit 1
        if [ "$action" = "-i" ]; then
            install -D -m 755 ./install "$INSTALLER_CACHE" || exit 1
        fi
    )
    status=$?
    rm -rf "$tmp_dir"
    return "$status"
}

write_config() {
    local candidate suffix="" ip
    CONFIG_CHANGED=0
    mkdir -p "$CONFIG_DIR" || fail "无法创建 SmartDNS 配置目录"
    candidate="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || fail "无法创建 SmartDNS 候选配置"
    if [ -n "$ECS_REGION" ]; then
        ip="$(ecs_ip "$ECS_REGION")" || fail "无法生成 SmartDNS ECS 配置"
        suffix=" -subnet ${ip}/24"
    fi
    cat > "$candidate" <<EOF || fail "无法生成 SmartDNS 配置"
server-name smartdns
log-level off
bind 127.0.0.1:53
server 1.1.1.1
server 45.11.45.11
server 8.8.8.8${suffix}
server 94.140.14.140${suffix}
speed-check-mode ping,tcp:80,tcp:443
serve-expired yes
serve-expired-ttl 129600
serve-expired-reply-ttl 1
prefetch-domain yes
serve-expired-prefetch-time 21600
cache-size 4096
cache-persist yes
cache-file /etc/smartdns/smartdns.cache
force-qtype-SOA 65
EOF
    case "$IPV6_MODE" in
        no)
            printf 'dualstack-ip-selection no\nforce-AAAA-SOA yes\n' >> "$candidate"
            ;;
        yes)
            printf 'dualstack-ip-selection yes\n' >> "$candidate"
            ;;
    esac
    if cmp -s "$candidate" "$CONFIG_FILE" 2>/dev/null; then
        rm -f "$candidate"
        return 0
    fi
    if ! chmod 644 "$candidate" || ! mv -f "$candidate" "$CONFIG_FILE"; then
        rm -f "$candidate"
        fail "无法发布 SmartDNS 配置"
    fi
    CONFIG_CHANGED=1
}

set_dns() {
    local mode="$1" candidate
    candidate="$(mktemp "${RESOLV_CONF}.tmp.XXXXXX")" || fail "无法创建 DNS 候选配置"
    if [ "$mode" = "local" ]; then
        printf 'nameserver 127.0.0.1\n' > "$candidate"
    else
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$candidate"
    fi
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
    if [ "$mode" = "local" ]; then
        log_info "已将系统 DNS 设置为 127.0.0.1"
    else
        log_info "已恢复公共 DNS：1.1.1.1、8.8.8.8"
    fi
}

apply_smartdns() {
    local restart_needed=0 service_exists=0
    systemctl cat "$SERVICE" >/dev/null 2>&1 && service_exists=1
    if [ "$service_exists" -eq 0 ]; then
        [ -z "$(udp53_listeners)" ] || fail "53 端口已被其他服务占用"
    fi
    if [ "$service_exists" -eq 0 ] || [ ! -x /usr/sbin/smartdns ]; then
        select_release_asset
        log_info "正在安装 SmartDNS"
        run_installer -i || fail "SmartDNS 安装失败"
        restart_needed=1
    fi
    write_config
    if [ "$CONFIG_CHANGED" -eq 1 ] || ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        restart_needed=1
    fi
    if ! systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
        systemctl enable "$SERVICE" >/dev/null 2>&1 || fail "无法启用 SmartDNS 服务"
        log_info "已启用系统服务：${SERVICE}"
    fi
    if [ "$restart_needed" -eq 1 ]; then
        systemctl restart "$SERVICE" >/dev/null 2>&1 ||
            fail "SmartDNS 启动失败，请执行：journalctl -u ${SERVICE} --no-pager"
    fi
    systemctl is-active --quiet "$SERVICE" || fail "SmartDNS 服务未运行"
    set_dns local
    if [ "$restart_needed" -eq 1 ]; then
        log_info "SmartDNS 已启动，服务地址：127.0.0.1:53"
    else
        log_info "SmartDNS 配置未变化，无需重新应用"
    fi
}

uninstall_smartdns() {
    if ! systemctl cat "$SERVICE" >/dev/null 2>&1 && [ ! -x /usr/sbin/smartdns ] && [ ! -e "$CONFIG_DIR" ]; then
        log_info "SmartDNS 已不存在，无需卸载"
        return 0
    fi
    if [ -x "$INSTALLER_CACHE" ]; then
        "$INSTALLER_CACHE" -u >/dev/null 2>&1 || fail "SmartDNS 卸载失败"
    else
        ensure_dependencies
        select_release_asset
        run_installer -u || fail "SmartDNS 卸载失败"
    fi
    systemctl is-active --quiet "$SERVICE" 2>/dev/null && fail "SmartDNS 服务仍在运行"
    rm -rf "$CONFIG_DIR" || fail "无法删除 SmartDNS 配置目录"
    systemctl daemon-reload >/dev/null 2>&1 || fail "systemd 配置刷新失败"
    set_dns public
    log_info "SmartDNS 已卸载，并恢复公共 DNS"
}

main() {
    parse_args "$@"
    require_environment
    if [ "$UNINSTALL" -eq 1 ]; then
        uninstall_smartdns
    else
        ensure_dependencies
        apply_smartdns
    fi
}

main "$@"
