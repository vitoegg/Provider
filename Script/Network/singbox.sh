#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

DEFAULT_PORT_START=50000
DEFAULT_PORT_END=60000
DEFAULT_PADDING_SCHEME="stop=3|0=30-30|1=140-320|2=420-780,c,780-1400"
SS_METHOD="2022-blake3-aes-128-gcm"
WARP_TAG="warp"
DIRECT_TAG="direct"
WARP_ENDPOINT_HOST="engage.cloudflareclient.com"
WARP_ENDPOINT_PORT=2408
WARP_MTU=1280
WARP_ADDRESS_IPV4="172.16.0.2/32"
WARP_ALLOWED_IP_IPV4="0.0.0.0/0"
WARP_ALLOWED_IP_IPV6="::/0"
WARP_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
WARP_KEEPALIVE=30
WARP_RULESET_TAG="pureSite"
WARP_RULESET_FORMAT="source"
WARP_RULESET_URL="https://raw.githubusercontent.com/vitoegg/Provider/master/RuleSet/Extra/Singbox/pureSite.json"

ARCH=""
PROTOCOLS=""
ANYTLS_ENABLED=0
SS_ENABLED=0
WARP_ENABLED=0

SINGBOX_VERSION=""
UPDATE_REQUESTED=0
UNINSTALL_REQUESTED=0

ANYTLS_PORT=""
ANYTLS_PORT_SET=0
ANYTLS_PASSWORD=""
ANYTLS_DOMAIN=""
ANYTLS_SCHEME=""
ANYTLS_CERT_MODE=""
ANYTLS_TOKEN=""
ANYTLS_CERT_PATH=""
ANYTLS_KEY_PATH=""

SS_PORT=""
SS_PORT_SET=0
SS_PASSWORD=""

WARP_KEY=""
WARP_ADDRESS=""

USED_PORTS=()

log_info() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*"
}

log_success() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] ${GREEN}$*${NC}"
}

log_warning() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [WARNING] ${YELLOW}$*${NC}"
}

log_error() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] ${RED}$*${NC}" >&2
}

print_header() {
    echo -e "\n${BOLD}=== $1 ===${NC}"
}

show_usage() {
    local name
    name="$(basename "$0")"
    cat << EOF
用法:
  bash ${name} --protocol anytls|shadowsocks|anytls,shadowsocks [OPTIONS]

协议:
  --protocol LIST

AnyTLS:
  --anytls-port PORT
  --anytls-password PASS
  --anytls-domain DOMAIN
  --anytls-scheme SCHEME
  --anytls-cert-mode acme|manual
  --anytls-token TOKEN
  --anytls-cert-path PATH
  --anytls-key-path PATH

Shadowsocks:
  --ss-port PORT
  --ss-password PASSWORD

WARP:
  --warp-key KEY
  --warp-address IPV6_CIDR  可选，提供后启用 IPv6 WARP address

全局:
  --version VERSION
  --update
  --uninstall
  -h, --help
EOF
}

cleanup_temp_files() {
    rm -f /tmp/sing-box.deb /tmp/sing-box-update.tar.gz /tmp/sing-box-binary-backup 2>/dev/null
    rm -rf /tmp/sing-box-update 2>/dev/null
}
trap cleanup_temp_files EXIT

package_known() {
    dpkg-query -W -f='${db:Status-Abbrev}' sing-box >/dev/null 2>&1
}

service_known() {
    systemctl list-unit-files --no-legend sing-box.service 2>/dev/null | grep -q '^sing-box\.service[[:space:]]'
}

remove_path() {
    local path="$1"

    if [[ ! -e "$path" ]]; then
        log_info "未发现: $path"
        return 0
    fi

    rm -rf "$path" || {
        log_error "删除失败: $path"
        return 1
    }
    log_info "已删除: $path"
}

verify_uninstalled() {
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        log_error "验证失败: sing-box 服务仍在运行"
        return 1
    fi

    if service_known; then
        log_error "验证失败: sing-box 服务单元仍存在"
        return 1
    fi

    if package_known; then
        log_error "验证失败: sing-box 包仍存在"
        return 1
    fi

    if [[ -e /etc/sing-box ]]; then
        log_error "验证失败: /etc/sing-box 仍存在"
        return 1
    fi

    if [[ -e /var/lib/sing-box ]]; then
        log_error "验证失败: /var/lib/sing-box 仍存在"
        return 1
    fi

    if command -v sing-box >/dev/null 2>&1; then
        log_error "验证失败: sing-box 仍在 PATH 中"
        return 1
    fi

    log_success "验证通过: 服务、包、配置、状态目录、命令均已清理"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限执行。"
        exit 1
    fi
}

