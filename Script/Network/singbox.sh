#!/bin/bash

set -o pipefail

SINGBOX_BINARY="${SINGBOX_BINARY:-/usr/bin/sing-box}"
SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_FILE:-/etc/sing-box/config.json}"
SINGBOX_STATE_DIR="${SINGBOX_STATE_DIR:-/var/lib/sing-box}"
DEFAULT_PORT_START=50000
DEFAULT_PORT_END=60000
DEFAULT_PADDING_SCHEME="stop=3|0=30-30|1=140-320|2=420-780,c,780-1400"
SS_METHOD="2022-blake3-aes-128-gcm"
SOCKS_RULESET_URL="https://raw.githubusercontent.com/vitoegg/Provider/master/RuleSet/Extra/Singbox/pureSite.json"

ARCH=""
PROTOCOLS=""
SHADOWTLS_ENABLED=0
ANYTLS_ENABLED=0
SS_ENABLED=0
SOCKS_ENABLED=0
UPDATE_REQUESTED=0
UNINSTALL_REQUESTED=0
SINGBOX_VERSION=""
SHADOWTLS_PORT=""
SHADOWTLS_PASSWORD=""
SHADOWTLS_DOMAIN=""
ANYTLS_PORT=""
ANYTLS_PASSWORD=""
ANYTLS_DOMAIN=""
ANYTLS_SCHEME=""
ANYTLS_CERT_MODE=""
ANYTLS_TOKEN=""
ANYTLS_CERT_PATH=""
ANYTLS_KEY_PATH=""
SS_PORT=""
SS_PASSWORD=""
SOCKS_HOST=""
SOCKS_PORT=""
USED_PORTS=()
PACKAGE_CHANGED=0
CONFIG_CHANGED=0
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
  bash singbox.sh --protocol LIST [OPTIONS]
  bash singbox.sh --update
  bash singbox.sh --uninstall

协议：
  --protocol LIST                 anytls、shadowsocks、shadowtls，支持逗号组合
  --shadowtls-port PORT           ShadowTLS 端口
  --shadowtls-password PASSWORD   ShadowTLS 密码
  --shadowtls-domain DOMAIN       ShadowTLS 单域名
  --anytls-port PORT              AnyTLS 端口
  --anytls-password PASSWORD      AnyTLS 密码
  --anytls-domain DOMAIN          AnyTLS 域名
  --anytls-scheme SCHEME          AnyTLS padding scheme
  --anytls-cert-mode acme|manual  AnyTLS 证书模式
  --anytls-token TOKEN            Cloudflare API Token
  --anytls-cert-path PATH         证书路径
  --anytls-key-path PATH          私钥路径
  --ss-port PORT                  Shadowsocks 端口
  --ss-password PASSWORD          Shadowsocks 密码
  --socks-host HOST               Socks 服务地址
  --socks-port PORT               Socks 服务端口
  --version VERSION               sing-box 版本
  --update                        更新 sing-box
  -u, --uninstall                 卸载 sing-box
  -h, --help                      显示帮助
EOF
}

parse_args() {
    local option value target_name
    local -A targets=(
        [--protocol]=PROTOCOLS
        [--shadowtls-port]=SHADOWTLS_PORT
        [--shadowtls-password]=SHADOWTLS_PASSWORD
        [--shadowtls-domain]=SHADOWTLS_DOMAIN
        [--anytls-port]=ANYTLS_PORT
        [--anytls-password]=ANYTLS_PASSWORD
        [--anytls-domain]=ANYTLS_DOMAIN
        [--anytls-scheme]=ANYTLS_SCHEME
        [--anytls-cert-mode]=ANYTLS_CERT_MODE
        [--anytls-token]=ANYTLS_TOKEN
        [--anytls-cert-path]=ANYTLS_CERT_PATH
        [--anytls-key-path]=ANYTLS_KEY_PATH
        [--ss-port]=SS_PORT
        [--ss-password]=SS_PASSWORD
        [--socks-host]=SOCKS_HOST
        [--socks-port]=SOCKS_PORT
        [--version]=SINGBOX_VERSION
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
            fail "更新或卸载不能同时使用协议、配置或版本参数。"
        fi
    fi
}

install_arguments_present() {
    [ -n "$PROTOCOLS$SHADOWTLS_PORT$SHADOWTLS_PASSWORD$SHADOWTLS_DOMAIN" ] ||
        [ -n "$ANYTLS_PORT$ANYTLS_PASSWORD$ANYTLS_DOMAIN$ANYTLS_SCHEME" ] ||
        [ -n "$ANYTLS_CERT_MODE$ANYTLS_TOKEN$ANYTLS_CERT_PATH$ANYTLS_KEY_PATH" ] ||
        [ -n "$SS_PORT$SS_PASSWORD$SOCKS_HOST$SOCKS_PORT$SINGBOX_VERSION" ]
}

parse_protocols() {
    local protocol protocol_items=()
    [ -n "$PROTOCOLS" ] || fail "缺少 --protocol。"
    IFS=',' read -ra protocol_items <<< "$PROTOCOLS"
    for protocol in "${protocol_items[@]}"; do
        protocol="${protocol//[[:space:]]/}"
        case "$protocol" in
            shadowtls)
                SHADOWTLS_ENABLED=1
                SS_ENABLED=1
                ;;
            anytls)
                ANYTLS_ENABLED=1
                ;;
            shadowsocks)
                SS_ENABLED=1
                ;;
            '')
                fail "--protocol 包含空协议。"
                ;;
            *)
                fail "不支持的协议：$protocol"
                ;;
        esac
    done
}

