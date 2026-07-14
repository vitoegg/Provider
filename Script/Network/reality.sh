#!/bin/bash

set -o pipefail

XRAY_BINARY="${XRAY_BINARY:-/usr/local/bin/xray}"
XRAY_CONFIG_FILE="${XRAY_CONFIG_FILE:-/usr/local/etc/xray/config.json}"
XRAY_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
DEFAULT_PORT_START=50000
DEFAULT_PORT_END=60000
SS_METHOD="2022-blake3-aes-128-gcm"
ROUTE_DOMAINS=("domain:reddit.com" "domain:cloudflare.com")

PROTOCOLS=""
REALITY_ENABLED=0
SS_ENABLED=0
SOCKS_ENABLED=0
UPDATE_REQUESTED=0
UNINSTALL_REQUESTED=0
REALITY_PORT=""
REALITY_DOMAIN=""
REALITY_UUID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
SS_PORT=""
SS_PASSWORD=""
SOCKS_HOST=""
SOCKS_PORT=""
USED_PORTS=()
CONFIG_CHANGED=0
XRAY_CHANGED=0
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
  bash reality.sh --protocol reality|shadowsocks|reality,shadowsocks [OPTIONS]
  bash reality.sh --update
  bash reality.sh --uninstall

参数：
  --protocol LIST
  --reality-port PORT
  --reality-domain DOMAIN
  --reality-uuid UUID
  --reality-private-key KEY
  --reality-public-key KEY
  --reality-short-id ID
  --ss-port PORT
  --ss-password PASSWORD
  --socks-host HOST
  --socks-port PORT
  --update
  -u, --uninstall
  -h, --help
EOF
}

parse_args() {
    local option value target_name
    local -A targets=(
        [--protocol]=PROTOCOLS
        [--reality-port]=REALITY_PORT
        [--reality-domain]=REALITY_DOMAIN
        [--reality-uuid]=REALITY_UUID
        [--reality-private-key]=REALITY_PRIVATE_KEY
        [--reality-public-key]=REALITY_PUBLIC_KEY
        [--reality-short-id]=REALITY_SHORT_ID
        [--ss-port]=SS_PORT
        [--ss-password]=SS_PASSWORD
        [--socks-host]=SOCKS_HOST
        [--socks-port]=SOCKS_PORT
    )

    while [ "$#" -gt 0 ]; do
        option="${1%%=*}"
        if [[ -v "targets[$option]" ]]; then
            if [[ "$1" == *=* ]]; then
                value="${1#*=}"
                shift
            else
                if [ "$#" -le 1 ] || [[ "$2" == -* ]]; then
                    fail "$1 缺少参数值。"
                fi
                value="$2"
                shift 2
            fi
            [ -n "$value" ] || fail "$option 缺少参数值。"
            target_name="${targets[$option]}"
            printf -v "$target_name" '%s' "$value"
            if [[ "$option" =~ ^--socks-(host|port)$ ]]; then
                SOCKS_ENABLED=1
            fi
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
    if (( UPDATE_REQUESTED || UNINSTALL_REQUESTED )); then
        if install_arguments_present; then
            fail "更新或卸载不能同时使用协议或配置参数。"
        fi
    fi
}

install_arguments_present() {
    [ -n "$PROTOCOLS$REALITY_PORT$REALITY_DOMAIN$REALITY_UUID" ] ||
        [ -n "$REALITY_PRIVATE_KEY$REALITY_PUBLIC_KEY$REALITY_SHORT_ID" ] ||
        [ -n "$SS_PORT$SS_PASSWORD$SOCKS_HOST$SOCKS_PORT" ]
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
    if [ "$UNINSTALL_REQUESTED" -eq 0 ]; then
        command -v jq >/dev/null 2>&1 || missing+=(jq)
        command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    fi
    if [ "$UPDATE_REQUESTED" -eq 0 ] && [ "$UNINSTALL_REQUESTED" -eq 0 ]; then
        command -v openssl >/dev/null 2>&1 || missing+=(openssl)
        command -v shuf >/dev/null 2>&1 || missing+=(coreutils)
    fi
    [ "${#missing[@]}" -eq 0 ] && return 0
    log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || fail "软件包索引更新失败。"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    log_info "已安装依赖：${missing[*]}"
}

