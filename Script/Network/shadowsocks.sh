#!/bin/bash

set -o pipefail

SS_BINARY="${SS_BINARY:-/usr/local/bin/ssserver}"
SS_CONFIG_FILE="${SS_CONFIG_FILE:-/etc/shadowsocks/config.json}"
SS_UNIT_FILE="${SS_UNIT_FILE:-/lib/systemd/system/shadowsocks.service}"
SS_METHOD="2022-blake3-aes-128-gcm"

ACTION=""
SS_PORT=""
SS_PASSWORD=""
BINARY_CHANGED=0
CONFIG_CHANGED=0
UNIT_CHANGED=0
TRANSACTION_DIR=""
TRANSACTION_ACTIVE=0
SERVICE_WAS_ACTIVE=0
SERVICE_WAS_ENABLED=0

log_info() {
    printf '[INFO] %s\n' "$*"
}

log_warning() {
    printf '[WARNING] %s\n' "$*" >&2
}

log_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

fail() {
    log_error "$*"
    exit 1
}

show_usage() {
    cat <<'EOF'
用法：
  bash shadowsocks.sh [-s PASSWORD] [-p PORT]
  bash shadowsocks.sh -u

参数：
  -s PASSWORD   Shadowsocks 密码，未提供时自动生成
  -p PORT       Shadowsocks 端口，未提供时自动生成
  -u            卸载 Shadowsocks
  -h, --help    显示帮助

无参数时显示安装、更新、卸载菜单。
EOF
}

parse_args() {
    local install_option=0 uninstall_option=0
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -s ] || [ "$1" = -p ]; then
            if [ "$#" -le 1 ] || [[ "$2" == -* ]]; then
                fail "$1 缺少参数值。"
            fi
            if [ "$1" = -s ]; then
                SS_PASSWORD="$2"
            else
                SS_PORT="$2"
            fi
            install_option=1
            shift 2
        elif [ "$1" = -u ]; then
            uninstall_option=1
            shift
        elif [ "$1" = -h ] || [ "$1" = --help ]; then
            show_usage
            exit 0
        else
            fail "未知参数：$1"
        fi
    done
    if (( install_option && uninstall_option )); then
        fail "安装参数和 -u 不能同时使用。"
    fi
    if [ "$uninstall_option" -eq 1 ]; then
        ACTION=uninstall
    elif [ "$install_option" -eq 1 ]; then
        ACTION=install
    fi
}

