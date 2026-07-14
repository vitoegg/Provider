#!/bin/bash

# 状态文件是唯一真相源；每次变更都全量渲染并原子应用 nftables ruleset。
# 运行环境为 Debian/Ubuntu，依赖 bash、nftables、util-linux 与 procfs。

set -o pipefail

readonly NAT_TABLE_NAME="forwardaws_nat"
readonly FILTER_TABLE_NAME="forwardaws_filter"
readonly NFT_MAIN_CONFIG_FILE="/etc/nftables.conf"
readonly NFT_INCLUDE_DIR="/etc/nftables.d"
readonly FORWARDAWS_RULES_FILE="${NFT_INCLUDE_DIR}/forwardaws.nft"
readonly NFT_INCLUDE_MARKER="# Managed by Provider nftables.sh"
readonly STATE_DIR="/etc/forwardaws"
readonly RULES_STATE_FILE="${STATE_DIR}/rules.db"
readonly CONFIG_FILE="${STATE_DIR}/config.env"
readonly GLOBAL_LOCK_FILE="/run/forwardaws.lock"
readonly IPV4_FORWARD_SYSCTL_FILE="/etc/sysctl.d/99-forwardaws.conf"
readonly SYSTEMD_SYSTEM_DIR="/etc/systemd/system"
readonly PROTECT_SERVICE_NAME="forwardaws-protect.service"
readonly PROTECT_TIMER_NAME="forwardaws-protect.timer"
readonly PROVIDERDNS_CONSUMER="forwardaws"
PROVIDERDNS_BIN="${PROVIDERDNS_BIN:-}"
readonly PROVIDERDNS_LOCAL_NAME="providerdns.sh"
readonly DEFAULT_EXCLUDE_PORTS="53"
readonly FORWARDAWS_TIMEZONE="Asia/Shanghai"
readonly FORWARDAWS_TIMEZONE_FALLBACK="UTC-8"

SYSTEMD_UNITS_CHANGED=0
DOMAIN_RULES_DROPPED=0

log_info() {
    [ "${FORWARDAWS_QUIET:-${QUIET:-0}}" = "1" ] || printf '[INFO] %s\n' "$*"
}

log_warning() {
    printf '[WARNING] %s\n' "$*" >&2
}

log_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_ip_address() {
    local ip="$1" octet
    local IFS='.'
    local -a octets
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
}

validate_noping_spec() {
    local spec="$1" ip
    local -a ips
    [ "$spec" = "1" ] && return 0
    case "$spec" in
        ""|,*|*,|*,,*)
            return 1
            ;;
    esac
    IFS=',' read -ra ips <<< "$spec"
    for ip in "${ips[@]}"; do
        validate_ip_address "$ip" || return 1
    done
}

