#!/bin/bash

set -o pipefail

readonly TABLE_NAME="gateway"
readonly NFT_MAIN_CONFIG_FILE="/etc/nftables.conf"
readonly NFT_INCLUDE_DIR="/etc/nftables.d"
readonly RULES_FILE="/etc/nftables.d/gateway.nft"
readonly NFT_INCLUDE_MARKER="# Managed by Provider nftables.sh"
readonly STATE_DIR="/etc/gateway"
readonly LOCK_FILE="/run/gateway.lock"
readonly SYSCTL_FILE="/etc/sysctl.d/99-gateway-forward.conf"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly SYNC_SERVICE="gateway-sync.service"
readonly SYNC_TIMER="gateway-sync.timer"
readonly URL_MAX_AGE_MINUTES=1440
readonly STATE_FILE="${STATE_DIR}/state"
readonly DNS_CACHE_FILE="${STATE_DIR}/dns.cache"
readonly LISTS_DIR="${STATE_DIR}/lists"
readonly IPV4_OCTET='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
readonly DOMAIN_LABEL='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
FORWARDS=()
WHITELIST=()
NEW_FORWARDS=()
NEW_WHITELIST=()
SET_FORWARD=0
SET_WHITELIST=0
PARSED_RULE=""
SYNC_MODE=""
TX_DIR=""
UNITS_CHANGED=0
RULES_APPLIED=0
declare -gA RESOLVED=()

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

show_help() {
    cat << 'EOF'
用法:
  nftables.sh --forward <规则> [规则 ...]     设置转发，完整列表覆盖原有设置
  nftables.sh --forward off                   关闭转发
  nftables.sh --whitelist <来源> [来源 ...]   设置白名单，完整列表覆盖原有设置
  nftables.sh --whitelist off                 关闭白名单，放行全部入站
  nftables.sh --list                          查看当前设置
  nftables.sh --uninstall                     全部移除
  nftables.sh -h, --help                      显示帮助
  --forward 与 --whitelist 可在同一条命令中同时设置
规则:
  源端口:目标IP或域名:目标端口[:SNAT_IP[:MSS]]，MSS 为 auto 或 536-9000
来源:
  IP、IP段、域名、https URL 或本地文件路径；URL 与文件内容为每行一个 IP 或 IP 段
说明:
  白名单开启后，只有白名单内的来源可以访问本机和使用转发
  URL 和本地文件更新后会自动生效
EOF
}

validate_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]
}

validate_ipv4() {
    [[ "$1" =~ ^(${IPV4_OCTET}\.){3}${IPV4_OCTET}$ ]]
}

