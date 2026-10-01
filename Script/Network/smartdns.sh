#!/bin/bash

set -o pipefail

SMARTDNS_BINARY="${SMARTDNS_BINARY:-/usr/sbin/smartdns}"
SMARTDNS_CONFIG_FILE="${SMARTDNS_CONFIG_FILE:-/etc/smartdns/smartdns.conf}"
SMARTDNS_LEGACY_INSTALLER="${SMARTDNS_LEGACY_INSTALLER:-/etc/smartdns/install}"
SMARTDNS_LEGACY_INIT="${SMARTDNS_LEGACY_INIT:-/etc/init.d/smartdns}"
RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"
SMARTDNS_DATA_DIRS=(/var/cache/smartdns /var/lib/smartdns /var/log/smartdns)
API_URL="https://api.github.com/repos/pymumu/smartdns/releases/latest"
SERVICE="smartdns.service"

ECS_REGION=""
IPV6_MODE=""
UPDATE_REQUESTED=0
UNINSTALL_REQUESTED=0
CURRENT_VERSION=""
TARGET_VERSION=""
PACKAGE_URL=""
WORK_DIR=""
PACKAGE_CHANGED=0
CONFIG_CHANGED=0
SERVICE_STARTED=0

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
用法:
  smartdns.sh [-e|--ecs HK|TYO|MY|SG|LA|OR|SEA] [-6|--ipv6 yes|no]
  smartdns.sh --update
  smartdns.sh -u, --uninstall
  smartdns.sh -h, --help
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
                UNINSTALL_REQUESTED=1
                shift
                ;;
            --update)
                UPDATE_REQUESTED=1
                shift
                ;;
            -e|--ecs)
                ECS_REGION="${2^^}"
                ecs_ip "$ECS_REGION" >/dev/null || fail "无效的 ECS 区域：${2:-}"
                shift 2
                ;;
            -6|--ipv6)
                [[ "${2:-}" =~ ^(yes|no)$ ]] || fail "无效的 IPv6 模式：${2:-}"
                IPV6_MODE="$2"
                shift 2
                ;;
            *)
                fail "未知参数：$1"
                ;;
        esac
    done
    if (( UPDATE_REQUESTED && UNINSTALL_REQUESTED )); then
        fail "--update 和 --uninstall 不能同时使用"
    fi
    if (( UPDATE_REQUESTED || UNINSTALL_REQUESTED )) && [ -n "$ECS_REGION$IPV6_MODE" ]; then
        fail "更新或卸载不能与配置参数混用"
    fi
}

ecs_ip() {
    local -A addresses=(
        [HK]="42.2.2.2"
        [TYO]="106.152.210.210"
        [MY]="218.208.8.8"
        [SG]="116.15.15.15"
        [LA]="107.119.53.53"
        [OR]="12.75.216.200"
        [SEA]="68.86.93.93"
    )
    [ -n "${addresses[$1]:-}" ] || return 1
    printf '%s' "${addresses[$1]}"
}

require_environment() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || fail "此操作必须以 root 权限运行"
    command -v apt-get >/dev/null 2>&1 || fail "仅支持 Debian/Ubuntu apt-get 环境"
    command -v systemctl >/dev/null 2>&1 || fail "未检测到 systemd"
}

ensure_dependencies() {
    local missing=()
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    [ -e /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)
    [ "${#missing[@]}" -gt 0 ] || return 0
    log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 ||
        fail "软件包索引更新失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    log_info "已安装依赖：${missing[*]}"
}

package_managed() {
    dpkg-query -W -f='${db:Status-Abbrev}' smartdns 2>/dev/null | grep -q '^ii '
}

port53_in_use() {
    ss -H -lunp 2>/dev/null |
        awk '$4 ~ /(^|\[::\]|0\.0\.0\.0|127\.0\.0\.1|\*):53$/ { print }' |
        grep -vq '"smartdns"'
}

get_current_version() {
    [ -x "$SMARTDNS_BINARY" ] || return 1
    "$SMARTDNS_BINARY" -v 2>/dev/null | awk '$1 == "smartdns" && $2 != "" { print $2; found = 1 } END { exit !found }'
}

