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
ENABLED_PROTOCOLS=()
GIVEN_OPTIONS=()
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
TROJAN_PORT=""
TROJAN_PASSWORD=""
TROJAN_DOMAIN=""
TROJAN_CERT_PATH=""
TROJAN_KEY_PATH=""
TROJAN_WS_NAME=""
SHADOWSOCKS_PORT=""
SHADOWSOCKS_PASSWORD=""
SOCKS_HOST=""
SOCKS_PORT=""
USED_PORTS=()
CURRENT_VERSION=""
TARGET_VERSION=""
WORK_DIR=""
PACKAGE_FILE=""
CANDIDATE_BINARY=""
CANDIDATE_CONFIG=""
PACKAGE_CHANGED=0
CONFIG_CHANGED=0

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
  singbox.sh --protocol anytls|shadowsocks|shadowtls|trojan[,...] [--version VERSION]
             [--shadowtls-port PORT] [--shadowtls-password PASSWORD] [--shadowtls-domain DOMAIN]
             [--anytls-port PORT] [--anytls-password PASSWORD] [--anytls-domain DOMAIN]
             [--anytls-scheme SCHEME] [--anytls-cert-mode acme|manual] [--anytls-token TOKEN]
             [--anytls-cert-path PATH] [--anytls-key-path PATH]
             [--trojan-port PORT] [--trojan-password PASSWORD] [--trojan-domain DOMAIN]
             [--trojan-cert-path PATH] [--trojan-key-path PATH] [--trojan-ws-name NAME]
             [--ss-port PORT] [--ss-password PASSWORD] [--socks-host HOST] [--socks-port PORT]
  singbox.sh --update
  singbox.sh -u, --uninstall
  singbox.sh -h, --help
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
        [--trojan-port]=TROJAN_PORT
        [--trojan-password]=TROJAN_PASSWORD
        [--trojan-domain]=TROJAN_DOMAIN
        [--trojan-cert-path]=TROJAN_CERT_PATH
        [--trojan-key-path]=TROJAN_KEY_PATH
        [--trojan-ws-name]=TROJAN_WS_NAME
        [--ss-port]=SHADOWSOCKS_PORT
        [--ss-password]=SHADOWSOCKS_PASSWORD
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
            GIVEN_OPTIONS+=("$option")
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
        [ "${#GIVEN_OPTIONS[@]}" -eq 0 ] || fail "更新或卸载不能同时使用协议、配置或版本参数。"
        return 0
    fi
    parse_protocols
    validate_protocol_scope
}

parse_protocols() {
    local protocol items=() requested=" "
    [ -n "$PROTOCOLS" ] || fail "缺少 --protocol。"
    IFS=',' read -ra items <<< "$PROTOCOLS"
    for protocol in "${items[@]}"; do
        protocol="${protocol//[[:space:]]/}"
        case "$protocol" in
            shadowtls)
                requested+="shadowtls shadowsocks "
                ;;
            anytls|trojan|shadowsocks)
                requested+="${protocol} "
                ;;
            '')
                fail "--protocol 包含空协议。"
                ;;
            *)
                fail "不支持的协议：$protocol"
                ;;
        esac
    done
    for protocol in shadowtls anytls trojan shadowsocks; do
        [[ "$requested" != *" ${protocol} "* ]] || ENABLED_PROTOCOLS+=("$protocol")
    done
}

protocol_enabled() {
    [[ " ${ENABLED_PROTOCOLS[*]} " == *" $1 "* ]]
}

validate_protocol_scope() {
    local option protocol
    for option in "${GIVEN_OPTIONS[@]}"; do
        protocol="${option#--}"
        protocol="${protocol%%-*}"
        [ "$protocol" != ss ] || protocol=shadowsocks
        case "$protocol" in
            shadowtls|anytls|trojan|shadowsocks)
                protocol_enabled "$protocol" || fail "$option 需要 --protocol ${protocol}。"
                ;;
        esac
    done
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
    ss -H -lntup 2>/dev/null | grep -E ":${1}[[:space:]]" | grep -vq '"sing-box"'
}

existing_value() {
    [ -r "$SINGBOX_CONFIG_FILE" ] || return 0
    jq -r --arg tag "$1" --argjson path "$2" \
        'first(.inbounds[]? | select(.tag == $tag) | getpath($path) // empty)' "$SINGBOX_CONFIG_FILE" 2>/dev/null
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
    ! port_in_use "$1" || fail "$2 端口已被其他进程占用：$1"
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
    local protocol variable
    USED_PORTS=()
    for protocol in "${ENABLED_PROTOCOLS[@]}"; do
        variable="${protocol^^}_PORT"
        [ -z "${!variable}" ] || reserve_port "${!variable}" "$protocol"
    done
    for protocol in "${ENABLED_PROTOCOLS[@]}"; do
        assign_port "${protocol^^}_PORT" "${protocol}-in" "$protocol"
    done
}

