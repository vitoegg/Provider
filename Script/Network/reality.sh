#!/bin/bash

set -o pipefail

XRAY_BINARY="${XRAY_BINARY:-/usr/local/bin/xray}"
XRAY_CONFIG_FILE="${XRAY_CONFIG_FILE:-/usr/local/etc/xray/config.json}"
XRAY_UNIT_FILE="${XRAY_UNIT_FILE:-/etc/systemd/system/xray.service}"
XRAY_RELEASE_URL="https://github.com/XTLS/Xray-core/releases/download"
DEFAULT_PORT_START=50000
DEFAULT_PORT_END=60000
SS_METHOD="2022-blake3-aes-128-gcm"
ROUTE_DOMAINS=("domain:reddit.com" "domain:cloudflare.com")

PROTOCOLS=""
ENABLED_PROTOCOLS=()
GIVEN_OPTIONS=()
SOCKS_ENABLED=0
UPDATE_REQUESTED=0
UNINSTALL_REQUESTED=0
REALITY_PORT=""
REALITY_DOMAIN=""
REALITY_UUID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
SHADOWSOCKS_PORT=""
SHADOWSOCKS_PASSWORD=""
SOCKS_HOST=""
SOCKS_PORT=""
USED_PORTS=()
CURRENT_VERSION=""
TARGET_VERSION=""
WORK_DIR=""
CANDIDATE_BINARY=""
CANDIDATE_CONFIG=""
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
  reality.sh --protocol reality|shadowsocks|reality,shadowsocks
             [--reality-port PORT] [--reality-domain DOMAIN] [--reality-uuid UUID]
             [--reality-private-key KEY] [--reality-short-id ID]
             [--ss-port PORT] [--ss-password PASSWORD] [--socks-host HOST] [--socks-port PORT]
  reality.sh --update
  reality.sh -u, --uninstall
  reality.sh -h, --help
EOF
}

parse_args() {
    local option value
    local -A targets=(
        [--protocol]=PROTOCOLS
        [--reality-port]=REALITY_PORT
        [--reality-domain]=REALITY_DOMAIN
        [--reality-uuid]=REALITY_UUID
        [--reality-private-key]=REALITY_PRIVATE_KEY
        [--reality-short-id]=REALITY_SHORT_ID
        [--ss-port]=SHADOWSOCKS_PORT
        [--ss-password]=SHADOWSOCKS_PASSWORD
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
            printf -v "${targets[$option]}" '%s' "$value"
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
        [ "${#GIVEN_OPTIONS[@]}" -eq 0 ] || fail "更新或卸载不能同时使用协议或配置参数。"
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
            reality|shadowsocks)
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
    for protocol in reality shadowsocks; do
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
            reality|shadowsocks)
                protocol_enabled "$protocol" || fail "$option 需要 --protocol ${protocol}。"
                ;;
        esac
    done
}

validate_port() {
    if ! [[ "$1" =~ ^[0-9]{1,5}$ ]] || (( 10#$1 < 1 || 10#$1 > 65535 )); then
        log_error "$2 端口无效：$1"
        return 1
    fi
}

validate_domain() {
    local label pattern
    label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    pattern="^${label}([.]${label})*$"
    [ "${#1}" -le 253 ] && [[ "$1" =~ $pattern ]]
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
    command -v unzip >/dev/null 2>&1 || missing+=(unzip)
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

detect_arch() {
    case "$(uname -m)" in
        x86_64)
            printf '64\n'
            ;;
        aarch64)
            printf 'arm64-v8a\n'
            ;;
        *)
            fail "不支持的系统架构：$(uname -m)"
            ;;
    esac
}

xray_tool() {
    printf '%s\n' "${CANDIDATE_BINARY:-$XRAY_BINARY}"
}

port_in_use() {
    ss -H -lntup 2>/dev/null | grep -E ":${1}[[:space:]]" | grep -vq '"xray"'
}