fetch_latest_release() {
    local arch asset
    arch="$(uname -m)"
    [[ "$arch" =~ ^(x86_64|aarch64)$ ]] || fail "不支持的系统架构：$arch"
    asset="$(curl -fSsL --connect-timeout 5 --max-time 15 --retry 2 "$API_URL" | jq -r --arg arch "$arch" '
        .assets[] | select(.name | test("^smartdns\\..+\\." + $arch + "-debian-all\\.deb$"))
        | "\(.name) \(.browser_download_url)"' | head -n 1)" || return 1
    [ -n "$asset" ] || return 1
    PACKAGE_URL="${asset#* }"
    TARGET_VERSION="${asset%% *}"
    TARGET_VERSION="${TARGET_VERSION#smartdns.}"
    TARGET_VERSION="${TARGET_VERSION%".${arch}-debian-all.deb"}"
}

render_config() {
    local suffix=""
    [ -z "$ECS_REGION" ] || suffix=" -subnet $(ecs_ip "$ECS_REGION")/24"
    cat <<EOF
server-name smartdns
user nobody
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
force-qtype-SOA 65
EOF
    [ "$IPV6_MODE" != no ] || printf 'dualstack-ip-selection no\nforce-AAAA-SOA yes\n'
    [ "$IPV6_MODE" != yes ] || printf 'dualstack-ip-selection yes\n'
}

resolve_version() {
    CURRENT_VERSION="$(get_current_version)" || CURRENT_VERSION=""
    if package_managed && [ -n "$CURRENT_VERSION" ] && [ "$UPDATE_REQUESTED" -eq 0 ]; then
        return 0
    fi
    [ "$UPDATE_REQUESTED" -eq 0 ] || [ -n "$CURRENT_VERSION" ] || fail "SmartDNS 未安装"
    fetch_latest_release || fail "无法获取 SmartDNS 最新版本"
    if package_managed && [ -n "$CURRENT_VERSION" ] &&
       [ "$(printf '%s\n%s\n' "$TARGET_VERSION" "$CURRENT_VERSION" | sort -V | tail -n 1)" = "$CURRENT_VERSION" ]; then
        PACKAGE_URL=""
    fi
}

resolve_config() {
    [ "$UPDATE_REQUESTED" -eq 0 ] || return 0
    ! port53_in_use || fail "53 端口已被其他服务占用"
    render_config > "${WORK_DIR}/smartdns.conf" || fail "无法生成 SmartDNS 配置"
}

stage_package() {
    local package="${WORK_DIR}/smartdns.deb"
    [ -n "$PACKAGE_URL" ] || return 0
    log_info "正在下载 SmartDNS ${TARGET_VERSION}"
    curl -fSsL --connect-timeout 10 --max-time 120 --retry 2 -o "$package" "$PACKAGE_URL" ||
        fail "SmartDNS 下载失败"
    if [ ! -s "$package" ] || [ "$(dpkg-deb -f "$package" Package 2>/dev/null)" != smartdns ]; then
        fail "SmartDNS 软件包校验失败"
    fi
}