validate_cidr() {
    [[ "$1" =~ ^(${IPV4_OCTET}\.){3}${IPV4_OCTET}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]
}

validate_domain() {
    [ "${#1}" -le 253 ] && [[ "$1" =~ ^${DOMAIN_LABEL}(\.${DOMAIN_LABEL})*$ ]] && [[ ! "$1" =~ ^[0-9.]+$ ]]
}

item_kind() {
    local item="$1"
    if [[ "$item" =~ ^https://[^[:space:]]+$ ]]; then
        printf 'url\n'
    elif [[ "$item" =~ ^/[^[:space:]]*[^/[:space:]]$ ]]; then
        printf 'file\n'
    elif validate_cidr "$item"; then
        printf 'ip\n'
    elif validate_domain "$item"; then
        printf 'domain\n'
    else
        return 1
    fi
}

parse_forward_rule() {
    local rule="$1" sport target dport snat mss
    [[ "$rule" =~ ^[^:]+:[^:]+:[^:]+(:[^:]*(:[^:]+)?)?$ ]] ||
        fail "规则格式错误：${rule}，正确格式为 源端口:目标IP或域名:目标端口[:SNAT_IP[:MSS]]"
    IFS=':' read -r sport target dport snat mss <<< "$rule"
    target="${target,,}"
    validate_port "$sport" || fail "无效的源端口：${sport}"
    validate_port "$dport" || fail "无效的目标端口：${dport}"
    if ! validate_ipv4 "$target" && ! validate_domain "$target"; then
        fail "无效的目标地址：${target}"
    fi
    if [ -n "$snat" ] && ! validate_ipv4 "$snat"; then
        fail "无效的 SNAT IP：${snat}"
    fi
    if [ -n "$mss" ] && [ "$mss" != auto ]; then
        if ! [[ "$mss" =~ ^[1-9][0-9]{2,3}$ ]] || [ "$mss" -lt 536 ] || [ "$mss" -gt 9000 ]; then
            fail "无效的 MSS：${mss}，必须为 auto 或 536-9000"
        fi
    fi
    PARSED_RULE="${sport} ${target} ${dport} ${snat:--} ${mss:--}"
}

parse_declaration() {
    local section="" arg item
    local -a forward_args=() whitelist_args=()
    for arg in "$@"; do
        case "$arg" in
            --forward|--whitelist)
                section="${arg#--}"
                if [ "$section" = forward ]; then
                    [ "$SET_FORWARD" -eq 0 ] || fail "--forward 只能指定一次"
                    SET_FORWARD=1
                else
                    [ "$SET_WHITELIST" -eq 0 ] || fail "--whitelist 只能指定一次"
                    SET_WHITELIST=1
                fi
                ;;
            *)
                if [ "$section" = forward ]; then
                    forward_args+=("$arg")
                elif [ "$section" = whitelist ]; then
                    whitelist_args+=("$arg")
                else
                    fail "未知参数：${arg}，请执行 --help 查看用法"
                fi
                ;;
        esac
    done
    if [ "$SET_FORWARD" -eq 1 ]; then
        [ "${#forward_args[@]}" -gt 0 ] || fail "--forward 需要规则或 off"
        if [ "${forward_args[*]}" != off ]; then
            for arg in "${forward_args[@]}"; do
                parse_forward_rule "$arg"
                for item in "${NEW_FORWARDS[@]}"; do
                    [ "${item%% *}" != "${PARSED_RULE%% *}" ] || fail "源端口重复：${PARSED_RULE%% *}"
                done
                NEW_FORWARDS+=("$PARSED_RULE")
            done
        fi
    fi
    if [ "$SET_WHITELIST" -eq 1 ]; then
        [ "${#whitelist_args[@]}" -gt 0 ] || fail "--whitelist 需要来源或 off"
        if [ "${whitelist_args[*]}" != off ]; then
            for arg in "${whitelist_args[@]}"; do
                [[ "$arg" == /* || "$arg" == https://* ]] || arg="${arg,,}"
                [ "$arg" != off ] || fail "off 不能与其他来源同时使用"
                item_kind "$arg" >/dev/null || fail "无效的白名单来源：${arg}"
                [[ " ${NEW_WHITELIST[*]} " == *" ${arg} "* ]] || NEW_WHITELIST+=("$arg")
            done
        fi
    fi
}

require_root() {
    [ "$EUID" -eq 0 ] || fail "此操作必须以 root 权限运行"
}

ensure_dependencies() {
    local -a missing=()
    command -v nft >/dev/null 2>&1 || missing+=(nftables)
    command -v flock >/dev/null 2>&1 || missing+=(util-linux)
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v sysctl >/dev/null 2>&1 || missing+=(procps)
    [ "${#missing[@]}" -gt 0 ] || return 0
    command -v apt-get >/dev/null 2>&1 || fail "缺少依赖且未检测到 apt-get：${missing[*]}"
    log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || fail "软件包索引更新失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    log_info "已安装依赖：${missing[*]}"
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 || fail "缺少依赖命令：flock"
    exec 9>"$LOCK_FILE" || fail "无法创建锁文件：${LOCK_FILE}"
    flock -w 10 9 || fail "已有网关任务正在执行，请稍后重试"
}

open_transaction() {
    mkdir -p "$STATE_DIR" || fail "无法创建状态目录：${STATE_DIR}"
    chmod 700 "$STATE_DIR" || fail "无法设置状态目录权限"
    TX_DIR="$(mktemp -d "${LOCK_FILE%/*}/gateway-tx.XXXXXX")" || fail "无法创建候选目录"
    trap 'rm -rf "$TX_DIR"; rmdir "$STATE_DIR" 2>/dev/null' EXIT
    mkdir "${TX_DIR}/lists" || fail "无法创建候选目录"
}

load_state() {
    local kind first second third fourth fifth
    FORWARDS=()
    WHITELIST=()
    [ -f "$STATE_FILE" ] || return 0
    while read -r kind first second third fourth fifth; do
        case "$kind" in
            forward)
                FORWARDS+=("${first} ${second} ${third} ${fourth} ${fifth}")
                ;;
            whitelist)
                WHITELIST+=("$first")
                ;;
        esac
    done < "$STATE_FILE" || fail "无法读取状态文件：${STATE_FILE}"
}

forward_domain() {
    local target
    read -r _ target _ <<< "$1"
    validate_ipv4 "$target" && return 1
    printf '%s\n' "$target"
}

list_sources() {
    local entry item
    for entry in "${FORWARDS[@]}"; do
        forward_domain "$entry"
    done
    for item in "${WHITELIST[@]}"; do
        [ "$(item_kind "$item")" = ip ] || printf '%s\n' "$item"
    done
}

apply_declaration() {
    [ "$SET_FORWARD" -eq 0 ] || FORWARDS=("${NEW_FORWARDS[@]}")
    [ "$SET_WHITELIST" -eq 0 ] || WHITELIST=("${NEW_WHITELIST[@]}")
}

source_is_strict() {
    [ "$SYNC_MODE" = user ]
}

lookup_ipv4() {
    timeout 5 getent ahostsv4 "$1" 2>/dev/null | awk '/STREAM/ { print $1; exit }'
}

resolve_domain() {
    local domain="$1" ip
    [ -z "${RESOLVED[$domain]:-}" ] || return 0
    ip="$(lookup_ipv4 "$domain")"
    if ! validate_ipv4 "$ip"; then
        source_is_strict && fail "域名解析失败：${domain}"
        ip="$(awk -v domain="$domain" '$1 == domain { print $2; exit }' "$DNS_CACHE_FILE" 2>/dev/null)"
        validate_ipv4 "$ip" || fail "域名解析失败且无可用缓存：${domain}"
        log_error "域名解析失败，沿用缓存：${domain} -> ${ip}"
    fi
    RESOLVED["$domain"]="$ip"
    printf '%s %s\n' "$domain" "$ip" >> "${TX_DIR}/dns.cache" || fail "无法写入解析缓存"
}

list_copy_name() {
    local sum
    sum="$(printf '%s' "$1" | cksum)" || return 1
    printf '%s.txt\n' "${sum%% *}"
}

fetch_list() {
    local item="$1" kind="$2" output="$3" raw="${3}.raw"
    if [ "$kind" = url ]; then
        curl -fsSL -m 60 -o "$raw" "$item" || return 1
    elif [ -f "$item" ] && [ -r "$item" ]; then
        cp "$item" "$raw" || return 1
    else
        return 1
    fi
    awk '
        function valid(value,    parts, octets, count, index_value) {
            count = split(value, parts, "/")
            if (count > 2 || (count == 2 && (parts[2] !~ /^[0-9]+$/ || parts[2] + 0 > 32))) return 0
            if (split(parts[1], octets, ".") != 4) return 0
            for (index_value = 1; index_value <= 4; index_value++) {
                if (octets[index_value] !~ /^[0-9]+$/ || octets[index_value] + 0 > 255) return 0
            }
            return 1
        }
        { sub(/#.*/, ""); gsub(/[[:space:]]/, "") }
        $0 == "" { next }
        !valid($0) { invalid = 1; exit }
        { print }
        END { exit invalid }
    ' "$raw" > "$output" || return 1
    rm -f "$raw"
    [ -s "$output" ]
}

refresh_list() {
    local item="$1" kind="$2" name current candidate
    name="$(list_copy_name "$item")" || fail "无法计算白名单副本名称"
    current="${LISTS_DIR}/${name}"
    candidate="${TX_DIR}/lists/${name}"
    if [ "$kind" = url ] && ! source_is_strict &&
        [ -n "$(find "$current" -mmin "-${URL_MAX_AGE_MINUTES}" 2>/dev/null)" ]; then
        cp -p "$current" "$candidate" || fail "无法读取白名单副本：${item}"
        return 0
    fi
    fetch_list "$item" "$kind" "$candidate" && return 0
    source_is_strict && fail "白名单来源获取失败或内容无效：${item}"
    [ -f "$current" ] || fail "白名单来源获取失败且无可用副本：${item}"
    log_error "白名单来源获取失败或内容无效，沿用旧副本：${item}"
    cp -p "$current" "$candidate" || fail "无法读取白名单副本：${item}"
}

refresh_sources() {
    local entry domain item kind elements="${TX_DIR}/elements"
    : > "${TX_DIR}/dns.cache" || fail "无法创建解析缓存"
    : > "$elements" || fail "无法创建白名单候选"
    for entry in "${FORWARDS[@]}"; do
        domain="$(forward_domain "$entry")" || continue
        resolve_domain "$domain"
    done
    for item in "${WHITELIST[@]}"; do
        kind="$(item_kind "$item")"
        case "$kind" in
            ip)
                printf '%s\n' "$item" >> "$elements"
                ;;
            domain)
                resolve_domain "$item"
                printf '%s\n' "${RESOLVED[$item]}" >> "$elements"
                ;;
            url|file)
                refresh_list "$item" "$kind"
                cat "${TX_DIR}/lists/$(list_copy_name "$item")" >> "$elements"
                ;;
        esac
    done || fail "无法生成白名单候选"
    sort -u "$elements" -o "$elements" || fail "无法整理白名单候选"
}

