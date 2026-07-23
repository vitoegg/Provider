#!/bin/bash

set -o pipefail

SNELL_CONFIG_FILE="${SNELL_CONFIG_FILE:-/etc/snell/snell.conf}"
SNELL_UNIT_FILE="${SNELL_UNIT_FILE:-/etc/systemd/system/snell.service}"
SNELL_BINARY="${SNELL_BINARY:-/usr/local/bin/snell-server}"
SNELL_DOWNLOAD_BASE="https://dl.nssurge.com/snell"

ACTION=""
VERSION=""
PORT=""
PSK=""
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
  bash snell.sh --install [VERSION] [--port PORT] [--psk PSK]
  bash snell.sh --update [VERSION]
  bash snell.sh --uninstall

参数：
  -i, --install [VERSION]  安装，可指定版本
  -n, --update [VERSION]   更新，可指定版本
  -u, --uninstall          卸载
  -p, --port PORT          监听端口，范围 10000-60000
  -k, --psk PSK            16 位字母数字预共享密钥
  -h, --help               显示帮助

无参数时显示交互菜单。
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        if [[ "$1" =~ ^(-i|--install|-n|--update|-u|--uninstall)$ ]]; then
            [ -z "$ACTION" ] || fail "只能选择一个操作。"
            if [[ "$1" =~ ^(-i|--install)$ ]]; then
                ACTION=install
            elif [[ "$1" =~ ^(-n|--update)$ ]]; then
                ACTION=update
            else
                ACTION=uninstall
            fi
            shift
            if [ "$ACTION" != uninstall ] && [ "$#" -gt 0 ] && [[ "$1" != -* ]]; then
                VERSION="$1"
                shift
            fi
        elif [[ "$1" =~ ^(-p|--port)$ ]]; then
            if [ "$#" -le 1 ] || [[ "$2" == -* ]]; then
                fail "$1 缺少参数值。"
            fi
            PORT="$2"
            shift 2
        elif [[ "$1" =~ ^(-k|--psk)$ ]]; then
            if [ "$#" -le 1 ] || [[ "$2" == -* ]]; then
                fail "$1 缺少参数值。"
            fi
            PSK="$2"
            shift 2
        elif [[ "$1" =~ ^(-h|--help)$ ]]; then
            show_usage
            exit 0
        else
            fail "未知参数：$1"
        fi
    done

    if [ "$ACTION" != install ] && [ -n "$PORT$PSK" ]; then
        fail "--port 和 --psk 只能用于安装。"
    fi
}