need_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" ]]; then
        log_error "$option 缺少参数值。"
        exit 1
    fi
    printf '%s' "$value"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --protocol)
                PROTOCOLS="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --protocol=*)
                PROTOCOLS="${1#*=}"
                shift
                ;;
            --anytls-port)
                ANYTLS_PORT="$(need_value "$1" "${2:-}")"
                ANYTLS_PORT_SET=1
                shift 2
                ;;
            --anytls-port=*)
                ANYTLS_PORT="${1#*=}"
                ANYTLS_PORT_SET=1
                shift
                ;;
            --anytls-password)
                ANYTLS_PASSWORD="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --anytls-password=*)
                ANYTLS_PASSWORD="${1#*=}"
                shift
                ;;
            --anytls-domain)
                ANYTLS_DOMAIN="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --anytls-domain=*)
                ANYTLS_DOMAIN="${1#*=}"
                shift
                ;;
            --anytls-scheme)
                ANYTLS_SCHEME="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --anytls-scheme=*)
                ANYTLS_SCHEME="${1#*=}"
                shift
                ;;
            --anytls-cert-mode)
                ANYTLS_CERT_MODE="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --anytls-cert-mode=*)
                ANYTLS_CERT_MODE="${1#*=}"
                shift
                ;;
            --anytls-token)
                ANYTLS_TOKEN="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --anytls-token=*)
                ANYTLS_TOKEN="${1#*=}"
                shift
                ;;
            --anytls-cert-path)
                ANYTLS_CERT_PATH="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --anytls-cert-path=*)
                ANYTLS_CERT_PATH="${1#*=}"
                shift
                ;;
            --anytls-key-path)
                ANYTLS_KEY_PATH="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --anytls-key-path=*)
                ANYTLS_KEY_PATH="${1#*=}"
                shift
                ;;
            --ss-port)
                SS_PORT="$(need_value "$1" "${2:-}")"
                SS_PORT_SET=1
                shift 2
                ;;
            --ss-port=*)
                SS_PORT="${1#*=}"
                SS_PORT_SET=1
                shift
                ;;
            --ss-password)
                SS_PASSWORD="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --ss-password=*)
                SS_PASSWORD="${1#*=}"
                shift
                ;;
            --warp-key)
                WARP_KEY="$(need_value "$1" "${2:-}")"
                WARP_ENABLED=1
                shift 2
                ;;
            --warp-key=*)
                WARP_KEY="${1#*=}"
                WARP_ENABLED=1
                shift
                ;;
            --warp-address)
                WARP_ADDRESS="$(need_value "$1" "${2:-}")"
                WARP_ENABLED=1
                shift 2
                ;;
            --warp-address=*)
                WARP_ADDRESS="${1#*=}"
                WARP_ENABLED=1
                shift
                ;;
            --version)
                SINGBOX_VERSION="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --version=*)
                SINGBOX_VERSION="${1#*=}"
                shift
                ;;
            --update)
                UPDATE_REQUESTED=1
                shift
                ;;
            -u|--uninstall)
                UNINSTALL_REQUESTED=1
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

parse_protocols() {
    local protocol

    if [[ -z "$PROTOCOLS" ]]; then
        log_error "缺少 --protocol。"
        show_usage
        exit 1
    fi

    IFS=',' read -ra protocol_items <<< "$PROTOCOLS"
    for protocol in "${protocol_items[@]}"; do
        protocol="${protocol//[[:space:]]/}"
        case "$protocol" in
            anytls)
                ANYTLS_ENABLED=1
                ;;
            shadowsocks)
                SS_ENABLED=1
                ;;
            "")
                log_error "--protocol 包含空协议。"
                exit 1
                ;;
            *)
                log_error "不支持的协议: $protocol"
                exit 1
                ;;
        esac
    done
}

validate_protocol_scope() {
    if [[ "$ANYTLS_ENABLED" -eq 0 ]]; then
        if [[ -n "$ANYTLS_PORT$ANYTLS_PASSWORD$ANYTLS_DOMAIN$ANYTLS_SCHEME$ANYTLS_CERT_MODE$ANYTLS_TOKEN$ANYTLS_CERT_PATH$ANYTLS_KEY_PATH" ]]; then
            log_error "AnyTLS 参数需要 --protocol anytls。"
            exit 1
        fi
    fi

    if [[ "$SS_ENABLED" -eq 0 ]]; then
        if [[ -n "$SS_PORT$SS_PASSWORD" ]]; then
            log_error "Shadowsocks 参数需要 --protocol shadowsocks。"
            exit 1
        fi
    fi
}

