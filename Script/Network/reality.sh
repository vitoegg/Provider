#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="xray"

DEFAULT_PORT_START=50000
DEFAULT_PORT_END=60000
SS_METHOD="2022-blake3-aes-128-gcm"

DIRECT_TAG="direct"
WARP_TAG="warp"
WARP_ENDPOINT_HOST="engage.cloudflareclient.com"
WARP_ENDPOINT_PORT=2408
WARP_MTU=1280
WARP_ADDRESS_IPV4="172.16.0.2/32"
WARP_ALLOWED_IP_IPV4="0.0.0.0/0"
WARP_ALLOWED_IP_IPV6="::/0"
WARP_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
WARP_KEEPALIVE=30
ROUTE_DOMAINS=("full:challenges.cloudflare.com" "full:stun.cloudflare.com" "domain:reddit.com")
ROUTE_DOMAIN_DISPLAY="challenges.cloudflare.com, stun.cloudflare.com, reddit.com"

PROTOCOLS=""
REALITY_ENABLED=0
SS_ENABLED=0
WARP_ENABLED=0

UPDATE_REQUESTED=0
UNINSTALL_REQUESTED=0

REALITY_PORT=""
REALITY_PORT_SET=0
REALITY_DOMAIN=""
REALITY_UUID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""

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
  bash ${name} --protocol reality|shadowsocks|reality,shadowsocks [OPTIONS]

协议:
  --protocol LIST

Reality:
  --reality-port PORT
  --reality-domain DOMAIN
  --reality-uuid UUID
  --reality-private-key KEY
  --reality-public-key KEY
  --reality-short-id ID

Shadowsocks:
  --ss-port PORT
  --ss-password PASSWORD

WARP:
  --warp-key KEY
  --warp-address IPV6_CIDR  可选，提供后启用 IPv6 WARP address

全局:
  --update
  --uninstall
  -h, --help
EOF
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
            --reality-port)
                REALITY_PORT="$(need_value "$1" "${2:-}")"
                REALITY_PORT_SET=1
                shift 2
                ;;
            --reality-port=*)
                REALITY_PORT="${1#*=}"
                REALITY_PORT_SET=1
                shift
                ;;
            --reality-domain)
                REALITY_DOMAIN="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --reality-domain=*)
                REALITY_DOMAIN="${1#*=}"
                shift
                ;;
            --reality-uuid)
                REALITY_UUID="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --reality-uuid=*)
                REALITY_UUID="${1#*=}"
                shift
                ;;
            --reality-private-key)
                REALITY_PRIVATE_KEY="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --reality-private-key=*)
                REALITY_PRIVATE_KEY="${1#*=}"
                shift
                ;;
            --reality-public-key)
                REALITY_PUBLIC_KEY="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --reality-public-key=*)
                REALITY_PUBLIC_KEY="${1#*=}"
                shift
                ;;
            --reality-short-id)
                REALITY_SHORT_ID="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --reality-short-id=*)
                REALITY_SHORT_ID="${1#*=}"
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
            reality)
                REALITY_ENABLED=1
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
    if [[ "$REALITY_ENABLED" -eq 0 ]]; then
        if [[ -n "$REALITY_PORT$REALITY_DOMAIN$REALITY_UUID$REALITY_PRIVATE_KEY$REALITY_PUBLIC_KEY$REALITY_SHORT_ID" ]]; then
            log_error "Reality 参数需要 --protocol reality。"
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

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限执行。"
        exit 1
    fi
}

check_curl() {
    if command -v curl >/dev/null 2>&1; then
        return 0
    fi

    print_header "安装依赖"
    log_warning "curl 未安装，正在安装..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm curl
    else
        log_error "无法自动安装 curl，请手动安装后重试。"
        exit 1
    fi

    command -v curl >/dev/null 2>&1 || {
        log_error "curl 安装失败。"
        exit 1
    }
    log_success "curl 已就绪"
}

xray_command() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [[ -x "$XRAY_BIN" ]]; then
        printf '%s\n' "$XRAY_BIN"
    else
        return 1
    fi
}