validate_value() {
    local type="$1" value="$2"
    if [ "$type" = version ] && ! [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "版本格式无效：$value；应为 X.Y.Z。"
        return 1
    fi
    if [ "$type" = port ]; then
        if ! [[ "$value" =~ ^[0-9]+$ ]] || (( 10#$value < 10000 || 10#$value > 60000 )); then
            log_error "端口无效：$value；范围应为 10000-60000。"
            return 1
        fi
    fi
    if [ "$type" = psk ] && ! [[ "$value" =~ ^[A-Za-z0-9]{16}$ ]]; then
        log_error "PSK 无效：必须是 16 位字母数字。"
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
    [ "${#missing[@]}" -eq 0 ] && return 0

    log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 ||
        fail "软件包索引更新失败。"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    log_info "已安装依赖：${missing[*]}"
}

detect_arch() {
    local arch

    arch="$(uname -m)"
    if [ "$arch" = x86_64 ]; then
        printf 'amd64\n'
    elif [[ "$arch" =~ ^(i386|i686)$ ]]; then
        printf 'i386\n'
    elif [ "$arch" = aarch64 ]; then
        printf 'aarch64\n'
    elif [ "$arch" = armv7l ]; then
        printf 'armv7l\n'
    else
        fail "不支持的系统架构：$arch"
    fi
}

get_current_version() {
    local output

    [ -x "$SNELL_BINARY" ] || return 1
    output="$("$SNELL_BINARY" -v 2>&1)" || return 1
    [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[0]}"
}

prepare_install_inputs() {
    while [ -z "$PORT" ]; do
        read -r -p '请输入端口（10000-60000）：' PORT || fail "未读取到端口。"
    done
    validate_value port "$PORT" || exit 1

    if [ -z "$PSK" ]; then
        PSK="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16 || true)"
        [ "${#PSK}" -eq 16 ] || fail "PSK 生成失败。"
    fi
    validate_value psk "$PSK" || exit 1
}

render_config() {
    cat <<EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = true
EOF
}

render_service() {
    cat <<EOF
[Unit]
Description=Snell Server
After=network.target

[Service]
Type=simple
LimitNOFILE=65536
ExecStart=${SNELL_BINARY} -c ${SNELL_CONFIG_FILE}
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
}

publish_candidate() {
    local candidate="$1" target="$2" mode="$3"

    if [ -f "$target" ] && cmp -s "$candidate" "$target"; then
        rm -f "$candidate"
        return 10
    fi
    chmod "$mode" "$candidate" || return 1
    mv -f "$candidate" "$target"
}

begin_transaction() {
    local targets names index

    targets=("$SNELL_BINARY" "$SNELL_CONFIG_FILE" "$SNELL_UNIT_FILE")
    names=(binary config unit)
    TRANSACTION_DIR="$(mktemp -d)" || fail "无法创建 Snell 事务目录。"
    if systemctl is-active --quiet snell 2>/dev/null; then
        SERVICE_WAS_ACTIVE=1
    else
        SERVICE_WAS_ACTIVE=0
    fi
    if systemctl is-enabled --quiet snell 2>/dev/null; then
        SERVICE_WAS_ENABLED=1
    else
        SERVICE_WAS_ENABLED=0
    fi

    for index in "${!targets[@]}"; do
        [ -e "${targets[$index]}" ] || continue
        cp -a "${targets[$index]}" "${TRANSACTION_DIR}/${names[$index]}" || {
            rm -rf "$TRANSACTION_DIR"
            fail "无法备份 Snell 当前状态。"
        }
    done
    TRANSACTION_ACTIVE=1
    trap rollback_transaction EXIT
}

rollback_transaction() {
    local targets names index restore_failed=0

    [ "$TRANSACTION_ACTIVE" -eq 1 ] || return 0
    targets=("$SNELL_BINARY" "$SNELL_CONFIG_FILE" "$SNELL_UNIT_FILE")
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
        systemctl enable snell >/dev/null 2>&1 || restore_failed=1
    elif systemctl is-enabled --quiet snell 2>/dev/null; then
        systemctl disable snell >/dev/null 2>&1 || restore_failed=1
    fi
    if [ "$SERVICE_WAS_ACTIVE" -eq 1 ]; then
        if ! systemctl restart snell >/dev/null 2>&1 ||
           ! systemctl is-active --quiet snell 2>/dev/null; then
            restore_failed=1
        fi
    elif systemctl is-active --quiet snell 2>/dev/null; then
        systemctl stop snell >/dev/null 2>&1 || restore_failed=1
    fi

    TRANSACTION_ACTIVE=0
    trap - EXIT
    rm -rf "$TRANSACTION_DIR" || restore_failed=1
    if [ "$restore_failed" -eq 1 ]; then
        log_error "Snell 旧状态恢复失败，请检查文件和服务状态。"
        return 1
    fi
    log_warning "Snell 变更失败，已恢复旧状态。"
}

commit_transaction() {
    TRANSACTION_ACTIVE=0
    trap - EXIT
    rm -rf "$TRANSACTION_DIR" || log_warning "Snell 事务临时目录清理失败：$TRANSACTION_DIR"
}

apply_files() {
    local config_dir unit_dir candidate result

    config_dir="$(dirname "$SNELL_CONFIG_FILE")"
    unit_dir="$(dirname "$SNELL_UNIT_FILE")"
    mkdir -p "$config_dir" "$unit_dir" || fail "无法创建 Snell 配置目录。"
    umask 077

    candidate="$(mktemp "${config_dir}/.snell.conf.XXXXXX")" || fail "无法创建 Snell 候选配置。"
    render_config > "$candidate" || {
        rm -f "$candidate"
        fail "Snell 配置生成失败。"
    }
    publish_candidate "$candidate" "$SNELL_CONFIG_FILE" 600
    result=$?
    if [ "$result" -eq 0 ]; then
        CONFIG_CHANGED=1
        log_info "已更新 Snell 配置：$SNELL_CONFIG_FILE"
    elif [ "$result" -eq 10 ]; then
        CONFIG_CHANGED=0
    else
        rm -f "$candidate"
        fail "Snell 配置应用失败。"
    fi

    candidate="$(mktemp "${unit_dir}/.snell.service.XXXXXX")" || fail "无法创建 Snell unit 候选文件。"
    render_service > "$candidate" || {
        rm -f "$candidate"
        fail "Snell unit 生成失败。"
    }
    publish_candidate "$candidate" "$SNELL_UNIT_FILE" 644
    result=$?
    if [ "$result" -eq 0 ]; then
        UNIT_CHANGED=1
        log_info "已更新系统服务：snell.service"
    elif [ "$result" -eq 10 ]; then
        UNIT_CHANGED=0
    else
        rm -f "$candidate"
        fail "Snell unit 应用失败。"
    fi
}

download_server() {
    local version="$1" arch temp_dir archive candidate install_candidate output

    validate_value version "$version" || exit 1
    arch="$(detect_arch)"
    [ -d "$TRANSACTION_DIR" ] || fail "Snell 事务尚未开始。"
    temp_dir="$(mktemp -d "${TRANSACTION_DIR}/download.XXXXXX")" || fail "无法创建下载临时目录。"
    archive="${temp_dir}/snell.zip"

    log_info "正在下载 Snell ${version}（${arch}）"
    curl -fSsL --connect-timeout 10 --max-time 120 --retry 2 -o "$archive" \
        "${SNELL_DOWNLOAD_BASE}/snell-server-v${version}-linux-${arch}.zip" || fail "Snell 下载失败。"
    [ -s "$archive" ] || fail "Snell 下载文件为空。"
    unzip -q "$archive" -d "$temp_dir" || fail "Snell 解压失败。"
    candidate="${temp_dir}/snell-server"
    [ -f "$candidate" ] || fail "压缩包中未找到 snell-server。"
    chmod 755 "$candidate" || fail "Snell 二进制权限设置失败。"
    output="$("$candidate" -v 2>&1)" || fail "Snell 二进制预检失败。"
    [[ "$output" == *"$version"* ]] || fail "Snell 版本校验失败。"

    if [ -f "$SNELL_BINARY" ] && cmp -s "$candidate" "$SNELL_BINARY"; then
        BINARY_CHANGED=0
        return 0
    fi
    mkdir -p "$(dirname "$SNELL_BINARY")" || fail "无法创建 Snell 安装目录。"
    install_candidate="$(mktemp "$(dirname "$SNELL_BINARY")/.snell-server.XXXXXX")" ||
        fail "无法创建 Snell 安装候选文件。"
    if ! install -m 755 "$candidate" "$install_candidate"; then
        rm -f "$install_candidate"
        fail "Snell 二进制安装失败。"
    fi
    if ! mv -f "$install_candidate" "$SNELL_BINARY"; then
        rm -f "$install_candidate"
        fail "Snell 二进制安装失败。"
    fi
    BINARY_CHANGED=1
}

ensure_server() {
    if [ -x "$SNELL_BINARY" ] && [ -z "$VERSION" ]; then
        BINARY_CHANGED=0
        return 0
    fi
    while [ -z "$VERSION" ]; do
        read -r -p '请输入 Snell 版本（例如 4.1.1）：' VERSION || fail "未读取到 Snell 版本。"
    done
    download_server "$VERSION"
}

converge_service() {
    if [ "$UNIT_CHANGED" -eq 1 ]; then
        systemctl daemon-reload >/dev/null 2>&1 || {
            log_error "systemd daemon 重载失败。"
            return 1
        }
    fi
    if ! systemctl is-enabled --quiet snell 2>/dev/null; then
        systemctl enable snell >/dev/null 2>&1 || {
            log_error "snell.service 启用失败。"
            return 1
        }
        log_info "已启用系统服务：snell.service"
    fi

    if systemctl is-active --quiet snell 2>/dev/null; then
        if (( BINARY_CHANGED || CONFIG_CHANGED || UNIT_CHANGED )); then
            systemctl restart snell >/dev/null 2>&1 || {
                log_error "Snell 重启失败，请执行：journalctl -u snell --no-pager"
                return 1
            }
        fi
    else
        systemctl start snell >/dev/null 2>&1 || {
            log_error "Snell 启动失败，请执行：journalctl -u snell --no-pager"
            return 1
        }
    fi
}

read_current_configuration() {
    [ -r "$SNELL_CONFIG_FILE" ] || fail "未找到 Snell 配置：$SNELL_CONFIG_FILE"
    PORT="$(sed -n 's/^listen = ::0:\([0-9][0-9]*\)$/\1/p' "$SNELL_CONFIG_FILE" | head -n 1)"
    PSK="$(sed -n 's/^psk = \([A-Za-z0-9][A-Za-z0-9]*\)$/\1/p' "$SNELL_CONFIG_FILE" | head -n 1)"
    validate_value port "$PORT" >/dev/null 2>&1 || fail "现有 Snell 端口无法解析。"
    validate_value psk "$PSK" >/dev/null 2>&1 || fail "现有 Snell PSK 无法解析。"
}

install_snell() {
    ensure_dependencies
    prepare_install_inputs
    begin_transaction
    ensure_server
    apply_files
    if ! converge_service || ! verify_service; then
        if rollback_transaction; then
            fail "Snell 应用失败，已恢复旧状态。"
        fi
        fail "Snell 应用失败，且旧状态恢复失败。"
    fi
    commit_transaction
    [ "$BINARY_CHANGED" -eq 0 ] || log_info "已安装 Snell 二进制。"
    log_info "Snell 已启动，服务端口：$PORT"
    show_configuration
}

update_snell() {
    local current_version highest

    ensure_dependencies
    current_version="$(get_current_version)" || fail "Snell 未安装或版本无法读取。"
    while [ -z "$VERSION" ]; do
        read -r -p '请输入目标 Snell 版本：' VERSION || fail "未读取到目标版本。"
    done
    validate_value version "$VERSION" || exit 1
    highest="$(printf '%s\n%s\n' "$VERSION" "$current_version" | sort -V | tail -n 1)"
    if [ "$highest" != "$VERSION" ] || [ "$VERSION" = "$current_version" ]; then
        log_info "无需更新：当前版本 ${current_version}，目标版本 ${VERSION}。"
        return 0
    fi

    read_current_configuration
    begin_transaction
    download_server "$VERSION"
    if ! converge_service || ! verify_service; then
        if rollback_transaction; then
            fail "Snell 更新失败，已恢复旧状态。"
        fi
        fail "Snell 更新失败，且旧状态恢复失败。"
    fi
    commit_transaction
    log_info "Snell 已更新：${current_version} -> ${VERSION}"
    show_configuration
}

uninstall_snell() {
    if [ ! -e "$SNELL_BINARY" ] && [ ! -e "$SNELL_CONFIG_FILE" ] &&
       [ ! -e "$SNELL_UNIT_FILE" ] && ! systemctl is-active --quiet snell 2>/dev/null &&
       ! systemctl cat snell.service >/dev/null 2>&1; then
        log_info "Snell 已不存在，无需卸载。"
        return 0
    fi

    if systemctl is-active --quiet snell 2>/dev/null; then
        systemctl stop snell >/dev/null 2>&1 || fail "Snell 服务停止失败。"
        log_info "已停止系统服务：snell.service"
    fi
    if systemctl is-enabled --quiet snell 2>/dev/null; then
        systemctl disable snell >/dev/null 2>&1 || fail "Snell 服务禁用失败。"
        log_info "已禁用系统服务：snell.service"
    fi
    rm -f "$SNELL_UNIT_FILE" "$SNELL_CONFIG_FILE" "$SNELL_BINARY" || fail "Snell 文件删除失败。"
    rmdir "$(dirname "$SNELL_CONFIG_FILE")" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || fail "systemd daemon 重载失败。"
    systemctl reset-failed snell >/dev/null 2>&1 || true
    if systemctl is-active --quiet snell 2>/dev/null ||
       systemctl cat snell.service >/dev/null 2>&1 || [ -e "$SNELL_BINARY" ] ||
       [ -e "$SNELL_CONFIG_FILE" ] || [ -e "$SNELL_UNIT_FILE" ]; then
        fail "Snell 卸载验证失败。"
    fi
    log_info "Snell 已卸载。"
}

verify_service() {
    systemctl is-active --quiet snell 2>/dev/null || {
        log_error "Snell 服务未运行，请执行：journalctl -u snell --no-pager"
        return 1
    }
}

show_configuration() {
    local current_version ip

    current_version="$(get_current_version 2>/dev/null || printf '%s' "${VERSION:-未知}")"
    ip="$(curl -fSs --max-time 5 --retry 1 https://api.ipify.org 2>/dev/null)" || true
    cat <<EOF

=== Snell 客户端配置 ===
服务器：${ip:-无法获取 IP}
端口：${PORT}
PSK：${PSK}
版本：${current_version}
========================
EOF
}

main() {
    local choice

    parse_args "$@"
    require_environment
    if [ -z "$ACTION" ]; then
        printf '1. 安装 Snell\n2. 更新 Snell\n3. 卸载 Snell\n'
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
        install_snell
    elif [ "$ACTION" = update ]; then
        update_snell
    else
        uninstall_snell
    fi
}

main "$@"