validate_domain_name() {
    local domain="$1"
    [[ "$domain" =~ ^[0-9]+([.][0-9]+){3}$ ]] && return 1
    [ -n "$domain" ] && [ "${#domain}" -le 253 ] && \
        [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\
([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

format_epoch_time() {
    local ts="$1"
    if ! [[ "$ts" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$ts"
        return 0
    fi
    TZ="$FORWARDAWS_TIMEZONE" date -d "@$ts" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null ||
        TZ="$FORWARDAWS_TIMEZONE_FALLBACK" date -d "@$ts" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null ||
        printf '%s\n' "$ts"
}

get_script_absolute_path() {
    readlink -f "$0" 2>/dev/null
}

providerdns_bin() {
    local script_dir local_path
    if [ -n "$PROVIDERDNS_BIN" ]; then
        [ -f "$PROVIDERDNS_BIN" ] || return 1
        printf '%s\n' "$PROVIDERDNS_BIN"
        return 0
    fi
    script_dir=$(cd "$(dirname "$(get_script_absolute_path)")" 2>/dev/null && pwd)
    local_path="${script_dir}/${PROVIDERDNS_LOCAL_NAME}"
    [ -f "$local_path" ] || return 1
    printf '%s\n' "$local_path"
}

require_providerdns() {
    providerdns_bin >/dev/null && return 0
    log_error "需要 providerdns.sh：请设置 PROVIDERDNS_BIN，或将 providerdns.sh 放在当前脚本同目录"
    return 1
}

run_providerdns() {
    local bin
    bin=$(providerdns_bin) || return 1
    /bin/bash "$bin" "$@"
}

providerdns_refresh() {
    require_providerdns || return 1
    PROVIDERDNS_LOCK_WAIT="${PROVIDERDNS_LOCK_WAIT:-10}" run_providerdns --refresh
}

providerdns_set_forwardaws() {
    local domains_file="$1" script_path hook_command quoted_script_path
    require_providerdns || return 1
    script_path=$(get_script_absolute_path)
    printf -v quoted_script_path '%q' "$script_path"
    hook_command="FORWARDAWS_QUIET=1 FORWARDAWS_LOCK_WAIT=10 /bin/bash ${quoted_script_path} --ddns apply"
    run_providerdns --set "$PROVIDERDNS_CONSUMER" "$domains_file" "$hook_command"
}

providerdns_unset_forwardaws() {
    providerdns_bin >/dev/null || return 0
    run_providerdns --unset "$PROVIDERDNS_CONSUMER"
}

require_root() {
    [ "$EUID" -eq 0 ] && return 0
    log_error "此操作必须以 root 权限运行"
    return 1
}

ensure_dependencies() {
    local -a missing=()
    command -v nft >/dev/null 2>&1 || missing+=(nftables)
    command -v flock >/dev/null 2>&1 || missing+=(util-linux)
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    command -v sysctl >/dev/null 2>&1 || missing+=(procps)
    command -v getent >/dev/null 2>&1 || missing+=(libc-bin)
    [ "${#missing[@]}" -gt 0 ] || return 0
    if ! command -v apt-get >/dev/null 2>&1; then
        log_error "缺少依赖且未检测到 apt-get：${missing[*]}"
        return 1
    fi
    FORWARDAWS_QUIET=0 QUIET=0 log_info "正在安装缺失依赖：${missing[*]}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1; then
        log_error "软件包索引更新失败"
        return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1; then
        log_error "依赖安装失败：${missing[*]}"
        return 1
    fi
    FORWARDAWS_QUIET=0 QUIET=0 log_info "已安装依赖：${missing[*]}"
}

acquire_global_lock() {
    local lock_wait="${FORWARDAWS_LOCK_WAIT:-0}" lock_error="检测到其他任务正在执行中，请稍后重试"
    if ! exec 9>"$GLOBAL_LOCK_FILE"; then
        log_error "无法创建全局锁文件: $GLOBAL_LOCK_FILE"
        return 1
    fi
    if [[ "$lock_wait" =~ ^[0-9]+$ ]] && [ "$lock_wait" -gt 0 ]; then
        lock_error="等待全局锁超时，请稍后重试"
        flock -w "$lock_wait" 9
    else
        flock -n 9
    fi || {
        log_error "$lock_error"
        return 1
    }
}

nft_main_config_has_forwardaws_include() {
    [ -f "$NFT_MAIN_CONFIG_FILE" ] || return 1
    grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/(\*|forwardaws)\.nft"?[[:space:]]*$' \
        "$NFT_MAIN_CONFIG_FILE"
}

ensure_nft_main_config_include() (
    local include_line='include "/etc/nftables.d/*.nft"' tmp
    if ! nft_main_config_has_forwardaws_include; then
        tmp="$(mktemp "${NFT_MAIN_CONFIG_FILE}.XXXXXX")" || return 1
        trap 'rm -f "$tmp"' EXIT
        if [ -e "$NFT_MAIN_CONFIG_FILE" ]; then
            cp -p "$NFT_MAIN_CONFIG_FILE" "$tmp" || return 1
        else
            chmod 644 "$tmp" 2>/dev/null || true
        fi
        printf '\n%s\n%s\n' "$NFT_INCLUDE_MARKER" "$include_line" >> "$tmp" 2>/dev/null || {
            log_error "写入主配置 include 失败: $NFT_MAIN_CONFIG_FILE"
            return 1
        }
        mv "$tmp" "$NFT_MAIN_CONFIG_FILE" || {
            log_error "发布主配置 include 失败: $NFT_MAIN_CONFIG_FILE"
            return 1
        }
    fi
    if command -v systemctl >/dev/null 2>&1 &&
        ! systemctl is-enabled nftables.service >/dev/null 2>&1; then
        if systemctl enable nftables.service >/dev/null 2>&1; then
            log_info "已启用系统服务：nftables.service"
        else
            log_warning "无法启用 nftables.service，重启后规则可能丢失"
        fi
    fi
)

ensure_ipv4_forwarding_enabled() {
    local current tmp persistent_changed=0
    current="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf '0\n')"
    if ! grep -q 'net.ipv4.ip_forward=1' "$IPV4_FORWARD_SYSCTL_FILE" 2>/dev/null; then
        tmp="$(mktemp "${IPV4_FORWARD_SYSCTL_FILE}.XXXXXX")" || return 1
        printf 'net.ipv4.ip_forward=1\n' > "$tmp" || {
            rm -f "$tmp"
            return 1
        }
        chmod 644 "$tmp" 2>/dev/null || true
        mv "$tmp" "$IPV4_FORWARD_SYSCTL_FILE" || {
            rm -f "$tmp"
            log_error "无法持久化 IP 转发设置: $IPV4_FORWARD_SYSCTL_FILE"
            return 1
        }
        persistent_changed=1
    fi
    if [ "$current" != "1" ] && ! sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
        log_error "无法启用 net.ipv4.ip_forward=1，远程端口转发无法生效"
        return 1
    fi
    [ "$persistent_changed" = "0" ] || log_info "已持久化 IPv4 转发配置：$IPV4_FORWARD_SYSCTL_FILE"
    [ "$current" = "1" ] || log_info "已启用 IPv4 转发"
}

ipv4_forwarding_needs_update() {
    local current
    current="$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" || current="0"
    if [ "$current" = "1" ] &&
        grep -q 'net.ipv4.ip_forward=1' "$IPV4_FORWARD_SYSCTL_FILE" 2>/dev/null; then
        return 1
    fi
    return 0
}

get_config_value() {
    local key="$1" default="$2"
    if [ ! -f "$CONFIG_FILE" ]; then
        printf '%s\n' "$default"
        return 0
    fi
    awk -F= -v k="$key" -v d="$default" '$1==k { print $2; found=1; exit } END { if (!found) print d }' "$CONFIG_FILE"
}

normalize_ports() {
    printf '%s\n' "$1" | tr -d ' ' | tr ',' '\n' | awk 'NF>0' | sort -un | tr '\n' ',' | sed 's/,$//'
}

filter_ports() {
    local ports="$1" exclude="${2:-}" result="" port
    local -a port_arr
    IFS=',' read -ra port_arr <<< "$(normalize_ports "$ports")"
    for port in "${port_arr[@]}"; do
        validate_port "$port" || continue
        if [ -n "$exclude" ] && [[ ",$exclude," == *",$port,"* ]]; then
            continue
        fi
        result="${result}${result:+,}${port}"
    done
    printf '%s\n' "$result"
}

detect_ssh_ports() {
    local config ports
    command -v sshd >/dev/null 2>&1 || {
        printf '\n'
        return 0
    }
    config="$(sshd -T 2>/dev/null)" || {
        log_error "无法读取 SSH 生效配置，拒绝应用端口保护"
        return 1
    }
    ports="$(printf '%s\n' "$config" |
        awk '$1 == "port" && $2 ~ /^[0-9]+$/ && $2 >= 1 && $2 <= 65535 { print $2 }' |
        sort -un | tr '\n' ',' | sed 's/,$//')"
    if [ -z "$ports" ]; then
        log_error "SSH 生效配置未包含有效端口，拒绝应用端口保护"
        return 1
    fi
    printf '%s\n' "$ports"
}

parse_local_endpoint() {
    local endpoint="$1" addr="$1" port=""
    if [[ "$endpoint" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
        addr="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        addr="${endpoint%:*}"
        port="${endpoint##*:}"
    fi
    printf '%s|%s\n' "${addr%%\%*}" "$port"
}

detect_runtime_public_ports() {
    local listeners ports="" endpoint parsed addr port
    command -v ss >/dev/null 2>&1 || {
        log_error "缺少依赖命令：ss"
        return 1
    }
    listeners="$(ss -H -ltn 2>/dev/null)" || {
        log_error "无法检测监听端口，拒绝应用端口保护"
        return 1
    }
    while IFS= read -r endpoint; do
        [ -n "$endpoint" ] || continue
        parsed=$(parse_local_endpoint "$endpoint")
        IFS='|' read -r addr port <<< "$parsed"
        validate_port "$port" || continue
        [[ "$addr" == "::1" || "$addr" =~ ^127\. ]] && continue
        ports="${ports}${ports:+,}${port}"
    done < <(printf '%s\n' "$listeners" | awk '{ print $(NF - 1) }')
    normalize_ports "$ports"
}

get_forwarding_ports_from_file() {
    if [ ! -s "$1" ]; then
        printf '\n'
        return 0
    fi
    awk -F'|' \
        'NF >= 8 && $1 ~ /^[0-9]+$/ && ($2 == "local" || $6 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $1 }' \
        "$1" | sort -un | tr '\n' ',' | sed 's/,$//'
}

get_auto_allow_ports() {
    local state_file="${1:-$RULES_STATE_FILE}" ssh_ports forward_ports runtime_ports exclude_ports merged filtered port
    local -a ssh_ports_arr
    ssh_ports=$(detect_ssh_ports) || return 1
    forward_ports=$(get_forwarding_ports_from_file "$state_file")
    runtime_ports=$(detect_runtime_public_ports) || return 1
    exclude_ports="$DEFAULT_EXCLUDE_PORTS"
    [ -z "${FORWARDAWS_EXCLUDE_PORTS:-}" ] || exclude_ports="${exclude_ports},${FORWARDAWS_EXCLUDE_PORTS}"
    exclude_ports=$(filter_ports "$exclude_ports")
    merged=$(normalize_ports "${ssh_ports},${forward_ports},${runtime_ports}")
    filtered=$(filter_ports "$merged" "$exclude_ports")
    IFS=',' read -ra ssh_ports_arr <<< "$ssh_ports"
    for port in "${ssh_ports_arr[@]}"; do
        validate_port "$port" || continue
        if [[ ",$filtered," != *",$port,"* ]]; then
            filtered=$(normalize_ports "${filtered},${port}")
        fi
    done
    printf '%s\n' "$filtered"
}

parse_rule() {
    local rule_string="$1" src_port target dest_port snat_ip mss
    [[ "$rule_string" =~ ^[^:]+:[^:]+:[^:]+(:[^:]+(:[^:]+)?)?$ ]] || {
        log_error "规则格式错误: $rule_string"
        log_error "正确格式: 端口:目标(IPv4/域名/local):端口[:SNAT_IP[:MSS]]"
        return 1
    }
    IFS=':' read -r src_port target dest_port snat_ip mss <<< "$rule_string"
    if ! validate_port "$src_port"; then
        log_error "无效的源端口: $src_port"
        return 1
    fi
    if ! validate_port "$dest_port"; then
        log_error "无效的目标端口: $dest_port"
        return 1
    fi
    if [ -n "$snat_ip" ] && ! validate_ip_address "$snat_ip"; then
        log_error "无效的 SNAT IP: $snat_ip"
        return 1
    fi
    if [ -n "$mss" ] && [ "$mss" != "auto" ]; then
        if ! [[ "$mss" =~ ^[0-9]+$ ]] || [ "$mss" -lt 536 ] || [ "$mss" -gt 9000 ]; then
            log_error "无效的 MSS: $mss (必须为 auto 或 536-9000 之间的数字)"
            return 1
        fi
    fi

    case "$target" in
        local|localhost|127.0.0.1)
            if [ -n "$snat_ip$mss" ]; then
                log_error "本地转发不支持 SNAT/MSS 扩展字段: $rule_string"
                return 1
            fi
            PARSED_MODE="local"
            PARSED_TARGET="127.0.0.1"
            PARSED_TYPE="local"
            PARSED_IP="127.0.0.1"
            PARSED_STATUS="ok"
            ;;
        *)
            PARSED_MODE="remote"
            PARSED_TARGET="$target"
            if validate_ip_address "$target"; then
                PARSED_TYPE="ipv4"
                PARSED_IP="$target"
                PARSED_STATUS="ok"
            elif validate_domain_name "$target"; then
                PARSED_TYPE="domain"
                PARSED_IP=""
                PARSED_STATUS="pending"
            else
                log_error "无效的目标地址: $target"
                return 1
            fi
            ;;
    esac
    PARSED_SRC_PORT="$src_port"
    PARSED_DEST_PORT="$dest_port"
    PARSED_SNAT_IP="$snat_ip"
    PARSED_MSS="$mss"
}

make_state_line() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${9:-}" "${10:-}"
}

state_rule_status() {
    local file="$1" src_port="$2" mode="$3" target="$4" dest_port="$5" snat_ip="${6:-}" mss="${7:-}"
    if [ ! -s "$file" ]; then
        printf 'none\n'
        return 0
    fi
    awk -F'|' -v sp="$src_port" -v mode="$mode" -v target="$target" \
        -v dp="$dest_port" -v snat="$snat_ip" -v mss="$mss" '
        BEGIN { result="none" }
        NF>=8 && $1==sp {
            if ($2==mode && $3==target && $4==dp) {
                if ($9==snat && $10==mss) { result="exact"; exit }
                result="base"
            } else if (result=="none") {
                result="port_conflict"
            }
        }
        END { print result }
    ' "$file"
}

state_domain_count() {
    if [ ! -s "${1:-$RULES_STATE_FILE}" ]; then
        printf '0\n'
        return 0
    fi
    awk -F'|' 'NF>=8 && $5=="domain" { count++ } END { print count+0 }' "${1:-$RULES_STATE_FILE}"
}

state_has_remote_rules() {
    [ -s "$1" ] || return 1
    awk -F'|' '
        NF >= 8 && $2 == "remote" && $6 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

sync_providerdns_subscription() (
    local state_file="$1" domains_file
    if [ "$(state_domain_count "$state_file")" -eq 0 ]; then
        providerdns_unset_forwardaws
        return
    fi
    domains_file=$(mktemp /tmp/forwardaws-domains.XXXXXX) || return 1
    trap 'rm -f "$domains_file"' EXIT
    awk -F'|' 'NF>=8 && $5=="domain" { print $3 }' "$state_file" | sort -u > "$domains_file" || return 1
    providerdns_set_forwardaws "$domains_file"
)

filter_candidate_domain_cache() {
    local candidate="$1" next now src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss
    local record new_ip new_status next_ip next_status next_updated_at
    DOMAIN_RULES_DROPPED=0
    next=$(mktemp "${candidate}.XXXXXX") || return 1
    : > "$next"
    now=$(date +%s)
    while IFS='|' read -r src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss; do
        [ -n "$src_port$mode$target$dest_port" ] || continue
        if [ "$target_type" != "domain" ]; then
            make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" \
                "$resolved_ip" "$status" "$updated_at" "$snat_ip" "$mss" >> "$next"
            continue
        fi
        next_ip="$resolved_ip"
        next_status="$status"
        next_updated_at="$updated_at"
        if record=$(run_providerdns --cache "$target" 2>/dev/null); then
            IFS=$'\t' read -r _ new_ip new_status _ <<< "$record"
            if validate_ip_address "$new_ip"; then
                next_ip="$new_ip"
                next_status="$new_status"
            elif validate_ip_address "$resolved_ip"; then
                next_status="${new_status:-failed}"
                log_warning "域名 ${target} 当前解析失败，继续使用旧 IP：${resolved_ip}"
            else
                DOMAIN_RULES_DROPPED=$((DOMAIN_RULES_DROPPED + 1))
                log_warning "域名 ${target} 解析失败，已跳过该规则"
                continue
            fi
        elif validate_ip_address "$resolved_ip"; then
            next_status="cache_missing"
            log_warning "域名 ${target} 解析结果缺失，继续使用旧 IP：${resolved_ip}"
        else
            DOMAIN_RULES_DROPPED=$((DOMAIN_RULES_DROPPED + 1))
            log_warning "域名 ${target} 解析结果缺失，已跳过该规则"
            continue
        fi
        if [ "$next_ip" != "$resolved_ip" ] || [ "$next_status" != "$status" ]; then
            next_updated_at="$now"
        fi
        make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" \
            "$next_ip" "$next_status" "$next_updated_at" "$snat_ip" "$mss" >> "$next"
    done < "$candidate"
    mv "$next" "$candidate" || {
        rm -f "$next"
        return 1
    }
}

prepare_candidate_domains() {
    local candidate="$1"
    DOMAIN_RULES_DROPPED=0
    sync_providerdns_subscription "$candidate" || return 1
    [ "$(state_domain_count "$candidate")" -gt 0 ] || return 0
    providerdns_refresh || return 1
    filter_candidate_domain_cache "$candidate" || return 1
    [ "$DOMAIN_RULES_DROPPED" -eq 0 ] || sync_providerdns_subscription "$candidate"
}

render_ruleset() {
    local state_file="$1" protect_flag="$2" output_file="$3" allow_ports="${4:-}" protect_noping="${5:-0}"
    if [ "$protect_flag" = "1" ] && [ -z "$allow_ports" ]; then
        allow_ports=$(get_auto_allow_ports "$state_file") || return 1
        if [ -z "$allow_ports" ]; then
            log_error "保护端口列表为空，拒绝渲染保护链"
            return 1
        fi
    fi
    awk -F'|' -v nat="$NAT_TABLE_NAME" -v filter="$FILTER_TABLE_NAME" \
        -v protect="$protect_flag" -v allow="$allow_ports" -v noping="$protect_noping" '
        function rule(s) { return "        " s "\n" }
        NF>=8 && $6 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
            if ($2=="remote") {
                pre=pre rule("tcp dport " $1 " dnat to " $6 ":" $4) rule("udp dport " $1 " dnat to " $6 ":" $4)
                fwd = fwd rule("ct status dnat ip daddr " $6 " tcp dport " $4 " accept") \
                    rule("ct status dnat ip daddr " $6 " udp dport " $4 " accept")
                if ($9!="") {
                    post = post rule("ip daddr " $6 " tcp dport " $4 " snat to " $9) \
                        rule("ip daddr " $6 " udp dport " $4 " snat to " $9)
                } else {
                    post = post rule("ct status dnat ip daddr " $6 " tcp dport " $4 " masquerade") \
                        rule("ct status dnat ip daddr " $6 " udp dport " $4 " masquerade")
                }
                if ($10!="") {
                    value=($10=="auto" ? "rt mtu" : $10)
                    mss=mss rule("ip daddr " $6 " tcp dport " $4 " tcp flags syn tcp option maxseg size set " value)
                }
            } else if ($2=="local") {
                out=out rule("tcp dport " $1 " dnat to " $6 ":" $4) rule("udp dport " $1 " dnat to " $6 ":" $4)
            }
        }
        END {
            print "#!/usr/sbin/nft -f"
            print "# forwardaws generated by nftables.sh"
            print "\ntable ip " nat "\ndelete table ip " nat "\ntable inet " filter "\ndelete table inet " filter
            print "\ntable ip " nat " {\n    chain prerouting {\n" \
                "        type nat hook prerouting priority -100; policy accept;"
            printf "%s", pre
            print "    }\n\n    chain output {\n        type nat hook output priority -100; policy accept;"
            printf "%s", out
            print "    }\n\n    chain postrouting {\n        type nat hook postrouting priority 100; policy accept;"
            printf "%s", post
            print "    }\n}"
            print "\ntable inet " filter " {"
            if (mss!="") {
                print "    chain forward_mss {\n        type filter hook forward priority -150; policy accept;"
                printf "%s", mss
                print "    }"
            }
            if (protect=="1") {
                print "    chain input {\n        type filter hook input priority 0; policy drop;"
                print "        iifname \"lo\" accept\n        ct state established,related accept"
                if (noping!="0") {
                    if (noping!="1") {
                        print "        ip saddr { " noping " } ip protocol icmp icmp type echo-request accept"
                    }
                    print "        ip protocol icmp icmp type echo-request drop"
                    print "        ip6 nexthdr icmpv6 icmpv6 type echo-request drop"
                }
                print "        ip protocol icmp accept\n        ip6 nexthdr icmpv6 accept"
                print "        ip6 saddr fe80::/10 udp sport 547 udp dport 546 limit rate 20/second accept"
                print "        tcp dport { " allow " } accept\n        udp dport { " allow " } accept\n    }"
            }
            if (fwd!="") {
                print "    chain forward {\n        type filter hook forward priority 0; policy accept;\n" \
                    "        ct state established,related accept;"
                printf "%s", fwd
                print "    }"
            }
            print "}"
        }
    ' "$state_file" > "$output_file"
}

run_nft_file() {
    local check_flag="$1" label="$2" file="$3" desc="$4" output
    if [ -n "$check_flag" ]; then
        output=$(nft "$check_flag" -f "$file" 2>&1)
    else
        output=$(nft -f "$file" 2>&1)
    fi
    [ $? -eq 0 ] && return 0
    log_error "nft ${label}失败: $desc"
    [ -n "$output" ] && log_error "$output"
    return 1
}

apply_candidate_state() (
    local candidate_state="$1" protect_flag="$2" desc="$3" protect_ports="${4:-}" protect_noping="${5:-}"
    local work_dir nft_tmp state_tmp config_tmp
    local rules_changed=0 state_changed=0 config_changed=0 include_missing=0
    local live_missing=0 forwarding_needs_update=0
    [ -n "$protect_noping" ] || protect_noping="$(get_config_value "PROTECT_NOPING" "0")"
    [ "$protect_flag" = "1" ] || protect_noping=0
    if [ "$protect_noping" != "0" ] && ! validate_noping_spec "$protect_noping"; then
        log_error "noping 状态无效: $protect_noping"
        return 1
    fi
    work_dir="$(mktemp -d "${STATE_DIR}/.apply.XXXXXX")" || {
        log_error "无法创建候选目录"
        return 1
    }
    trap 'rm -rf "$work_dir"' EXIT
    nft_tmp="${work_dir}/forwardaws.nft"
    state_tmp="${work_dir}/rules.db"
    config_tmp="${work_dir}/config.env"
    render_ruleset "$candidate_state" "$protect_flag" "$nft_tmp" "$protect_ports" "$protect_noping" || return 1
    if ! cp "$candidate_state" "$state_tmp"; then
        log_error "写入状态临时文件失败"
        return 1
    fi
    if ! printf 'PROTECTION_ENABLED=%s\nPROTECT_NOPING=%s\n' \
        "$protect_flag" "$protect_noping" > "$config_tmp"; then
        log_error "写入配置临时文件失败"
        return 1
    fi
    cmp -s "$nft_tmp" "$FORWARDAWS_RULES_FILE" || rules_changed=1
    cmp -s "$state_tmp" "$RULES_STATE_FILE" || state_changed=1
    cmp -s "$config_tmp" "$CONFIG_FILE" || config_changed=1
    nft_main_config_has_forwardaws_include || include_missing=1
    if [ "$rules_changed" -eq 0 ]; then
        if ! nft list table ip "$NAT_TABLE_NAME" >/dev/null 2>&1 ||
            ! nft list table inet "$FILTER_TABLE_NAME" >/dev/null 2>&1; then
            live_missing=1
        fi
    fi
    if state_has_remote_rules "$candidate_state" && ipv4_forwarding_needs_update; then
        forwarding_needs_update=1
    fi

    if [ "$rules_changed$state_changed$config_changed$include_missing$live_missing$forwarding_needs_update" \
        = "000000" ]; then
        return 0
    fi
    if [ "$rules_changed" -eq 1 ] || [ "$live_missing" -eq 1 ]; then
        if ! run_nft_file "-c" "预检" "$nft_tmp" "$desc" ||
            ! run_nft_file "" "应用" "$nft_tmp" "$desc" ||
            ! nft list table ip "$NAT_TABLE_NAME" >/dev/null 2>&1 ||
            ! nft list table inet "$FILTER_TABLE_NAME" >/dev/null 2>&1; then
            log_error "nftables 最终状态验证失败，请检查当前规则"
            return 1
        fi
    fi
    if [ "$rules_changed" -eq 1 ]; then
        mv "$nft_tmp" "$FORWARDAWS_RULES_FILE" || {
            log_error "运行规则已应用，但持久规则发布失败：$FORWARDAWS_RULES_FILE"
            return 1
        }
        chmod 600 "$FORWARDAWS_RULES_FILE" 2>/dev/null || true
    fi
    if [ "$state_changed" -eq 1 ] && ! mv "$state_tmp" "$RULES_STATE_FILE"; then
        log_error "运行规则已应用，但状态文件发布失败：$RULES_STATE_FILE"
        return 1
    fi
    if [ "$config_changed" -eq 1 ] && ! mv "$config_tmp" "$CONFIG_FILE"; then
        log_error "运行规则已应用，但配置文件发布失败：$CONFIG_FILE"
        return 1
    fi
    if [ "$include_missing" -eq 1 ] || [ "$rules_changed" -eq 1 ]; then
        ensure_nft_main_config_include || return 1
    fi
    if [ "$forwarding_needs_update" -eq 1 ]; then
        ensure_ipv4_forwarding_enabled || return 1
    fi
)

write_systemd_unit_if_changed() {
    local target_file="$1" tmp_file
    tmp_file="$(mktemp "${target_file}.XXXXXX")" || {
        log_error "创建 systemd unit 临时文件失败: $target_file"
        return 1
    }
    if ! cat > "$tmp_file"; then
        rm -f "$tmp_file"
        log_error "生成 systemd unit 失败: $target_file"
        return 1
    fi
    if cmp -s "$tmp_file" "$target_file"; then
        rm -f "$tmp_file"
        return 0
    fi
    mv "$tmp_file" "$target_file" || {
        rm -f "$tmp_file"
        log_error "写入 systemd unit 失败: $target_file"
        return 1
    }
    chmod 644 "$target_file" 2>/dev/null || true
    SYSTEMD_UNITS_CHANGED=1
}

install_protection_units() {
    local script_path
    local service_file="${SYSTEMD_SYSTEM_DIR}/${PROTECT_SERVICE_NAME}"
    local timer_file="${SYSTEMD_SYSTEM_DIR}/${PROTECT_TIMER_NAME}"
    command -v systemctl >/dev/null 2>&1 || return 1
    script_path=$(get_script_absolute_path)
    [ -n "$script_path" ] || {
        log_error "无法确定脚本绝对路径，systemd 定时器安装失败"
        return 1
    }

    write_systemd_unit_if_changed "$service_file" << EOF || return 1
[Unit]
Description=ForwardAWS protection sync service
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=FORWARDAWS_QUIET=1
Environment=FORWARDAWS_LOCK_WAIT=10
ExecStart=/bin/bash "${script_path}" --protect sync
EOF
    write_systemd_unit_if_changed "$timer_file" << EOF
[Unit]
Description=Run ForwardAWS protection sync every 10 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=10min
AccuracySec=5s
Unit=${PROTECT_SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF
}

has_systemctl() {
    command -v systemctl >/dev/null 2>&1
}

reconcile_protection_timer() {
    local protect_flag
    protect_flag="$(get_config_value "PROTECTION_ENABLED" "0")"
    if [ "$protect_flag" = "0" ]; then
        has_systemctl || return 0
        if systemctl is-enabled --quiet "$PROTECT_TIMER_NAME" 2>/dev/null ||
            systemctl is-active --quiet "$PROTECT_TIMER_NAME" 2>/dev/null; then
            if ! systemctl disable --now --no-reload "$PROTECT_TIMER_NAME" >/dev/null 2>&1; then
                log_error "停用保护端口自动同步失败"
                return 1
            fi
            log_info "保护端口自动同步已停用"
        fi
        return 0
    fi
    if ! has_systemctl; then
        log_error "未检测到 systemctl，无法启用保护端口自动同步"
        return 1
    fi
    SYSTEMD_UNITS_CHANGED=0
    install_protection_units || return 1
    if [ "$SYSTEMD_UNITS_CHANGED" = "1" ]; then
        if ! systemctl daemon-reload >/dev/null 2>&1; then
            log_error "systemd daemon-reload 失败，请检查 systemd 状态"
            return 1
        fi
    fi
    if systemctl is-enabled --quiet "$PROTECT_TIMER_NAME" 2>/dev/null &&
        systemctl is-active --quiet "$PROTECT_TIMER_NAME" 2>/dev/null; then
        return 0
    fi
    if ! systemctl enable --now --no-reload "$PROTECT_TIMER_NAME" >/dev/null 2>&1; then
        log_error "启用保护端口自动同步失败，请检查 systemd 状态"
        return 1
    fi
    log_info "保护端口自动同步已启用"
}

remove_nft_main_config_include_if_unused() (
    local tmp_file other_file keep_include=0
    [ -f "$NFT_MAIN_CONFIG_FILE" ] || return 0
    grep -Fqx "$NFT_INCLUDE_MARKER" "$NFT_MAIN_CONFIG_FILE" || return 0
    other_file=$(find "$NFT_INCLUDE_DIR" -maxdepth 1 -name '*.nft' ! -name 'forwardaws.nft' -print -quit 2>/dev/null)
    [ -z "$other_file" ] || keep_include=1

    tmp_file=$(mktemp "${NFT_MAIN_CONFIG_FILE}.XXXXXX") || return 1
    trap 'rm -f "$tmp_file"' EXIT
    awk -v marker="$NFT_INCLUDE_MARKER" -v keep="$keep_include" '
        $0 == marker {
            owned = 1
            next
        }
        owned && $0 ~ /^[[:space:]]*include[[:space:]]+"?\/etc\/nftables[.]d\/(forwardaws|[*])[.]nft"?[[:space:]]*$/ {
            owned = 0
            if (keep == 1) print
            next
        }
        { owned = 0; print }
    ' "$NFT_MAIN_CONFIG_FILE" > "$tmp_file" || {
        log_error "清理 nftables 主配置 include 失败: $NFT_MAIN_CONFIG_FILE"
        return 1
    }
    if ! mv "$tmp_file" "$NFT_MAIN_CONFIG_FILE"; then
        log_error "写回 nftables 主配置失败: $NFT_MAIN_CONFIG_FILE"
        return 1
    fi
)

remove_active_nft_tables() (
    local nft_tmp
    command -v nft >/dev/null 2>&1 || {
        log_warning "未检测到 nft，跳过运行时规则清理"
        return 0
    }
    nft_tmp="$(mktemp /tmp/forwardaws-cleanup.XXXXXX)" || return 1
    trap 'rm -f "$nft_tmp"' EXIT
    cat > "$nft_tmp" << EOF
table ip ${NAT_TABLE_NAME}
delete table ip ${NAT_TABLE_NAME}
table inet ${FILTER_TABLE_NAME}
delete table inet ${FILTER_TABLE_NAME}
table ip forwardaws
delete table ip forwardaws
table ip6 forwardaws
delete table ip6 forwardaws
EOF
    run_nft_file "" "清理" "$nft_tmp" "卸载 forwardaws nftables 表" || return 1
    log_info "已删除 ForwardAWS 运行规则"
)

forwardaws_resources_exist() {
    if [ -e "$FORWARDAWS_RULES_FILE" ] || [ -d "$STATE_DIR" ] || [ -e "$IPV4_FORWARD_SYSCTL_FILE" ] ||
        [ -e "${SYSTEMD_SYSTEM_DIR}/${PROTECT_SERVICE_NAME}" ] ||
        [ -e "${SYSTEMD_SYSTEM_DIR}/${PROTECT_TIMER_NAME}" ]; then
        return 0
    fi
    grep -Fqx "$NFT_INCLUDE_MARKER" "$NFT_MAIN_CONFIG_FILE" 2>/dev/null && return 0
    if has_systemctl; then
        if systemctl is-enabled --quiet "$PROTECT_TIMER_NAME" 2>/dev/null ||
            systemctl is-active --quiet "$PROTECT_TIMER_NAME" 2>/dev/null ||
            systemctl is-active --quiet "$PROTECT_SERVICE_NAME" 2>/dev/null; then
            return 0
        fi
    fi
    command -v nft >/dev/null 2>&1 || return 1
    nft list table ip "$NAT_TABLE_NAME" >/dev/null 2>&1 ||
        nft list table inet "$FILTER_TABLE_NAME" >/dev/null 2>&1 ||
        nft list table ip forwardaws >/dev/null 2>&1 ||
        nft list table ip6 forwardaws >/dev/null 2>&1
}

remove_systemd_units() {
    local path units_removed=0

    if has_systemctl; then
        if systemctl is-enabled --quiet "$PROTECT_TIMER_NAME" 2>/dev/null ||
            systemctl is-active --quiet "$PROTECT_TIMER_NAME" 2>/dev/null; then
            if ! systemctl disable --now --no-reload "$PROTECT_TIMER_NAME" >/dev/null 2>&1; then
                log_error "无法停用定时器：${PROTECT_TIMER_NAME}"
                return 1
            fi
            log_info "已停用定时器：${PROTECT_TIMER_NAME}"
        fi
        if systemctl is-active --quiet "$PROTECT_SERVICE_NAME" 2>/dev/null; then
            if ! systemctl stop "$PROTECT_SERVICE_NAME" >/dev/null 2>&1; then
                log_error "无法停止系统服务：${PROTECT_SERVICE_NAME}"
                return 1
            fi
            log_info "已停止系统服务：${PROTECT_SERVICE_NAME}"
        fi
        systemctl reset-failed "$PROTECT_TIMER_NAME" "$PROTECT_SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    for path in \
        "${SYSTEMD_SYSTEM_DIR}/${PROTECT_SERVICE_NAME}" \
        "${SYSTEMD_SYSTEM_DIR}/${PROTECT_TIMER_NAME}" \
        "${SYSTEMD_SYSTEM_DIR}/timers.target.wants/${PROTECT_TIMER_NAME}"; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        if ! rm -f "$path"; then
            log_error "删除 systemd 单元失败：$path"
            return 1
        fi
        units_removed=1
    done
    [ "$units_removed" -eq 0 ] || log_info "已删除 ForwardAWS systemd 单元"

    providerdns_unset_forwardaws || return 1

    if [ "$units_removed" -eq 1 ] && has_systemctl; then
        if ! systemctl daemon-reload >/dev/null 2>&1; then
            log_error "systemd 配置刷新失败"
            return 1
        fi
    fi
}

uninstall_forwardaws() {
    if ! forwardaws_resources_exist; then
        providerdns_unset_forwardaws || return 1
        log_info "nftables.sh 产物已不存在，无需卸载"
        return 0
    fi

    remove_systemd_units || return 1
    remove_active_nft_tables || return 1
    if ! rm -rf "$FORWARDAWS_RULES_FILE" "$STATE_DIR" "$IPV4_FORWARD_SYSCTL_FILE" "$GLOBAL_LOCK_FILE"; then
        log_error "删除 ForwardAWS 持久文件失败"
        return 1
    fi
    remove_nft_main_config_include_if_unused || return 1
    rmdir "$NFT_INCLUDE_DIR" 2>/dev/null || true

    log_info "ForwardAWS 防火墙配置已卸载"
}

append_rule_to_state() {
    local candidate="$1" rule="$2" now="$3" duplicate_mode="$4" status
    parse_rule "$rule" || return 1
    status=$(state_rule_status "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" \
        "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_SNAT_IP" "$PARSED_MSS")
    case "$status" in
        exact)
            if [ "$duplicate_mode" = "skip" ]; then
                log_warning "规则已存在，跳过：$rule"
                return 2
            fi
            log_error "重复规则：$rule"
            return 1
            ;;
        base|port_conflict)
            log_error "规则冲突：$rule"
            return 1
            ;;
    esac
    make_state_line \
        "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT" \
        "$PARSED_TYPE" "$PARSED_IP" "$PARSED_STATUS" "$now" \
        "$PARSED_SNAT_IP" "$PARSED_MSS" >> "$candidate"
}

remove_rule_from_state() (
    local candidate="$1" rule="$2" next_candidate status
    parse_rule "$rule" || return 1
    status=$(state_rule_status "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" \
        "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_SNAT_IP" "$PARSED_MSS")
    if [ "$status" != "exact" ] && [ "$status" != "base" ]; then
        log_warning "规则不存在，跳过：$rule"
        return 2
    fi
    next_candidate=$(mktemp "${candidate}.XXXXXX") || return 3
    trap 'rm -f "$next_candidate"' EXIT
    awk -F'|' -v sp="$PARSED_SRC_PORT" -v mode="$PARSED_MODE" -v target="$PARSED_TARGET" -v dp="$PARSED_DEST_PORT" \
        'NF>=8 && !($1==sp && $2==mode && $3==target && $4==dp) { print $0 }' \
        "$candidate" > "$next_candidate" || return 3
    mv "$next_candidate" "$candidate" || return 3
)

rule_batch() (
    local action="$1" protect_noping="$2" candidate now rule rc operation duplicate_mode
    local protect_flag=1 success=0 skipped=0 failed=0
    shift 2
    if [ $# -eq 0 ]; then
        log_error "未提供任何规则"
        return 1
    fi
    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    trap 'rm -f "$candidate"' EXIT
    case "$action" in
        add)
            operation="添加"
            duplicate_mode="skip"
            ;;
        delete)
            operation="删除"
            protect_flag="$(get_config_value "PROTECTION_ENABLED" "0")"
            ;;
        replace)
            operation="替换"
            duplicate_mode="fail"
            ;;
    esac
    if [ "$action" = "replace" ]; then
        : > "$candidate"
    else
        cp "$RULES_STATE_FILE" "$candidate" || return 1
    fi
    now="$(date +%s)"
    for rule in "$@"; do
        if [ "$action" = "delete" ]; then
            remove_rule_from_state "$candidate" "$rule"
            rc=$?
        else
            append_rule_to_state "$candidate" "$rule" "$now" "$duplicate_mode"
            rc=$?
        fi
        case "$rc" in
            0)
                success=$((success + 1))
                ;;
            2)
                skipped=$((skipped + 1))
                ;;
            3)
                return 1
                ;;
            *)
                failed=$((failed + 1))
                ;;
        esac
    done
    if [ "$action" = "replace" ] && [ "$failed" -gt 0 ]; then
        log_error "替换前校验失败，已取消所有变更"
        return 1
    fi
    if [ "$success" -eq 0 ]; then
        if [ "$failed" -eq 0 ] && [ -n "$protect_noping" ] && \
            [ "$(get_config_value "PROTECT_NOPING" "0")" != "$protect_noping" ]; then
            apply_candidate_state "$candidate" "$protect_flag" \
                "${operation}转发规则" "" "$protect_noping" || return 1
            reconcile_protection_timer || return 1
            [ "$action" = "delete" ] || show_protection_status
        fi
        log_warning "没有规则变更：跳过 ${skipped} 条，失败 ${failed} 条"
        [ "$failed" -eq 0 ]
        return
    fi

    if [ "$(state_domain_count "$candidate")" -gt 0 ]; then
        log_info "检测到域名规则，正在刷新解析"
    fi
    prepare_candidate_domains "$candidate" || {
        sync_providerdns_subscription "$RULES_STATE_FILE" ||
            log_warning "Provider DNS 订阅回滚失败，请手动执行 --ddns sync"
        return 1
    }
    if [ "$DOMAIN_RULES_DROPPED" -gt 0 ]; then
        skipped=$((skipped + DOMAIN_RULES_DROPPED))
        success=$((success - DOMAIN_RULES_DROPPED))
        if [ "$success" -lt 0 ]; then
            success=0
        fi
    fi
    if [ "$action" != "delete" ] && [ "$success" -eq 0 ]; then
        log_warning "没有规则变更：跳过 ${skipped} 条，失败 ${failed} 条"
        if [ "$action" = "replace" ] && [ "$(state_domain_count "$RULES_STATE_FILE")" -gt 0 ]; then
            sync_providerdns_subscription "$RULES_STATE_FILE" ||
                log_warning "Provider DNS 订阅回滚失败，请手动执行 --ddns sync"
        fi
        return 0
    fi
    apply_candidate_state "$candidate" "$protect_flag" "${operation}转发规则" "" "$protect_noping" || {
        sync_providerdns_subscription "$RULES_STATE_FILE" ||
            log_warning "Provider DNS 订阅回滚失败，请手动执行 --ddns sync"
        return 1
    }
    log_info "${operation}完成：成功 ${success}，跳过 ${skipped}，失败 ${failed}"
    reconcile_protection_timer || return 1
    if [ "$action" != "delete" ]; then
        show_protection_status || return 1
    fi
    [ "$failed" -eq 0 ]
)