ensure_xray_installed() {
    print_header "安装 Xray"
    if xray_command >/dev/null 2>&1 && systemctl cat "$XRAY_SERVICE" >/dev/null 2>&1; then
        log_info "Xray 已存在: $(xray_command)"
        return 0
    fi

    log_info "开始安装 Xray..."
    if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --without-geodata; then
        log_success "Xray 安装完成"
        return 0
    fi

    log_error "Xray 安装失败。"
    return 1
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

    if [[ "$REALITY_ENABLED" -eq 1 && -n "$REALITY_PORT" ]]; then
        add_used_port "$REALITY_PORT" "Reality"
    fi

    if [[ "$SS_ENABLED" -eq 1 && -n "$SS_PORT" ]]; then
        add_used_port "$SS_PORT" "Shadowsocks"
    fi

    if [[ "$REALITY_ENABLED" -eq 1 && -z "$REALITY_PORT" ]]; then
        REALITY_PORT="$(generate_unique_port)"
        add_used_port "$REALITY_PORT" "Reality"
        log_info "生成 Reality 端口: $REALITY_PORT"
    elif [[ "$REALITY_ENABLED" -eq 1 && "$REALITY_PORT_SET" -eq 1 ]]; then
        log_info "使用指定 Reality 端口: $REALITY_PORT"
    fi

    if [[ "$SS_ENABLED" -eq 1 && -z "$SS_PORT" ]]; then
        SS_PORT="$(generate_unique_port)"
        add_used_port "$SS_PORT" "Shadowsocks"
        log_info "生成 Shadowsocks 端口: $SS_PORT"
    elif [[ "$SS_ENABLED" -eq 1 && "$SS_PORT_SET" -eq 1 ]]; then
        log_info "使用指定 Shadowsocks 端口: $SS_PORT"
    fi
}

validate_domain() {
    local domain="$1"

    [[ -n "$domain" && ${#domain} -le 253 &&
        "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

generate_uuid() {
    local bin
    bin="$(xray_command)" || {
        log_error "无法生成 UUID，请确保 Xray 已正确安装。"
        exit 1
    }
    "$bin" uuid
}

generate_x25519() {
    local bin
    bin="$(xray_command)" || {
        log_error "无法生成 X25519 密钥，请确保 Xray 已正确安装。"
        exit 1
    }
    "$bin" x25519
}

parse_x25519_keys() {
    local raw="$1"
    local private_key public_key

    private_key="$(printf '%s\n' "$raw" | awk -F: 'tolower($1) ~ /private/ { gsub(/[[:space:]\r\n\t]/, "", $2); print $2; exit }')"
    public_key="$(printf '%s\n' "$raw" | awk -F: 'tolower($1) ~ /(public|password)/ { gsub(/[[:space:]\r\n\t]/, "", $2); print $2; exit }')"

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        log_error "X25519 密钥解析失败。"
        return 1
    fi

    printf '%s|%s\n' "$private_key" "$public_key"
}

generate_shortid() {
    openssl rand -hex 4
}

generate_ss_password() {
    openssl rand -base64 16
}

prepare_reality_params() {
    local keys parsed_keys

    if [[ "$REALITY_ENABLED" -ne 1 ]]; then
        return 0
    fi

    if [[ -z "$REALITY_DOMAIN" ]]; then
        log_error "启用 Reality 时必须提供 --reality-domain。"
        exit 1
    fi
    validate_domain "$REALITY_DOMAIN" || {
        log_error "Reality 域名无效: $REALITY_DOMAIN"
        exit 1
    }
    log_info "使用 Reality 域名: $REALITY_DOMAIN"

    if [[ -z "$REALITY_UUID" ]]; then
        REALITY_UUID="$(generate_uuid)"
        log_info "生成 Reality UUID"
    else
        log_info "使用指定 Reality UUID"
    fi

    if [[ -n "$REALITY_PRIVATE_KEY$REALITY_PUBLIC_KEY" ]]; then
        if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
            log_error "--reality-private-key 和 --reality-public-key 必须同时提供。"
            exit 1
        fi
        log_info "使用指定 Reality 密钥对"
    else
        keys="$(generate_x25519)"
        parsed_keys="$(parse_x25519_keys "$keys")" || exit 1
        REALITY_PRIVATE_KEY="${parsed_keys%%|*}"
        REALITY_PUBLIC_KEY="${parsed_keys#*|}"
        log_info "生成 Reality 密钥对"
    fi

    if [[ -z "$REALITY_SHORT_ID" ]]; then
        REALITY_SHORT_ID="$(generate_shortid)"
        log_info "生成 Reality short id"
    else
        log_info "使用指定 Reality short id"
    fi
}

prepare_shadowsocks_params() {
    if [[ "$SS_ENABLED" -ne 1 ]]; then
        return 0
    fi

    if [[ -z "$SS_PASSWORD" ]]; then
        SS_PASSWORD="$(generate_ss_password)"
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

    log_info "启用 WARP 分流: $ROUTE_DOMAIN_DISPLAY"
}

prepare_config_params() {
    print_header "准备配置"
    prepare_ports
    prepare_reality_params
    prepare_shadowsocks_params
    prepare_warp_params
    log_success "配置参数已就绪"
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

json_string() {
    printf '"%s"' "$(json_escape "$1")"
}

json_array() {
    local first=1
    local value

    printf '['
    for value in "$@"; do
        if [[ "$first" -eq 0 ]]; then
            printf ', '
        fi
        json_string "$value"
        first=0
    done
    printf ']'
}

build_reality_inbound() {
    cat << EOF
    {
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": $(json_string "$REALITY_UUID"),
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "ios",
          "target": "$(json_escape "$REALITY_DOMAIN"):443",
          "serverNames": [
            $(json_string "$REALITY_DOMAIN")
          ],
          "privateKey": $(json_string "$REALITY_PRIVATE_KEY"),
          "shortIds": [
            $(json_string "$REALITY_SHORT_ID")
          ]
        }
      }
    }
EOF
}

build_shadowsocks_inbound() {
    cat << EOF
    {
      "tag": "shadowsocks-in",
      "listen": "0.0.0.0",
      "port": $SS_PORT,
      "protocol": "shadowsocks",
      "settings": {
        "network": "tcp,udp",
        "method": "$SS_METHOD",
        "password": $(json_string "$SS_PASSWORD")
      }
    }
EOF
}

build_direct_outbound() {
    cat << EOF
    {
      "protocol": "freedom",
      "tag": "$DIRECT_TAG"
    }
EOF
}

build_warp_outbound() {
    local addresses=("$WARP_ADDRESS_IPV4")
    local allowed_ips=("$WARP_ALLOWED_IP_IPV4")
    local domain_strategy="ForceIPv4"

    if [[ -n "$WARP_ADDRESS" ]]; then
        addresses+=("$WARP_ADDRESS")
        allowed_ips+=("$WARP_ALLOWED_IP_IPV6")
        domain_strategy="ForceIPv4v6"
    fi

    cat << EOF
    {
      "protocol": "wireguard",
      "tag": "$WARP_TAG",
      "settings": {
        "secretKey": $(json_string "$WARP_KEY"),
        "address": $(json_array "${addresses[@]}"),
        "peers": [
          {
            "endpoint": "$(json_escape "$WARP_ENDPOINT_HOST"):$WARP_ENDPOINT_PORT",
            "publicKey": "$WARP_PUBLIC_KEY",
            "keepAlive": $WARP_KEEPALIVE,
            "allowedIPs": $(json_array "${allowed_ips[@]}")
          }
        ],
        "mtu": $WARP_MTU,
        "domainStrategy": "$domain_strategy"
      }
    }
EOF
}

build_routing() {
    cat << EOF
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "domain": $(json_array "${ROUTE_DOMAINS[@]}"),
        "outboundTag": "$WARP_TAG"
      }
    ]
  }
EOF
}