validate_protocol_scope() {
    local anytls_options

    anytls_options="$ANYTLS_PORT$ANYTLS_PASSWORD$ANYTLS_DOMAIN$ANYTLS_SCHEME"
    anytls_options+="$ANYTLS_CERT_MODE$ANYTLS_TOKEN$ANYTLS_CERT_PATH$ANYTLS_KEY_PATH"
    if [ "$SHADOWTLS_ENABLED" -eq 0 ] && [ -n "$SHADOWTLS_PORT$SHADOWTLS_PASSWORD$SHADOWTLS_DOMAIN" ]; then
        fail "ShadowTLS 参数需要 --protocol shadowtls。"
    fi
    if [ "$ANYTLS_ENABLED" -eq 0 ] && [ -n "$anytls_options" ]; then
        fail "AnyTLS 参数需要 --protocol anytls。"
    fi
    if [ "$SS_ENABLED" -eq 0 ] && [ -n "$SS_PORT$SS_PASSWORD" ]; then
        fail "Shadowsocks 参数需要 --protocol shadowsocks。"
    fi
}

validate_port() {
    if ! [[ "$1" =~ ^[0-9]+$ ]] || (( 10#$1 < 1 || 10#$1 > 65535 )); then
        log_error "$2 端口无效：$1"
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
    command -v dpkg-deb >/dev/null 2>&1 || missing+=(dpkg)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    command -v shuf >/dev/null 2>&1 || missing+=(coreutils)
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
    local synced="" i
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
    case "$(uname -m)" in
        x86_64)
            ARCH=amd64
            ;;
        x86|i386|i686)
            ARCH=386
            ;;
        aarch64|arm64)
            ARCH=arm64
            ;;
        armv7l)
            ARCH=armv7
            ;;
        s390x)
            ARCH=s390x
            ;;
        *)
            fail "不支持的系统架构：$(uname -m)"
            ;;
    esac
}

port_in_use() {
    ss -H -lntu 2>/dev/null | grep -Eq ":${1}[[:space:]]"
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
    [ "$SHADOWTLS_ENABLED" -eq 0 ] || [ -z "$SHADOWTLS_PORT" ] || reserve_port "$SHADOWTLS_PORT" ShadowTLS
    [ "$ANYTLS_ENABLED" -eq 0 ] || [ -z "$ANYTLS_PORT" ] || reserve_port "$ANYTLS_PORT" AnyTLS
    [ "$SS_ENABLED" -eq 0 ] || [ -z "$SS_PORT" ] || reserve_port "$SS_PORT" Shadowsocks
    if [ "$SHADOWTLS_ENABLED" -eq 1 ] && [ -z "$SHADOWTLS_PORT" ]; then
        SHADOWTLS_PORT="$(generate_unique_port)"
        reserve_port "$SHADOWTLS_PORT" ShadowTLS
    fi
    if [ "$ANYTLS_ENABLED" -eq 1 ] && [ -z "$ANYTLS_PORT" ]; then
        ANYTLS_PORT="$(generate_unique_port)"
        reserve_port "$ANYTLS_PORT" AnyTLS
    fi
    if [ "$SS_ENABLED" -eq 1 ] && [ -z "$SS_PORT" ]; then
        SS_PORT="$(generate_unique_port)"
        reserve_port "$SS_PORT" Shadowsocks
    fi
}