apply_changes() {
    local package="${WORK_DIR}/smartdns.deb" candidate="${WORK_DIR}/smartdns.conf" directory staged
    if [ -f "$package" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            "$package" >/dev/null 2>&1 || fail "SmartDNS 软件包安装失败"
        PACKAGE_CHANGED=1
        log_info "已安装 SmartDNS 软件包：${TARGET_VERSION}"
        rm -f "$SMARTDNS_LEGACY_INSTALLER" "$SMARTDNS_LEGACY_INIT" || fail "无法清理旧版安装器文件"
    fi
    if [ ! -f "$candidate" ] || cmp -s "$candidate" "$SMARTDNS_CONFIG_FILE"; then
        return 0
    fi
    directory="$(dirname "$SMARTDNS_CONFIG_FILE")"
    mkdir -p "$directory" || fail "无法创建 SmartDNS 配置目录"
    staged="$(mktemp "${directory}/.smartdns.conf.XXXXXX")" || fail "无法创建 SmartDNS 候选配置"
    if ! install -m 644 "$candidate" "$staged" || ! mv -f "$staged" "$SMARTDNS_CONFIG_FILE"; then
        rm -f "$staged"
        fail "无法发布 SmartDNS 配置"
    fi
    CONFIG_CHANGED=1
    log_info "已更新 SmartDNS 配置：$SMARTDNS_CONFIG_FILE"
}

converge_service() {
    if [ "$PACKAGE_CHANGED" -eq 1 ]; then
        systemctl daemon-reload >/dev/null 2>&1 || fail "systemd 配置刷新失败"
    fi
    if ! systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
        systemctl enable "$SERVICE" >/dev/null 2>&1 || fail "无法启用 SmartDNS 服务"
        log_info "已启用系统服务：${SERVICE}"
    fi
    if (( PACKAGE_CHANGED || CONFIG_CHANGED )) || ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        systemctl restart "$SERVICE" >/dev/null 2>&1 ||
            fail "SmartDNS 启动失败，请执行：journalctl -u ${SERVICE} --no-pager"
        SERVICE_STARTED=1
        sleep 2
    fi
    systemctl is-active --quiet "$SERVICE" 2>/dev/null ||
        fail "SmartDNS 服务未运行，请执行：journalctl -u ${SERVICE} --no-pager"
}

set_dns() {
    local servers="127.0.0.1" content candidate
    [ "$1" = local ] || servers="1.1.1.1 8.8.8.8"
    content="$(printf 'nameserver %s\n' $servers)"
    chattr -i "$RESOLV_CONF" 2>/dev/null
    if [ "$(cat "$RESOLV_CONF" 2>/dev/null)" != "$content" ]; then
        candidate="$(mktemp "${RESOLV_CONF}.tmp.XXXXXX")" || fail "无法创建 DNS 候选配置"
        printf '%s\n' "$content" > "$candidate"
        if ! chmod 644 "$candidate" || ! mv -f "$candidate" "$RESOLV_CONF"; then
            rm -f "$candidate"
            fail "无法更新系统 DNS"
        fi
        log_info "已将系统 DNS 设置为：${servers}"
    fi
    [ "$1" != local ] || chattr +i "$RESOLV_CONF" 2>/dev/null
}

uninstall_smartdns() {
    local config_dir
    config_dir="$(dirname "$SMARTDNS_CONFIG_FILE")"
    if ! systemctl cat "$SERVICE" >/dev/null 2>&1 && [ ! -e "$SMARTDNS_BINARY" ] && [ ! -e "$config_dir" ]; then
        log_info "SmartDNS 已不存在，无需卸载"
        return 0
    fi
    set_dns public
    if package_managed; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq smartdns >/dev/null 2>&1 ||
            fail "SmartDNS 软件包卸载失败"
        log_info "已卸载软件包：smartdns"
    elif [ -x "$SMARTDNS_LEGACY_INSTALLER" ]; then
        "$SMARTDNS_LEGACY_INSTALLER" -u >/dev/null 2>&1 || fail "SmartDNS 卸载失败"
    fi
    rm -rf "$config_dir" "${SMARTDNS_DATA_DIRS[@]}" "$SMARTDNS_LEGACY_INIT" ||
        fail "无法删除 SmartDNS 配置和数据目录"
    systemctl daemon-reload >/dev/null 2>&1 || fail "systemd 配置刷新失败"
    if [ -e "$SMARTDNS_BINARY" ] || systemctl cat "$SERVICE" >/dev/null 2>&1; then
        fail "SmartDNS 卸载验证失败"
    fi
    log_info "SmartDNS 已卸载，并恢复公共 DNS"
}

show_result() {
    if [ "$UPDATE_REQUESTED" -eq 1 ]; then
        if [ "$PACKAGE_CHANGED" -eq 1 ] && [ "$CURRENT_VERSION" != "$TARGET_VERSION" ]; then
            log_info "SmartDNS 已更新：${CURRENT_VERSION} -> ${TARGET_VERSION}"
        else
            log_info "SmartDNS 已是最新版本：${CURRENT_VERSION}"
        fi
    elif [ "$SERVICE_STARTED" -eq 1 ]; then
        log_info "SmartDNS 已启动，服务地址：127.0.0.1:53"
    else
        log_info "SmartDNS 配置未变化，无需重新应用"
    fi
}

main() {
    parse_args "$@"
    require_environment
    if [ "$UNINSTALL_REQUESTED" -eq 1 ]; then
        uninstall_smartdns
        return
    fi
    ensure_dependencies
    WORK_DIR="$(mktemp -d)" || fail "无法创建 SmartDNS 临时目录"
    trap 'rm -rf "$WORK_DIR"' EXIT
    resolve_version
    resolve_config
    stage_package
    apply_changes
    converge_service
    set_dns local
    show_result
}

main "$@"