apply_ddns_cache() (
    local candidate total_domains
    total_domains="$(state_domain_count "$RULES_STATE_FILE")"
    if [ "$total_domains" -eq 0 ]; then
        log_info "未配置 DDNS 域名规则，无需同步"
        sync_providerdns_subscription "$RULES_STATE_FILE" || return 1
        reconcile_protection_timer
        return $?
    fi
    require_providerdns || return 1
    candidate="$(mktemp /tmp/forwardaws-state.XXXXXX)" || return 1
    trap 'rm -f "$candidate"' EXIT
    cp "$RULES_STATE_FILE" "$candidate" || return 1
    log_info "正在同步 DDNS 缓存（${total_domains} 条域名规则）"
    filter_candidate_domain_cache "$candidate" || return 1
    if [ "$DOMAIN_RULES_DROPPED" -gt 0 ]; then
        sync_providerdns_subscription "$candidate" || return 1
    fi
    apply_candidate_state "$candidate" "$(get_config_value "PROTECTION_ENABLED" "0")" "DDNS 同步" || {
        [ "$DOMAIN_RULES_DROPPED" -eq 0 ] || sync_providerdns_subscription "$RULES_STATE_FILE" ||
            log_warning "Provider DNS 订阅回滚失败，请手动执行 --ddns sync"
        return 1
    }
    reconcile_protection_timer || return 1
    log_info "DDNS 同步完成：${total_domains} 条域名规则"
)