generate_password() {
    openssl rand -base64 16 || fail "密码生成失败。"
}

prepare_shadowtls_params() {
    [ "$SHADOWTLS_ENABLED" -eq 1 ] || return 0
    [ -n "$SHADOWTLS_DOMAIN" ] || fail "启用 ShadowTLS 时必须提供 --shadowtls-domain。"
    if [[ "$SHADOWTLS_DOMAIN" == *,* || "$SHADOWTLS_DOMAIN" =~ [[:space:]] ]]; then
        fail "ShadowTLS 只支持单个域名。"
    fi
    [ -n "$SHADOWTLS_PASSWORD" ] || SHADOWTLS_PASSWORD="$(generate_password)"
}

prepare_anytls_params() {
    [ "$ANYTLS_ENABLED" -eq 1 ] || return 0
    [ -n "$ANYTLS_PASSWORD" ] || ANYTLS_PASSWORD="$(generate_password)"
    [ -n "$ANYTLS_DOMAIN" ] || fail "启用 AnyTLS 时必须提供 --anytls-domain。"
    if [ -z "$ANYTLS_CERT_MODE" ]; then
        if [ -n "$ANYTLS_CERT_PATH$ANYTLS_KEY_PATH" ]; then
            ANYTLS_CERT_MODE=manual
        elif [ -n "$ANYTLS_TOKEN" ]; then
            ANYTLS_CERT_MODE=acme
        else
            fail "AnyTLS 需要 --anytls-token 或手动证书路径。"
        fi
    fi
    case "$ANYTLS_CERT_MODE" in
        acme)
            [ -n "$ANYTLS_TOKEN" ] || fail "AnyTLS ACME 模式需要 --anytls-token。"
            [ -z "$ANYTLS_CERT_PATH$ANYTLS_KEY_PATH" ] || fail "ACME 模式不能使用手动证书路径。"
            ;;
        manual)
            [ -z "$ANYTLS_TOKEN" ] || fail "手动证书模式不能使用 --anytls-token。"
            if [ ! -f "$ANYTLS_CERT_PATH" ] || [ ! -f "$ANYTLS_KEY_PATH" ]; then
                fail "手动证书文件不存在。"
            fi
            ;;
        *)
            fail "AnyTLS 证书模式无效：$ANYTLS_CERT_MODE"
            ;;
    esac
}

prepare_shadowsocks_params() {
    [ "$SS_ENABLED" -eq 1 ] || return 0
    [ -n "$SS_PASSWORD" ] || SS_PASSWORD="$(generate_password)"
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
    prepare_shadowtls_params
    prepare_anytls_params
    prepare_shadowsocks_params
    prepare_socks_params
}

build_shadowtls_inbound() {
    jq -n --argjson port "$SHADOWTLS_PORT" --arg password "$SHADOWTLS_PASSWORD" --arg domain "$SHADOWTLS_DOMAIN" \
        '{
            type: "shadowtls",
            tag: "shadowtls-in",
            listen: "::",
            listen_port: $port,
            detour: "shadowsocks-in",
            version: 3,
            users: [{
                name: "ShadowTLS",
                password: $password
            }],
            handshake: {
                server: $domain,
                server_port: 443
            },
            strict_mode: true,
            wildcard_sni: "off"
        }'
}

