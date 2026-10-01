#!/bin/bash

set -o pipefail

SS_BINARY="${SS_BINARY:-/usr/local/bin/ssserver}"
SS_CONFIG_FILE="${SS_CONFIG_FILE:-/etc/shadowsocks/config.json}"
SS_UNIT_FILE="${SS_UNIT_FILE:-/lib/systemd/system/shadowsocks.service}"
SS_METHOD="2022-blake3-aes-128-gcm"

UPDATE_REQUESTED=0
UNINSTALL_REQUESTED=0
SS_PORT=""
SS_PASSWORD=""
CURRENT_VERSION=""
TARGET_VERSION=""
WORK_DIR=""
CANDIDATE_BINARY=""
BINARY_CHANGED=0
CONFIG_CHANGED=0
UNIT_CHANGED=0

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

show_usage() {
    cat <<'EOF'
用法:
  shadowsocks.sh [-s PASSWORD] [-p PORT]
  shadowsocks.sh --update
  shadowsocks.sh -u
  shadowsocks.sh -h, --help
EOF
}

parse_args() {
    local install_option=0
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -s ] || [ "$1" = -p ]; then
            if [ "$#" -le 1 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
                fail "$1 缺少参数值。"
            fi
            if [ "$1" = -s ]; then
                SS_PASSWORD="$2"
            else
                SS_PORT="$2"
            fi
            install_option=1
            shift 2
        elif [ "$1" = --update ]; then
            UPDATE_REQUESTED=1
            shift
        elif [ "$1" = -u ]; then
            UNINSTALL_REQUESTED=1
            shift
        elif [ "$1" = -h ] || [ "$1" = --help ]; then
            show_usage
            exit 0
        else
            fail "未知参数：$1"
        fi
    done
    if (( UPDATE_REQUESTED && UNINSTALL_REQUESTED )); then
        fail "--update 和 -u 不能同时使用。"
    fi
    if (( (UPDATE_REQUESTED || UNINSTALL_REQUESTED) && install_option )); then
        fail "更新或卸载不能同时使用 -s 或 -p。"
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
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    [ -e /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v tar >/dev/null 2>&1 || missing+=(tar)
    command -v xz >/dev/null 2>&1 || missing+=(xz-utils)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    if ! command -v shuf >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        missing+=(coreutils)
    fi
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    [ "${#missing[@]}" -eq 0 ] && return 0
    log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || fail "软件包索引更新失败。"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    log_info "已安装依赖：${missing[*]}"
}

detect_target() {
    local arch
    arch="$(uname -m)"
    if [ "$arch" = x86_64 ]; then
        printf 'x86_64-unknown-linux-musl\n'
    elif [ "$arch" = aarch64 ]; then
        printf 'aarch64-unknown-linux-musl\n'
    else
        fail "不支持的系统架构：$arch"
    fi
}

port_in_use() {
    ss -H -lntup 2>/dev/null | grep -E ":${1}[[:space:]]" | grep -vq '"ssserver"'
}

generate_port() {
    local port
    while true; do
        port="$(shuf -i 20000-40000 -n 1)" || fail "端口生成失败。"
        if [[ "$port" != *4* ]] && ! port_in_use "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
}

existing_value() {
    [ -r "$SS_CONFIG_FILE" ] || return 0
    jq -r "$1 // empty" "$SS_CONFIG_FILE" 2>/dev/null
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
    version="$(curl -fSsL --connect-timeout 5 --max-time 15 --retry 2 \
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
DynamicUser=yes
LoadCredential=config.json:${SS_CONFIG_FILE}
LimitNOFILE=65536
ExecStart=${SS_BINARY} -c \${CREDENTIALS_DIRECTORY}/config.json
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
}

resolve_version() {
    local latest
    CURRENT_VERSION="$(get_current_version)" || CURRENT_VERSION=""
    if [ "$UPDATE_REQUESTED" -eq 0 ] && [ -n "$CURRENT_VERSION" ]; then
        TARGET_VERSION="$CURRENT_VERSION"
        return 0
    fi
    [ "$UPDATE_REQUESTED" -eq 0 ] || [ -n "$CURRENT_VERSION" ] || fail "Shadowsocks 未安装。"
    latest="$(get_latest_version)" || fail "无法获取 Shadowsocks 最新版本。"
    TARGET_VERSION="${latest#v}"
    if [ -n "$CURRENT_VERSION" ] &&
       [ "$(printf '%s\n%s\n' "$TARGET_VERSION" "$CURRENT_VERSION" | sort -V | tail -n 1)" != "$TARGET_VERSION" ]; then
        TARGET_VERSION="$CURRENT_VERSION"
    fi
}

resolve_config() {
    [ -n "$SS_PORT" ] || SS_PORT="$(existing_value .server_port)"
    [ -n "$SS_PASSWORD" ] || SS_PASSWORD="$(existing_value .password)"
    if [ -z "$SS_PORT" ]; then
        SS_PORT="$(generate_port)" || exit 1
    fi
    if [ -z "$SS_PASSWORD" ]; then
        SS_PASSWORD="$(openssl rand -base64 16)" || fail "Shadowsocks 密码生成失败。"
    fi
    validate_port "$SS_PORT" || exit 1
    ! port_in_use "$SS_PORT" || fail "Shadowsocks 端口已被其他进程占用：$SS_PORT"
    [[ "$SS_PASSWORD" =~ ^[A-Za-z0-9+/]{21}[AQgw]==$ ]] ||
        fail "Shadowsocks 密码必须是 16 字节密钥的 base64 编码，可用 openssl rand -base64 16 生成。"
    render_config > "${WORK_DIR}/config.json" || fail "Shadowsocks 配置生成失败。"
    render_service > "${WORK_DIR}/shadowsocks.service" || fail "Shadowsocks unit 生成失败。"
}

stage_binary() {
    local target archive_name release_url archive output
    [ "$TARGET_VERSION" != "$CURRENT_VERSION" ] || return 0
    target="$(detect_target)" || exit 1
    archive_name="shadowsocks-v${TARGET_VERSION}.${target}.tar.xz"
    release_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${TARGET_VERSION}"
    archive="${WORK_DIR}/${archive_name}"
    log_info "正在下载 Shadowsocks ${TARGET_VERSION}（${target}）"
    curl -fSsL --connect-timeout 10 --max-time 120 --retry 2 -o "$archive" "${release_url}/${archive_name}" ||
        fail "Shadowsocks 下载失败。"
    curl -fSsL --connect-timeout 10 --max-time 120 --retry 2 -o "${archive}.sha256" \
        "${release_url}/${archive_name}.sha256" || fail "Shadowsocks 校验文件下载失败。"
    [ -s "$archive" ] || fail "Shadowsocks 下载文件为空。"
    [ -s "${archive}.sha256" ] || fail "Shadowsocks 校验文件为空。"
    if ! (cd "$WORK_DIR" && sha256sum -c "${archive_name}.sha256" >/dev/null 2>&1); then
        fail "Shadowsocks 下载文件校验失败。"
    fi
    tar -xJf "$archive" -C "$WORK_DIR" >/dev/null 2>&1 || fail "Shadowsocks 解压失败。"
    CANDIDATE_BINARY="${WORK_DIR}/ssserver"
    [ -f "$CANDIDATE_BINARY" ] || fail "压缩包中未找到 ssserver。"
    chmod 755 "$CANDIDATE_BINARY" || fail "ssserver 权限设置失败。"
    if ! output="$("$CANDIDATE_BINARY" -V 2>&1)"; then
        fail "ssserver 二进制预检失败：${output:-无错误输出}"
    fi
    [[ "$output" == *"$TARGET_VERSION"* ]] || fail "ssserver 版本校验失败。"
}

publish_file() {
    local source="$1" target="$2" mode="$3" directory staged
    if [ -f "$target" ] && cmp -s "$source" "$target"; then
        chmod "$mode" "$target" || fail "文件权限设置失败：$target"
        return 1
    fi
    directory="$(dirname "$target")"
    mkdir -p "$directory" || fail "无法创建目录：$directory"
    staged="$(mktemp "${directory}/.$(basename "$target").XXXXXX")" || fail "无法创建候选文件：$target"
    if ! install -m "$mode" "$source" "$staged" || ! mv -f "$staged" "$target"; then
        rm -f "$staged"
        fail "文件写入失败：$target"
    fi
}

apply_changes() {
    if [ -n "$CANDIDATE_BINARY" ] && publish_file "$CANDIDATE_BINARY" "$SS_BINARY" 755; then
        BINARY_CHANGED=1
        log_info "已安装 Shadowsocks 二进制：${TARGET_VERSION}"
    fi
    if publish_file "${WORK_DIR}/config.json" "$SS_CONFIG_FILE" 600; then
        CONFIG_CHANGED=1
        log_info "已更新 Shadowsocks 配置：$SS_CONFIG_FILE"
    fi
    if publish_file "${WORK_DIR}/shadowsocks.service" "$SS_UNIT_FILE" 644; then
        UNIT_CHANGED=1
        log_info "已更新系统服务：shadowsocks.service"
    fi
}

converge_service() {
    if [ "$UNIT_CHANGED" -eq 1 ]; then
        systemctl daemon-reload >/dev/null 2>&1 || fail "systemd daemon 重载失败。"
    fi
    if ! systemctl is-enabled --quiet shadowsocks.service 2>/dev/null; then
        systemctl enable shadowsocks.service >/dev/null 2>&1 || fail "shadowsocks.service 启用失败。"
        log_info "已启用系统服务：shadowsocks.service"
    fi
    if ! systemctl is-active --quiet shadowsocks.service 2>/dev/null; then
        systemctl start shadowsocks.service >/dev/null 2>&1 ||
            fail "Shadowsocks 启动失败，请执行：journalctl -u shadowsocks --no-pager"
    elif (( BINARY_CHANGED || CONFIG_CHANGED || UNIT_CHANGED )); then
        systemctl restart shadowsocks.service >/dev/null 2>&1 ||
            fail "Shadowsocks 重启失败，请执行：journalctl -u shadowsocks --no-pager"
    else
        return 0
    fi
    sleep 2
}

cleanup_work_dir() {
    [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
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
    systemctl is-active --quiet shadowsocks.service 2>/dev/null ||
        fail "Shadowsocks 服务未运行，请执行：journalctl -u shadowsocks --no-pager"
}

show_configuration() {
    local ip
    ip="$(curl -fSs --max-time 5 --retry 1 https://api.ipify.org 2>/dev/null)" || true
    cat <<EOF

=== Shadowsocks 客户端配置 ===
服务器：${ip:-无法获取 IP}
端口：${SS_PORT}
密码：${SS_PASSWORD}
加密：${SS_METHOD}
==============================
EOF
}

show_result() {
    if [ "$UPDATE_REQUESTED" -eq 0 ]; then
        log_info "Shadowsocks 已启动，服务端口：$SS_PORT"
        show_configuration
    elif [ "$BINARY_CHANGED" -eq 1 ]; then
        log_info "Shadowsocks 已更新：${CURRENT_VERSION} -> ${TARGET_VERSION}"
    else
        log_info "Shadowsocks 已是最新版本：${CURRENT_VERSION}"
    fi
}

main() {
    parse_args "$@"
    require_environment
    if [ "$UNINSTALL_REQUESTED" -eq 1 ]; then
        uninstall_shadowsocks
        return
    fi
    ensure_dependencies
    WORK_DIR="$(mktemp -d)" || fail "无法创建 Shadowsocks 临时目录。"
    trap cleanup_work_dir EXIT
    resolve_version
    resolve_config
    stage_binary
    apply_changes
    converge_service
    verify_service
    show_result
}

main "$@"