detect_arch() {
    print_header "检测系统架构"
    case "$(uname -m)" in
        x86_64)
            ARCH="amd64"
            ;;
        x86|i686|i386)
            ARCH="386"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l)
            ARCH="armv7"
            ;;
        s390x)
            ARCH="s390x"
            ;;
        *)
            log_error "不支持的系统架构: $(uname -m)"
            exit 1
            ;;
    esac
    log_success "系统架构: $ARCH"
}

install_packages() {
    print_header "安装依赖"
    local packages_needed=(wget dpkg jq tar)
    local pkg

    if ! command -v apt-get >/dev/null 2>&1; then
        log_error "仅支持 Debian/Ubuntu apt 环境。"
        exit 1
    fi

    log_info "更新软件源..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1; then
        log_error "软件源更新失败。"
        exit 1
    fi

    for pkg in "${packages_needed[@]}"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            log_info "依赖已存在: $pkg"
            continue
        fi

        log_info "安装依赖: $pkg"
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" -qq >/dev/null 2>&1; then
            log_error "依赖安装失败: $pkg"
            exit 1
        fi
    done

    log_success "依赖已就绪"
}

ensure_time_sync() {
    print_header "时间同步"
    local old_services=(systemd-timesyncd.service ntp.service ntpsec.service openntpd.service)

    if systemctl is-active --quiet chrony 2>/dev/null; then
        log_info "chrony 已经运行，跳过安装"
    else
        log_info "安装 chrony..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y chrony -qq >/dev/null 2>&1; then
            log_error "chrony 安装失败。"
            exit 1
        fi
    fi

    log_info "停用其它时间同步服务..."
    for service in "${old_services[@]}"; do
        systemctl disable --now "$service" >/dev/null 2>&1 || true
    done

    log_info "启动 chrony..."
    if ! systemctl enable --now chrony >/dev/null 2>&1; then
        log_error "chrony 启动失败。"
        exit 1
    fi

    if ! systemctl is-active --quiet chrony 2>/dev/null; then
        log_error "chrony 未运行。"
        exit 1
    fi

    log_success "chrony 正在运行"
}

generate_port() {
    local start="$1"
    local end="$2"
    local port

    while true; do
        port="$(shuf -i "${start}-${end}" -n 1)"
        if [[ "$port" != *4* ]]; then
            printf '%s\n' "$port"
            return 0
        fi
    done
}

port_is_used() {
    local candidate="$1"
    local port

    for port in "${USED_PORTS[@]}"; do
        [[ "$port" == "$candidate" ]] && return 0
    done

    return 1
}

validate_port() {
    local port="$1"
    local name="$2"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$name 端口无效: $port"
        exit 1
    fi
}

add_used_port() {
    local port="$1"
    local name="$2"

    validate_port "$port" "$name"
    if port_is_used "$port"; then
        log_error "端口冲突: $port"
        exit 1
    fi

    USED_PORTS+=("$port")
}

generate_unique_port() {
    local port

    while true; do
        port="$(generate_port "$DEFAULT_PORT_START" "$DEFAULT_PORT_END")"
        if ! port_is_used "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
}

prepare_ports() {
    USED_PORTS=()

    if [[ "$ANYTLS_ENABLED" -eq 1 && -n "$ANYTLS_PORT" ]]; then
        add_used_port "$ANYTLS_PORT" "AnyTLS"
    fi

    if [[ "$SS_ENABLED" -eq 1 && -n "$SS_PORT" ]]; then
        add_used_port "$SS_PORT" "Shadowsocks"
    fi

    if [[ "$ANYTLS_ENABLED" -eq 1 && -z "$ANYTLS_PORT" ]]; then
        ANYTLS_PORT="$(generate_unique_port)"
        add_used_port "$ANYTLS_PORT" "AnyTLS"
        log_info "生成 AnyTLS 端口: $ANYTLS_PORT"
    elif [[ "$ANYTLS_ENABLED" -eq 1 && "$ANYTLS_PORT_SET" -eq 1 ]]; then
        log_info "使用指定 AnyTLS 端口: $ANYTLS_PORT"
    fi

    if [[ "$SS_ENABLED" -eq 1 && -z "$SS_PORT" ]]; then
        SS_PORT="$(generate_unique_port)"
        add_used_port "$SS_PORT" "Shadowsocks"
        log_info "生成 Shadowsocks 端口: $SS_PORT"
    elif [[ "$SS_ENABLED" -eq 1 && "$SS_PORT_SET" -eq 1 ]]; then
        log_info "使用指定 Shadowsocks 端口: $SS_PORT"
    fi
}