parse_protocols() {
    local protocol protocol_items=()

    [ -n "$PROTOCOLS" ] || fail "缺少 --protocol。"
    IFS=',' read -ra protocol_items <<< "$PROTOCOLS"
    for protocol in "${protocol_items[@]}"; do
        protocol="${protocol//[[:space:]]/}"
        if [ "$protocol" = reality ]; then
            REALITY_ENABLED=1
        elif [ "$protocol" = shadowsocks ]; then
            SS_ENABLED=1
        elif [ -z "$protocol" ]; then
            fail "--protocol 包含空协议。"
        else
            fail "不支持的协议：$protocol"
        fi
    done
}

validate_protocol_scope() {
    if [ "$REALITY_ENABLED" -eq 0 ] &&
       [ -n "$REALITY_PORT$REALITY_DOMAIN$REALITY_UUID$REALITY_PRIVATE_KEY$REALITY_PUBLIC_KEY$REALITY_SHORT_ID" ]; then
        fail "Reality 参数需要 --protocol reality。"
    fi
    if [ "$SS_ENABLED" -eq 0 ] && [ -n "$SS_PORT$SS_PASSWORD" ]; then
        fail "Shadowsocks 参数需要 --protocol shadowsocks。"
    fi
}

xray_command() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x "$XRAY_BINARY" ]; then
        printf '%s\n' "$XRAY_BINARY"
    else
        return 1
    fi
}

run_xray_installer() {
    local temp_dir installer status

    temp_dir="$(mktemp -d)" || fail "无法创建 Xray 安装器临时目录。"
    installer="${temp_dir}/install-release.sh"
    curl --fail --silent --show-error --location --connect-timeout 10 --max-time 120 --retry 3 \
        -o "$installer" "$XRAY_INSTALLER_URL" || {
        rm -rf "$temp_dir"
        fail "Xray 安装器下载失败。"
    }
    [ -s "$installer" ] || {
        rm -rf "$temp_dir"
        fail "Xray 安装器为空。"
    }
    bash -n "$installer" >/dev/null 2>&1 || {
        rm -rf "$temp_dir"
        fail "Xray 安装器语法校验失败。"
    }
    bash "$installer" "$@" >/dev/null 2>&1
    status=$?
    rm -rf "$temp_dir"
    [ "$status" -eq 0 ] || fail "Xray 安装器执行失败。"
}

port_in_use() {
    ss -H -lntu 2>/dev/null | grep -Eq ":${1}[[:space:]]"
}

