#!/bin/bash

set -o pipefail

SNELL_BINARY="${SNELL_BINARY:-/usr/local/bin/snell-server}"
SNELL_CONFIG_FILE="${SNELL_CONFIG_FILE:-/etc/snell/snell.conf}"
SNELL_UNIT_FILE="${SNELL_UNIT_FILE:-/etc/systemd/system/snell.service}"
SNELL_DOWNLOAD_BASE="https://dl.nssurge.com/snell"
SNELL_RELEASE_NOTES="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell.md"

UPDATE_REQUESTED=0
UNINSTALL_REQUESTED=0
SNELL_VERSION=""
SNELL_PORT=""
SNELL_PSK=""
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
  snell.sh [-p|--port PORT] [-k|--psk PSK] [--version VERSION]
  snell.sh --update
  snell.sh -u, --uninstall
  snell.sh -h, --help
EOF
}

parse_args() {
    local install_option=0
    while [ "$#" -gt 0 ]; do
        if [[ "$1" =~ ^(-p|--port|-k|--psk|--version)$ ]]; then
            if [ "$#" -le 1 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
                fail "$1 缺少参数值。"
            fi
            if [[ "$1" =~ ^(-p|--port)$ ]]; then
                SNELL_PORT="$2"
            elif [[ "$1" =~ ^(-k|--psk)$ ]]; then
                SNELL_PSK="$2"
            else
                SNELL_VERSION="${2#v}"
            fi
            install_option=1
            shift 2
        elif [ "$1" = --update ]; then
            UPDATE_REQUESTED=1
            shift
        elif [ "$1" = -u ] || [ "$1" = --uninstall ]; then
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
        fail "--update 和 --uninstall 不能同时使用。"
    fi
    if (( (UPDATE_REQUESTED || UNINSTALL_REQUESTED) && install_option )); then
        fail "更新或卸载不能同时使用端口、PSK 或版本参数。"
    fi
    if [ -n "$SNELL_VERSION" ] && ! [[ "$SNELL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*$ ]]; then
        fail "Snell 版本格式无效：$SNELL_VERSION"
    fi
}

validate_port() {
    if ! [[ "$1" =~ ^[0-9]{5}$ ]] || (( 10#$1 < 10000 || 10#$1 > 60000 )); then
        log_error "Snell 端口无效：$1；范围应为 10000-60000。"
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
    command -v unzip >/dev/null 2>&1 || missing+=(unzip)
    command -v shuf >/dev/null 2>&1 || missing+=(coreutils)
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    [ "${#missing[@]}" -eq 0 ] && return 0
    log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || fail "软件包索引更新失败。"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    log_info "已安装依赖：${missing[*]}"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)
            printf 'amd64\n'
            ;;
        i386|i686)
            printf 'i386\n'
            ;;
        aarch64)
            printf 'aarch64\n'
            ;;
        armv7l)
            printf 'armv7l\n'
            ;;
        *)
            fail "不支持的系统架构：$(uname -m)"
            ;;
    esac
}

port_in_use() {
    ss -H -lntup 2>/dev/null | grep -E ":${1}[[:space:]]" | grep -vq '"snell-server"'
}

generate_port() {
    local port
    while true; do
        port="$(shuf -i 10000-60000 -n 1)" || fail "端口生成失败。"
        if [[ "$port" != *4* ]] && ! port_in_use "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
}

generate_psk() {
    local psk
    psk="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32)" || true
    [ "${#psk}" -eq 32 ] || fail "Snell PSK 生成失败。"
    printf '%s\n' "$psk"
}

existing_value() {
    [ -r "$SNELL_CONFIG_FILE" ] || return 0
    sed -n "s/^${1}[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p" "$SNELL_CONFIG_FILE" | head -n 1
}

get_current_version() {
    local output
    [ -x "$SNELL_BINARY" ] || return 1
    output="$("$SNELL_BINARY" -v 2>&1)" || return 1
    [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[0]}"
}

get_stable_versions() {
    curl -fSsL --connect-timeout 5 --max-time 15 --retry 2 "$SNELL_RELEASE_NOTES" 2>/dev/null |
        grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+-linux-' |
        sed -E 's/^snell-server-v//; s/-linux-$//' | sort -uV
}

render_config() {
    cat <<EOF
[snell-server]
listen = ::0:${SNELL_PORT}
psk = ${SNELL_PSK}
EOF
}