write_state() {
    local entry item
    {
        for entry in "${FORWARDS[@]}"; do
            printf 'forward %s\n' "$entry"
        done
        for item in "${WHITELIST[@]}"; do
            printf 'whitelist %s\n' "$item"
        done
    } > "${TX_DIR}/state" || fail "无法写入状态候选"
}

render_admission() {
    cat << EOF

    set whitelist {
        type ipv4_addr
        flags interval
        auto-merge
        elements = {
$(awk 'NR > 1 { printf ",\n" } { printf "            %s", $0 } END { printf "\n" }' "${TX_DIR}/elements")
        }
    }

    chain admission {
        type filter hook prerouting priority -150; policy drop;
        iif "lo" accept
        ct state established,related accept
        meta l4proto ipv6-icmp icmpv6 type != echo-request accept
        udp sport 67 udp dport 68 accept
        ip6 saddr fe80::/10 udp sport 547 udp dport 546 accept
        ip saddr @whitelist accept
    }
EOF
}

render_chain() {
    printf '\n    chain %s {\n        %s\n%s    }\n' "$1" "$2" "$3"
}

compile_rules() {
    local output="$1" entry sport target dport snat mss ip action protocol
    local dnat_rules="" snat_rules="" mss_rules="" indent="        "
    for entry in "${FORWARDS[@]}"; do
        read -r sport target dport snat mss <<< "$entry"
        ip="$target"
        validate_ipv4 "$ip" || ip="${RESOLVED[$target]}"
        action="masquerade"
        [ "$snat" = - ] || action="snat ip to ${snat}"
        for protocol in tcp udp; do
            dnat_rules+="${indent}meta nfproto ipv4 fib daddr type local ${protocol} dport ${sport}"
            dnat_rules+=" dnat ip to ${ip}:${dport}"$'\n'
            snat_rules+="${indent}ct status dnat meta l4proto ${protocol} ct original proto-dst ${sport} ${action}"$'\n'
        done
        if [ "$mss" != - ]; then
            [ "$mss" != auto ] || mss="rt mtu"
            mss_rules+="${indent}ct status dnat meta l4proto tcp ct original proto-dst ${sport}"
            mss_rules+=" tcp flags syn tcp option maxseg size set ${mss}"$'\n'
        fi
    done
    {
        printf '#!/usr/sbin/nft -f\n%s\n\n' "$NFT_INCLUDE_MARKER"
        printf 'table inet %s\ndelete table inet %s\n\n' "$TABLE_NAME" "$TABLE_NAME"
        printf 'table inet %s {' "$TABLE_NAME"
        if [ "${#WHITELIST[@]}" -gt 0 ]; then
            render_admission
        fi
        if [ -n "$dnat_rules" ]; then
            render_chain forward_dnat "type nat hook prerouting priority dstnat; policy accept;" "$dnat_rules"
            render_chain forward_snat "type nat hook postrouting priority srcnat; policy accept;" "$snat_rules"
        fi
        if [ -n "$mss_rules" ]; then
            render_chain forward_mss "type filter hook forward priority mangle; policy accept;" "$mss_rules"
        fi
        printf '}\n'
    } > "$output" || fail "无法生成 nftables 规则"
}