sync_ddns_rules() {
    sync_providerdns_subscription "$RULES_STATE_FILE" || return 1
    if [ "$(state_domain_count "$RULES_STATE_FILE")" -gt 0 ]; then
        providerdns_refresh || return 1
    fi
    apply_ddns_cache
}

apply_protection_state() (
    local protect_flag="$1" desc="$2" success_msg="$3" protect_noping="${4:-}" reset_rules="${5:-0}"
    local candidate current_ports=""
    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    trap 'rm -f "$candidate"' EXIT
    if [ "$reset_rules" = "1" ]; then
        : > "$candidate"
    else
        cp "$RULES_STATE_FILE" "$candidate" || return 1
    fi
    [ -n "$protect_noping" ] || protect_noping=$(get_config_value "PROTECT_NOPING" "0")
    [ "$protect_flag" = "1" ] || protect_noping=0
    if [ "$protect_flag" = "1" ]; then
        current_ports=$(get_auto_allow_ports "$candidate") || return 1
    fi
    apply_candidate_state "$candidate" "$protect_flag" "$desc" "$current_ports" "$protect_noping" || return 1
    [ "$reset_rules" != "1" ] || sync_providerdns_subscription "$RULES_STATE_FILE" || return 1
    reconcile_protection_timer || return 1
    if [ "$protect_flag" = "1" ]; then
        log_info "${success_msg}: $current_ports"
    else
        log_info "$success_msg"
    fi
)