build_xray_config() {
    local first

    printf '{\n'
    printf '  "log": {\n'
    printf '    "loglevel": "error"\n'
    printf '  },\n'
    printf '  "inbounds": [\n'

    first=1
    if [[ "$REALITY_ENABLED" -eq 1 ]]; then
        build_reality_inbound
        first=0
    fi
    if [[ "$SS_ENABLED" -eq 1 ]]; then
        [[ "$first" -eq 0 ]] && printf ',\n'
        build_shadowsocks_inbound
        first=0
    fi

    printf '\n  ],\n'
    printf '  "outbounds": [\n'
    build_direct_outbound
    if [[ "$WARP_ENABLED" -eq 1 ]]; then
        printf ',\n'
        build_warp_outbound
    fi
    printf '\n  ]'
    if [[ "$WARP_ENABLED" -eq 1 ]]; then
        printf ',\n'
        build_routing
    fi
    printf '\n}\n'
}

create_xray_config() {
    print_header "生成 Xray 配置"
    local config_dir
    local temp_file

    config_dir="$(dirname "$CONFIG_FILE")"
    temp_file="${CONFIG_FILE}.tmp"

    mkdir -p "$config_dir"
    chmod 755 "$config_dir"

    if ! build_xray_config > "$temp_file"; then
        log_error "Xray 配置生成失败。"
        rm -f "$temp_file"
        exit 1
    fi

    mv "$temp_file" "$CONFIG_FILE"
    log_success "配置文件已生成: $CONFIG_FILE"
}