check_lockout() {
    local peer="${SSH_CONNECTION:-}"
    peer="${peer%% *}"
    [ "${#WHITELIST[@]}" -gt 0 ] || return 0
    [ "${GATEWAY_ALLOW_LOCKOUT:-0}" != 1 ] || return 0
    [ -n "$peer" ] || return 0
    validate_ipv4 "$peer" ||
        fail "当前 SSH 来源 ${peer} 无法被 IPv4 白名单覆盖；确认后可设置 GATEWAY_ALLOW_LOCKOUT=1 重试"
    awk -v peer="$peer" '
        function number(ip,    octets) {
            split(ip, octets, ".")
            return ((octets[1] * 256 + octets[2]) * 256 + octets[3]) * 256 + octets[4]
        }
        BEGIN { target = number(peer) }
        {
            bits = 32
            if (split($0, parts, "/") == 2) bits = parts[2] + 0
            size = 2 ^ (32 - bits)
            if (int(target / size) == int(number(parts[1]) / size)) { found = 1; exit }
        }
        END { exit !found }
    ' "${TX_DIR}/elements" && return 0
    fail "当前 SSH 来源 ${peer} 不在白名单中，应用后将无法建立新连接；确认后可设置 GATEWAY_ALLOW_LOCKOUT=1 重试"
}