validate_port() {
    if ! [[ "$1" =~ ^[0-9]+$ ]] || (( 10#$1 < 1 || 10#$1 > 65535 )); then
        log_error "Shadowsocks 端口无效：$1"
        return 1
    fi
}

require_environment() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || fail "请使用 root 权限执行。"
    command -v apt-get >/dev/null 2>&1 || fail "仅支持 Debian/Ubuntu apt 环境。"
    command -v systemctl >/dev/null 2>&1 || fail "当前系统未提供 systemd。"
}

ensure_dependencies() {
    local missing=()
    command -v wget >/dev/null 2>&1 || missing+=(wget)
    [ -e /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v tar >/dev/null 2>&1 || missing+=(tar)
    command -v xz >/dev/null 2>&1 || missing+=(xz-utils)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    if ! command -v shuf >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        missing+=(coreutils)
    fi
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    dpkg-query -W -f='${db:Status-Abbrev}' systemd-timesyncd 2>/dev/null | grep -q '^ii ' ||
        missing+=(systemd-timesyncd)
    [ "${#missing[@]}" -eq 0 ] && return 0
    log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || fail "软件包索引更新失败。"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    log_info "已安装依赖：${missing[*]}"
}

ensure_time_sync() {
    local synced i
    synced="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)"
    [ "$synced" != yes ] || return 0
    if ! systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null ||
       ! systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        if ! systemctl enable --now systemd-timesyncd >/dev/null 2>&1 ||
           ! systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
            fail "systemd-timesyncd 启动失败。"
        fi
        log_info "已启用系统服务：systemd-timesyncd.service"
    fi
    for ((i=0; i<30; i++)); do
        synced="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)"
        [ "$synced" = yes ] && return 0
        sleep 2
    done
    fail "systemd-timesyncd 已运行，但时间尚未同步。"
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    if [[ "$arch" =~ ^(i386|i686)$ ]]; then
        printf 'i686\n'
    elif [[ "$arch" =~ ^(armv6l|armv7.*)$ ]]; then
        printf 'arm\n'
    elif [[ "$arch" =~ ^(armv8.*|aarch64)$ ]]; then
        printf 'aarch64\n'
    elif [ "$arch" = x86_64 ]; then
        printf 'x86_64\n'
    else
        fail "不支持的系统架构：$arch"
    fi
}

prepare_configuration() {
    local generated
    while [ -z "$SS_PORT" ]; do
        generated="$(shuf -i 20000-40000 -n 1)" || fail "端口生成失败。"
        if [[ "$generated" != *4* ]] &&
           ! ss -H -lntu 2>/dev/null | grep -Eq ":${generated}[[:space:]]"; then
            SS_PORT="$generated"
        fi
    done
    validate_port "$SS_PORT" || exit 1
    if [ -z "$SS_PASSWORD" ]; then
        SS_PASSWORD="$(openssl rand -base64 16)" || fail "Shadowsocks 密码生成失败。"
    fi
    [ -n "$SS_PASSWORD" ] || fail "Shadowsocks 密码不能为空。"
}

get_current_version() {
    local output
    [ -x "$SS_BINARY" ] || return 1
    output="$("$SS_BINARY" -V 2>&1)" || return 1
    [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[0]}"
}

get_latest_version() {
    local version
    version="$(wget -qO- --timeout=10 --tries=3 \
        https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases 2>/dev/null |
        jq -r '[.[] | select(.prerelease == false and .draft == false) | .tag_name][0]')" || return 1
    if [ -z "$version" ] || [ "$version" = null ]; then
        return 1
    fi
    printf '%s\n' "$version"
}

render_config() {
    jq -n \
        --argjson port "$SS_PORT" \
        --arg password "$SS_PASSWORD" \
        --arg method "$SS_METHOD" \
        '{
            log: {writers: []},
            server: "0.0.0.0",
            server_port: $port,
            password: $password,
            timeout: 600,
            mode: "tcp_and_udp",
            method: $method
        }'
}

render_service() {
    cat <<EOF
[Unit]
Description=Shadowsocks Server
After=network.target
Before=network-online.target
StartLimitBurst=0
StartLimitIntervalSec=60

[Service]
Type=simple
LimitNOFILE=65536
ExecStart=${SS_BINARY} -c ${SS_CONFIG_FILE}
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
}

apply_candidate() {
    local renderer="$1" target="$2" mode="$3" changed_name="$4" success="$5" label="$6"
    local directory candidate
    directory="$(dirname "$target")"
    mkdir -p "$directory" || fail "无法创建 ${label} 目录。"
    umask 077
    candidate="$(mktemp "${directory}/.$(basename "$target").XXXXXX")" || fail "无法创建 ${label} 候选文件。"
    "$renderer" > "$candidate" || {
        rm -f "$candidate"
        fail "${label} 生成失败。"
    }
    if [ -f "$target" ] && cmp -s "$candidate" "$target"; then
        rm -f "$candidate"
        printf -v "$changed_name" '%s' 0
        return 0
    fi
    if ! chmod "$mode" "$candidate" || ! mv -f "$candidate" "$target"; then
        rm -f "$candidate"
        fail "${label} 应用失败。"
    fi
    printf -v "$changed_name" '%s' 1
    log_info "$success"
}

begin_transaction() {
    local targets names index
    targets=("$SS_BINARY" "$SS_CONFIG_FILE" "$SS_UNIT_FILE")
    names=(binary config unit)
    TRANSACTION_DIR="$(mktemp -d)" || fail "无法创建 Shadowsocks 事务目录。"
    if systemctl is-active --quiet shadowsocks.service 2>/dev/null; then
        SERVICE_WAS_ACTIVE=1
    else
        SERVICE_WAS_ACTIVE=0
    fi
    if systemctl is-enabled --quiet shadowsocks.service 2>/dev/null; then
        SERVICE_WAS_ENABLED=1
    else
        SERVICE_WAS_ENABLED=0
    fi
    for index in "${!targets[@]}"; do
        [ -e "${targets[$index]}" ] || continue
        cp -a "${targets[$index]}" "${TRANSACTION_DIR}/${names[$index]}" || {
            rm -rf "$TRANSACTION_DIR"
            fail "无法备份 Shadowsocks 当前状态。"
        }
    done
    TRANSACTION_ACTIVE=1
    trap rollback_transaction EXIT
}