sync_protection_ports() {
    [ "$(get_config_value "PROTECTION_ENABLED" "0")" = "1" ] || {
        log_info "保护模式未开启，无需同步"
        return 0
    }
    apply_protection_state 1 "同步端口保护" "保护端口同步完成"
}

show_protection_status() {
    local protect_flag protect_noping auto_ports
    protect_flag=$(get_config_value "PROTECTION_ENABLED" "0")
    protect_noping=$(get_config_value "PROTECT_NOPING" "0")
    printf '%s\n' '端口保护状态'
    if [ "$protect_flag" = "1" ]; then
        auto_ports=$(get_auto_allow_ports "$RULES_STATE_FILE") || return 1
        printf '保护状态：已开启\n'
        printf '当前放行端口：%s\n' "$auto_ports"
        case "$protect_noping" in
            0)
                printf 'Ping：允许\n'
                ;;
            1)
                printf 'Ping：已禁止\n'
                ;;
            *)
                printf 'Ping：仅允许 %s\n' "$protect_noping"
                ;;
        esac
    else
        printf '保护状态：未开启\n'
    fi
    if ! has_systemctl; then
        printf '自动同步：systemctl 不可用\n'
    elif systemctl is-active --quiet "$PROTECT_TIMER_NAME"; then
        printf '自动同步：已启用\n'
    else
        printf '自动同步：未启用\n'
    fi
}