build_anytls_inbound() {
    local padding scheme

    scheme="${ANYTLS_SCHEME:-$DEFAULT_PADDING_SCHEME}"
    padding="$(jq -n --arg scheme "$scheme" \
        '$scheme | split("|") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')" || return 1
    if [ "$ANYTLS_CERT_MODE" = manual ]; then
        jq -n --argjson port "$ANYTLS_PORT" --arg password "$ANYTLS_PASSWORD" --arg domain "$ANYTLS_DOMAIN" \
            --argjson padding "$padding" --arg cert "$ANYTLS_CERT_PATH" --arg key "$ANYTLS_KEY_PATH" \
            '{
                type: "anytls",
                tag: "anytls-in",
                listen: "::",
                listen_port: $port,
                users: [{
                    name: "AnyCloud",
                    password: $password
                }],
                padding_scheme: $padding,
                tls: {
                    enabled: true,
                    alpn: ["h2", "http/1.1"],
                    server_name: $domain,
                    certificate_path: $cert,
                    key_path: $key
                }
            }'
    else
        jq -n --argjson port "$ANYTLS_PORT" --arg password "$ANYTLS_PASSWORD" --arg domain "$ANYTLS_DOMAIN" \
            --argjson padding "$padding" --arg token "$ANYTLS_TOKEN" \
            '{
                type: "anytls",
                tag: "anytls-in",
                listen: "::",
                listen_port: $port,
                users: [{
                    name: "AnyCloud",
                    password: $password
                }],
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
    jq -n --argjson port "$SS_PORT" --arg method "$SS_METHOD" --arg password "$SS_PASSWORD" \
        '{
            type: "shadowsocks",
            tag: "shadowsocks-in",
            listen: "::",
            listen_port: $port,
            method: $method,
            password: $password
        }'
}

build_config() {
    local inbounds='[]' inbound

    if [ "$SHADOWTLS_ENABLED" -eq 1 ]; then
        inbound="$(build_shadowtls_inbound)" || return 1
        inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$inbound" '$a+[$b]')"
    fi
    if [ "$ANYTLS_ENABLED" -eq 1 ]; then
        inbound="$(build_anytls_inbound)" || return 1
        inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$inbound" '$a+[$b]')"
    fi
    if [ "$SS_ENABLED" -eq 1 ]; then
        inbound="$(build_shadowsocks_inbound)" || return 1
        inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$inbound" '$a+[$b]')"
    fi
    if [ "$SOCKS_ENABLED" -eq 1 ]; then
        jq -n --argjson inbounds "$inbounds" --arg host "$SOCKS_HOST" \
            --argjson port "$SOCKS_PORT" --arg url "$SOCKS_RULESET_URL" \
            '{
                log: {disabled: true},
                inbounds: $inbounds,
                outbounds: [
                    {
                        type: "socks",
                        tag: "proxy",
                        server: $host,
                        server_port: $port,
                        network: "tcp"
                    },
                    {
                        type: "direct",
                        tag: "direct"
                    }
                ],
                route: {
                    rules: [{
                        rule_set: "pureSite",
                        action: "route",
                        outbound: "proxy"
                    }],
                    rule_set: [{
                        type: "remote",
                        tag: "pureSite",
                        format: "source",
                        url: $url
                    }],
                    final: "direct"
                }
            }'
    else
        jq -n --argjson inbounds "$inbounds" \
            '{
                log: {disabled: true},
                inbounds: $inbounds
            }'
    fi
}

get_current_version() {
    local output
    [ -x "$SINGBOX_BINARY" ] || return 1
    output="$($SINGBOX_BINARY version 2>/dev/null | head -n 1)" || return 1
    [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)? ]] || return 1
    printf '%s\n' "${BASH_REMATCH[0]}"
}

get_latest_version() {
    local version
    version="$(curl -fSsL --connect-timeout 5 --max-time 15 --retry 2 \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null |
        jq -r .tag_name)" || return 1
    if [ -z "$version" ] || [ "$version" = null ]; then
        return 1
    fi
    printf '%s\n' "$version"
}

compare_versions() {
    local left="${1#v}" right="${2#v}" highest
    [ "$left" = "$right" ] && return 0
    highest="$(printf '%s\n%s\n' "$left" "$right" | sort -V | tail -n 1)"
    [ "$highest" = "$left" ] && return 1
    return 2
}

download_package_file() {
    local version="$1" target="$2"

    [[ "$version" = v* ]] || version="v$version"
    curl -fSsL --connect-timeout 10 --max-time 120 --retry 2 -o "$target" \
        "https://github.com/SagerNet/sing-box/releases/download/${version}/sing-box_${version#v}_linux_${ARCH}.deb" ||
        return 1
    [ -s "$target" ] || return 1
    dpkg-deb --info "$target" >/dev/null 2>&1
}