rollback_transaction() {
    local targets names index restore_failed=0
    [ "$TRANSACTION_ACTIVE" -eq 1 ] || return 0
    targets=("$SS_BINARY" "$SS_CONFIG_FILE" "$SS_UNIT_FILE")
    names=(binary config unit)
    for index in "${!targets[@]}"; do
        if [ -e "${TRANSACTION_DIR}/${names[$index]}" ]; then
            if ! mkdir -p "$(dirname "${targets[$index]}")" ||
               ! cp -a "${TRANSACTION_DIR}/${names[$index]}" "${targets[$index]}"; then
                restore_failed=1
            fi
        else
            rm -f "${targets[$index]}" || restore_failed=1
        fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || restore_failed=1
    if [ "$SERVICE_WAS_ENABLED" -eq 1 ]; then
        systemctl enable shadowsocks.service >/dev/null 2>&1 || restore_failed=1
    elif systemctl is-enabled --quiet shadowsocks.service 2>/dev/null; then
        systemctl disable shadowsocks.service >/dev/null 2>&1 || restore_failed=1
    fi
    if [ "$SERVICE_WAS_ACTIVE" -eq 1 ]; then
        if ! systemctl restart shadowsocks.service >/dev/null 2>&1 ||
           ! systemctl is-active --quiet shadowsocks.service 2>/dev/null; then
            restore_failed=1
        fi
    elif systemctl is-active --quiet shadowsocks.service 2>/dev/null; then
        systemctl stop shadowsocks.service >/dev/null 2>&1 || restore_failed=1
    fi
    TRANSACTION_ACTIVE=0
    trap - EXIT
    rm -rf "$TRANSACTION_DIR" || restore_failed=1
    if [ "$restore_failed" -eq 1 ]; then
        log_error "Shadowsocks 旧状态恢复失败，请检查文件和服务状态。"
        return 1
    fi
    log_warning "Shadowsocks 变更失败，已恢复旧状态。"
}

download_server() {
    local version="$1" arch archive_name release_url temp_dir archive checksum
    local candidate install_candidate output
    arch="$(detect_arch)"
    archive_name="shadowsocks-${version}.${arch}-unknown-linux-gnu.tar.xz"
    release_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${version}"
    [ -d "$TRANSACTION_DIR" ] || fail "Shadowsocks 事务尚未开始。"
    temp_dir="$(mktemp -d "${TRANSACTION_DIR}/download.XXXXXX")" || fail "无法创建下载临时目录。"
    archive="${temp_dir}/${archive_name}"
    checksum="${archive}.sha256"
    log_info "正在下载 Shadowsocks ${version#v}（${arch}）"
    wget -q --timeout=20 --tries=3 -O "$archive" "${release_url}/${archive_name}" ||
        fail "Shadowsocks 下载失败。"
    wget -q --timeout=20 --tries=3 -O "$checksum" "${release_url}/${archive_name}.sha256" ||
        fail "Shadowsocks 校验文件下载失败。"
    [ -s "$archive" ] || fail "Shadowsocks 下载文件为空。"
    [ -s "$checksum" ] || fail "Shadowsocks 校验文件为空。"
    if ! (cd "$temp_dir" && sha256sum -c "${archive_name}.sha256" >/dev/null 2>&1); then
        fail "Shadowsocks 下载文件校验失败。"
    fi
    tar -xJf "$archive" -C "$temp_dir" >/dev/null 2>&1 || fail "Shadowsocks 解压失败。"
    candidate="${temp_dir}/ssserver"
    [ -f "$candidate" ] || fail "压缩包中未找到 ssserver。"
    chmod 755 "$candidate" || fail "ssserver 权限设置失败。"
    output="$("$candidate" -V 2>&1)" || fail "ssserver 二进制预检失败。"
    [[ "$output" == *"${version#v}"* ]] || fail "ssserver 版本校验失败。"
    if [ -f "$SS_BINARY" ] && cmp -s "$candidate" "$SS_BINARY"; then
        BINARY_CHANGED=0
        return 0
    fi
    mkdir -p "$(dirname "$SS_BINARY")" || fail "无法创建 Shadowsocks 安装目录。"
    install_candidate="$(mktemp "$(dirname "$SS_BINARY")/.ssserver.XXXXXX")" ||
        fail "无法创建 ssserver 安装候选文件。"
    if ! install -m 755 "$candidate" "$install_candidate"; then
        rm -f "$install_candidate"
        fail "ssserver 安装失败。"
    fi
    if ! mv -f "$install_candidate" "$SS_BINARY"; then
        rm -f "$install_candidate"
        fail "ssserver 安装失败。"
    fi
    BINARY_CHANGED=1
}