show_ddns_rules() {
    local count=1 domain resolved_ip status updated_at refs
    [ "$(state_domain_count "$RULES_STATE_FILE")" -gt 0 ] || {
        log_warning "未找到 DDNS 域名规则"
        return 0
    }
    printf '%s\n' 'DDNS 域名规则状态'
    while IFS='|' read -r domain resolved_ip status updated_at refs; do
        printf '%s) 域名：%s 当前 IP：%s 状态：%s 更新时间：%s 转发：%s\n' \
            "$count" "$domain" "${resolved_ip:-未解析}" "${status:-unknown}" \
            "$(format_epoch_time "$updated_at")" "$refs"
        count=$((count + 1))
    done < <(awk -F'|' '
        NF>=8 && $5=="domain" {
            domain=$3
            if (!(domain in seen)) {
                seen[domain]=1
                order[++count]=domain
                ip[domain]=$6
                status[domain]=$7
                updated[domain]=$8
            } else if ($8 > updated[domain]) {
                updated[domain]=$8
                ip[domain]=$6
                status[domain]=$7
            }
            ref=$1 "->" $4
            refs[domain]=(refs[domain] ? refs[domain] "," ref : ref)
        }
        END {
            for (i=1; i<=count; i++) {
                domain=order[i]
                print domain "|" ip[domain] "|" status[domain] "|" updated[domain] "|" refs[domain]
            }
        }
    ' "$RULES_STATE_FILE")
}

display_rules() {
    local count=1 src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss extra
    [ -s "$RULES_STATE_FILE" ] || {
        log_warning "未找到转发规则"
        return 0
    }
    printf '%s\n' '端口转发规则'
    while IFS='|' read -r src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss; do
        [ -n "$src_port$mode$target$dest_port" ] || continue
        extra=""
        if [ -n "$snat_ip" ]; then
            extra=" SNAT: ${snat_ip}"
        fi
        if [ -n "$mss" ]; then
            extra="${extra} MSS: ${mss}"
        fi
        if [ "$mode" = "local" ]; then
            printf '%s) [本地] 端口：%s -> %s:%s (TCP+UDP)\n' "$count" "$src_port" "$target" "$dest_port"
        elif [ "$target_type" = "domain" ]; then
            printf '%s) 端口：%s -> 域名：%s:%s 当前 IP：%s 状态：%s%s\n' \
                "$count" "$src_port" "$target" "$dest_port" "${resolved_ip:-未解析}" "${status:-unknown}" "$extra"
        else
            printf '%s) 端口：%s -> 目标：%s:%s (TCP+UDP)%s\n' \
                "$count" "$src_port" "$target" "$dest_port" "$extra"
        fi
        count=$((count + 1))
    done < "$RULES_STATE_FILE"
    printf '\n'
    show_protection_status
}

show_help() {
    cat << EOF
用法:
  $0 --help
  $0 --list
  $0 --add [noping[=IPv4,...]] <规则1> [规则2 ...]
  $0 --delete <规则1> [规则2 ...]
  $0 --replace [noping[=IPv4,...]] <规则1> [规则2 ...]
  $0 --ddns sync
  $0 --ddns apply
  $0 --ddns list
  $0 --protect on [noping[=IPv4,...]]
  $0 --protect only [noping[=IPv4,...]]
  $0 --protect off
  $0 --protect status
  $0 --protect sync
  $0 --uninstall|-u

规则格式:
  <源端口>:<目标(IPv4/域名/local)>:<目标端口>[:SNAT_IP[:MSS]]
EOF
}

run_mutation() {
    local desc="$1"
    shift
    acquire_global_lock || return 1
    log_info "$desc"
    "$@"
}

parse_noping_arg() {
    local arg="$1" value
    case "$arg" in
        noping)
            printf '1\n'
            ;;
        noping=*)
            value="${arg#noping=}"
            if ! validate_noping_spec "$value"; then
                log_error "noping 白名单格式无效: $value"
                return 1
            fi
            printf '%s\n' "$value"
            ;;
        *)
            log_error "未知的 noping 参数: $arg"
            return 1
            ;;
    esac
}