get_ipv4_address() {
    local ip
    ip="$(wget -qO- --timeout=5 --tries=2 https://api.ipify.org 2>/dev/null)"
    if [[ -z "$ip" ]]; then
        printf '无法获取 IP\n'
    else
        printf '%s\n' "$ip"
    fi
}

get_current_version() {
    if command -v sing-box >/dev/null 2>&1; then
        sing-box version 2>/dev/null | head -n1 | awk '{print $3}' | sed 's/^v//'
    fi
}

compare_versions() {
    local version1="${1#v}"
    local version2="${2#v}"
    local max_parts i part1 part2

    [[ "$version1" == "$version2" ]] && return 0

    IFS='.' read -ra ver1_parts <<< "$version1"
    IFS='.' read -ra ver2_parts <<< "$version2"
    max_parts=$((${#ver1_parts[@]} > ${#ver2_parts[@]} ? ${#ver1_parts[@]} : ${#ver2_parts[@]}))

    for ((i=0; i<max_parts; i++)); do
        part1="${ver1_parts[i]:-0}"
        part2="${ver2_parts[i]:-0}"
        part1="$(echo "$part1" | sed 's/[^0-9].*//')"
        part2="$(echo "$part2" | sed 's/[^0-9].*//')"
        part1="${part1:-0}"
        part2="${part2:-0}"

        if (( part1 > part2 )); then
            return 1
        elif (( part1 < part2 )); then
            return 2
        fi
    done

    return 0
}

install_singbox() {
    print_header "安装 sing-box"
    local target_version
    local download_url
    local temp_file="/tmp/sing-box.deb"

    if command -v sing-box >/dev/null 2>&1 && [[ -z "$SINGBOX_VERSION" ]]; then
        log_info "sing-box 已存在: $(command -v sing-box)"
        return 0
    fi

    if [[ -n "$SINGBOX_VERSION" ]]; then
        target_version="$SINGBOX_VERSION"
        [[ "$target_version" == v* ]] || target_version="v$target_version"
        log_info "使用指定版本: $target_version"
    else
        log_info "获取最新版本..."
        target_version="$(wget -qO- --timeout=10 --tries=3 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r .tag_name)"
        if [[ -z "$target_version" || "$target_version" == "null" ]]; then
            log_error "无法获取 sing-box 发布版本。"
            exit 1
        fi
    fi

    download_url="https://github.com/SagerNet/sing-box/releases/download/${target_version}/sing-box_${target_version#v}_linux_${ARCH}.deb"
    log_info "下载 sing-box: $download_url"
    if ! wget --no-check-certificate -q -O "$temp_file" "$download_url"; then
        log_error "sing-box 安装包下载失败。"
        exit 1
    fi

    log_info "安装 sing-box 包..."
    if ! DEBIAN_FRONTEND=noninteractive dpkg -i "$temp_file" >/dev/null 2>&1; then
        log_error "sing-box 包安装失败。"
        exit 1
    fi

    rm -f "$temp_file"
    log_success "sing-box 安装完成"
}

update_singbox() {
    print_header "更新 sing-box"
    local current_version latest_version comparison_result
    local service_was_running=0
    local binary_backup="/tmp/sing-box-binary-backup"
    local temp_archive="/tmp/sing-box-update.tar.gz"
    local temp_dir="/tmp/sing-box-update"
    local download_url binary_file new_version

    if ! command -v sing-box >/dev/null 2>&1; then
        log_error "sing-box 未安装。"
        return 1
    fi

    detect_arch
    install_packages

    current_version="$(get_current_version)"
    if [[ -z "$current_version" ]]; then
        log_error "无法获取当前 sing-box 版本。"
        return 1
    fi
    log_info "当前版本: $current_version"

    latest_version="$(wget -qO- --timeout=10 --tries=3 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r .tag_name)"
    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        log_error "无法获取最新 sing-box 版本。"
        return 1
    fi
    log_info "最新版本: $latest_version"

    compare_versions "$latest_version" "$current_version"
    comparison_result=$?
    if [[ "$comparison_result" -eq 0 ]]; then
        log_info "sing-box 已是最新版本。"
        return 0
    elif [[ "$comparison_result" -eq 2 ]]; then
        log_warning "当前版本高于最新发布版本，跳过更新。"
        return 0
    fi

    if systemctl is-active --quiet sing-box 2>/dev/null; then
        service_was_running=1
        log_info "停止 sing-box 服务..."
        if ! systemctl stop sing-box >/dev/null 2>&1; then
            log_error "sing-box 服务停止失败。"
            return 1
        fi
    fi

    if [[ -f "/usr/bin/sing-box" ]]; then
        cp "/usr/bin/sing-box" "$binary_backup" || return 1
    fi

    download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${latest_version#v}-linux-${ARCH}.tar.gz"
    log_info "下载 sing-box 二进制: $download_url"
    if ! wget --no-check-certificate -q -O "$temp_archive" "$download_url"; then
        log_error "sing-box 二进制下载失败。"
        [[ "$service_was_running" -eq 1 ]] && systemctl start sing-box >/dev/null 2>&1
        return 1
    fi

    mkdir -p "$temp_dir"
    if ! tar -xzf "$temp_archive" -C "$temp_dir" >/dev/null 2>&1; then
        log_error "sing-box 压缩包解压失败。"
        [[ "$service_was_running" -eq 1 ]] && systemctl start sing-box >/dev/null 2>&1
        return 1
    fi

    binary_file="$(find "$temp_dir" -name "sing-box" -type f | head -n1)"
    if [[ -z "$binary_file" ]]; then
        log_error "压缩包内未找到 sing-box 二进制。"
        [[ "$service_was_running" -eq 1 ]] && systemctl start sing-box >/dev/null 2>&1
        return 1
    fi

    if ! cp "$binary_file" "/usr/bin/sing-box"; then
        log_error "sing-box 二进制替换失败。"
        [[ -f "$binary_backup" ]] && cp "$binary_backup" "/usr/bin/sing-box"
        [[ "$service_was_running" -eq 1 ]] && systemctl start sing-box >/dev/null 2>&1
        return 1
    fi

    chmod +x "/usr/bin/sing-box" >/dev/null 2>&1
    new_version="$(get_current_version)"
    if [[ "$new_version" != "${latest_version#v}" ]]; then
        log_error "版本校验失败，期望 ${latest_version#v}，实际 $new_version。"
        return 1
    fi

    cleanup_temp_files
    if [[ "$service_was_running" -eq 1 ]]; then
        systemctl start sing-box >/dev/null 2>&1 || return 1
    fi

    log_success "sing-box 已更新: $current_version -> $new_version"
}

generate_password() {
    local password

    password="$(sing-box generate rand --base64 16 2>/dev/null)"
    if [[ -z "$password" ]]; then
        log_error "密码生成失败。"
        exit 1
    fi

    printf '%s\n' "$password"
}

prepare_anytls_params() {
    if [[ "$ANYTLS_ENABLED" -ne 1 ]]; then
        return 0
    fi

    if [[ -z "$ANYTLS_PASSWORD" ]]; then
        ANYTLS_PASSWORD="$(generate_password)"
        log_info "生成 AnyTLS 密码"
    else
        log_info "使用指定 AnyTLS 密码"
    fi

    if [[ -z "$ANYTLS_DOMAIN" ]]; then
        log_error "启用 AnyTLS 时必须提供 --anytls-domain。"
        exit 1
    fi

    if [[ -z "$ANYTLS_CERT_MODE" ]]; then
        if [[ -n "$ANYTLS_CERT_PATH$ANYTLS_KEY_PATH" ]]; then
            ANYTLS_CERT_MODE="manual"
        elif [[ -n "$ANYTLS_TOKEN" ]]; then
            ANYTLS_CERT_MODE="acme"
        else
            log_error "AnyTLS 需要 --anytls-token 或手动证书路径。"
            exit 1
        fi
    fi

    case "$ANYTLS_CERT_MODE" in
        acme)
            if [[ -z "$ANYTLS_TOKEN" ]]; then
                log_error "AnyTLS ACME 模式需要 --anytls-token。"
                exit 1
            fi
            if [[ -n "$ANYTLS_CERT_PATH$ANYTLS_KEY_PATH" ]]; then
                log_error "ACME 模式不能使用手动证书路径。"
                exit 1
            fi
            ;;
        manual)
            if [[ -n "$ANYTLS_TOKEN" ]]; then
                log_error "手动证书模式不能使用 --anytls-token。"
                exit 1
            fi
            if [[ -z "$ANYTLS_CERT_PATH" || -z "$ANYTLS_KEY_PATH" ]]; then
                log_error "手动证书模式需要 --anytls-cert-path 和 --anytls-key-path。"
                exit 1
            fi
            if [[ ! -f "$ANYTLS_CERT_PATH" ]]; then
                log_error "证书文件不存在: $ANYTLS_CERT_PATH"
                exit 1
            fi
            if [[ ! -f "$ANYTLS_KEY_PATH" ]]; then
                log_error "私钥文件不存在: $ANYTLS_KEY_PATH"
                exit 1
            fi
            ;;
        *)
            log_error "AnyTLS 证书模式无效: $ANYTLS_CERT_MODE"
            exit 1
            ;;
    esac
}

prepare_shadowsocks_params() {
    if [[ "$SS_ENABLED" -ne 1 ]]; then
        return 0
    fi

    if [[ -z "$SS_PASSWORD" ]]; then
        SS_PASSWORD="$(generate_password)"
        log_info "生成 Shadowsocks 密码"
    else
        log_info "使用指定 Shadowsocks 密码"
    fi
}

prepare_warp_params() {
    if [[ "$WARP_ENABLED" -ne 1 ]]; then
        return 0
    fi

    if [[ -z "$WARP_KEY" ]]; then
        log_error "启用 WARP 时必须提供 --warp-key。"
        exit 1
    fi
    log_info "启用 WARP 分流"
}

prepare_config_params() {
    print_header "准备配置"
    prepare_ports
    prepare_anytls_params
    prepare_shadowsocks_params
    prepare_warp_params
    log_success "配置参数已就绪"
}

generate_padding_scheme_json() {
    local scheme_str="${1:-$DEFAULT_PADDING_SCHEME}"

    jq -n --arg scheme "$scheme_str" '$scheme | split("|") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

build_anytls_inbound() {
    local padding_json
    padding_json="$(generate_padding_scheme_json "$ANYTLS_SCHEME")"

    if [[ "$ANYTLS_CERT_MODE" == "manual" ]]; then
        jq -n \
            --argjson port "$ANYTLS_PORT" \
            --arg password "$ANYTLS_PASSWORD" \
            --arg domain "$ANYTLS_DOMAIN" \
            --argjson padding "$padding_json" \
            --arg cert_path "$ANYTLS_CERT_PATH" \
            --arg key_path "$ANYTLS_KEY_PATH" \
            '{
              type: "anytls",
              tag: "anytls-in",
              listen: "::",
              listen_port: $port,
              users: [{ name: "AnyCloud", password: $password }],
              padding_scheme: $padding,
              tls: {
                enabled: true,
                alpn: ["h2", "http/1.1"],
                server_name: $domain,
                certificate_path: $cert_path,
                key_path: $key_path
              }
            }'
    else
        jq -n \
            --argjson port "$ANYTLS_PORT" \
            --arg password "$ANYTLS_PASSWORD" \
            --arg domain "$ANYTLS_DOMAIN" \
            --argjson padding "$padding_json" \
            --arg token "$ANYTLS_TOKEN" \
            '{
              type: "anytls",
              tag: "anytls-in",
              listen: "::",
              listen_port: $port,
              users: [{ name: "AnyCloud", password: $password }],
              padding_scheme: $padding,
              tls: {
                enabled: true,
                alpn: ["h2", "http/1.1"],
                server_name: $domain,
                acme: {
                  domain: [$domain],
                  email: "admin@xinsight.eu.org",
                  provider: "letsencrypt",
                  dns01_challenge: {
                    provider: "cloudflare",
                    api_token: $token
                  }
                }
              }
            }'
    fi
}