install_file() {
    local source="$1" target="$2" mode="${3:-600}" tmp
    cmp -s "$source" "$target" && return 0
    tmp="$(mktemp "${target}.XXXXXX")" || return 1
    if cp "$source" "$tmp" && chmod "$mode" "$tmp" && mv "$tmp" "$target"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

publish_lists() {
    local file target
    mkdir -p "$LISTS_DIR" || return 1
    for file in "${TX_DIR}"/lists/*.txt; do
        [ -f "$file" ] || continue
        target="${LISTS_DIR}/${file##*/}"
        install_file "$file" "$target" || return 1
        touch -r "$file" "$target" || return 1
    done
    for file in "${LISTS_DIR}"/*.txt; do
        [ -f "$file" ] || continue
        [ -f "${TX_DIR}/lists/${file##*/}" ] || rm -f "$file" || return 1
    done
}

nft_include_present() {
    local pattern="^[[:space:]]*include[[:space:]]+\"?${NFT_INCLUDE_DIR}/(\\*|${TABLE_NAME})\\.nft\"?[[:space:]]*$"
    grep -Eq "$pattern" "$NFT_MAIN_CONFIG_FILE" 2>/dev/null
}

ensure_nft_include() {
    local tmp
    if ! nft_include_present; then
        tmp="$(mktemp "${NFT_MAIN_CONFIG_FILE}.XXXXXX")" || fail "无法创建 nftables 主配置候选"
        if [ -f "$NFT_MAIN_CONFIG_FILE" ]; then
            cp -p "$NFT_MAIN_CONFIG_FILE" "$tmp" || fail "无法读取 nftables 主配置"
        else
            chmod 644 "$tmp" || fail "无法设置 nftables 主配置权限"
        fi
        printf '\n%s\ninclude "%s"\n' "$NFT_INCLUDE_MARKER" "$RULES_FILE" >> "$tmp" ||
            fail "无法写入 nftables include"
        mv "$tmp" "$NFT_MAIN_CONFIG_FILE" || fail "无法写入 nftables include"
        log_info "已写入 nftables include：${NFT_MAIN_CONFIG_FILE}"
    fi
    systemctl is-enabled --quiet nftables.service 2>/dev/null && return 0
    systemctl enable nftables.service >/dev/null 2>&1 || fail "无法启用 nftables.service，重启后规则将丢失"
    log_info "已启用系统服务：nftables.service"
}