run_rule_batch_command() {
    local action="$1" protect_noping=""
    shift
    case "${1:-}" in
        noping|noping=*)
            if [ "$action" = "delete" ]; then
                log_error "删除命令不支持 noping 参数"
                return 1
            fi
            protect_noping="$(parse_noping_arg "$1")" || return 1
            shift
            ;;
    esac
    if [ $# -eq 0 ]; then
        log_error "未提供任何规则"
        show_help
        return 1
    fi
    ensure_for_write || return 1
    run_mutation "正在处理 $# 条转发规则" rule_batch "$action" "$protect_noping" "$@"
}

run_protection_enable_command() {
    local mode="$1" protect_noping=0 desc success reset_rules=0
    shift
    if [ $# -gt 1 ]; then
        log_error "保护模式 ${mode} 不支持额外参数: $*"
        return 1
    fi
    if [ $# -eq 1 ]; then
        protect_noping="$(parse_noping_arg "$1")" || return 1
    fi
    case "$mode" in
        on)
            desc="正在开启端口保护模式..."
            success="端口保护已开启，开放端口"
            ;;
        only)
            desc="正在切换纯保护模式..."
            success="纯保护模式已开启，开放端口"
            reset_rules=1
            ;;
    esac
    ensure_for_write || return 1
    run_mutation "$desc" apply_protection_state \
        1 "$desc" "$success" "$protect_noping" "$reset_rules" || return 1
    show_protection_status
}