build_shadowsocks_inbound() {
    jq -n \
        --argjson port "$SS_PORT" \
        --arg method "$SS_METHOD" \
        --arg password "$SS_PASSWORD" \
        '{
          type: "shadowsocks",
          tag: "shadowsocks-in",
          listen: "::",
          listen_port: $port,
          method: $method,
          password: $password
        }'
}

build_warp_config() {
    jq -n \
        --arg warp_tag "$WARP_TAG" \
        --arg direct_tag "$DIRECT_TAG" \
        --argjson mtu "$WARP_MTU" \
        --arg address_ipv4 "$WARP_ADDRESS_IPV4" \
        --arg address_ipv6 "$WARP_ADDRESS" \
        --arg private_key "$WARP_KEY" \
        --arg peer_address "$WARP_ENDPOINT_HOST" \
        --argjson peer_port "$WARP_ENDPOINT_PORT" \
        --arg peer_public_key "$WARP_PUBLIC_KEY" \
        --arg allowed_ip_ipv4 "$WARP_ALLOWED_IP_IPV4" \
        --arg allowed_ip_ipv6 "$WARP_ALLOWED_IP_IPV6" \
        --argjson keepalive "$WARP_KEEPALIVE" \
        --arg rule_set "$WARP_RULESET_TAG" \
        --arg rule_format "$WARP_RULESET_FORMAT" \
        --arg rule_url "$WARP_RULESET_URL" \
        '{
          endpoints: [
            {
              type: "wireguard",
              tag: $warp_tag,
              system: false,
              mtu: $mtu,
              address: ([$address_ipv4] + if $address_ipv6 == "" then [] else [$address_ipv6] end),
              private_key: $private_key,
              peers: [
                {
                  address: $peer_address,
                  port: $peer_port,
                  public_key: $peer_public_key,
                  allowed_ips: ([$allowed_ip_ipv4] + if $address_ipv6 == "" then [] else [$allowed_ip_ipv6] end),
                  persistent_keepalive_interval: $keepalive
                }
              ]
            }
          ],
          outbounds: [
            {
              type: "direct",
              tag: $direct_tag
            }
          ],
          route: {
            rules: [
              {
                rule_set: $rule_set,
                action: "route",
                outbound: $warp_tag
              }
            ],
            rule_set: [
              {
                type: "remote",
                tag: $rule_set,
                format: $rule_format,
                url: $rule_url
              }
            ],
            final: $direct_tag
          }
        }'
}