assign_port() {
    local port
    [ -z "${!1}" ] || return 0
    port="$(existing_value "$2" '["listen_port"]')"
    if [ -z "$port" ] || port_is_reserved "$port"; then
        port="$(generate_unique_port)" || exit 1
    fi
    printf -v "$1" '%s' "$port"
    reserve_port "$port" "$3"
}

assign_password() {
    local password
    [ -z "${!1}" ] || return 0
    password="$(existing_value "$2" "$3")"
    if [ -z "$password" ]; then
        password="$(generate_password)" || exit 1
    fi
    printf -v "$1" '%s' "$password"
}

generate_password() {
    openssl rand -base64 16 || fail "密码生成失败。"
}

prepare_shadowtls() {
    [ -n "$SHADOWTLS_DOMAIN" ] || fail "启用 ShadowTLS 时必须提供 --shadowtls-domain。"
    if [[ "$SHADOWTLS_DOMAIN" == *,* || "$SHADOWTLS_DOMAIN" =~ [[:space:]] ]]; then
        fail "ShadowTLS 只支持单个域名。"
    fi
    assign_password SHADOWTLS_PASSWORD shadowtls-in '["users",0,"password"]'
}

prepare_anytls() {
    assign_password ANYTLS_PASSWORD anytls-in '["users",0,"password"]'
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

prepare_trojan() {
    assign_password TROJAN_PASSWORD trojan-in '["users",0,"password"]'
    [ -n "$TROJAN_DOMAIN" ] || fail "启用 Trojan 时必须提供 --trojan-domain。"
    case "$TROJAN_WS_NAME" in
        .|..|*/*|*'?'*|*'#'*|*[[:space:][:cntrl:]]*)
            fail "Trojan WS 路径名无效：$TROJAN_WS_NAME"
            ;;
    esac
    if [ ! -f "$TROJAN_CERT_PATH" ] || [ ! -f "$TROJAN_KEY_PATH" ]; then
        fail "Trojan 证书文件不存在。"
    fi
}

prepare_shadowsocks() {
    assign_password SHADOWSOCKS_PASSWORD shadowsocks-in '["password"]'
}

prepare_socks() {
    [ "$SOCKS_ENABLED" -eq 1 ] || return 0
    if [ -z "$SOCKS_HOST" ] || [ -z "$SOCKS_PORT" ]; then
        fail "启用 Socks 时必须同时提供 host 和 port。"
    fi
    validate_port "$SOCKS_PORT" Socks || exit 1
}

inbound_shadowtls() {
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

inbound_anytls() {
    jq -n --argjson port "$ANYTLS_PORT" --arg password "$ANYTLS_PASSWORD" --arg domain "$ANYTLS_DOMAIN" \
        --arg scheme "${ANYTLS_SCHEME:-$DEFAULT_PADDING_SCHEME}" --arg mode "$ANYTLS_CERT_MODE" \
        --arg cert "$ANYTLS_CERT_PATH" --arg key "$ANYTLS_KEY_PATH" --arg token "$ANYTLS_TOKEN" \
        '{
            type: "anytls",
            tag: "anytls-in",
            listen: "::",
            listen_port: $port,
            users: [{
                name: "AnyCloud",
                password: $password
            }],
            padding_scheme: ($scheme | split("|") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))),
            tls: ({
                enabled: true,
                alpn: ["h2", "http/1.1"],
                server_name: $domain
            } + if $mode == "manual" then
                {certificate_path: $cert, key_path: $key}
            else
                {
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
            end)
        }'
}

inbound_trojan() {
    jq -n --argjson port "$TROJAN_PORT" --arg password "$TROJAN_PASSWORD" --arg domain "$TROJAN_DOMAIN" \
        --arg cert "$TROJAN_CERT_PATH" --arg key "$TROJAN_KEY_PATH" --arg ws_path "/${TROJAN_WS_NAME:-img}" \
        '{
            type: "trojan",
            tag: "trojan-in",
            listen: "::",
            listen_port: $port,
            users: [{
                name: "Trojan",
                password: $password
            }],
            tls: {
                enabled: true,
                alpn: ["http/1.1"],
                server_name: $domain,
                certificate_path: $cert,
                key_path: $key
            },
            transport: {
                type: "ws",
                path: $ws_path
            }
        }'
}

inbound_shadowsocks() {
    jq -n --argjson port "$SHADOWSOCKS_PORT" --arg method "$SS_METHOD" --arg password "$SHADOWSOCKS_PASSWORD" \
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
    local inbounds protocol

    inbounds="$(
        for protocol in "${ENABLED_PROTOCOLS[@]}"; do
            "inbound_${protocol}" || exit 1
        done | jq -s .
    )" || return 1
    jq -n --argjson inbounds "$inbounds" --argjson socks "$SOCKS_ENABLED" --arg host "$SOCKS_HOST" \
        --arg port "$SOCKS_PORT" --arg url "$SOCKS_RULESET_URL" \
        '{
            log: {disabled: true},
            inbounds: $inbounds
        } + if $socks == 1 then {
            outbounds: [
                {
                    type: "socks",
                    tag: "proxy",
                    server: $host,
                    server_port: ($port | tonumber),
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
            },
            experimental: {
                cache_file: {enabled: true}
            }
        } else {} end'
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

download_package_file() {
    local version="$1" target="$2"

    [[ "$version" = v* ]] || version="v$version"
    curl -fSsL --connect-timeout 10 --max-time 120 --retry 2 -o "$target" \
        "https://github.com/SagerNet/sing-box/releases/download/${version}/sing-box_${version#v}_linux_${ARCH}.deb" ||
        return 1
    [ -s "$target" ] || return 1
    dpkg-deb --info "$target" >/dev/null 2>&1
}

resolve_version() {
    local latest
    CURRENT_VERSION="$(get_current_version)" || CURRENT_VERSION=""
    if [ -n "$SINGBOX_VERSION" ]; then
        TARGET_VERSION="${SINGBOX_VERSION#v}"
        return 0
    fi
    if [ "$UPDATE_REQUESTED" -eq 0 ] && [ -n "$CURRENT_VERSION" ]; then
        TARGET_VERSION="$CURRENT_VERSION"
        return 0
    fi
    [ "$UPDATE_REQUESTED" -eq 0 ] || [ -n "$CURRENT_VERSION" ] || fail "sing-box 未安装。"
    latest="$(get_latest_version)" || fail "无法获取 sing-box 最新版本。"
    TARGET_VERSION="${latest#v}"
    if [ -n "$CURRENT_VERSION" ] &&
       [ "$(printf '%s\n%s\n' "$TARGET_VERSION" "$CURRENT_VERSION" | sort -V | tail -n 1)" != "$TARGET_VERSION" ]; then
        TARGET_VERSION="$CURRENT_VERSION"
    fi
}

resolve_config() {
    local protocol

    if [ "$UPDATE_REQUESTED" -eq 1 ]; then
        [ -r "$SINGBOX_CONFIG_FILE" ] || fail "未找到 sing-box 配置：$SINGBOX_CONFIG_FILE"
        return 0
    fi
    prepare_ports
    for protocol in "${ENABLED_PROTOCOLS[@]}"; do
        "prepare_${protocol}"
    done
    prepare_socks
    CANDIDATE_CONFIG="${WORK_DIR}/config.json"
    build_config > "$CANDIDATE_CONFIG" || fail "sing-box 配置生成失败。"
}

stage_binary() {
    local actual

    if [ "$TARGET_VERSION" = "$CURRENT_VERSION" ]; then
        CANDIDATE_BINARY="$SINGBOX_BINARY"
        return 0
    fi
    detect_arch
    PACKAGE_FILE="${WORK_DIR}/sing-box.deb"
    log_info "正在下载 sing-box ${TARGET_VERSION}（${ARCH}）"
    download_package_file "$TARGET_VERSION" "$PACKAGE_FILE" || fail "sing-box 下载或软件包预检失败。"
    dpkg-deb -x "$PACKAGE_FILE" "${WORK_DIR}/extract" >/dev/null 2>&1 || fail "sing-box 软件包解包失败。"
    CANDIDATE_BINARY="${WORK_DIR}/extract${SINGBOX_BINARY}"
    [ -x "$CANDIDATE_BINARY" ] || fail "软件包中未找到 sing-box 二进制。"
    actual="$("$CANDIDATE_BINARY" version 2>/dev/null | head -n 1)" || fail "sing-box 二进制预检失败。"
    [[ "$actual" == *"$TARGET_VERSION"* ]] || fail "sing-box 软件包版本不匹配。"
}

preflight() {
    "$CANDIDATE_BINARY" check -c "${CANDIDATE_CONFIG:-$SINGBOX_CONFIG_FILE}" >/dev/null 2>&1 ||
        fail "sing-box 配置预检失败。"
}

apply_changes() {
    local directory staged

    if [ -n "$PACKAGE_FILE" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            "$PACKAGE_FILE" >/dev/null 2>&1 || fail "sing-box 软件包安装失败。"
        PACKAGE_CHANGED=1
        log_info "已安装 sing-box 软件包：${TARGET_VERSION}"
    fi
    [ -n "$CANDIDATE_CONFIG" ] || return 0
    if [ -f "$SINGBOX_CONFIG_FILE" ] && cmp -s "$CANDIDATE_CONFIG" "$SINGBOX_CONFIG_FILE"; then
        return 0
    fi
    directory="$(dirname "$SINGBOX_CONFIG_FILE")"
    mkdir -p "$directory" || fail "无法创建 sing-box 配置目录。"
    staged="$(mktemp "${directory}/.config.json.XXXXXX")" || fail "无法创建 sing-box 候选配置。"
    if ! cp "$CANDIDATE_CONFIG" "$staged" || ! mv -f "$staged" "$SINGBOX_CONFIG_FILE"; then
        rm -f "$staged"
        fail "sing-box 配置应用失败。"
    fi
    CONFIG_CHANGED=1
    log_info "已更新 sing-box 配置：$SINGBOX_CONFIG_FILE"
}

converge_service() {
    if ! systemctl is-enabled --quiet sing-box 2>/dev/null; then
        systemctl enable sing-box >/dev/null 2>&1 || fail "sing-box 服务启用失败。"
        log_info "已启用系统服务：sing-box.service"
    fi
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then
        systemctl start sing-box >/dev/null 2>&1 ||
            fail "sing-box 启动失败，请执行：journalctl -u sing-box --no-pager"
    elif (( PACKAGE_CHANGED || CONFIG_CHANGED )); then
        systemctl restart sing-box >/dev/null 2>&1 ||
            fail "sing-box 重启失败，请执行：journalctl -u sing-box --no-pager"
    else
        return 0
    fi
    sleep 2
}

cleanup_work_dir() {
    [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
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
    systemctl is-active --quiet sing-box 2>/dev/null ||
        fail "sing-box 服务未运行，请执行：journalctl -u sing-box --no-pager"
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
    if protocol_enabled shadowtls; then
        printf 'ShadowTLS 端口：%s\nShadowTLS 密码：%s\nShadowTLS 域名：%s\n' \
            "$SHADOWTLS_PORT" "$SHADOWTLS_PASSWORD" "$SHADOWTLS_DOMAIN"
    fi
    if protocol_enabled anytls; then
        printf 'AnyTLS 端口：%s\nAnyTLS 密码：%s\nAnyTLS 域名：%s\n证书模式：%s\n' \
            "$ANYTLS_PORT" "$ANYTLS_PASSWORD" "$ANYTLS_DOMAIN" "$ANYTLS_CERT_MODE"
    fi
    if protocol_enabled trojan; then
        printf 'Trojan 端口：%s\nTrojan 密码：%s\nTrojan 域名：%s\nTrojan WS 路径：/%s\n' \
            "$TROJAN_PORT" "$TROJAN_PASSWORD" "$TROJAN_DOMAIN" "${TROJAN_WS_NAME:-img}"
    fi
    if protocol_enabled shadowsocks; then
        printf 'Shadowsocks 端口：%s\nShadowsocks 密码：%s\n加密：%s\n' \
            "$SHADOWSOCKS_PORT" "$SHADOWSOCKS_PASSWORD" "$SS_METHOD"
    fi
    if [ "$SOCKS_ENABLED" -eq 1 ]; then
        printf 'Socks：%s:%s\n规则集：%s\n' "$SOCKS_HOST" "$SOCKS_PORT" "$SOCKS_RULESET_URL"
    fi
    printf '===========================\n'
}

show_result() {
    if [ "$UPDATE_REQUESTED" -eq 0 ]; then
        log_info "sing-box 配置完成并正在运行。"
        show_configuration
    elif [ "$PACKAGE_CHANGED" -eq 1 ]; then
        log_info "sing-box 已更新：${CURRENT_VERSION} -> ${TARGET_VERSION}"
    else
        log_info "sing-box 已是最新版本：${CURRENT_VERSION}"
    fi
}

main() {
    parse_args "$@"
    require_environment
    if [ "$UNINSTALL_REQUESTED" -eq 1 ]; then
        uninstall_singbox
        return
    fi
    ensure_dependencies
    WORK_DIR="$(mktemp -d)" || fail "无法创建 sing-box 临时目录。"
    trap cleanup_work_dir EXIT
    resolve_version
    resolve_config
    stage_binary
    preflight
    apply_changes
    converge_service
    verify_service
    show_result
}

main "$@"