remove_nft_include() {
    local tmp
    [ -f "$NFT_MAIN_CONFIG_FILE" ] || return 0
    grep -Fqx "$NFT_INCLUDE_MARKER" "$NFT_MAIN_CONFIG_FILE" || return 0
    tmp="$(mktemp "${NFT_MAIN_CONFIG_FILE}.XXXXXX")" || return 1
    if cp -p "$NFT_MAIN_CONFIG_FILE" "$tmp" &&
        awk -v marker="$NFT_INCLUDE_MARKER" '
            $0 == marker { skip = 1; next }
            skip { skip = 0; next }
            { print }
        ' "$NFT_MAIN_CONFIG_FILE" > "$tmp" && mv "$tmp" "$NFT_MAIN_CONFIG_FILE"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

ensure_forwarding() {
    if [ "${#FORWARDS[@]}" -eq 0 ]; then
        rm -f "$SYSCTL_FILE" || fail "无法删除 IPv4 转发配置：${SYSCTL_FILE}"
        return 0
    fi
    printf 'net.ipv4.ip_forward=1\n' > "${TX_DIR}/sysctl.conf" || fail "无法生成 IPv4 转发配置"
    install_file "${TX_DIR}/sysctl.conf" "$SYSCTL_FILE" 644 || fail "无法写入 IPv4 转发配置：${SYSCTL_FILE}"
    [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ] && return 0
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || fail "无法启用 IPv4 转发"
    log_info "已启用 IPv4 转发"
}

script_path() {
    readlink -f "$0"
}

publish_unit() {
    local name="$1"
    cmp -s "${TX_DIR}/${name}" "${SYSTEMD_DIR}/${name}" && return 0
    install_file "${TX_DIR}/${name}" "${SYSTEMD_DIR}/${name}" 644 || fail "无法写入 systemd 单元：${name}"
    UNITS_CHANGED=1
}

install_sync_units() {
    local script
    script="$(script_path)" || fail "无法定位脚本路径"
    cat > "${TX_DIR}/${SYNC_SERVICE}" << EOF || fail "无法生成 systemd 单元"
[Unit]
Description=Gateway nftables sync
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash "${script}" --sync
EOF
    cat > "${TX_DIR}/${SYNC_TIMER}" << EOF || fail "无法生成 systemd 单元"
[Unit]
Description=Gateway nftables sync timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=10min
AccuracySec=5s
Unit=${SYNC_SERVICE}

[Install]
WantedBy=timers.target
EOF
    publish_unit "$SYNC_SERVICE"
    publish_unit "$SYNC_TIMER"
    if [ "$UNITS_CHANGED" -eq 1 ]; then
        systemctl daemon-reload >/dev/null 2>&1 || fail "systemd daemon-reload 失败"
    fi
    if systemctl is-enabled --quiet "$SYNC_TIMER" 2>/dev/null &&
        systemctl is-active --quiet "$SYNC_TIMER" 2>/dev/null; then
        return 0
    fi
    systemctl enable --now "$SYNC_TIMER" >/dev/null 2>&1 || fail "定时同步启用失败：${SYNC_TIMER}"
    log_info "已启用定时同步：${SYNC_TIMER}"
}

remove_sync_units() {
    [ -e "${SYSTEMD_DIR}/${SYNC_TIMER}" ] || [ -e "${SYSTEMD_DIR}/${SYNC_SERVICE}" ] || return 0
    systemctl disable --now "$SYNC_TIMER" >/dev/null 2>&1 || fail "定时同步停用失败：${SYNC_TIMER}"
    rm -f "${SYSTEMD_DIR}/${SYNC_TIMER}" "${SYSTEMD_DIR}/${SYNC_SERVICE}" || fail "无法删除定时同步单元"
    systemctl daemon-reload >/dev/null 2>&1 || fail "systemd daemon-reload 失败"
    log_info "已移除定时同步：${SYNC_TIMER}"
}

apply_rules() {
    local candidate="${TX_DIR}/gateway.nft" output
    if [ "$SYNC_MODE" != user ] && cmp -s "$candidate" "$RULES_FILE" &&
        nft list table inet "$TABLE_NAME" >/dev/null 2>&1; then
        return 0
    fi
    output="$(nft -f "$candidate" 2>&1)" || fail "规则应用失败，运行规则与持久规则保持不变：${output}"
    mkdir -p "$NFT_INCLUDE_DIR" || fail "无法创建目录：${NFT_INCLUDE_DIR}"
    install_file "$candidate" "$RULES_FILE" || fail "规则已生效但持久化失败；修复后请执行 --sync"
    RULES_APPLIED=1
}

teardown() {
    local tables=""
    if command -v nft >/dev/null 2>&1; then
        tables="$(nft list tables 2>/dev/null)" || fail "无法读取 nftables 状态，已保留网关状态"
    fi
    remove_sync_units
    if grep -Fqx "table inet ${TABLE_NAME}" <<< "$tables"; then
        nft delete table inet "$TABLE_NAME" >/dev/null 2>&1 || fail "无法删除 nftables 表：${TABLE_NAME}"
    fi
    remove_nft_include || fail "无法清理 nftables include"
    rm -f "$RULES_FILE" "$SYSCTL_FILE" || fail "无法删除网关规则文件"
    rm -rf "$STATE_DIR" || fail "无法删除状态目录：${STATE_DIR}"
}

commit_changes() {
    local output
    refresh_sources
    if [ "${#FORWARDS[@]}" -eq 0 ] && [ "${#WHITELIST[@]}" -eq 0 ]; then
        teardown
        log_info "转发与白名单均已关闭，网关规则已全部移除"
        return 0
    fi
    write_state
    compile_rules "${TX_DIR}/gateway.nft"
    if [ "$SYNC_MODE" = user ] || ! cmp -s "${TX_DIR}/gateway.nft" "$RULES_FILE"; then
        output="$(nft -c -f "${TX_DIR}/gateway.nft" 2>&1)" || fail "nftables 规则预检失败：${output}"
    fi
    check_lockout
    install_file "${TX_DIR}/state" "$STATE_FILE" || fail "状态提交失败，运行规则未变"
    install_file "${TX_DIR}/dns.cache" "$DNS_CACHE_FILE" || fail "解析缓存提交失败，运行规则未变"
    publish_lists || fail "白名单副本提交失败，运行规则未变"
    apply_rules
    ensure_nft_include
    ensure_forwarding
    if [ -n "$(list_sources)" ]; then
        install_sync_units
    else
        remove_sync_units
    fi
    [ "$RULES_APPLIED" -eq 0 ] || log_info "网关规则已应用：白名单 ${#WHITELIST[@]} 项，转发 ${#FORWARDS[@]} 条"
}

run_change() {
    SYNC_MODE="$1"
    require_root
    ensure_dependencies
    acquire_lock
    if [ "$SYNC_MODE" = timer ] && [ ! -f "$STATE_FILE" ]; then
        log_info "未配置网关规则，无需同步"
        return 0
    fi
    open_transaction
    load_state
    [ "$SYNC_MODE" = timer ] || apply_declaration
    commit_changes
}

run_uninstall() {
    require_root
    acquire_lock
    teardown
    log_info "网关已卸载"
}

cached_ip() {
    awk -v domain="$1" '$1 == domain { print $2; exit }' "$DNS_CACHE_FILE" 2>/dev/null
}

item_note() {
    local item="$1" kind count
    kind="$(item_kind "$item")"
    case "$kind" in
        domain)
            printf '（解析：%s）' "$(cached_ip "$item")"
            ;;
        url|file)
            count="$(wc -l < "${LISTS_DIR}/$(list_copy_name "$item")" 2>/dev/null)"
            printf '（%s 条）' "${count// /}"
            ;;
    esac
}