create_singbox_config() {
    print_header "生成 sing-box 配置"
    local config_dir="/etc/sing-box"
    local config_file="${config_dir}/config.json"
    local temp_file="${config_file}.tmp"
    local inbounds_json="["
    local warp_json
    local first=1
    local inbound

    mkdir -p "$config_dir"
    chmod 755 "$config_dir"

    if [[ "$ANYTLS_ENABLED" -eq 1 ]]; then
        inbound="$(build_anytls_inbound)"
        inbounds_json+="$inbound"
        first=0
    fi

    if [[ "$SS_ENABLED" -eq 1 ]]; then
        inbound="$(build_shadowsocks_inbound)"
        [[ "$first" -eq 0 ]] && inbounds_json+=","
        inbounds_json+="$inbound"
    fi

    inbounds_json+="]"

    if [[ "$WARP_ENABLED" -eq 1 ]]; then
        warp_json="$(build_warp_config)"
        if ! jq -n \
            --argjson inbounds "$inbounds_json" \
            --argjson warp "$warp_json" \
            '{ log: { disabled: true }, inbounds: $inbounds } + $warp' > "$temp_file"; then
            log_error "sing-box 配置生成失败。"
            rm -f "$temp_file"
            exit 1
        fi
    elif ! jq -n --argjson inbounds "$inbounds_json" '{ log: { disabled: true }, inbounds: $inbounds }' > "$temp_file"; then
        log_error "sing-box 配置生成失败。"
        rm -f "$temp_file"
        exit 1
    fi

    mv "$temp_file" "$config_file"
    log_success "配置文件已生成: $config_file"
}