validate_xray_config() {
    print_header "校验 Xray 配置"
    local bin
    local output

    bin="$(xray_command)" || {
        log_error "未找到 xray 命令。"
        exit 1
    }

    if output="$("$bin" run -test -config "$CONFIG_FILE" 2>&1)"; then
        log_success "Xray 配置校验通过"
        return 0
    fi

    log_error "Xray 配置校验失败。"
    printf '%s\n' "$output" >&2
    exit 1
}

restart_xray_service() {
    print_header "启动 Xray 服务"

    if ! systemctl enable "$XRAY_SERVICE" >/dev/null 2>&1; then
        log_error "Xray 服务启用失败。"
        exit 1
    fi

    if systemctl is-active --quiet "$XRAY_SERVICE" 2>/dev/null; then
        log_info "重启 Xray 服务..."
        if ! systemctl restart "$XRAY_SERVICE" >/dev/null 2>&1; then
            log_error "Xray 服务重启失败。"
            log_error "查看日志: journalctl -u $XRAY_SERVICE"
            exit 1
        fi
    else
        log_info "启动 Xray 服务..."
        if ! systemctl start "$XRAY_SERVICE" >/dev/null 2>&1; then
            log_error "Xray 服务启动失败。"
            log_error "查看日志: journalctl -u $XRAY_SERVICE"
            exit 1
        fi
    fi

    sleep 2
    if ! systemctl is-active --quiet "$XRAY_SERVICE"; then
        log_error "Xray 服务未运行。"
        log_error "查看日志: journalctl -u $XRAY_SERVICE"
        exit 1
    fi

    log_success "Xray 服务运行中"
}

get_ipv4_address() {
    local ip
    ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"

    if [[ -z "$ip" ]]; then
        printf '无法获取 IP\n'
    else
        printf '%s\n' "$ip"
    fi
}

show_configuration() {
    local server_ip
    local status
    local warp_address_display

    print_header "配置详情"
    server_ip="$(get_ipv4_address)"
    status="$(systemctl is-active "$XRAY_SERVICE" 2>/dev/null || printf 'unknown')"

    printf "%-22s %s\n" "服务:" "xray (${status})"
    printf "%-22s %s\n" "服务器 IP:" "$server_ip"

    if [[ "$REALITY_ENABLED" -eq 1 ]]; then
        echo ""
        echo "Reality:"
        printf "%-22s %s\n" "端口:" "$REALITY_PORT"
        printf "%-22s %s\n" "协议:" "vless"
        printf "%-22s %s\n" "UUID:" "$REALITY_UUID"
        printf "%-22s %s\n" "域名:" "$REALITY_DOMAIN"
        printf "%-22s %s\n" "PrivateKey:" "$REALITY_PRIVATE_KEY"
        printf "%-22s %s\n" "PublicKey:" "$REALITY_PUBLIC_KEY"
        printf "%-22s %s\n" "Short ID:" "$REALITY_SHORT_ID"
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
        printf "%-22s %s\n" "Route domains:" "$ROUTE_DOMAIN_DISPLAY"
        printf "%-22s %s\n" "Final:" "$DIRECT_TAG"
    fi

    echo ""
}

update_xray() {
    print_header "更新 Xray"
    local service_was_running=0

    if systemctl is-active --quiet "$XRAY_SERVICE" 2>/dev/null; then
        service_was_running=1
    fi

    if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --without-geodata; then
        log_error "Xray 更新失败。"
        exit 1
    fi

    if [[ "$service_was_running" -eq 1 ]]; then
        systemctl restart "$XRAY_SERVICE" >/dev/null 2>&1 || {
            log_error "Xray 服务重启失败。"
            exit 1
        }
    fi

    log_success "Xray 更新完成"
}

uninstall_xray() {
    print_header "卸载 Xray"

    log_info "停止服务: $XRAY_SERVICE"
    systemctl stop "$XRAY_SERVICE" >/dev/null 2>&1 || true

    log_info "禁用服务: $XRAY_SERVICE"
    systemctl disable "$XRAY_SERVICE" >/dev/null 2>&1 || true

    log_info "执行 Xray 卸载脚本"
    if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge; then
        log_error "Xray 卸载失败。"
        exit 1
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$XRAY_SERVICE" >/dev/null 2>&1 || true
    log_success "Xray 卸载完成"
}

run_installation() {
    ensure_xray_installed
    prepare_config_params
    create_xray_config
    validate_xray_config
    restart_xray_service
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
    check_curl

    if [[ "$UPDATE_REQUESTED" -eq 1 ]]; then
        update_xray
        exit 0
    fi

    if [[ "$UNINSTALL_REQUESTED" -eq 1 ]]; then
        uninstall_xray
        exit 0
    fi

    run_installation
}

main "$@"