validate_port() {
    if ! [[ "$1" =~ ^[0-9]+$ ]] || (( 10#$1 < 1 || 10#$1 > 65535 )); then
        log_error "$2 端口无效：$1"
        return 1
    fi
}

port_is_reserved() {
    local item
    for item in "${USED_PORTS[@]}"; do
        [ "$item" = "$1" ] && return 0
    done
    return 1
}

reserve_port() {
    validate_port "$1" "$2" || exit 1
    ! port_is_reserved "$1" || fail "端口冲突：$1"
    USED_PORTS+=("$1")
}

generate_unique_port() {
    local port
    while true; do
        port="$(shuf -i "${DEFAULT_PORT_START}-${DEFAULT_PORT_END}" -n 1)" || fail "端口生成失败。"
        if [[ "$port" != *4* ]] && ! port_is_reserved "$port" && ! port_in_use "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
}

prepare_ports() {
    USED_PORTS=()
    [ "$REALITY_ENABLED" -eq 0 ] || [ -z "$REALITY_PORT" ] || reserve_port "$REALITY_PORT" Reality
    [ "$SS_ENABLED" -eq 0 ] || [ -z "$SS_PORT" ] || reserve_port "$SS_PORT" Shadowsocks
    if [ "$REALITY_ENABLED" -eq 1 ] && [ -z "$REALITY_PORT" ]; then
        REALITY_PORT="$(generate_unique_port)"
        reserve_port "$REALITY_PORT" Reality
    fi
    if [ "$SS_ENABLED" -eq 1 ] && [ -z "$SS_PORT" ]; then
        SS_PORT="$(generate_unique_port)"
        reserve_port "$SS_PORT" Shadowsocks
    fi
}

validate_domain() {
    local domain="$1" label pattern

    label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    pattern="^${label}([.]${label})*$"
    [ -n "$domain" ] && [ "${#domain}" -le 253 ] && [[ "$domain" =~ $pattern ]]
}

generate_uuid() {
    local binary
    binary="$(xray_command)" || fail "无法生成 UUID：Xray 未安装。"
    "$binary" uuid || fail "UUID 生成失败。"
}

generate_x25519() {
    local binary
    binary="$(xray_command)" || fail "无法生成 X25519 密钥：Xray 未安装。"
    "$binary" x25519 || fail "X25519 密钥生成失败。"
}

parse_x25519_keys() {
    local raw="$1" private_key public_key

    private_key="$(printf '%s\n' "$raw" | awk -F: '
        tolower($1) ~ /private/ {
            gsub(/[[:space:]\r\n\t]/, "", $2)
            print $2
            exit
        }
    ')"
    public_key="$(printf '%s\n' "$raw" | awk -F: '
        tolower($1) ~ /(public|password)/ {
            gsub(/[[:space:]\r\n\t]/, "", $2)
            print $2
            exit
        }
    ')"
    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        log_error "X25519 密钥解析失败。"
        return 1
    fi
    printf '%s|%s\n' "$private_key" "$public_key"
}

prepare_reality_params() {
    local keys parsed
    [ "$REALITY_ENABLED" -eq 1 ] || return 0
    validate_domain "$REALITY_DOMAIN" || fail "Reality 域名无效：$REALITY_DOMAIN"
    [ -n "$REALITY_UUID" ] || REALITY_UUID="$(generate_uuid)"
    if [ -n "$REALITY_PRIVATE_KEY$REALITY_PUBLIC_KEY" ]; then
        if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
            fail "Reality 私钥和公钥必须同时提供。"
        fi
    else
        keys="$(generate_x25519)"
        parsed="$(parse_x25519_keys "$keys")" || exit 1
        REALITY_PRIVATE_KEY="${parsed%%|*}"
        REALITY_PUBLIC_KEY="${parsed#*|}"
    fi
    [ -n "$REALITY_SHORT_ID" ] || REALITY_SHORT_ID="$(openssl rand -hex 4)" || fail "Reality short id 生成失败。"
}

prepare_shadowsocks_params() {
    [ "$SS_ENABLED" -eq 1 ] || return 0
    [ -n "$SS_PASSWORD" ] || SS_PASSWORD="$(openssl rand -base64 16)" || fail "Shadowsocks 密码生成失败。"
}

prepare_socks_params() {
    [ "$SOCKS_ENABLED" -eq 1 ] || return 0
    if [ -z "$SOCKS_HOST" ] || [ -z "$SOCKS_PORT" ]; then
        fail "启用 Socks 时必须同时提供 host 和 port。"
    fi
    validate_port "$SOCKS_PORT" Socks || exit 1
}

prepare_config_params() {
    prepare_ports
    prepare_reality_params
    prepare_shadowsocks_params
    prepare_socks_params
}

build_reality_inbound() {
    jq -n --argjson port "$REALITY_PORT" --arg uuid "$REALITY_UUID" \
        --arg domain "$REALITY_DOMAIN" --arg key "$REALITY_PRIVATE_KEY" \
        --arg sid "$REALITY_SHORT_ID" \
        '{
            tag: "reality-in",
            listen: "0.0.0.0",
            port: $port,
            protocol: "vless",
            settings: {
                clients: [{id: $uuid, flow: "xtls-rprx-vision"}],
                decryption: "none"
            },
            streamSettings: {
                network: "raw",
                security: "reality",
                realitySettings: {
                    fingerprint: "ios",
                    target: ($domain + ":443"),
                    serverNames: [$domain],
                    privateKey: $key,
                    shortIds: [$sid]
                }
            }
        }'
}

build_shadowsocks_inbound() {
    jq -n --argjson port "$SS_PORT" --arg method "$SS_METHOD" --arg password "$SS_PASSWORD" \
        '{
            tag: "shadowsocks-in",
            listen: "0.0.0.0",
            port: $port,
            protocol: "shadowsocks",
            settings: {
                network: "tcp,udp",
                method: $method,
                password: $password
            }
        }'
}