show_list() {
    local entry item sport target dport snat mss extra
    load_state
    if [ "${#FORWARDS[@]}" -eq 0 ] && [ "${#WHITELIST[@]}" -eq 0 ]; then
        printf '无\n'
        return 0
    fi
    if [ "${#WHITELIST[@]}" -eq 0 ]; then
        printf '准入：全部放行\n'
    else
        printf '准入：白名单（%s 项）\n' "${#WHITELIST[@]}"
        for item in "${WHITELIST[@]}"; do
            printf -- '- %s%s\n' "$item" "$(item_note "$item")"
        done
    fi
    [ "${#FORWARDS[@]}" -gt 0 ] || return 0
    printf '\n转发：\n'
    for entry in "${FORWARDS[@]}"; do
        read -r sport target dport snat mss <<< "$entry"
        extra=""
        validate_ipv4 "$target" || extra="解析：$(cached_ip "$target")"
        [ "$snat" = - ] || extra+="${extra:+，}SNAT：${snat}"
        [ "$mss" = - ] || extra+="${extra:+，}MSS：${mss/auto/自动}"
        printf -- '- %s -> %s:%s%s\n' "$sport" "$target" "$dport" "${extra:+（${extra}）}"
    done
}

main() {
    local command="${1:-}"
    case "$command" in
        --help|-h)
            [ "$#" -eq 1 ] || fail "${command} 不接受额外参数"
            show_help
            ;;
        --list)
            [ "$#" -eq 1 ] || fail "--list 不接受额外参数"
            require_root
            show_list
            ;;
        --forward|--whitelist)
            parse_declaration "$@"
            run_change user
            ;;
        --sync)
            [ "$#" -eq 1 ] || fail "--sync 不接受额外参数"
            run_change timer
            ;;
        --uninstall)
            [ "$#" -eq 1 ] || fail "--uninstall 不接受额外参数"
            run_uninstall
            ;;
        "")
            show_help
            return 1
            ;;
        *)
            fail "未知参数：${command}，请执行 --help 查看用法"
            ;;
    esac
}

main "$@"