converge_service() {
    if [ "$UNIT_CHANGED" -eq 1 ]; then
        systemctl daemon-reload >/dev/null 2>&1 || {
            log_error "systemd daemon 重载失败。"
            return 1
        }
    fi
    if ! systemctl is-enabled --quiet shadowsocks.service 2>/dev/null; then
        systemctl enable shadowsocks.service >/dev/null 2>&1 || {
            log_error "shadowsocks.service 启用失败。"
            return 1
        }
        log_info "已启用系统服务：shadowsocks.service"
    fi
    if systemctl is-active --quiet shadowsocks.service 2>/dev/null; then
        if (( BINARY_CHANGED || CONFIG_CHANGED || UNIT_CHANGED )); then
            systemctl restart shadowsocks.service >/dev/null 2>&1 || {
                log_error "Shadowsocks 重启失败。"
                return 1
            }
        fi
    else
        systemctl start shadowsocks.service >/dev/null 2>&1 || {
            log_error "Shadowsocks 启动失败。"
            return 1
        }
    fi
}

read_current_configuration() {
    [ -r "$SS_CONFIG_FILE" ] || fail "未找到 Shadowsocks 配置。"
    SS_PORT="$(jq -r '.server_port' "$SS_CONFIG_FILE")" || fail "无法读取 Shadowsocks 端口。"
    SS_PASSWORD="$(jq -r '.password' "$SS_CONFIG_FILE")" || fail "无法读取 Shadowsocks 密码。"
    validate_port "$SS_PORT" >/dev/null 2>&1 || fail "现有 Shadowsocks 端口无效。"
    if [ -z "$SS_PASSWORD" ] || [ "$SS_PASSWORD" = null ]; then
        fail "现有 Shadowsocks 密码无效。"
    fi
}

install_shadowsocks() {
    local latest
    ensure_dependencies
    ensure_time_sync
    prepare_configuration
    begin_transaction
    BINARY_CHANGED=0
    if [ ! -x "$SS_BINARY" ]; then
        latest="$(get_latest_version)" || fail "无法获取 Shadowsocks 最新版本。"
        download_server "$latest"
    fi
    apply_candidate render_config "$SS_CONFIG_FILE" 600 CONFIG_CHANGED \
        "已更新 Shadowsocks 配置：$SS_CONFIG_FILE" "Shadowsocks 配置"
    apply_candidate render_service "$SS_UNIT_FILE" 644 UNIT_CHANGED \
        "已更新系统服务：shadowsocks.service" "Shadowsocks unit"
    if ! converge_service || ! verify_service; then
        if rollback_transaction; then
            fail "Shadowsocks 应用失败，已恢复旧状态。"
        fi
        fail "Shadowsocks 应用失败，且旧状态恢复失败。"
    fi
    TRANSACTION_ACTIVE=0
    trap - EXIT
    rm -rf "$TRANSACTION_DIR" || log_warning "Shadowsocks 事务临时目录清理失败：$TRANSACTION_DIR"
    [ "$BINARY_CHANGED" -eq 0 ] || log_info "已安装 Shadowsocks 二进制。"
    log_info "Shadowsocks 已启动，服务端口：$SS_PORT"
    show_configuration
}