build_xray_config() {
    local inbounds='[]' inbound outbounds routing='{}'
    if [ "$REALITY_ENABLED" -eq 1 ]; then
        inbound="$(build_reality_inbound)" || return 1
        inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$inbound" '$a+[$b]')"
    fi
    if [ "$SS_ENABLED" -eq 1 ]; then
        inbound="$(build_shadowsocks_inbound)" || return 1
        inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$inbound" '$a+[$b]')"
    fi
    outbounds='[{"protocol":"freedom","tag":"direct"}]'
    if [ "$SOCKS_ENABLED" -eq 1 ]; then
        outbounds="$(jq -cn \
            --argjson base "$outbounds" \
            --arg host "$SOCKS_HOST" \
            --argjson port "$SOCKS_PORT" \
            '$base + [{
                protocol: "socks",
                tag: "proxy",
                settings: {address: $host, port: $port}
            }]')"
        routing="$(jq -cn \
            --argjson domains "$(printf '%s\n' "${ROUTE_DOMAINS[@]}" | jq -R . | jq -s .)" \
            '{
                domainStrategy: "AsIs",
                rules: [{
                    type: "field",
                    network: "tcp",
                    domain: $domains,
                    outboundTag: "proxy"
                }]
            }')"
    fi
    jq -n --argjson inbounds "$inbounds" --argjson outbounds "$outbounds" --argjson routing "$routing" \
        '{
            log: {loglevel: "error"},
            inbounds: $inbounds,
            outbounds: $outbounds
        } + (if ($routing | length) > 0 then {routing: $routing} else {} end)'
}

apply_config() {
    local directory candidate binary

    directory="$(dirname "$XRAY_CONFIG_FILE")"
    mkdir -p "$directory" || fail "无法创建 Xray 配置目录。"
    candidate="$(mktemp "${directory}/.config.json.XXXXXX")" || fail "无法创建 Xray 候选配置。"
    umask 077
    build_xray_config > "$candidate" || {
        rm -f "$candidate"
        fail "Xray 配置生成失败。"
    }
    jq -e . "$candidate" >/dev/null 2>&1 || {
        rm -f "$candidate"
        fail "Xray JSON 预检失败。"
    }
    binary="$(xray_command)" || {
        rm -f "$candidate"
        fail "未找到 Xray。"
    }
    "$binary" run -test -config "$candidate" >/dev/null 2>&1 || {
        rm -f "$candidate"
        fail "Xray 配置预检失败。"
    }
    if [ -f "$XRAY_CONFIG_FILE" ] && cmp -s "$candidate" "$XRAY_CONFIG_FILE"; then
        rm -f "$candidate"
        CONFIG_CHANGED=0
        return 0
    fi
    if ! chmod 600 "$candidate" || ! mv -f "$candidate" "$XRAY_CONFIG_FILE"; then
        rm -f "$candidate"
        fail "Xray 配置应用失败。"
    fi
    CONFIG_CHANGED=1
    log_info "已更新 Xray 配置：$XRAY_CONFIG_FILE"
}

begin_transaction() {
    TRANSACTION_DIR="$(mktemp -d)" || fail "无法创建 Xray 事务目录。"
    if systemctl is-active --quiet xray 2>/dev/null; then
        SERVICE_WAS_ACTIVE=1
    else
        SERVICE_WAS_ACTIVE=0
    fi
    if systemctl is-enabled --quiet xray 2>/dev/null; then
        SERVICE_WAS_ENABLED=1
    else
        SERVICE_WAS_ENABLED=0
    fi
    if [ -e "$XRAY_CONFIG_FILE" ]; then
        cp -a "$XRAY_CONFIG_FILE" "${TRANSACTION_DIR}/config" || {
            rm -rf "$TRANSACTION_DIR"
            fail "无法备份 Xray 配置。"
        }
        : > "${TRANSACTION_DIR}/config.exists"
    fi
    CONFIG_CHANGED=0
    TRANSACTION_ACTIVE=1
    trap rollback_transaction EXIT
}