install_package_version() {
    local version="$1" temp_dir package extract_dir candidate actual

    [[ "$version" = v* ]] || version="v$version"
    [ -d "$TRANSACTION_DIR" ] || fail "sing-box 事务尚未开始。"
    temp_dir="${TRANSACTION_DIR}/package"
    mkdir "$temp_dir" || fail "无法创建 sing-box 下载临时目录。"
    package="${temp_dir}/sing-box.deb"
    log_info "正在下载 sing-box ${version#v}（${ARCH}）"
    download_package_file "$version" "$package" || fail "sing-box 下载或软件包预检失败。"
    extract_dir="${temp_dir}/extract"
    mkdir "$extract_dir" || fail "无法创建软件包预检目录。"
    dpkg-deb -x "$package" "$extract_dir" >/dev/null 2>&1 || fail "sing-box 软件包解包失败。"
    candidate="${extract_dir}${SINGBOX_BINARY}"
    [ -x "$candidate" ] || fail "软件包中未找到 sing-box 二进制。"
    actual="$("$candidate" version 2>/dev/null | head -n 1)" || fail "sing-box 二进制预检失败。"
    [[ "$actual" == *"${version#v}"* ]] || fail "sing-box 软件包版本不匹配。"
    if [ -r "$SINGBOX_CONFIG_FILE" ] &&
       ! "$candidate" check -c "$SINGBOX_CONFIG_FILE" >/dev/null 2>&1; then
        fail "新版本无法加载现有 sing-box 配置。"
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$package" >/dev/null 2>&1 ||
        fail "sing-box 软件包安装失败。"
    PACKAGE_CHANGED=1
}

ensure_singbox() {
    local version
    if [ -x "$SINGBOX_BINARY" ] && [ -z "$SINGBOX_VERSION" ]; then
        PACKAGE_CHANGED=0
        return 0
    fi
    if [ -n "$SINGBOX_VERSION" ]; then
        version="$SINGBOX_VERSION"
    else
        version="$(get_latest_version)" || fail "无法获取 sing-box 最新版本。"
    fi
    install_package_version "$version"
}

apply_config() {
    local directory candidate result
    directory="$(dirname "$SINGBOX_CONFIG_FILE")"
    mkdir -p "$directory" || fail "无法创建 sing-box 配置目录。"
    candidate="$(mktemp "${directory}/.config.json.XXXXXX")" || fail "无法创建 sing-box 候选配置。"
    umask 077
    if ! build_config > "$candidate"; then
        rm -f "$candidate"
        fail "sing-box 配置生成失败。"
    fi
    if ! jq -e . "$candidate" >/dev/null 2>&1; then
        rm -f "$candidate"
        fail "sing-box JSON 预检失败。"
    fi
    if ! "$SINGBOX_BINARY" check -c "$candidate" >/dev/null 2>&1; then
        rm -f "$candidate"
        fail "sing-box 配置预检失败。"
    fi
    if [ -f "$SINGBOX_CONFIG_FILE" ] && cmp -s "$candidate" "$SINGBOX_CONFIG_FILE"; then
        rm -f "$candidate"
        CONFIG_CHANGED=0
        return 0
    fi
    if ! chmod 600 "$candidate" || ! mv -f "$candidate" "$SINGBOX_CONFIG_FILE"; then
        rm -f "$candidate"
        fail "sing-box 配置应用失败。"
    fi
    CONFIG_CHANGED=1
    log_info "已更新 sing-box 配置：$SINGBOX_CONFIG_FILE"
}

begin_transaction() {
    TRANSACTION_DIR="$(mktemp -d)" || fail "无法创建 sing-box 事务目录。"
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        SERVICE_WAS_ACTIVE=1
    else
        SERVICE_WAS_ACTIVE=0
    fi
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
        SERVICE_WAS_ENABLED=1
    else
        SERVICE_WAS_ENABLED=0
    fi
    if [ -e "$SINGBOX_CONFIG_FILE" ]; then
        cp -a "$SINGBOX_CONFIG_FILE" "${TRANSACTION_DIR}/config" || {
            rm -rf "$TRANSACTION_DIR"
            fail "无法备份 sing-box 配置。"
        }
    fi
    TRANSACTION_ACTIVE=1
    trap rollback_transaction EXIT
}