update_shadowsocks() {
    local current latest highest
    ensure_dependencies
    current="$(get_current_version)" || fail "Shadowsocks 未安装。"
    latest="$(get_latest_version)" || fail "无法获取 Shadowsocks 最新版本。"
    highest="$(printf '%s\n%s\n' "${latest#v}" "$current" | sort -V | tail -n 1)"
    if [ "$highest" != "${latest#v}" ] || [ "${latest#v}" = "$current" ]; then
        log_info "Shadowsocks 已是最新版本：$current"
        return 0
    fi
    read_current_configuration
    begin_transaction
    download_server "$latest"
    if ! converge_service || ! verify_service; then
        if rollback_transaction; then
            fail "Shadowsocks 更新失败，已恢复旧状态。"
        fi
        fail "Shadowsocks 更新失败，且旧状态恢复失败。"
    fi
    TRANSACTION_ACTIVE=0
    trap - EXIT
    rm -rf "$TRANSACTION_DIR" || log_warning "Shadowsocks 事务临时目录清理失败：$TRANSACTION_DIR"
    log_info "Shadowsocks 已更新：${current} -> ${latest#v}"
}

uninstall_shadowsocks() {
    if [ ! -e "$SS_BINARY" ] && [ ! -e "$SS_CONFIG_FILE" ] && [ ! -e "$SS_UNIT_FILE" ] &&
       ! systemctl is-active --quiet shadowsocks.service 2>/dev/null &&
       ! systemctl cat shadowsocks.service >/dev/null 2>&1; then
        log_info "Shadowsocks 已不存在，无需卸载。"
        return 0
    fi
    if systemctl is-active --quiet shadowsocks.service 2>/dev/null; then
        systemctl stop shadowsocks.service >/dev/null 2>&1 || fail "Shadowsocks 服务停止失败。"
        log_info "已停止系统服务：shadowsocks.service"
    fi
    if systemctl is-enabled --quiet shadowsocks.service 2>/dev/null; then
        systemctl disable shadowsocks.service >/dev/null 2>&1 || fail "Shadowsocks 服务禁用失败。"
        log_info "已禁用系统服务：shadowsocks.service"
    fi
    rm -f "$SS_UNIT_FILE" "$SS_CONFIG_FILE" "$SS_BINARY" || fail "Shadowsocks 文件删除失败。"
    rmdir "$(dirname "$SS_CONFIG_FILE")" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || fail "systemd daemon 重载失败。"
    systemctl reset-failed shadowsocks.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet shadowsocks.service 2>/dev/null ||
       systemctl cat shadowsocks.service >/dev/null 2>&1 || [ -e "$SS_BINARY" ] ||
       [ -e "$SS_CONFIG_FILE" ] || [ -e "$SS_UNIT_FILE" ]; then
        fail "Shadowsocks 卸载验证失败。"
    fi
    log_info "Shadowsocks 已卸载。"
}

verify_service() {
    systemctl is-active --quiet shadowsocks.service 2>/dev/null || {
        log_error "Shadowsocks 服务未运行。"
        return 1
    }
}

show_configuration() {
    local ip
    ip="$(wget -qO- --timeout=5 --tries=2 https://api.ipify.org 2>/dev/null)" || true
    cat <<EOF

=== Shadowsocks 客户端配置 ===
服务器：${ip:-无法获取 IP}
端口：${SS_PORT}
密码：${SS_PASSWORD}
加密：${SS_METHOD}
==============================
EOF
}

main() {
    local choice
    parse_args "$@"
    require_environment
    if [ -z "$ACTION" ]; then
        printf '1. 安装 Shadowsocks\n2. 更新 Shadowsocks\n3. 卸载 Shadowsocks\n'
        read -r -p '请选择（1-3）：' choice || fail "未读取到选择。"
        if [ "$choice" = 1 ]; then
            ACTION=install
        elif [ "$choice" = 2 ]; then
            ACTION=update
        elif [ "$choice" = 3 ]; then
            ACTION=uninstall
        else
            fail "无效选择：$choice"
        fi
    fi
    if [ "$ACTION" = install ]; then
        install_shadowsocks
    elif [ "$ACTION" = update ]; then
        update_shadowsocks
    else
        uninstall_shadowsocks
    fi
}

main "$@"