rollback_transaction() {
    local restore_failed=0 restore_candidate=""

    [ "$TRANSACTION_ACTIVE" -eq 1 ] || return 0
    if [ -e "${TRANSACTION_DIR}/config.exists" ]; then
        mkdir -p "$(dirname "$XRAY_CONFIG_FILE")" || restore_failed=1
        restore_candidate="$(mktemp "$(dirname "$XRAY_CONFIG_FILE")/.config.restore.XXXXXX")" ||
            restore_failed=1
        if [ -n "$restore_candidate" ]; then
            if ! cp -a "${TRANSACTION_DIR}/config" "$restore_candidate" ||
               ! mv -f "$restore_candidate" "$XRAY_CONFIG_FILE"; then
                restore_failed=1
            fi
            rm -f "$restore_candidate" || restore_failed=1
        fi
    else
        rm -f "$XRAY_CONFIG_FILE" || restore_failed=1
    fi
    if [ "$SERVICE_WAS_ENABLED" -eq 1 ]; then
        systemctl enable xray >/dev/null 2>&1 || restore_failed=1
    elif systemctl is-enabled --quiet xray 2>/dev/null; then
        systemctl disable xray >/dev/null 2>&1 || restore_failed=1
    fi
    if [ "$SERVICE_WAS_ACTIVE" -eq 1 ]; then
        systemctl restart xray >/dev/null 2>&1 || restore_failed=1
    elif systemctl is-active --quiet xray 2>/dev/null; then
        systemctl stop xray >/dev/null 2>&1 || restore_failed=1
    fi
    TRANSACTION_ACTIVE=0
    trap - EXIT
    rm -rf "$TRANSACTION_DIR" || restore_failed=1
    if [ "$restore_failed" -eq 1 ]; then
        log_error "Xray 配置或服务状态恢复失败。"
        return 1
    fi
    log_warning "Xray 变更失败，已恢复脚本管理的配置和服务状态。"
}

commit_transaction() {
    [ "$TRANSACTION_ACTIVE" -eq 1 ] || return 0
    TRANSACTION_ACTIVE=0
    trap - EXIT
    rm -rf "$TRANSACTION_DIR" || log_warning "Xray 事务临时目录清理失败：$TRANSACTION_DIR"
}

ensure_xray_installed() {
    if xray_command >/dev/null 2>&1 && systemctl cat xray.service >/dev/null 2>&1; then
        XRAY_CHANGED=0
        return 0
    fi
    run_xray_installer install --without-geodata
    XRAY_CHANGED=1
}

converge_service() {
    if ! systemctl is-enabled --quiet xray 2>/dev/null; then
        if ! systemctl enable xray >/dev/null 2>&1; then
            log_error "Xray 服务启用失败。"
            return 1
        fi
        log_info "已启用系统服务：xray.service"
    fi
    if systemctl is-active --quiet xray 2>/dev/null; then
        if (( XRAY_CHANGED || CONFIG_CHANGED )); then
            if ! systemctl restart xray >/dev/null 2>&1; then
                log_error "Xray 重启失败。"
                return 1
            fi
            log_info "已重启系统服务：xray.service"
        fi
    elif ! systemctl start xray >/dev/null 2>&1; then
        log_error "Xray 启动失败。"
        return 1
    else
        log_info "已启动系统服务：xray.service"
    fi
}

port_listening() {
    ss -H -lntu 2>/dev/null | grep -Eq ":${1}[[:space:]]"
}

verify_service() {
    if ! systemctl is-active --quiet xray 2>/dev/null; then
        log_error "Xray 服务未运行。"
        return 1
    fi
    if [ "$REALITY_ENABLED" -eq 1 ] && ! port_listening "$REALITY_PORT"; then
        log_error "Reality 未监听端口：$REALITY_PORT"
        return 1
    fi
    if [ "$SS_ENABLED" -eq 1 ] && ! port_listening "$SS_PORT"; then
        log_error "Shadowsocks 未监听端口：$SS_PORT"
        return 1
    fi
}