existing_value() {
    [ -r "$XRAY_CONFIG_FILE" ] || return 0
    jq -r --arg tag "$1" --argjson path "$2" \
        'first(.inbounds[]? | select(.tag == $tag) | getpath($path) // empty)' "$XRAY_CONFIG_FILE" 2>/dev/null
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

generate_port() {
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
    local protocol variable port
    USED_PORTS=()
    for protocol in "${ENABLED_PROTOCOLS[@]}"; do
        variable="${protocol^^}_PORT"
        [ -z "${!variable}" ] || reserve_port "${!variable}" "$protocol"
    done
    for protocol in "${ENABLED_PROTOCOLS[@]}"; do
        variable="${protocol^^}_PORT"
        [ -z "${!variable}" ] || continue
        port="$(existing_value "${protocol}-in" '["port"]')"
        if [ -z "$port" ] || port_is_reserved "$port"; then
            port="$(generate_port)" || exit 1
        fi
        printf -v "$variable" '%s' "$port"
        reserve_port "$port" "$protocol"
    done
}

assign_value() {
    local value
    [ -z "${!1}" ] || return 0
    value="$(existing_value "$2" "$3")"
    if [ -z "$value" ]; then
        value="$("$4")" || exit 1
    fi
    printf -v "$1" '%s' "$value"
}

generate_uuid() {
    "$(xray_tool)" uuid || fail "UUID 生成失败。"
}

generate_private_key() {
    local output
    output="$("$(xray_tool)" x25519)" || fail "X25519 密钥生成失败。"
    printf '%s\n' "$output" | sed -n -E 's/^Private ?[Kk]ey:[[:space:]]*//p' | head -n 1
}

generate_short_id() {
    openssl rand -hex 4 || fail "Reality short id 生成失败。"
}

generate_ss_password() {
    openssl rand -base64 16 || fail "Shadowsocks 密码生成失败。"
}

prepare_reality() {
    local output
    [ -n "$REALITY_DOMAIN" ] || fail "启用 Reality 时必须提供 --reality-domain。"
    validate_domain "$REALITY_DOMAIN" || fail "Reality 域名无效：$REALITY_DOMAIN"
    assign_value REALITY_UUID reality-in '["settings","clients",0,"id"]' generate_uuid
    assign_value REALITY_PRIVATE_KEY reality-in '["streamSettings","realitySettings","privateKey"]' \
        generate_private_key
    assign_value REALITY_SHORT_ID reality-in '["streamSettings","realitySettings","shortIds",0]' generate_short_id
    [[ "$REALITY_UUID" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] ||
        fail "Reality UUID 无效：$REALITY_UUID"
    [[ "$REALITY_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] || fail "Reality 私钥无效。"
    [[ "$REALITY_SHORT_ID" =~ ^([0-9a-f]{2}){1,8}$ ]] || fail "Reality short id 无效：$REALITY_SHORT_ID"
    output="$("$(xray_tool)" x25519 -i "$REALITY_PRIVATE_KEY" 2>/dev/null)" || fail "Reality 公钥推导失败。"
    REALITY_PUBLIC_KEY="$(printf '%s\n' "$output" | sed -n -E 's/^(Public ?[Kk]ey|Password[^:]*):[[:space:]]*//p')"
    [ -n "$REALITY_PUBLIC_KEY" ] || fail "Reality 公钥推导失败。"
}

prepare_shadowsocks() {
    assign_value SHADOWSOCKS_PASSWORD shadowsocks-in '["settings","password"]' generate_ss_password
    [[ "$SHADOWSOCKS_PASSWORD" =~ ^[A-Za-z0-9+/]{21}[AQgw]==$ ]] ||
        fail "Shadowsocks 密码必须是 16 字节密钥的 base64 编码，可用 openssl rand -base64 16 生成。"
}

prepare_socks() {
    [ "$SOCKS_ENABLED" -eq 1 ] || return 0
    if [ -z "$SOCKS_HOST" ] || [ -z "$SOCKS_PORT" ]; then
        fail "启用 Socks 时必须同时提供 host 和 port。"
    fi
    validate_port "$SOCKS_PORT" Socks || exit 1
}

inbound_reality() {
    jq -n --argjson port "$REALITY_PORT" --arg uuid "$REALITY_UUID" --arg domain "$REALITY_DOMAIN" \
        --arg key "$REALITY_PRIVATE_KEY" --arg sid "$REALITY_SHORT_ID" \
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

inbound_shadowsocks() {
    jq -n --argjson port "$SHADOWSOCKS_PORT" --arg method "$SS_METHOD" --arg password "$SHADOWSOCKS_PASSWORD" \
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

build_config() {
    local inbounds protocol domains

    inbounds="$(
        for protocol in "${ENABLED_PROTOCOLS[@]}"; do
            "inbound_${protocol}" || exit 1
        done | jq -s .
    )" || return 1
    domains="$(printf '%s\n' "${ROUTE_DOMAINS[@]}" | jq -R . | jq -s .)" || return 1
    jq -n --argjson inbounds "$inbounds" --argjson socks "$SOCKS_ENABLED" --arg host "$SOCKS_HOST" \
        --arg port "$SOCKS_PORT" --argjson domains "$domains" \
        '{
            log: {loglevel: "error"},
            inbounds: $inbounds,
            outbounds: ([{protocol: "freedom", tag: "direct"}] + if $socks == 1 then [{
                protocol: "socks",
                tag: "proxy",
                settings: {address: $host, port: ($port | tonumber)}
            }] else [] end)
        } + if $socks == 1 then {
            routing: {
                domainStrategy: "AsIs",
                rules: [{
                    type: "field",
                    network: "tcp",
                    domain: $domains,
                    outboundTag: "proxy"
                }]
            }
        } else {} end'
}

render_service() {
    cat <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
DynamicUser=yes
LoadCredential=config.json:${XRAY_CONFIG_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=65536
ExecStart=${XRAY_BINARY} run -config \${CREDENTIALS_DIRECTORY}/config.json
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
}

get_current_version() {
    local output
    [ -x "$XRAY_BINARY" ] || return 1
    output="$("$XRAY_BINARY" version 2>/dev/null)" || return 1
    [[ "$output" =~ ^Xray\ ([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

get_latest_version() {
    local version
    version="$(curl -fSsL --connect-timeout 5 --max-time 15 --retry 2 \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | jq -r '.tag_name // empty')" ||
        return 1
    [ -n "$version" ] || return 1
    printf '%s\n' "${version#v}"
}

resolve_version() {
    local latest
    CURRENT_VERSION="$(get_current_version)" || CURRENT_VERSION=""
    if [ "$UPDATE_REQUESTED" -eq 0 ] && [ -n "$CURRENT_VERSION" ]; then
        TARGET_VERSION="$CURRENT_VERSION"
        return 0
    fi
    [ "$UPDATE_REQUESTED" -eq 0 ] || [ -n "$CURRENT_VERSION" ] || fail "Xray 未安装。"
    latest="$(get_latest_version)" || fail "无法获取 Xray 最新版本。"
    TARGET_VERSION="$latest"
    if [ -n "$CURRENT_VERSION" ] &&
       [ "$(printf '%s\n%s\n' "$TARGET_VERSION" "$CURRENT_VERSION" | sort -V | tail -n 1)" != "$TARGET_VERSION" ]; then
        TARGET_VERSION="$CURRENT_VERSION"
    fi
}

stage_binary() {
    local arch asset archive expected actual output
    [ "$TARGET_VERSION" != "$CURRENT_VERSION" ] || return 0
    arch="$(detect_arch)" || exit 1
    asset="Xray-linux-${arch}.zip"
    archive="${WORK_DIR}/${asset}"
    log_info "正在下载 Xray ${TARGET_VERSION}（${arch}）"
    curl -fSsL --connect-timeout 10 --max-time 120 --retry 2 -o "$archive" \
        "${XRAY_RELEASE_URL}/v${TARGET_VERSION}/${asset}" || fail "Xray 下载失败。"
    curl -fSsL --connect-timeout 10 --max-time 30 --retry 2 -o "${archive}.dgst" \
        "${XRAY_RELEASE_URL}/v${TARGET_VERSION}/${asset}.dgst" || fail "Xray 校验文件下载失败。"
    expected="$(sed -n 's/^SHA2-256=[[:space:]]*//p' "${archive}.dgst")"
    actual="$(sha256sum "$archive")" || fail "Xray 下载文件校验失败。"
    if [ -z "$expected" ] || [ "${actual%% *}" != "$expected" ]; then
        fail "Xray 下载文件校验失败。"
    fi
    unzip -qo "$archive" xray -d "$WORK_DIR" >/dev/null 2>&1 || fail "Xray 解压失败。"
    CANDIDATE_BINARY="${WORK_DIR}/xray"
    chmod 755 "$CANDIDATE_BINARY" || fail "Xray 二进制权限设置失败。"
    if ! output="$("$CANDIDATE_BINARY" version 2>&1)"; then
        fail "Xray 二进制预检失败：${output:-无错误输出}"
    fi
    [[ "$output" == "Xray ${TARGET_VERSION} "* ]] || fail "Xray 版本校验失败。"
}

resolve_config() {
    local protocol
    render_service > "${WORK_DIR}/xray.service" || fail "Xray unit 生成失败。"
    if [ "$UPDATE_REQUESTED" -eq 1 ]; then
        [ -r "$XRAY_CONFIG_FILE" ] || fail "未找到 Xray 配置：$XRAY_CONFIG_FILE"
        return 0
    fi
    prepare_ports
    for protocol in "${ENABLED_PROTOCOLS[@]}"; do
        "prepare_${protocol}"
    done
    prepare_socks
    CANDIDATE_CONFIG="${WORK_DIR}/config.json"
    build_config > "$CANDIDATE_CONFIG" || fail "Xray 配置生成失败。"
}

preflight() {
    local output
    if ! output="$("$(xray_tool)" run -test -config "${CANDIDATE_CONFIG:-$XRAY_CONFIG_FILE}" 2>&1)"; then
        fail "Xray 配置预检失败：$(printf '%s\n' "$output" | tail -n 1)"
    fi
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
    if [ -n "$CANDIDATE_BINARY" ] && publish_file "$CANDIDATE_BINARY" "$XRAY_BINARY" 755; then
        BINARY_CHANGED=1
        log_info "已安装 Xray 二进制：${TARGET_VERSION}"
    fi
    if [ -n "$CANDIDATE_CONFIG" ] && publish_file "$CANDIDATE_CONFIG" "$XRAY_CONFIG_FILE" 600; then
        CONFIG_CHANGED=1
        log_info "已更新 Xray 配置：$XRAY_CONFIG_FILE"
    fi
    if publish_file "${WORK_DIR}/xray.service" "$XRAY_UNIT_FILE" 644; then
        UNIT_CHANGED=1
        log_info "已更新系统服务：xray.service"
    fi
}

converge_service() {
    if [ "$UNIT_CHANGED" -eq 1 ]; then
        systemctl daemon-reload >/dev/null 2>&1 || fail "systemd daemon 重载失败。"
    fi
    if ! systemctl is-enabled --quiet xray.service 2>/dev/null; then
        systemctl enable xray.service >/dev/null 2>&1 || fail "xray.service 启用失败。"
        log_info "已启用系统服务：xray.service"
    fi
    if ! systemctl is-active --quiet xray.service 2>/dev/null; then
        systemctl start xray.service >/dev/null 2>&1 ||
            fail "Xray 启动失败，请执行：journalctl -u xray --no-pager"
    elif (( BINARY_CHANGED || CONFIG_CHANGED || UNIT_CHANGED )); then
        systemctl restart xray.service >/dev/null 2>&1 ||
            fail "Xray 重启失败，请执行：journalctl -u xray --no-pager"
    else
        return 0
    fi
    sleep 2
}

cleanup_work_dir() {
    [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
}

uninstall_xray() {
    if [ ! -e "$XRAY_BINARY" ] && [ ! -e "$XRAY_CONFIG_FILE" ] && [ ! -e "$XRAY_UNIT_FILE" ] &&
       ! systemctl is-active --quiet xray.service 2>/dev/null &&
       ! systemctl cat xray.service >/dev/null 2>&1; then
        log_info "Xray 已不存在，无需卸载。"
        return 0
    fi
    if systemctl is-active --quiet xray.service 2>/dev/null; then
        systemctl stop xray.service >/dev/null 2>&1 || fail "Xray 服务停止失败。"
        log_info "已停止系统服务：xray.service"
    fi
    if systemctl is-enabled --quiet xray.service 2>/dev/null; then
        systemctl disable xray.service >/dev/null 2>&1 || fail "Xray 服务禁用失败。"
        log_info "已禁用系统服务：xray.service"
    fi
    rm -f "$XRAY_UNIT_FILE" "$XRAY_CONFIG_FILE" "$XRAY_BINARY" || fail "Xray 文件删除失败。"
    rmdir "$(dirname "$XRAY_CONFIG_FILE")" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || fail "systemd daemon 重载失败。"
    systemctl reset-failed xray.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet xray.service 2>/dev/null ||
       systemctl cat xray.service >/dev/null 2>&1 || [ -e "$XRAY_BINARY" ] ||
       [ -e "$XRAY_CONFIG_FILE" ] || [ -e "$XRAY_UNIT_FILE" ]; then
        fail "Xray 卸载验证失败。"
    fi
    log_info "Xray 已卸载。"
}

verify_service() {
    systemctl is-active --quiet xray.service 2>/dev/null ||
        fail "Xray 服务未运行，请执行：journalctl -u xray --no-pager"
}

show_configuration() {
    local ip
    ip="$(curl -fSs --max-time 5 --retry 1 https://api.ipify.org 2>/dev/null)" || true
    printf '\n=== Xray 客户端配置 ===\n服务器：%s\n' "${ip:-无法获取 IP}"
    if protocol_enabled reality; then
        printf 'Reality 端口：%s\nUUID：%s\n域名：%s\nPublicKey：%s\nShort ID：%s\n' \
            "$REALITY_PORT" "$REALITY_UUID" "$REALITY_DOMAIN" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID"
    fi
    if protocol_enabled shadowsocks; then
        printf 'Shadowsocks 端口：%s\nShadowsocks 密码：%s\n加密：%s\n' \
            "$SHADOWSOCKS_PORT" "$SHADOWSOCKS_PASSWORD" "$SS_METHOD"
    fi
    if [ "$SOCKS_ENABLED" -eq 1 ]; then
        printf 'Socks：%s:%s\n分流域名：reddit.com, cloudflare.com\n' "$SOCKS_HOST" "$SOCKS_PORT"
    fi
    printf '========================\n'
}

show_result() {
    if [ "$UPDATE_REQUESTED" -eq 0 ]; then
        log_info "Xray 配置完成并正在运行。"
        show_configuration
    elif [ "$BINARY_CHANGED" -eq 1 ]; then
        log_info "Xray 已更新：${CURRENT_VERSION} -> ${TARGET_VERSION}"
    else
        log_info "Xray 已是最新版本：${CURRENT_VERSION}"
    fi
}

main() {
    parse_args "$@"
    require_environment
    if [ "$UNINSTALL_REQUESTED" -eq 1 ]; then
        uninstall_xray
        return
    fi
    ensure_dependencies
    WORK_DIR="$(mktemp -d)" || fail "无法创建 Xray 临时目录。"
    trap cleanup_work_dir EXIT
    resolve_version
    stage_binary
    resolve_config
    preflight
    apply_changes
    converge_service
    verify_service
    show_result
}

main "$@"