render_service() {
    cat <<EOF
[Unit]
Description=Snell Server
After=network.target

[Service]
Type=simple
DynamicUser=yes
LoadCredential=snell.conf:${SNELL_CONFIG_FILE}
LimitNOFILE=65536
ExecStart=${SNELL_BINARY} -c \${CREDENTIALS_DIRECTORY}/snell.conf
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
}

resolve_version() {
    local versions latest
    CURRENT_VERSION="$(get_current_version)" || CURRENT_VERSION=""
    if [ -n "$SNELL_VERSION" ]; then
        TARGET_VERSION="$SNELL_VERSION"
        return 0
    fi
    if [ "$UPDATE_REQUESTED" -eq 0 ] && [ -n "$CURRENT_VERSION" ]; then
        return 0
    fi
    [ "$UPDATE_REQUESTED" -eq 0 ] || [ -n "$CURRENT_VERSION" ] || fail "Snell 未安装。"
    versions="$(get_stable_versions)" || fail "无法获取 Snell 正式版本列表，请使用 --version 指定版本。"
    if [ -n "$CURRENT_VERSION" ]; then
        latest="$(printf '%s\n' "$versions" | grep "^${CURRENT_VERSION%%.*}\." | tail -n 1)"
        [ -n "$latest" ] || return 0
        if [ "$(printf '%s\n%s\n' "$latest" "$CURRENT_VERSION" | sort -V | tail -n 1)" != "$latest" ]; then
            return 0
        fi
    else
        latest="$(printf '%s\n' "$versions" | tail -n 1)"
    fi
    TARGET_VERSION="$latest"
}

resolve_config() {
    local listen
    if [ -z "$SNELL_PORT" ]; then
        listen="$(existing_value listen)"
        SNELL_PORT="${listen##*:}"
    fi
    [ -n "$SNELL_PSK" ] || SNELL_PSK="$(existing_value psk)"
    if [ -z "$SNELL_PORT" ]; then
        SNELL_PORT="$(generate_port)" || exit 1
    fi
    if [ -z "$SNELL_PSK" ]; then
        SNELL_PSK="$(generate_psk)" || exit 1
    fi
    validate_port "$SNELL_PORT" || exit 1
    ! port_in_use "$SNELL_PORT" || fail "Snell 端口已被其他进程占用：$SNELL_PORT"
    [[ "$SNELL_PSK" =~ ^[A-Za-z0-9]{16,64}$ ]] || fail "Snell PSK 无效：必须是 16-64 位字母数字。"
    render_config > "${WORK_DIR}/snell.conf" || fail "Snell 配置生成失败。"
    render_service > "${WORK_DIR}/snell.service" || fail "Snell unit 生成失败。"
}

stage_binary() {
    local arch archive output
    [ -n "$TARGET_VERSION" ] || return 0
    arch="$(detect_arch)" || exit 1
    archive="${WORK_DIR}/snell-server.zip"
    log_info "正在下载 Snell ${TARGET_VERSION}（${arch}）"
    curl -fSsL --connect-timeout 10 --max-time 120 --retry 2 -o "$archive" \
        "${SNELL_DOWNLOAD_BASE}/snell-server-v${TARGET_VERSION}-linux-${arch}.zip" || fail "Snell 下载失败。"
    unzip -qo "$archive" snell-server -d "$WORK_DIR" >/dev/null 2>&1 || fail "Snell 解压失败。"
    CANDIDATE_BINARY="${WORK_DIR}/snell-server"
    [ -f "$CANDIDATE_BINARY" ] || fail "压缩包中未找到 snell-server。"
    chmod 755 "$CANDIDATE_BINARY" || fail "snell-server 权限设置失败。"
    if ! output="$("$CANDIDATE_BINARY" -v 2>&1)"; then
        fail "snell-server 二进制预检失败：${output:-无错误输出}"
    fi
    [[ "$output" == *"snell-server v${TARGET_VERSION%%.*}."* ]] || fail "snell-server 大版本校验失败。"
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
    if [ -n "$CANDIDATE_BINARY" ] && publish_file "$CANDIDATE_BINARY" "$SNELL_BINARY" 755; then
        BINARY_CHANGED=1
        log_info "已安装 Snell 二进制：${TARGET_VERSION}"
    fi
    if publish_file "${WORK_DIR}/snell.conf" "$SNELL_CONFIG_FILE" 600; then
        CONFIG_CHANGED=1
        log_info "已更新 Snell 配置：$SNELL_CONFIG_FILE"
    fi
    if publish_file "${WORK_DIR}/snell.service" "$SNELL_UNIT_FILE" 644; then
        UNIT_CHANGED=1
        log_info "已更新系统服务：snell.service"
    fi
}