verify_existing_listeners() {
    local port
    systemctl is-active --quiet xray 2>/dev/null || return 1
    while IFS= read -r port; do
        port_listening "$port" || return 1
    done < <(jq -r '.inbounds[].port' "$XRAY_CONFIG_FILE")
}

show_configuration() {
    local ip

    ip="$(curl --fail --silent --show-error --max-time 5 https://api.ipify.org 2>/dev/null)" || true
    printf '\n=== Xray 客户端配置 ===\n服务器：%s\n' "${ip:-无法获取 IP}"
    if [ "$REALITY_ENABLED" -eq 1 ]; then
        printf 'Reality 端口：%s\nUUID：%s\n域名：%s\nPrivateKey：%s\nPublicKey：%s\nShort ID：%s\n' \
            "$REALITY_PORT" "$REALITY_UUID" "$REALITY_DOMAIN" \
            "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID"
    fi
    if [ "$SS_ENABLED" -eq 1 ]; then
        printf 'Shadowsocks 端口：%s\nShadowsocks 密码：%s\n加密：%s\n' \
            "$SS_PORT" "$SS_PASSWORD" "$SS_METHOD"
    fi
    if [ "$SOCKS_ENABLED" -eq 1 ]; then
        printf 'Socks：%s:%s\n分流域名：reddit.com, cloudflare.com\n' "$SOCKS_HOST" "$SOCKS_PORT"
    fi
    printf '========================\n'
}

install_reality() {
    begin_transaction
    ensure_xray_installed
    prepare_config_params
    apply_config
    if ! converge_service || ! verify_service; then
        if rollback_transaction; then
            fail "Xray 应用失败，配置和服务状态已恢复；官方安装器变更保留。"
        fi
        fail "Xray 应用失败，且配置或服务状态恢复失败。"
    fi
    commit_transaction
    log_info "Xray 配置完成并正在运行。"
    show_configuration
}

update_xray() {
    local binary

    begin_transaction
    run_xray_installer install --without-geodata
    XRAY_CHANGED=1
    binary="$(xray_command)" || fail "Xray 更新后命令不存在。"
    "$binary" run -test -config "$XRAY_CONFIG_FILE" >/dev/null 2>&1 ||
        fail "新 Xray 无法加载现有配置；官方安装器变更已保留。"
    if ! converge_service || ! verify_existing_listeners; then
        if rollback_transaction; then
            fail "Xray 更新后服务验证失败，服务状态已恢复；新版本保留。"
        fi
        fail "Xray 更新后服务验证失败，且服务状态恢复失败。"
    fi
    commit_transaction
    log_info "Xray 已更新并验证运行状态。"
}

verify_uninstalled() {
    if systemctl is-active --quiet xray 2>/dev/null ||
       systemctl cat xray.service >/dev/null 2>&1 ||
       [ -e "$XRAY_BINARY" ] || [ -e "$XRAY_CONFIG_FILE" ]; then
        fail "Xray 卸载验证失败。"
    fi
}

uninstall_xray() {
    if [ ! -e "$XRAY_BINARY" ] && [ ! -e "$XRAY_CONFIG_FILE" ] &&
       ! systemctl is-active --quiet xray 2>/dev/null &&
       ! systemctl cat xray.service >/dev/null 2>&1; then
        log_info "Xray 已不存在，无需卸载。"
        return 0
    fi
    ensure_dependencies
    run_xray_installer remove --purge
    systemctl daemon-reload >/dev/null 2>&1 || fail "systemd daemon 重载失败。"
    systemctl reset-failed xray >/dev/null 2>&1 || true
    verify_uninstalled
    log_info "Xray 已卸载。"
}

main() {
    parse_args "$@"
    if [ "$UPDATE_REQUESTED" -eq 0 ] && [ "$UNINSTALL_REQUESTED" -eq 0 ]; then
        parse_protocols
        validate_protocol_scope
    fi
    require_environment
    if [ "$UPDATE_REQUESTED" -eq 1 ]; then
        ensure_dependencies
        update_xray
    elif [ "$UNINSTALL_REQUESTED" -eq 1 ]; then
        uninstall_xray
    else
        ensure_dependencies
        install_reality
    fi
}

main "$@"