ensure_for_write() {
    require_root || return 1
    ensure_dependencies || return 1
    mkdir -p "$STATE_DIR" "$NFT_INCLUDE_DIR" || return 1
    [ -f "$RULES_STATE_FILE" ] || : > "$RULES_STATE_FILE"
}

require_arg_count() {
    local expected="$1" message="$2"
    shift 2
    [ "$#" -eq "$expected" ] && return 0
    log_error "$message"
    return 1
}

main() {
    local protect_mode
    if [ $# -eq 0 ]; then
        log_error "请使用参数模式执行，例如: $0 --help"
        show_help
        return 1
    fi
    case "$1" in
        --help|-h)
            show_help
            ;;
        --list|-l)
            display_rules
            ;;
        --add|-a)
            shift
            run_rule_batch_command add "$@"
            ;;
        --delete|-d)
            shift
            run_rule_batch_command delete "$@"
            ;;
        --replace|-r)
            shift
            run_rule_batch_command replace "$@"
            ;;
        --ddns)
            shift
            require_arg_count 1 "DDNS 命令需要且仅需要一个模式参数" "$@" || return 1
            case "$1" in
                sync)
                    ensure_for_write || return 1
                    run_mutation "开始执行 DDNS 同步..." sync_ddns_rules
                    ;;
                apply)
                    ensure_for_write || return 1
                    run_mutation "正在应用 DDNS 缓存..." apply_ddns_cache
                    ;;
                list)
                    show_ddns_rules
                    ;;
                run)
                    require_root || return 1
                    require_providerdns || return 1
                    run_providerdns --refresh hooks
                    ;;
                *)
                    log_error "未知的 DDNS 模式参数: $1"
                    return 1
                    ;;
            esac
            ;;
        --uninstall|--unistall|-u)
            require_root || return 1
            if ! command -v flock >/dev/null 2>&1; then
                log_error "缺少依赖命令：flock"
                return 1
            fi
            run_mutation "正在卸载 ForwardAWS 防火墙配置" uninstall_forwardaws
            ;;
        --protect|-p)
            shift
            if [ $# -eq 0 ]; then
                log_error "未提供保护模式参数"
                show_help
                return 1
            fi
            protect_mode="$1"
            shift
            case "$protect_mode" in
                on|only)
                    run_protection_enable_command "$protect_mode" "$@"
                    ;;
                off)
                    require_arg_count 0 "保护模式 off 不支持额外参数: $*" "$@" || return 1
                    ensure_for_write || return 1
                    run_mutation "正在关闭端口保护模式..." apply_protection_state \
                        0 "关闭端口保护" "端口保护已关闭" || return 1
                    show_protection_status
                    ;;
                status)
                    require_arg_count 0 "保护模式 status 不支持额外参数: $*" "$@" || return 1
                    show_protection_status
                    ;;
                sync)
                    require_arg_count 0 "保护模式 sync 不支持额外参数: $*" "$@" || return 1
                    ensure_for_write || return 1
                    run_mutation "正在同步端口保护..." sync_protection_ports
                    ;;
                *)
                    log_error "未知的保护模式参数: $protect_mode"
                    return 1
                    ;;
            esac
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            return 1
            ;;
    esac
}

main "$@"