converge_service() {
    if [ "$UNIT_CHANGED" -eq 1 ]; then
        systemctl daemon-reload >/dev/null 2>&1 || fail "systemd daemon 重载失败。"
    fi
    if ! systemctl is-enabled --quiet snell.service 2>/dev/null; then
        systemctl enable snell.service >/dev/null 2>&1 || fail "snell.service 启用失败。"
        log_info "已启用系统服务：snell.service"
    fi
    if ! systemctl is-active --quiet snell.service 2>/dev/null; then
        systemctl start snell.service >/dev/null 2>&1 ||
            fail "Snell 启动失败，请执行：journalctl -u snell --no-pager"
    elif (( BINARY_CHANGED || CONFIG_CHANGED || UNIT_CHANGED )); then
        systemctl restart snell.service >/dev/null 2>&1 ||
            fail "Snell 重启失败，请执行：journalctl -u snell --no-pager"
    else
        return 0
    fi
    sleep 2
}

cleanup_work_dir() {
    [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
}

uninstall_snell() {
    if [ ! -e "$SNELL_BINARY" ] && [ ! -e "$SNELL_CONFIG_FILE" ] && [ ! -e "$SNELL_UNIT_FILE" ] &&
       ! systemctl is-active --quiet snell.service 2>/dev/null &&
       ! systemctl cat snell.service >/dev/null 2>&1; then
        log_info "Snell 已不存在，无需卸载。"
        return 0
    fi
    if systemctl is-active --quiet snell.service 2>/dev/null; then
        systemctl stop snell.service >/dev/null 2>&1 || fail "Snell 服务停止失败。"
        log_info "已停止系统服务：snell.service"
    fi
    if systemctl is-enabled --quiet snell.service 2>/dev/null; then
        systemctl disable snell.service >/dev/null 2>&1 || fail "Snell 服务禁用失败。"
        log_info "已禁用系统服务：snell.service"
    fi
    rm -f "$SNELL_UNIT_FILE" "$SNELL_CONFIG_FILE" "$SNELL_BINARY" || fail "Snell 文件删除失败。"
    rmdir "$(dirname "$SNELL_CONFIG_FILE")" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || fail "systemd daemon 重载失败。"
    systemctl reset-failed snell.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet snell.service 2>/dev/null ||
       systemctl cat snell.service >/dev/null 2>&1 || [ -e "$SNELL_BINARY" ] ||
       [ -e "$SNELL_CONFIG_FILE" ] || [ -e "$SNELL_UNIT_FILE" ]; then
        fail "Snell 卸载验证失败。"
    fi
    log_info "Snell 已卸载。"
}

verify_service() {
    systemctl is-active --quiet snell.service 2>/dev/null ||
        fail "Snell 服务未运行，请执行：journalctl -u snell --no-pager"
}

show_configuration() {
    local ip
    ip="$(curl -fSs --max-time 5 --retry 1 https://api.ipify.org 2>/dev/null)" || true
    cat <<EOF

=== Snell 客户端配置 ===
服务器：${ip:-无法获取 IP}
端口：${SNELL_PORT}
PSK：${SNELL_PSK}
版本：${TARGET_VERSION:-$CURRENT_VERSION}
========================
EOF
}

show_result() {
    if [ "$UPDATE_REQUESTED" -eq 0 ]; then
        log_info "Snell 已启动，服务端口：$SNELL_PORT"
        show_configuration
    elif [ "$BINARY_CHANGED" -eq 1 ]; then
        log_info "Snell 已更新到：${TARGET_VERSION}"
    else
        log_info "Snell 已是最新版本：${TARGET_VERSION:-$CURRENT_VERSION}"
    fi
}

main() {
    parse_args "$@"
    require_environment
    if [ "$UNINSTALL_REQUESTED" -eq 1 ]; then
        uninstall_snell
        return
    fi
    ensure_dependencies
    WORK_DIR="$(mktemp -d)" || fail "无法创建 Snell 临时目录。"
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