rollback_transaction() {
    local restore_failed=0 restore_candidate=""

    [ "$TRANSACTION_ACTIVE" -eq 1 ] || return 0
    if [ -e "${TRANSACTION_DIR}/config" ]; then
        mkdir -p "$(dirname "$SINGBOX_CONFIG_FILE")" || restore_failed=1
        restore_candidate="$(mktemp "$(dirname "$SINGBOX_CONFIG_FILE")/.config.restore.XXXXXX")" ||
            restore_failed=1
        if [ -n "$restore_candidate" ]; then
            if ! cp -a "${TRANSACTION_DIR}/config" "$restore_candidate" ||
               ! mv -f "$restore_candidate" "$SINGBOX_CONFIG_FILE"; then
                restore_failed=1
            fi
            rm -f "$restore_candidate" || restore_failed=1
        fi
    else
        rm -f "$SINGBOX_CONFIG_FILE" || restore_failed=1
    fi
    if [ "$SERVICE_WAS_ENABLED" -eq 1 ]; then
        systemctl enable sing-box >/dev/null 2>&1 || restore_failed=1
    elif systemctl is-enabled --quiet sing-box 2>/dev/null; then
        systemctl disable sing-box >/dev/null 2>&1 || restore_failed=1
    fi
    if [ "$SERVICE_WAS_ACTIVE" -eq 1 ]; then
        if ! systemctl restart sing-box >/dev/null 2>&1 ||
           ! systemctl is-active --quiet sing-box 2>/dev/null; then
            restore_failed=1
        fi
    elif systemctl is-active --quiet sing-box 2>/dev/null; then
        systemctl stop sing-box >/dev/null 2>&1 || restore_failed=1
    fi
    TRANSACTION_ACTIVE=0
    trap - EXIT
    rm -rf "$TRANSACTION_DIR" || restore_failed=1
    if [ "$restore_failed" -eq 1 ]; then
        log_error "sing-box 配置或服务状态恢复失败。"
        return 1
    fi
    log_warning "sing-box 变更失败，已恢复脚本管理的配置和服务状态。"
}

commit_transaction() {
    [ "$TRANSACTION_ACTIVE" -eq 1 ] || return 0

    TRANSACTION_ACTIVE=0
    trap - EXIT
    rm -rf "$TRANSACTION_DIR" || log_warning "sing-box 事务临时目录清理失败：$TRANSACTION_DIR"
}

converge_service() {
    if ! systemctl is-enabled --quiet sing-box 2>/dev/null; then
        if ! systemctl enable sing-box >/dev/null 2>&1; then
            log_error "sing-box 服务启用失败。"
            return 1
        fi
        log_info "已启用系统服务：sing-box.service"
    fi
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        if (( PACKAGE_CHANGED || CONFIG_CHANGED )); then
            if ! systemctl restart sing-box >/dev/null 2>&1; then
                log_error "sing-box 重启失败。"
                return 1
            fi
        fi
    else
        if ! systemctl start sing-box >/dev/null 2>&1; then
            log_error "sing-box 启动失败。"
            return 1
        fi
    fi
}

install_singbox() {
    detect_arch
    ensure_dependencies
    ensure_time_sync
    prepare_config_params
    begin_transaction
    ensure_singbox
    apply_config
    if ! converge_service || ! verify_service; then
        if rollback_transaction; then
            fail "sing-box 应用失败，配置和服务状态已恢复；软件包变更保留。"
        fi
        fail "sing-box 应用失败，且配置或服务状态恢复失败。"
    fi
    commit_transaction
    [ "$PACKAGE_CHANGED" -eq 0 ] || log_info "已安装 sing-box 软件包。"
    log_info "sing-box 配置完成并正在运行。"
    show_configuration
}

update_singbox() {
    local current latest result
    detect_arch
    ensure_dependencies
    current="$(get_current_version)" || fail "sing-box 未安装。"
    latest="$(get_latest_version)" || fail "无法获取 sing-box 最新版本。"
    compare_versions "$latest" "$current"
    result=$?
    if [ "$result" -eq 0 ]; then
        log_info "sing-box 已是最新版本：$current"
        return 0
    fi
    if [ "$result" -eq 2 ]; then
        log_info "当前 sing-box 版本高于最新发布版本，无需更新。"
        return 0
    fi
    begin_transaction
    install_package_version "$latest"
    if ! converge_service || ! verify_service; then
        if rollback_transaction; then
            fail "sing-box 更新后服务验证失败，服务状态已恢复；新软件包保留。"
        fi
        fail "sing-box 更新后服务验证失败，且服务状态恢复失败。"
    fi
    commit_transaction
    log_info "sing-box 已更新：${current} -> ${latest#v}"
}