validate_singbox_config() {
    local config_file="/etc/sing-box/config.json"

    print_header "校验 sing-box 配置"
    if ! sing-box check -c "$config_file"; then
        log_error "sing-box 配置校验失败。"
        exit 1
    fi

    log_success "sing-box 配置校验通过"
}

restart_singbox_service() {
    print_header "启动 sing-box 服务"

    if ! systemctl enable sing-box >/dev/null 2>&1; then
        log_error "sing-box 服务启用失败。"
        exit 1
    fi

    if systemctl is-active --quiet sing-box 2>/dev/null; then
        log_info "重启 sing-box 服务..."
        if ! systemctl restart sing-box >/dev/null 2>&1; then
            log_error "sing-box 服务重启失败。"
            log_error "查看日志: journalctl -u sing-box"
            exit 1
        fi
    else
        log_info "启动 sing-box 服务..."
        if ! systemctl start sing-box >/dev/null 2>&1; then
            log_error "sing-box 服务启动失败。"
            log_error "查看日志: journalctl -u sing-box"
            exit 1
        fi
    fi

    sleep 2
    if ! systemctl is-active --quiet sing-box; then
        log_error "sing-box 服务未运行。"
        log_error "查看日志: journalctl -u sing-box"
        exit 1
    fi

    log_success "sing-box 服务运行中"
}