package_known() {
    dpkg-query -W -f='${db:Status-Abbrev}' sing-box 2>/dev/null | grep -q '^ii '
}

uninstall_singbox() {
    if ! package_known && [ ! -e "$SINGBOX_CONFIG_FILE" ] && [ ! -e "$SINGBOX_STATE_DIR" ] &&
       [ ! -e "$SINGBOX_BINARY" ] && ! systemctl cat sing-box.service >/dev/null 2>&1 &&
       ! systemctl is-active --quiet sing-box 2>/dev/null; then
        log_info "sing-box 已不存在，无需卸载。"
        return 0
    fi
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        systemctl stop sing-box >/dev/null 2>&1 || fail "sing-box 服务停止失败。"
        log_info "已停止服务：sing-box.service"
    fi
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
        systemctl disable sing-box >/dev/null 2>&1 || fail "sing-box 服务禁用失败。"
        log_info "已禁用服务：sing-box.service"
    fi
    if package_known; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq sing-box >/dev/null 2>&1 ||
            fail "sing-box 软件包卸载失败。"
        log_info "已卸载软件包：sing-box"
    fi
    rm -rf "$SINGBOX_STATE_DIR" "$SINGBOX_BINARY" ||
        fail "sing-box 文件清理失败。"
    rm -f "$SINGBOX_CONFIG_FILE" || fail "sing-box 配置删除失败。"
    rmdir "$(dirname "$SINGBOX_CONFIG_FILE")" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || fail "systemd daemon 重载失败。"
    systemctl reset-failed sing-box >/dev/null 2>&1 || true
    verify_uninstalled
    log_info "sing-box 已卸载。"
}

verify_service() {
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then
        log_error "sing-box 服务未运行。"
        return 1
    fi
}

verify_uninstalled() {
    if systemctl is-active --quiet sing-box 2>/dev/null ||
       systemctl cat sing-box.service >/dev/null 2>&1 ||
       package_known || [ -e "$SINGBOX_CONFIG_FILE" ] ||
       [ -e "$SINGBOX_STATE_DIR" ] || [ -e "$SINGBOX_BINARY" ]; then
        fail "sing-box 卸载验证失败。"
    fi
}

show_configuration() {
    local ip

    ip="$(curl -fSs --max-time 5 --retry 1 https://api.ipify.org 2>/dev/null)" || true
    printf '\n=== sing-box 客户端配置 ===\n服务器：%s\n' "${ip:-无法获取 IP}"
    if [ "$SHADOWTLS_ENABLED" -eq 1 ]; then
        printf 'ShadowTLS 端口：%s\nShadowTLS 密码：%s\nShadowTLS 域名：%s\n' \
            "$SHADOWTLS_PORT" "$SHADOWTLS_PASSWORD" "$SHADOWTLS_DOMAIN"
    fi
    if [ "$ANYTLS_ENABLED" -eq 1 ]; then
        printf 'AnyTLS 端口：%s\nAnyTLS 密码：%s\nAnyTLS 域名：%s\n证书模式：%s\n' \
            "$ANYTLS_PORT" "$ANYTLS_PASSWORD" "$ANYTLS_DOMAIN" "$ANYTLS_CERT_MODE"
    fi
    if [ "$SS_ENABLED" -eq 1 ]; then
        printf 'Shadowsocks 端口：%s\nShadowsocks 密码：%s\n加密：%s\n' \
            "$SS_PORT" "$SS_PASSWORD" "$SS_METHOD"
    fi
    if [ "$SOCKS_ENABLED" -eq 1 ]; then
        printf 'Socks：%s:%s\n规则集：%s\n' "$SOCKS_HOST" "$SOCKS_PORT" "$SOCKS_RULESET_URL"
    fi
    printf '===========================\n'
}

main() {
    parse_args "$@"
    if [ "$UPDATE_REQUESTED" -eq 0 ] && [ "$UNINSTALL_REQUESTED" -eq 0 ]; then
        parse_protocols
        validate_protocol_scope
    fi
    require_environment
    if [ "$UPDATE_REQUESTED" -eq 1 ]; then
        update_singbox
    elif [ "$UNINSTALL_REQUESTED" -eq 1 ]; then
        uninstall_singbox
    else
        install_singbox
    fi
}

main "$@"