show_configuration() {
    local server_ip
    local status
    local display_scheme
    local warp_address_display

    print_header "配置详情"
    server_ip="$(get_ipv4_address)"
    status="$(systemctl is-active sing-box 2>/dev/null || printf 'unknown')"

    printf "%-22s %s\n" "服务:" "sing-box (${status})"
    printf "%-22s %s\n" "服务器 IP:" "$server_ip"

    if [[ "$ANYTLS_ENABLED" -eq 1 ]]; then
        display_scheme="${ANYTLS_SCHEME:-$DEFAULT_PADDING_SCHEME}"
        echo ""
        echo "AnyTLS:"
        printf "%-22s %s\n" "端口:" "$ANYTLS_PORT"
        printf "%-22s %s\n" "密码:" "$ANYTLS_PASSWORD"
        printf "%-22s %s\n" "域名:" "$ANYTLS_DOMAIN"
        printf "%-22s %s\n" "证书模式:" "$ANYTLS_CERT_MODE"
        printf "%-22s %s\n" "Padding Scheme:" "$display_scheme"
        if [[ "$ANYTLS_CERT_MODE" == "manual" ]]; then
            printf "%-22s %s\n" "证书路径:" "$ANYTLS_CERT_PATH"
            printf "%-22s %s\n" "私钥路径:" "$ANYTLS_KEY_PATH"
        fi
    fi

    if [[ "$SS_ENABLED" -eq 1 ]]; then
        echo ""
        echo "Shadowsocks:"
        printf "%-22s %s\n" "端口:" "$SS_PORT"
        printf "%-22s %s\n" "密码:" "$SS_PASSWORD"
        printf "%-22s %s\n" "加密:" "$SS_METHOD"
    fi

    if [[ "$WARP_ENABLED" -eq 1 ]]; then
        warp_address_display="$WARP_ADDRESS_IPV4"
        if [[ -n "$WARP_ADDRESS" ]]; then
            warp_address_display+=", $WARP_ADDRESS"
        fi
        echo ""
        echo "WARP:"
        printf "%-22s %s\n" "状态:" "enabled"
        printf "%-22s %s\n" "Address:" "$warp_address_display"
        printf "%-22s %s\n" "Ruleset:" "$WARP_RULESET_URL"
        printf "%-22s %s\n" "Final:" "$DIRECT_TAG"
    fi

    echo ""
}

uninstall_service() {
    print_header "卸载 sing-box"

    log_info "停止服务: sing-box"
    systemctl stop sing-box >/dev/null 2>&1 || true

    log_info "禁用服务: sing-box"
    systemctl disable sing-box >/dev/null 2>&1 || true

    if package_known; then
        log_info "卸载包: sing-box"
        if ! DEBIAN_FRONTEND=noninteractive dpkg --purge sing-box >/dev/null 2>&1; then
            log_error "sing-box 包卸载失败"
            exit 1
        fi
    else
        log_info "包未安装: sing-box"
    fi

    remove_path /etc/sing-box || exit 1
    remove_path /var/lib/sing-box || exit 1

    log_info "重载 systemd daemon"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed sing-box >/dev/null 2>&1 || true
    cleanup_temp_files

    verify_uninstalled || exit 1
    log_success "sing-box 卸载完成"
}

run_installation() {
    detect_arch
    install_packages
    ensure_time_sync
    install_singbox
    prepare_config_params
    create_singbox_config
    validate_singbox_config
    restart_singbox_service
    show_configuration
}

main() {
    parse_args "$@"

    if [[ "$UPDATE_REQUESTED" -eq 1 && "$UNINSTALL_REQUESTED" -eq 1 ]]; then
        log_error "--update 和 --uninstall 不能同时使用。"
        exit 1
    fi

    if [[ "$UPDATE_REQUESTED" -eq 0 && "$UNINSTALL_REQUESTED" -eq 0 ]]; then
        parse_protocols
        validate_protocol_scope
    fi

    require_root

    if [[ "$UPDATE_REQUESTED" -eq 1 ]]; then
        update_singbox
        exit $?
    fi

    if [[ "$UNINSTALL_REQUESTED" -eq 1 ]]; then
        uninstall_service
        exit 0
    fi

    run_installation
}

main "$@"
