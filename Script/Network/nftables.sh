#!/bin/bash

# ============================================================================
# NFTables 端口转发与保护管理工具
# 架构：状态文件是唯一真相源，每次变更全量渲染 nft ruleset 并原子应用
# 运行环境：Debian/Ubuntu，依赖 bash、nftables、util-linux、procfs
# ============================================================================

set -o pipefail

readonly NAT_TABLE_NAME="forwardaws_nat"
readonly FILTER_TABLE_NAME="forwardaws_filter"
readonly NFT_MAIN_CONFIG_FILE="/etc/nftables.conf"
readonly NFT_INCLUDE_DIR="/etc/nftables.d"
readonly FORWARDAWS_RULES_FILE="${NFT_INCLUDE_DIR}/forwardaws.nft"
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

if TZ="$FORWARDAWS_TIMEZONE" date +%s >/dev/null 2>&1; then
    export TZ="$FORWARDAWS_TIMEZONE"
else
    export TZ="$FORWARDAWS_TIMEZONE_FALLBACK"
fi

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
readonly RED GREEN YELLOW BLUE NC

FORWARDAWS_LOCK_HELD=0
APT_UPDATED=0
APPLY_CANDIDATE_CHANGED=0
SYSTEMD_UNITS_CHANGED=0
DOMAIN_RULES_DROPPED=0

log_info()  { printf '%b\n' "${GREEN}[INFO]${NC} $1"; }
log_warn()  { printf '%b\n' "${YELLOW}[WARNING]${NC} $1" >&2; }
log_error() { printf '%b\n' "${RED}[ERROR]${NC} $1" >&2; }
quiet_mode() { [ "${FORWARDAWS_QUIET:-0}" = "1" ]; }
log_info_noisy() { quiet_mode || log_info "$1"; }

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
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
}

validate_noping_spec() {
    local spec="$1" ip
    local -a ips
    [ "$spec" = "1" ] && return 0
    case "$spec" in ""|,*|*,|*,,*) return 1 ;; esac
    IFS=',' read -ra ips <<< "$spec"
    for ip in "${ips[@]}"; do
        validate_ip_address "$ip" || return 1
    done
}

validate_domain_name() {
    local domain="$1"
    [ -n "$domain" ] && [ "${#domain}" -le 253 ] && \
        [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

format_epoch_time() {
    local ts="$1"
    [[ "$ts" =~ ^[0-9]+$ ]] && date -d "@$ts" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || echo "$ts"
}

get_script_absolute_path() {
    local resolved="" base_dir
    command -v readlink >/dev/null 2>&1 && resolved=$(readlink -f "$0" 2>/dev/null)
    [ -z "$resolved" ] && command -v realpath >/dev/null 2>&1 && resolved=$(realpath "$0" 2>/dev/null)
    if [ -z "$resolved" ]; then
        base_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
        resolved="${base_dir}/$(basename "$0")"
    fi
    echo "$resolved"
}

providerdns_cache_field() {
    local domain="$1" field="$2" record
    record=$(providerdns_cache_record "$domain") || return 1
    awk -v f="$field" '{ print $f }' <<< "$record"
}

providerdns_cache_ip() {
    local ip
    ip=$(providerdns_cache_field "$1" 2 2>/dev/null || true)
    validate_ip_address "$ip" || return 1
    printf '%s\n' "$ip"
}

providerdns_cache_status() {
    providerdns_cache_field "$1" 3 2>/dev/null || printf 'missing\n'
}

providerdns_cache_record() {
    local domain="$1"
    run_providerdns --cache "$domain" 2>/dev/null
}

providerdns_local_source() {
    local script_dir local_path
    script_dir=$(cd "$(dirname "$(get_script_absolute_path)")" 2>/dev/null && pwd)
    local_path="${script_dir}/${PROVIDERDNS_LOCAL_NAME}"
    [ -f "$local_path" ] || return 1
    printf '%s\n' "$local_path"
}

providerdns_bin() {
    if [ -n "$PROVIDERDNS_BIN" ]; then
        [ -f "$PROVIDERDNS_BIN" ] || return 1
        printf '%s\n' "$PROVIDERDNS_BIN"
        return 0
    fi
    providerdns_local_source
}

find_providerdns() {
    providerdns_bin >/dev/null
}

require_providerdns() {
    find_providerdns && return 0
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

providerdns_refresh_hooks() {
    require_providerdns || return 1
    run_providerdns --refresh hooks
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
    find_providerdns || return 0
    run_providerdns --unset "$PROVIDERDNS_CONSUMER"
}

require_root() {
    [ "$EUID" -eq 0 ] && return 0
    log_error "此操作必须以 root 权限运行"
    return 1
}

ensure_supported_bash() {
    [ "${BASH_VERSINFO[0]:-0}" -ge 3 ] && return 0
    log_error "此脚本要求 Bash >= 3（当前: ${BASH_VERSION:-unknown}）"
    return 1
}

install_package() {
    local package="$1"
    command -v apt-get >/dev/null 2>&1 || {
        log_error "缺失依赖包 ${package}，且未检测到 apt-get，无法自动安装"
        return 1
    }
    if [ "$APT_UPDATED" != "1" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || { log_error "apt-get update 失败"; return 1; }
        APT_UPDATED=1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" >/dev/null 2>&1 || { log_error "安装依赖失败: $package"; return 1; }
    log_info_noisy "已安装缺失依赖: $package"
}

ensure_dependencies() {
    local command_name package_name
    while read -r command_name package_name; do
        [ -n "$command_name" ] || continue
        command -v "$command_name" >/dev/null 2>&1 && continue
        install_package "$package_name" || return 1
        command -v "$command_name" >/dev/null 2>&1 || {
            log_error "安装 ${package_name} 后仍未检测到命令: ${command_name}"
            return 1
        }
    done << EOF
nft nftables
flock util-linux
ss iproute2
sysctl procps
getent libc-bin
EOF
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR" "$NFT_INCLUDE_DIR"
}

acquire_global_lock() {
    local lock_wait="${FORWARDAWS_LOCK_WAIT:-0}" lock_error="检测到其他任务正在执行中，请稍后重试"
    [ "$FORWARDAWS_LOCK_HELD" = "1" ] && return 0
    exec 9>"$GLOBAL_LOCK_FILE" || { log_error "无法创建全局锁文件: $GLOBAL_LOCK_FILE"; return 1; }
    if [[ "$lock_wait" =~ ^[0-9]+$ ]] && [ "$lock_wait" -gt 0 ]; then
        lock_error="等待全局锁超时，请稍后重试"
        flock -w "$lock_wait" 9
    else
        flock -n 9
    fi || { log_error "$lock_error"; return 1; }
    FORWARDAWS_LOCK_HELD=1
}

ensure_nftables_service_enabled() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl is-enabled nftables.service >/dev/null 2>&1 && return 0
    systemctl enable nftables.service >/dev/null 2>&1 && \
        log_info_noisy "已启用 nftables.service 开机自启" || \
        log_warn "无法启用 nftables.service，重启后规则可能丢失"
}

nft_main_config_has_forwardaws_include() {
    [ -f "$NFT_MAIN_CONFIG_FILE" ] || return 1
    grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/\*\.nft"?[[:space:]]*$' "$NFT_MAIN_CONFIG_FILE"
}

ensure_nft_main_config_include() {
    local include_line='include "/etc/nftables.d/*.nft"'
    if ! nft_main_config_has_forwardaws_include; then
        touch "$NFT_MAIN_CONFIG_FILE" 2>/dev/null || { log_error "无法访问主配置文件: $NFT_MAIN_CONFIG_FILE"; return 1; }
        printf '\n%s\n' "$include_line" >> "$NFT_MAIN_CONFIG_FILE" 2>/dev/null || {
            log_error "写入主配置 include 失败: $NFT_MAIN_CONFIG_FILE"
            return 1
        }
    fi
    ensure_nftables_service_enabled
}

ensure_ipv4_forwarding_enabled() {
    local current
    current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    if [ "$current" != "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || {
            log_error "无法启用 net.ipv4.ip_forward=1，远程端口转发无法生效"
            return 1
        }
        log_info_noisy "已启用 net.ipv4.ip_forward=1（运行时）"
    fi
    if [ ! -f "$IPV4_FORWARD_SYSCTL_FILE" ] || ! grep -q 'net.ipv4.ip_forward=1' "$IPV4_FORWARD_SYSCTL_FILE" 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" > "$IPV4_FORWARD_SYSCTL_FILE" 2>/dev/null || {
            log_error "无法持久化 IP 转发设置: $IPV4_FORWARD_SYSCTL_FILE"
            return 1
        }
        log_info_noisy "已持久化 net.ipv4.ip_forward=1 至 $IPV4_FORWARD_SYSCTL_FILE"
    fi
}

ipv4_forwarding_needs_update() {
    [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")" = "1" ] && \
        grep -q 'net.ipv4.ip_forward=1' "$IPV4_FORWARD_SYSCTL_FILE" 2>/dev/null && return 1
    return 0
}

get_config_value() {
    local key="$1" default="$2"
    [ -f "$CONFIG_FILE" ] || { echo "$default"; return 0; }
    awk -F= -v k="$key" -v d="$default" '$1==k { print $2; found=1; exit } END { if (!found) print d }' "$CONFIG_FILE"
}

get_protection_flag() { get_config_value "PROTECTION_ENABLED" "0"; }
get_protect_noping() { get_config_value "PROTECT_NOPING" "0"; }
write_config_file() {
    local output_file="$1" protect_flag="$2" protect_noping="${3:-0}"
    [ "$protect_flag" = "1" ] || protect_noping=0
    printf 'PROTECTION_ENABLED=%s\nPROTECT_NOPING=%s\n' "$protect_flag" "$protect_noping" > "$output_file"
}

normalize_ports() {
    echo "$1" | tr -d ' ' | tr ',' '\n' | awk 'NF>0' | sort -un | tr '\n' ',' | sed 's/,$//'
}

is_port_in_list() {
    [ -n "$1" ] && [ -n "$2" ] && [[ ",$2," == *",$1,"* ]]
}

filter_ports() {
    local mode="$1" ports="$2" compare="$3" result="" port
    local -a port_arr
    IFS=',' read -ra port_arr <<< "$(normalize_ports "$ports")"
    for port in "${port_arr[@]}"; do
        validate_port "$port" || continue
        if [ "$mode" = "exclude" ] && is_port_in_list "$port" "$compare"; then
            continue
        fi
        result="${result}${result:+,}${port}"
    done
    echo "$result"
}

get_exclude_ports() {
    local ports="$DEFAULT_EXCLUDE_PORTS"
    [ -n "${FORWARDAWS_EXCLUDE_PORTS:-}" ] && ports="${ports},${FORWARDAWS_EXCLUDE_PORTS}"
    filter_ports keep "$ports" ""
}

apply_exclude_ports_filter() {
    local ports exclude_ports
    ports=$(normalize_ports "$1")
    exclude_ports=$(normalize_ports "$2")
    [ -z "$ports" ] && { echo ""; return 0; }
    [ -z "$exclude_ports" ] && { echo "$ports"; return 0; }
    filter_ports exclude "$ports" "$exclude_ports"
}

detect_ssh_ports() {
    command -v sshd >/dev/null 2>&1 || { echo ""; return 0; }
    sshd -T 2>/dev/null | awk '$1=="port" && $2 ~ /^[0-9]+$/ && $2>=1 && $2<=65535 { print $2 }' | sort -un | tr '\n' ',' | sed 's/,$//'
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
    echo "${addr%%\%*}|${port}"
}

is_loopback_address() {
    [[ "$1" == "::1" || "$1" =~ ^127\. ]]
}

detect_runtime_public_ports() {
    command -v ss >/dev/null 2>&1 || { log_error "缺失依赖: ss"; return 1; }
    local ports="" endpoint parsed addr port
    while IFS= read -r endpoint; do
        [ -n "$endpoint" ] || continue
        parsed=$(parse_local_endpoint "$endpoint")
        IFS='|' read -r addr port <<< "$parsed"
        validate_port "$port" || continue
        is_loopback_address "$addr" && continue
        ports="${ports}${ports:+,}${port}"
    done < <(ss -H -ltn 2>/dev/null | awk '{ print $(NF-1) }')
    normalize_ports "$ports"
}

get_forwarding_ports_from_file() {
    [ -s "$1" ] || { echo ""; return 0; }
    awk -F'|' 'NF>=8 && $1 ~ /^[0-9]+$/ && ($2=="local" || $6 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $1 }' "$1" | sort -un | tr '\n' ',' | sed 's/,$//'
}

get_auto_allow_ports() {
    local state_file="${1:-$RULES_STATE_FILE}" ssh_ports forward_ports runtime_ports exclude_ports merged filtered port
    local -a ssh_ports_arr
    ssh_ports=$(detect_ssh_ports)
    forward_ports=$(get_forwarding_ports_from_file "$state_file")
    runtime_ports=$(detect_runtime_public_ports) || return 1
    exclude_ports=$(get_exclude_ports)
    merged=$(normalize_ports "${ssh_ports},${forward_ports},${runtime_ports}")
    filtered=$(apply_exclude_ports_filter "$merged" "$exclude_ports")
    IFS=',' read -ra ssh_ports_arr <<< "$ssh_ports"
    for port in "${ssh_ports_arr[@]}"; do
        validate_port "$port" || continue
        is_port_in_list "$port" "$filtered" || filtered=$(normalize_ports "${filtered},${port}")
    done
    echo "$filtered"
}

parse_rule() {
    local rule_string="$1" resolve_domain="${2:-1}" src_port target dest_port snat_ip mss
    PARSED_SRC_PORT=""; PARSED_MODE=""; PARSED_TARGET=""; PARSED_DEST_PORT=""
    PARSED_TYPE=""; PARSED_IP=""; PARSED_STATUS="ok"; PARSED_SNAT_IP=""; PARSED_MSS=""

    [[ "$rule_string" =~ ^[^:]+:[^:]+:[^:]+(:[^:]+(:[^:]+)?)?$ ]] || {
        log_error "规则格式错误: $rule_string (正确格式: 端口:目标(IPv4/域名/local):端口[:SNAT_IP[:MSS]])"
        return 1
    }
    IFS=':' read -r src_port target dest_port snat_ip mss <<< "$rule_string"
    validate_port "$src_port" || { log_error "无效的源端口: $src_port"; return 1; }
    validate_port "$dest_port" || { log_error "无效的目标端口: $dest_port"; return 1; }
    [ -z "$snat_ip" ] || validate_ip_address "$snat_ip" || { log_error "无效的 SNAT IP: $snat_ip"; return 1; }
    if [ -n "$mss" ] && { [ "$mss" != "auto" ] && { ! [[ "$mss" =~ ^[0-9]+$ ]] || [ "$mss" -lt 536 ] || [ "$mss" -gt 9000 ]; }; }; then
        log_error "无效的 MSS: $mss (必须为 auto 或 536-9000 之间的数字)"
        return 1
    fi

    case "$target" in
        local|localhost|127.0.0.1)
            [ -z "$snat_ip$mss" ] || { log_error "本地转发不支持 SNAT/MSS 扩展字段: $rule_string"; return 1; }
            PARSED_MODE="local"; PARSED_TARGET="127.0.0.1"; PARSED_TYPE="local"; PARSED_IP="127.0.0.1"
            ;;
        *)
            PARSED_MODE="remote"; PARSED_TARGET="$target"
            if validate_ip_address "$target"; then
                PARSED_TYPE="ipv4"; PARSED_IP="$target"
            elif validate_domain_name "$target"; then
                PARSED_TYPE="domain"
                if [ "$resolve_domain" = "1" ]; then
                    if PARSED_IP=$(providerdns_cache_ip "$target"); then
                        PARSED_STATUS=$(providerdns_cache_status "$target")
                    else
                        PARSED_IP=""; PARSED_STATUS="pending"
                        log_info_noisy "域名尚未解析，规则将先保存并等待 Provider DNS 生效: $target"
                    fi
                else
                    PARSED_IP=""; PARSED_STATUS="pending"
                fi
            else
                log_error "无效的目标地址: $target"
                return 1
            fi
            ;;
    esac
    PARSED_SRC_PORT="$src_port"; PARSED_DEST_PORT="$dest_port"; PARSED_SNAT_IP="$snat_ip"; PARSED_MSS="$mss"
}

make_state_line() {
    echo "$1|$2|$3|$4|$5|$6|$7|$8|${9:-}|${10:-}"
}

state_rule_status() {
    local file="$1" src_port="$2" mode="$3" target="$4" dest_port="$5" snat_ip="${6:-}" mss="${7:-}"
    [ -s "$file" ] || { echo "none"; return 0; }
    awk -F'|' -v sp="$src_port" -v mode="$mode" -v target="$target" -v dp="$dest_port" -v snat="$snat_ip" -v mss="$mss" '
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
    [ -s "${1:-$RULES_STATE_FILE}" ] || { echo 0; return 0; }
    awk -F'|' 'NF>=8 && $5=="domain" { count++ } END { print count+0 }' "${1:-$RULES_STATE_FILE}"
}

state_has_domain() {
    [ "$(state_domain_count "$1")" -gt 0 ]
}

state_has_remote_rules() {
    [ -s "$1" ] || return 1
    awk -F'|' 'NF>=8 && $2=="remote" && $6 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { found=1; exit } END { exit(found ? 0 : 1) }' "$1"
}

write_state_domains() {
    local state_file="$1" output_file="$2"
    awk -F'|' 'NF>=8 && $5=="domain" { print $3 }' "$state_file" | sort -u > "$output_file"
}

apply_providerdns_for_state() {
    local state_file="$1" domains_file
    if state_has_domain "$state_file"; then
        domains_file=$(mktemp /tmp/forwardaws-domains.XXXXXX) || return 1
        write_state_domains "$state_file" "$domains_file" || { rm -f "$domains_file"; return 1; }
        providerdns_set_forwardaws "$domains_file" || { rm -f "$domains_file"; return 1; }
        rm -f "$domains_file"
        providerdns_refresh
    else
        providerdns_unset_forwardaws
    fi
}

filter_candidate_domain_cache() {
    local candidate="$1" next now src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss
    local record record_domain new_ip new_status cache_updated_at
    DOMAIN_RULES_DROPPED=0
    next=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    : > "$next"
    now=$(date +%s)
    while IFS='|' read -r src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss; do
        [ -n "$src_port$mode$target$dest_port" ] || continue
        if [ "$target_type" != "domain" ]; then
            make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$resolved_ip" "$status" "$updated_at" "$snat_ip" "$mss" >> "$next"
        elif record=$(providerdns_cache_record "$target"); then
            IFS=$'\t' read -r record_domain new_ip new_status cache_updated_at <<< "$record"
            if validate_ip_address "$new_ip"; then
                make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$new_ip" "$new_status" "$now" "$snat_ip" "$mss" >> "$next"
            elif validate_ip_address "$resolved_ip"; then
                make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$resolved_ip" "${new_status:-failed}" "$now" "$snat_ip" "$mss" >> "$next"
                log_warn "域名 ${target} 当前解析失败，继续使用旧 IP: ${resolved_ip}"
            else
                DOMAIN_RULES_DROPPED=$((DOMAIN_RULES_DROPPED + 1))
                log_warn "域名 ${target} 解析失败，已跳过该规则，未写入配置、未生成转发、未放行端口"
            fi
        elif validate_ip_address "$resolved_ip"; then
            make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$resolved_ip" "cache_missing" "$now" "$snat_ip" "$mss" >> "$next"
            log_warn "域名 ${target} 解析结果缺失，继续使用旧 IP: ${resolved_ip}"
        else
            DOMAIN_RULES_DROPPED=$((DOMAIN_RULES_DROPPED + 1))
            log_warn "域名 ${target} 解析结果缺失，已跳过该规则，未写入配置、未生成转发、未放行端口"
        fi
    done < "$candidate"
    mv "$next" "$candidate" || { rm -f "$next"; return 1; }
}

resolve_candidate_domains() {
    state_has_domain "$1" || return 0
    apply_providerdns_for_state "$1" || return 1
    filter_candidate_domain_cache "$1"
}

prepare_state_file() {
    ensure_state_dir || return 1
    [ -f "$RULES_STATE_FILE" ] || : > "$RULES_STATE_FILE"
}

prepare_state_file_for_read() {
    [ -f "$RULES_STATE_FILE" ] && return 0
    return 0
}

copy_current_state_to() {
    prepare_state_file || return 1
    cp "$RULES_STATE_FILE" "$1"
}

render_ruleset() {
    local state_file="$1" protect_flag="$2" output_file="$3" allow_ports="${4:-}" protect_noping="${5:-0}"
    if [ "$protect_flag" = "1" ] && [ -z "$allow_ports" ]; then
        allow_ports=$(get_auto_allow_ports "$state_file") || return 1
        [ -n "$allow_ports" ] || { log_error "保护端口列表为空，拒绝渲染保护链"; return 1; }
    fi
    awk -F'|' -v nat="$NAT_TABLE_NAME" -v filter="$FILTER_TABLE_NAME" \
        -v protect="$protect_flag" -v allow="$allow_ports" -v noping="$protect_noping" '
        function rule(s) { return "        " s "\n" }
        NF>=8 && $6 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
            if ($2=="remote") {
                pre=pre rule("tcp dport " $1 " dnat to " $6 ":" $4) rule("udp dport " $1 " dnat to " $6 ":" $4)
                fwd=fwd rule("ct status dnat ip daddr " $6 " tcp dport " $4 " accept") rule("ct status dnat ip daddr " $6 " udp dport " $4 " accept")
                if ($9!="") {
                    post=post rule("ip daddr " $6 " tcp dport " $4 " snat to " $9) rule("ip daddr " $6 " udp dport " $4 " snat to " $9)
                } else {
                    post=post rule("ct status dnat ip daddr " $6 " tcp dport " $4 " masquerade") rule("ct status dnat ip daddr " $6 " udp dport " $4 " masquerade")
                }
                has_remote=1
                if ($10!="") {
                    value=($10=="auto" ? "rt mtu" : $10)
                    mss=mss rule("ip daddr " $6 " tcp dport " $4 " tcp flags syn tcp option maxseg size set " value)
                    has_mss=1
                }
            } else if ($2=="local") {
                out=out rule("tcp dport " $1 " dnat to " $6 ":" $4) rule("udp dport " $1 " dnat to " $6 ":" $4)
            }
        }
        END {
            print "#!/usr/sbin/nft -f"
            print "# forwardaws generated by nftables.sh"
            print "\ntable ip " nat "\ndelete table ip " nat "\ntable inet " filter "\ndelete table inet " filter
            print "\ntable ip " nat " {\n    chain prerouting {\n        type nat hook prerouting priority -100; policy accept;"
            printf "%s", pre
            print "    }\n\n    chain output {\n        type nat hook output priority -100; policy accept;"
            printf "%s", out
            print "    }\n\n    chain postrouting {\n        type nat hook postrouting priority 100; policy accept;"
            printf "%s", post
            print "    }\n}"
            if (protect!="1" && !has_remote && !has_mss) exit
            print "\ntable inet " filter " {"
            if (has_mss) {
                print "    chain forward_mss {\n        type filter hook forward priority -150; policy accept;"
                printf "%s", mss
                print "    }"
            }
            if (protect=="1") {
                print "    chain input {\n        type filter hook input priority 0; policy drop;"
                print "        iifname \"lo\" accept\n        ct state established,related accept"
                if (noping!="0") {
                    if (noping!="1") print "        ip saddr { " noping " } ip protocol icmp icmp type echo-request accept"
                    print "        ip protocol icmp icmp type echo-request drop"
                    print "        ip6 nexthdr icmpv6 icmpv6 type echo-request drop"
                }
                print "        ip protocol icmp accept\n        ip6 nexthdr icmpv6 accept"
                print "        ip6 saddr fe80::/10 udp sport 547 udp dport 546 limit rate 20/second accept"
                print "        tcp dport { " allow " } accept\n        udp dport { " allow " } accept\n    }"
            }
            if (has_remote) {
                print "    chain forward {\n        type filter hook forward priority 0; policy accept;\n        ct state established,related accept;"
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

apply_candidate_state() {
    local candidate_state="$1" protect_flag="$2" desc="$3" protect_ports="${4:-}" protect_noping="${5:-}"
    local nft_tmp state_tmp config_tmp rules_changed=0 include_missing=0 forwarding_needs_update=0 state_changed=0 config_changed=0
    APPLY_CANDIDATE_CHANGED=0
    ensure_state_dir || return 1
    [ -n "$protect_noping" ] || protect_noping=$(get_protect_noping)
    [ "$protect_flag" = "1" ] || protect_noping=0
    [ "$protect_noping" = "0" ] || validate_noping_spec "$protect_noping" || { log_error "noping 状态无效: $protect_noping"; return 1; }
    if [ "$protect_flag" = "1" ] && [ -z "$protect_ports" ]; then
        protect_ports=$(get_auto_allow_ports "$candidate_state") || return 1
    fi

    nft_tmp="${FORWARDAWS_RULES_FILE}.tmp.$$"
    state_tmp="${RULES_STATE_FILE}.tmp.$$"
    config_tmp="${CONFIG_FILE}.tmp.$$"
    render_ruleset "$candidate_state" "$protect_flag" "$nft_tmp" "$protect_ports" "$protect_noping" || { rm -f "$nft_tmp"; return 1; }
    state_has_remote_rules "$candidate_state" && ipv4_forwarding_needs_update && forwarding_needs_update=1
    cp "$candidate_state" "$state_tmp" || { rm -f "$nft_tmp" "$state_tmp"; log_error "写入状态临时文件失败"; return 1; }
    write_config_file "$config_tmp" "$protect_flag" "$protect_noping" || { rm -f "$nft_tmp" "$state_tmp" "$config_tmp"; log_error "写入配置临时文件失败"; return 1; }
    cmp -s "$nft_tmp" "$FORWARDAWS_RULES_FILE" || rules_changed=1
    nft_main_config_has_forwardaws_include || include_missing=1
    cmp -s "$state_tmp" "$RULES_STATE_FILE" || state_changed=1
    cmp -s "$config_tmp" "$CONFIG_FILE" || config_changed=1

    if [ "$rules_changed$include_missing$forwarding_needs_update" = "000" ] && \
        [ "$state_changed$config_changed" = "00" ]; then
        rm -f "$nft_tmp" "$state_tmp" "$config_tmp"
        return 0
    fi
    APPLY_CANDIDATE_CHANGED=1
    [ "$rules_changed" -eq 0 ] || run_nft_file "-c" "预检" "$nft_tmp" "$desc" || { rm -f "$nft_tmp" "$state_tmp" "$config_tmp"; return 1; }
    [ "$forwarding_needs_update" -eq 0 ] || ensure_ipv4_forwarding_enabled || { rm -f "$nft_tmp" "$state_tmp" "$config_tmp"; return 1; }
    if [ "$rules_changed" -eq 1 ]; then
        run_nft_file "" "应用" "$nft_tmp" "$desc" || { rm -f "$nft_tmp" "$state_tmp" "$config_tmp"; return 1; }
        mv "$nft_tmp" "$FORWARDAWS_RULES_FILE" || { rm -f "$state_tmp" "$config_tmp"; log_error "写入持久化规则文件失败: $FORWARDAWS_RULES_FILE"; return 1; }
        chmod 600 "$FORWARDAWS_RULES_FILE" 2>/dev/null || true
    else
        rm -f "$nft_tmp"
    fi
    mv "$state_tmp" "$RULES_STATE_FILE" || { rm -f "$config_tmp"; log_error "写入规则状态文件失败: $RULES_STATE_FILE"; return 1; }
    mv "$config_tmp" "$CONFIG_FILE" || { log_error "写入配置状态文件失败: $CONFIG_FILE"; return 1; }
    if [ "$include_missing" -eq 1 ] || [ "$rules_changed" -eq 1 ]; then
        ensure_nft_main_config_include || return 1
    fi
}

commit_systemd_unit_if_changed() {
    local tmp_file="$1" target_file="$2"
    if cmp -s "$tmp_file" "$target_file"; then
        rm -f "$tmp_file"
        return 0
    fi
    mv "$tmp_file" "$target_file" || { rm -f "$tmp_file"; log_error "写入 systemd unit 失败: $target_file"; return 1; }
    chmod 644 "$target_file" 2>/dev/null || true
    SYSTEMD_UNITS_CHANGED=1
}

write_systemd_service_if_changed() {
    local service_file="$1" service_desc="$2" script_path="$3" exec_args="$4" tmp_file
    tmp_file=$(mktemp "${service_file}.XXXXXX") || { log_error "创建 systemd service 临时文件失败: $service_file"; return 1; }
    cat > "$tmp_file" << EOF || { rm -f "$tmp_file"; log_error "生成 systemd service 失败: $service_file"; return 1; }
[Unit]
Description=${service_desc}
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=FORWARDAWS_QUIET=1
Environment=FORWARDAWS_LOCK_WAIT=10
ExecStart=/bin/bash "${script_path}" ${exec_args}
EOF
    commit_systemd_unit_if_changed "$tmp_file" "$service_file"
}

write_systemd_timer_if_changed() {
    local timer_file="$1" timer_desc="$2" service_name="$3" tmp_file
    tmp_file=$(mktemp "${timer_file}.XXXXXX") || { log_error "创建 systemd timer 临时文件失败: $timer_file"; return 1; }
    cat > "$tmp_file" << EOF || { rm -f "$tmp_file"; log_error "生成 systemd timer 失败: $timer_file"; return 1; }
[Unit]
Description=${timer_desc}

[Timer]
OnBootSec=30s
OnUnitActiveSec=10min
AccuracySec=5s
Unit=${service_name}

[Install]
WantedBy=timers.target
EOF
    commit_systemd_unit_if_changed "$tmp_file" "$timer_file"
}

install_systemd_units_if_needed() {
    local service_name="$1" timer_name="$2" service_desc="$3" timer_desc="$4" exec_args="$5"
    local script_path service_file="${SYSTEMD_SYSTEM_DIR}/${service_name}" timer_file="${SYSTEMD_SYSTEM_DIR}/${timer_name}"
    command -v systemctl >/dev/null 2>&1 || return 1
    script_path=$(get_script_absolute_path)
    [ -n "$script_path" ] || { log_error "无法确定脚本绝对路径，systemd 定时器安装失败"; return 1; }

    write_systemd_service_if_changed "$service_file" "$service_desc" "$script_path" "$exec_args" || return 1
    write_systemd_timer_if_changed "$timer_file" "$timer_desc" "$service_name"
}

has_systemctl() { command -v systemctl >/dev/null 2>&1; }

enable_timer_if_available() {
    local timer_name="$1" success_msg="$2" fail_msg="$3"
    has_systemctl || { log_error "未检测到 systemctl，无法启用自动同步"; return 1; }
    systemctl is-enabled --quiet "$timer_name" 2>/dev/null && systemctl is-active --quiet "$timer_name" 2>/dev/null && return 0
    systemctl enable --now --no-reload "$timer_name" >/dev/null 2>&1 && { log_info_noisy "$success_msg"; return 0; }
    log_warn "$fail_msg"
    return 1
}

disable_timer_if_available() {
    has_systemctl || return 0
    systemctl disable --now --no-reload "$1" >/dev/null 2>&1 && log_info_noisy "$2"
}

reconcile_forwardaws_dns() {
    local domain_count
    domain_count=$(state_domain_count "$RULES_STATE_FILE")
    if [ "$domain_count" -gt 0 ]; then
        apply_providerdns_for_state "$RULES_STATE_FILE" || {
            log_warn "注册 Provider DNS 订阅失败，请手动检查 systemd 状态"
            return 1
        }
    else
        providerdns_unset_forwardaws || return 1
    fi
}

reconcile_protection_timer() {
    local protect_flag enable_protect=0 failed=0
    protect_flag=$(get_protection_flag)
    SYSTEMD_UNITS_CHANGED=0
    if [ "$protect_flag" = "1" ]; then
        install_systemd_units_if_needed "$PROTECT_SERVICE_NAME" "$PROTECT_TIMER_NAME" "ForwardAWS protection sync service" "Run ForwardAWS protection sync every 10 minutes" "--protect sync" || return 1
        enable_protect=1
    else
        disable_timer_if_available "$PROTECT_TIMER_NAME" "保护端口自动同步已停用"
    fi
    if [ "$SYSTEMD_UNITS_CHANGED" = "1" ]; then
        systemctl daemon-reload >/dev/null 2>&1 || { log_warn "systemd daemon-reload 失败，请手动检查 systemd 状态"; return 1; }
    fi
    [ "$enable_protect" -eq 0 ] || enable_timer_if_available "$PROTECT_TIMER_NAME" "保护端口自动同步已启用" "启用保护同步定时器失败，请手动检查 systemd 状态" || failed=1
    [ "$failed" -eq 0 ]
}

reconcile_timers() {
    reconcile_forwardaws_dns || return 1
    reconcile_protection_timer
}

get_protect_timer_status() {
    has_systemctl || { echo "unavailable"; return 0; }
    systemctl is-active --quiet "$PROTECT_TIMER_NAME" && echo "active" || echo "inactive"
}

remove_path() {
    local path="$1" path_type="${2:-文件}"
    [ -e "$path" ] || [ -L "$path" ] || return 0
    rm -rf "$path" || { log_error "删除失败: $path"; return 1; }
    log_info_noisy "  ✓ 删除${path_type}: $path"
}

remove_systemd_unit_path() {
    local path="$1"
    [ -e "$path" ] || [ -L "$path" ] || return 0
    rm -rf "$path" || { log_error "删除失败: $path"; return 1; }
    log_info_noisy "  ✓ 删除 systemd 单元: $path"
    SYSTEMD_UNITS_CHANGED=1
}

nft_include_dir_has_other_files() {
    local current_file other_file
    current_file=$(basename "$FORWARDAWS_RULES_FILE")
    [ -d "$NFT_INCLUDE_DIR" ] || return 1
    other_file=$(find "$NFT_INCLUDE_DIR" -maxdepth 1 -type f -name '*.nft' ! -name "$current_file" -print -quit 2>/dev/null)
    [ -n "$other_file" ]
}

remove_nft_main_config_include_if_unused() {
    local tmp_file
    [ -f "$NFT_MAIN_CONFIG_FILE" ] || return 0

    tmp_file=$(mktemp /tmp/forwardaws-nftables-conf.XXXXXX) || return 1
    if nft_include_dir_has_other_files; then
        awk '$0 !~ /^[[:space:]]*include[[:space:]]+"?\/etc\/nftables[.]d\/forwardaws[.]nft"?[[:space:]]*$/' "$NFT_MAIN_CONFIG_FILE" > "$tmp_file"
    else
        awk '$0 !~ /^[[:space:]]*include[[:space:]]+"?\/etc\/nftables[.]d\/(forwardaws|[*])[.]nft"?[[:space:]]*$/' "$NFT_MAIN_CONFIG_FILE" > "$tmp_file"
    fi || {
        rm -f "$tmp_file"
        log_error "清理 nftables 主配置 include 失败: $NFT_MAIN_CONFIG_FILE"
        return 1
    }
    if cmp -s "$tmp_file" "$NFT_MAIN_CONFIG_FILE"; then
        rm -f "$tmp_file"
    else
        mv "$tmp_file" "$NFT_MAIN_CONFIG_FILE" || { rm -f "$tmp_file"; log_error "写回 nftables 主配置失败: $NFT_MAIN_CONFIG_FILE"; return 1; }
    fi
}

write_nft_cleanup_ruleset() {
    cat > "$1" << EOF
#!/usr/sbin/nft -f
# forwardaws cleanup generated by nftables.sh

table ip ${NAT_TABLE_NAME}
delete table ip ${NAT_TABLE_NAME}
table inet ${FILTER_TABLE_NAME}
delete table inet ${FILTER_TABLE_NAME}
table ip forwardaws
delete table ip forwardaws
table ip6 forwardaws
delete table ip6 forwardaws
EOF
}

remove_active_nft_tables() {
    local nft_tmp
    command -v nft >/dev/null 2>&1 || { log_warn "未检测到 nft，跳过运行时规则清理"; return 0; }
    nft_tmp=$(mktemp /tmp/forwardaws-cleanup.XXXXXX) || return 1
    write_nft_cleanup_ruleset "$nft_tmp" || { rm -f "$nft_tmp"; return 1; }
    log_info_noisy "  ✓ 清除 nftables 表:"
    run_nft_file "" "清理" "$nft_tmp" "卸载 forwardaws nftables 表"
    local rc=$?
    rm -f "$nft_tmp"
    if [ $rc -eq 0 ]; then
        log_info_noisy "    - 已删除: table ip ${NAT_TABLE_NAME}"
        log_info_noisy "    - 已删除: table inet ${FILTER_TABLE_NAME}"
        log_info_noisy "    - 已删除: table ip forwardaws"
        log_info_noisy "    - 已删除: table ip6 forwardaws"
    fi
    return "$rc"
}

remove_systemd_units() {
    local service_removed=0 timer_removed=0 dns_removed=0
    SYSTEMD_UNITS_CHANGED=0

    log_info_noisy "  清理 systemd 服务和定时器:"
    if has_systemctl; then
        systemctl disable --now --no-reload "$PROTECT_TIMER_NAME" >/dev/null 2>&1 && { service_removed=1; log_info_noisy "    - 已停用定时器: ${PROTECT_TIMER_NAME}"; } || true
        systemctl stop "$PROTECT_SERVICE_NAME" >/dev/null 2>&1 && { service_removed=1; } || true
        systemctl reset-failed "$PROTECT_TIMER_NAME" "$PROTECT_SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    log_info_noisy "  删除 systemd 单元文件:"
    remove_systemd_unit_path "${SYSTEMD_SYSTEM_DIR}/${PROTECT_SERVICE_NAME}" || return 1
    remove_systemd_unit_path "${SYSTEMD_SYSTEM_DIR}/${PROTECT_TIMER_NAME}" || return 1
    remove_systemd_unit_path "${SYSTEMD_SYSTEM_DIR}/timers.target.wants/${PROTECT_TIMER_NAME}" || return 1

    log_info_noisy "  清理 DNS 订阅:"
    providerdns_unset_forwardaws || return 1

    [ "$SYSTEMD_UNITS_CHANGED" != "1" ] || { has_systemctl && systemctl daemon-reload >/dev/null 2>&1 || true; log_info_noisy "    - 已重新加载 systemd daemon"; }
}

uninstall_forwardaws() {
    local nft_removed=0 config_removed=0 sysctl_removed=0

    log_info "开始清理 nftables.sh 产物..."
    echo -e "${BLUE}─────────────────────────────────────${NC}"

    # 步骤 1: 清理 systemd 服务和定时器
    log_info_noisy "步骤 1/5: 清理 systemd 服务和定时器"
    remove_systemd_units || return 1

    # 步骤 2: 清理运行时 nftables 规则
    log_info_noisy "步骤 2/5: 清理运行时 nftables 规则"
    remove_active_nft_tables || return 1

    # 步骤 3: 删除规则配置文件
    log_info_noisy "步骤 3/5: 删除规则配置文件"
    [ -f "$FORWARDAWS_RULES_FILE" ] && { remove_path "$FORWARDAWS_RULES_FILE" "NFT 规则文件" || return 1; nft_removed=1; } || true

    # 步骤 4: 清理 nftables 主配置包含行
    log_info_noisy "步骤 4/5: 清理 nftables 主配置"
    remove_nft_main_config_include_if_unused || return 1
    rmdir "$NFT_INCLUDE_DIR" 2>/dev/null || true

    # 步骤 5: 删除状态文件和系统配置
    log_info_noisy "步骤 5/5: 删除状态目录和系统配置"
    [ -d "$STATE_DIR" ] && { remove_path "$STATE_DIR" "状态目录" || return 1; } || true
    [ -f "$IPV4_FORWARD_SYSCTL_FILE" ] && { remove_path "$IPV4_FORWARD_SYSCTL_FILE" "sysctl 配置文件" || return 1; sysctl_removed=1; } || true
    [ -f "$GLOBAL_LOCK_FILE" ] && { remove_path "$GLOBAL_LOCK_FILE" "全局锁文件" || return 1; } || true

    # 输出清理摘要
    echo -e "${BLUE}─────────────────────────────────────${NC}"
    log_info "清理完成，已移除:"
    [ "$nft_removed" = "1" ] && log_info_noisy "  • NFT 规则文件"
    [ "$config_removed" = "1" ] && log_info_noisy "  • nftables 配置包含"
    [ "$sysctl_removed" = "1" ] && log_info_noisy "  • IP 转发 sysctl 配置"
    log_info_noisy "  • systemd 服务和定时器"
    log_info_noisy "  • 状态数据库和配置"
    log_info_noisy "  • DNS 订阅和 Hook"
}

append_rule_to_state() {
    local candidate="$1" rule="$2" now="$3" duplicate_mode="$4" status suffix=""
    parse_rule "$rule" 0 || return 1
    status=$(state_rule_status "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_SNAT_IP" "$PARSED_MSS")
    [ "$duplicate_mode" = "skip" ] && suffix="，跳过"
    case "$status" in
        exact) [ "$duplicate_mode" = "skip" ] && { log_warn "规则已存在，跳过: $rule"; return 2; }; log_error "重复规则: $rule"; return 1 ;;
        base) log_error "规则已存在但 SNAT/MSS 不一致${suffix}: $rule"; return 1 ;;
        port_conflict) log_error "端口冲突${suffix}: $rule"; return 1 ;;
    esac
    make_state_line "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_TYPE" "$PARSED_IP" "$PARSED_STATUS" "$now" "$PARSED_SNAT_IP" "$PARSED_MSS" >> "$candidate"
}

remove_rule_from_state() {
    local candidate="$1" rule="$2" next_candidate status
    parse_rule "$rule" 0 || return 1
    status=$(state_rule_status "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_SNAT_IP" "$PARSED_MSS")
    case "$status" in
        exact|base) ;;
        *) log_warn "规则不存在，跳过: $rule"; return 2 ;;
    esac
    next_candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 3
    awk -F'|' -v sp="$PARSED_SRC_PORT" -v mode="$PARSED_MODE" -v target="$PARSED_TARGET" -v dp="$PARSED_DEST_PORT" \
        'NF>=8 && !($1==sp && $2==mode && $3==target && $4==dp) { print $0 }' "$candidate" > "$next_candidate" || { rm -f "$next_candidate"; return 3; }
    mv "$next_candidate" "$candidate" || return 3
}

rule_batch() {
     local action="$1" protect_noping="$2" candidate now success=0 skipped=0 failed=0 rule rc protect_flag desc success_msg empty_msg show_status=0 prepared_domains=0 applied_success=0
     shift 2
     [ $# -gt 0 ] || { log_error "未提供任何规则"; return 1; }
     candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
     case "$action" in
         add)
             copy_current_state_to "$candidate" || { rm -f "$candidate"; return 1; }
             protect_flag=1; desc="批量添加转发规则"; success_msg="批量添加"; empty_msg="新增规则"; show_status=1
             ;;
         delete)
             copy_current_state_to "$candidate" || { rm -f "$candidate"; return 1; }
             protect_flag=$(get_protection_flag); desc="批量删除转发规则"; success_msg="批量删除"; empty_msg="删除规则"
             ;;
         replace) : > "$candidate"; protect_flag=1; desc="原子替换转发规则"; success_msg="原子替换"; empty_msg="新规则"; show_status=1 ;;
     esac
     now=$(date +%s)
     for rule in "$@"; do
         log_info "$([ "$action" = "replace" ] && echo "校验规则" || echo "处理规则"): $rule"
         case "$action" in
             delete)
                 remove_rule_from_state "$candidate" "$rule"
                 rc=$?
                 ;;
             replace)
                 if append_rule_to_state "$candidate" "$rule" "$now" "fail"; then
                     rc=0
                 else
                     rc=$?
                 fi
                 ;;
             *)
                 if append_rule_to_state "$candidate" "$rule" "$now" "skip"; then
                     rc=0
                 else
                     rc=$?
                 fi
                 ;;
         esac
         case "$rc" in
             0) success=$((success + 1)) ;;
             2) skipped=$((skipped + 1)) ;;
             3) rm -f "$candidate"; return 1 ;;
             *) failed=$((failed + 1)) ;;
         esac
     done
     if [ "$action" = "replace" ] && [ "$failed" -gt 0 ]; then
         rm -f "$candidate"
         log_error "替换前校验失败，已取消所有变更"
         return 1
     fi
     if [ "$success" -gt 0 ]; then
         if state_has_domain "$candidate"; then
             log_info "检测到域名规则，触发 Provider DNS 解析..."
             prepared_domains=1
             resolve_candidate_domains "$candidate" || {
                 reconcile_forwardaws_dns || log_warn "Provider DNS 订阅回滚失败，请手动执行 --ddns sync"
                 rm -f "$candidate"
                 return 1
             }
             if [ "$DOMAIN_RULES_DROPPED" -gt 0 ]; then
                 skipped=$((skipped + DOMAIN_RULES_DROPPED))
                 success=$((success - DOMAIN_RULES_DROPPED))
                 [ "$success" -lt 0 ] && success=0
             fi
         fi
         applied_success=$success
         if [ "$action" != "delete" ] && [ "$applied_success" -eq 0 ]; then
             log_warn "没有${empty_msg}: 跳过 ${skipped} 条，失败 ${failed} 条"
             [ "$prepared_domains" -eq 0 ] || reconcile_forwardaws_dns || log_warn "Provider DNS 订阅回滚失败，请手动执行 --ddns sync"
             rm -f "$candidate"
             return 0
         fi
         apply_candidate_state "$candidate" "$protect_flag" "$desc" "" "$protect_noping" || {
             [ "$prepared_domains" -eq 0 ] || reconcile_forwardaws_dns || log_warn "Provider DNS 订阅回滚失败，请手动执行 --ddns sync"
             rm -f "$candidate"
             return 1
         }
         [ "$action" = "replace" ] && log_info "原子替换完成，共应用 ${applied_success} 条规则" || log_info "${success_msg}完成: 成功 ${applied_success} 条，跳过 ${skipped} 条，失败 ${failed} 条"
         reconcile_timers || { rm -f "$candidate"; return 1; }

         [ "$show_status" = "1" ] && show_protection_status
     elif [ "$failed" -eq 0 ] && [ -n "$protect_noping" ] && [ "$(get_protect_noping)" != "$protect_noping" ]; then
         apply_candidate_state "$candidate" "$protect_flag" "$desc" "" "$protect_noping" || { rm -f "$candidate"; return 1; }
         log_warn "没有${empty_msg}: 跳过 ${skipped} 条，失败 ${failed} 条"
         reconcile_timers || { rm -f "$candidate"; return 1; }
         [ "$show_status" = "1" ] && show_protection_status
     else
         log_warn "没有${empty_msg}: 跳过 ${skipped} 条，失败 ${failed} 条"
     fi
     rm -f "$candidate"
     [ "$failed" -eq 0 ]
 }

apply_ddns_cache() {
    local candidate candidate_changed=0 changed=0 unchanged=0 pending=0 failed=0 now
    local src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss record record_domain new_ip new_status cache_updated_at
    local total_domains
    prepare_state_file || return 1
    total_domains=$(state_domain_count "$RULES_STATE_FILE")
    if [ "$total_domains" -eq 0 ]; then
        log_info_noisy "未配置 DDNS 域名规则，无需同步"
        reconcile_timers
        return 0
    fi
    require_providerdns || return 1
    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    : > "$candidate"
    now=$(date +%s)

    # 打印 DDNS 同步开始信息
    log_info "DDNS 缓存同步开始 (共 ${total_domains} 条域名规则)"
    echo -e "${BLUE}─────────────────────────────────────${NC}"

    while IFS='|' read -r src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss; do
        [ -n "$src_port$mode$target$dest_port" ] || continue
        if [ "$target_type" != "domain" ]; then
            make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$resolved_ip" "$status" "$updated_at" "$snat_ip" "$mss" >> "$candidate"
        elif record=$(providerdns_cache_record "$target"); then
            IFS=$'\t' read -r record_domain new_ip new_status cache_updated_at <<< "$record"
            if validate_ip_address "$new_ip"; then
                if [ "$new_ip" = "$resolved_ip" ] && [ "$status" = "$new_status" ]; then
                    make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$resolved_ip" "$status" "$updated_at" "$snat_ip" "$mss" >> "$candidate"
                    unchanged=$((unchanged + 1))
                    log_info_noisy "  ✓ 无变化 ${target} -> ${new_ip}"
                else
                    make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$new_ip" "$new_status" "$now" "$snat_ip" "$mss" >> "$candidate"
                    changed=$((changed + 1))
                    log_info "  ✓ 更新 ${target}: ${resolved_ip:-未解析} → ${new_ip}"
                fi
            elif validate_ip_address "$resolved_ip"; then
                if [ "$status" = "$new_status" ]; then
                    make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$resolved_ip" "$status" "$updated_at" "$snat_ip" "$mss" >> "$candidate"
                    unchanged=$((unchanged + 1))
                else
                    make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$resolved_ip" "$new_status" "$now" "$snat_ip" "$mss" >> "$candidate"
                    changed=$((changed + 1))
                fi
                failed=$((failed + 1))
                log_warn "  ✗ 解析失败 ${target}，保留原 IP (${resolved_ip})"
            else
                changed=$((changed + 1))
                pending=$((pending + 1))
                log_warn "  ✗ 解析失败 ${target}，已移除未生效规则"
            fi
        else
            if validate_ip_address "$resolved_ip"; then
                new_status="cache_missing"
                if [ "$status" = "$new_status" ]; then
                    make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$resolved_ip" "$status" "$updated_at" "$snat_ip" "$mss" >> "$candidate"
                    unchanged=$((unchanged + 1))
                else
                    make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$resolved_ip" "$new_status" "$now" "$snat_ip" "$mss" >> "$candidate"
                    changed=$((changed + 1))
                fi
                failed=$((failed + 1))
                log_warn "  ✗ 缓存缺失 ${target}，保留原 IP (${resolved_ip})"
            else
                changed=$((changed + 1))
                pending=$((pending + 1))
                log_warn "  ✗ 缓存缺失 ${target}，已移除未生效规则"
            fi
        fi
    done < "$RULES_STATE_FILE"
    cmp -s "$candidate" "$RULES_STATE_FILE" || candidate_changed=1

    # 应用候选状态
    apply_candidate_state "$candidate" "$(get_protection_flag)" "DDNS 同步" || { rm -f "$candidate"; return 1; }
    rm -f "$candidate"
    reconcile_timers || return 1

    # 输出 DDNS 同步结果汇总
    echo -e "${BLUE}─────────────────────────────────────${NC}"
    if [ "$candidate_changed" -eq 1 ]; then
        log_info "DDNS 缓存同步完成: 已更新 ${GREEN}${changed}${NC} 条，无变化 ${unchanged} 条，等待解析 ${YELLOW}${pending}${NC} 条，失败 ${RED}${failed}${NC} 条"
    else
        log_info_noisy "DDNS 缓存同步完成: 无变化，无变化 ${unchanged} 条，等待解析 ${pending} 条，失败 ${failed} 条"
    fi
    return 0
}

sync_ddns_rules() {
    reconcile_forwardaws_dns || return 1
    apply_ddns_cache
}

apply_protection_state() {
    local protect_flag="$1" desc="$2" success_msg="$3" protect_noping="${4:-}" reset_rules="${5:-0}" candidate current_ports=""
    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    if [ "$reset_rules" = "1" ]; then
        : > "$candidate"
    else
        copy_current_state_to "$candidate" || { rm -f "$candidate"; return 1; }
    fi
    [ -n "$protect_noping" ] || protect_noping=$(get_protect_noping)
    [ "$protect_flag" = "1" ] || protect_noping=0
    if [ "$protect_flag" = "1" ]; then
        current_ports=$(get_auto_allow_ports "$candidate") || { rm -f "$candidate"; return 1; }
    fi
    apply_candidate_state "$candidate" "$protect_flag" "$desc" "$current_ports" "$protect_noping" || { rm -f "$candidate"; return 1; }
    rm -f "$candidate"
    reconcile_timers
    if [ "${APPLY_CANDIDATE_CHANGED:-0}" = "1" ]; then
        [ "$protect_flag" = "1" ] && log_info "${success_msg}: $current_ports" || log_info "$success_msg"
    else
        [ "$protect_flag" = "1" ] && log_info_noisy "${success_msg}: $current_ports" || log_info_noisy "$success_msg"
    fi
}

sync_protection_ports() {
    [ "$(get_protection_flag)" = "1" ] || { log_info_noisy "保护模式未开启，跳过端口同步"; return 0; }
    apply_protection_state 1 "同步端口保护" "保护端口同步完成"
}

enable_protection() { apply_protection_state 1 "开启端口保护" "端口保护已开启，开放端口" "${1:-0}" 1; }
disable_protection() { apply_protection_state 0 "关闭端口保护" "端口保护已关闭"; }

show_protection_status() {
    local protect_flag protect_noping timer_status auto_ports
    prepare_state_file_for_read
    protect_flag=$(get_protection_flag)
    protect_noping=$(get_protect_noping)
    timer_status=$(get_protect_timer_status)
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}           端口保护状态${NC}"
    echo -e "${BLUE}========================================${NC}"
    if [ "$protect_flag" = "1" ]; then
        auto_ports=$(get_auto_allow_ports "$RULES_STATE_FILE") || return 1
        echo -e "保护状态: ${GREEN}已开启${NC}"
        echo -e "当前放行端口: ${YELLOW}${auto_ports}${NC}"
        case "$protect_noping" in
            0) echo -e "Ping: ${GREEN}允许${NC}" ;;
            1) echo -e "Ping: ${RED}已禁止${NC}" ;;
            *) echo -e "Ping: ${YELLOW}仅允许 $protect_noping${NC}" ;;
        esac
    else
        echo -e "保护状态: ${RED}未开启${NC}"
    fi
    case "$timer_status" in
        active) echo -e "自动同步: ${GREEN}已启用${NC}" ;;
        inactive) echo -e "自动同步: ${YELLOW}未启用${NC}" ;;
        *) echo -e "自动同步: ${YELLOW}systemctl 不可用${NC}" ;;
    esac
    echo -e "${BLUE}========================================${NC}"
}

rule_extra_text() {
    local snat_ip="$1" mss="$2" extra=""
    [ -n "$snat_ip" ] && extra="${extra} SNAT: ${BLUE}${snat_ip}${NC}"
    [ -n "$mss" ] && extra="${extra} MSS: ${BLUE}${mss}${NC}"
    echo "$extra"
}

show_ddns_rules() {
    local count=1 domain resolved_ip status updated_at refs
    prepare_state_file_for_read
    [ "$(state_domain_count "$RULES_STATE_FILE")" -gt 0 ] || { log_warn "未找到 DDNS 域名规则"; return 0; }
    echo -e "${YELLOW}=== DDNS 域名规则状态 ===${NC}"
    while IFS='|' read -r domain resolved_ip status updated_at refs; do
        echo -e "${GREEN}${count})${NC} 域名: ${YELLOW}${domain}${NC} 当前IP: ${BLUE}${resolved_ip:-未解析}${NC} 状态: ${BLUE}${status:-unknown}${NC} 更新时间: ${BLUE}$(format_epoch_time "$updated_at")${NC} 转发: ${YELLOW}${refs}${NC}"
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
    prepare_state_file_for_read
    [ -s "$RULES_STATE_FILE" ] || { log_warn "未找到转发规则"; return 0; }
    echo -e "${YELLOW}=== 端口转发规则 ===${NC}"
    while IFS='|' read -r src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss; do
        [ -n "$src_port$mode$target$dest_port" ] || continue
        extra=$(rule_extra_text "$snat_ip" "$mss")
        if [ "$mode" = "local" ]; then
            echo -e "${GREEN}${count})${NC} ${BLUE}[本地]${NC} 端口: ${YELLOW}${src_port}${NC} -> ${YELLOW}${target}:${dest_port}${NC} (${BLUE}TCP+UDP${NC})"
        elif [ "$target_type" = "domain" ]; then
            echo -e "${GREEN}${count})${NC} 端口: ${YELLOW}${src_port}${NC} -> 域名: ${YELLOW}${target}:${dest_port}${NC} 当前IP: ${BLUE}${resolved_ip:-未解析}${NC} 状态: ${BLUE}${status:-unknown}${NC}${extra}"
        else
            echo -e "${GREEN}${count})${NC} 端口: ${YELLOW}${src_port}${NC} -> 目标: ${YELLOW}${target}:${dest_port}${NC} (${BLUE}TCP+UDP${NC})${extra}"
        fi
        count=$((count + 1))
    done < "$RULES_STATE_FILE"
    echo ""
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
    log_info_noisy "$desc"
    "$@"
}

run_rule_batch_command() {
    local action="$1" desc_prefix="$2" desc_suffix="$3" allow_noping="$4" protect_noping=""
    shift 4
    case "${1:-}" in
        noping) protect_noping=1 ;;
        noping=*)
            protect_noping="${1#noping=}"
            validate_noping_spec "$protect_noping" || { log_error "noping 白名单格式无效: $protect_noping"; return 1; }
            ;;
        *) protect_noping="" ;;
    esac
    if [ -n "$protect_noping" ]; then
        [ "$allow_noping" = "1" ] || { log_error "当前命令不支持 noping 参数"; return 1; }
        shift
    fi
    [ $# -gt 0 ] || { log_error "未提供任何规则"; show_help; return 1; }
    ensure_for_write || return 1
    run_mutation "${desc_prefix} $# ${desc_suffix}" rule_batch "$action" "$protect_noping" "$@"
}

ensure_for_read() {
    ensure_supported_bash || return 1
    prepare_state_file_for_read
}

ensure_for_write() {
    ensure_supported_bash || return 1
    require_root || return 1
    ensure_dependencies || return 1
    prepare_state_file || return 1
}

ensure_for_uninstall() {
    ensure_supported_bash || return 1
    require_root || return 1
}

main() {
    local protect_noping
    ensure_supported_bash || exit 1
    [ $# -eq 0 ] && { log_error "请使用参数模式执行，例如: $0 --help"; show_help; exit 1; }
    case "$1" in
        --help|-h) show_help ;;
        --list|-l) ensure_for_read && display_rules || exit 1 ;;
        --add|-a) shift; run_rule_batch_command add "准备批量添加" "条转发规则..." 1 "$@" || exit 1 ;;
        --delete|-d) shift; run_rule_batch_command delete "准备批量删除" "条转发规则..." 0 "$@" || exit 1 ;;
        --replace|-r) shift; run_rule_batch_command replace "准备原子替换为" "条新规则..." 1 "$@" || exit 1 ;;
        --ddns)
            shift
            [ $# -gt 0 ] || { log_error "未提供 DDNS 模式参数"; show_help; exit 1; }
            case "$1" in
                sync) ensure_for_write && run_mutation "开始执行 DDNS 同步..." sync_ddns_rules || exit 1 ;;
                apply) ensure_for_write && run_mutation "正在应用 DDNS 缓存..." apply_ddns_cache || exit 1 ;;
                list) ensure_for_read && show_ddns_rules || exit 1 ;;
                run) ensure_supported_bash && require_root && providerdns_refresh_hooks || exit 1 ;;
                *) log_error "未知的 DDNS 模式参数: $1"; exit 1 ;;
            esac
            ;;
        --uninstall|--unistall|-u) ensure_for_uninstall && run_mutation "正在清理 nftables.sh 产物..." uninstall_forwardaws || exit 1 ;;
        --protect|-p)
            shift
            [ $# -gt 0 ] || { log_error "未提供保护模式参数"; show_help; exit 1; }
            case "$1" in
                on)
                    shift
                    case "${1:-}" in
                        "") protect_noping=0 ;;
                        noping) protect_noping=1; shift ;;
                        noping=*)
                            protect_noping="${1#noping=}"
                            validate_noping_spec "$protect_noping" || { log_error "noping 白名单格式无效: $protect_noping"; exit 1; }
                            shift
                            ;;
                        *) log_error "未知的保护模式参数: $1"; exit 1 ;;
                    esac
                    [ $# -eq 0 ] || { log_error "保护模式 on 不支持额外参数: $*"; exit 1; }
                    ensure_for_write && run_mutation "正在开启端口保护模式..." enable_protection "$protect_noping" && show_protection_status || exit 1
                    ;;
                off)
                    [ $# -eq 1 ] || { log_error "保护模式 off 不支持额外参数: ${*:2}"; exit 1; }
                    ensure_for_write && run_mutation "正在关闭端口保护模式..." disable_protection && show_protection_status || exit 1
                    ;;
                status)
                    [ $# -eq 1 ] || { log_error "保护模式 status 不支持额外参数: ${*:2}"; exit 1; }
                    ensure_for_read && show_protection_status || exit 1
                    ;;
                sync)
                    [ $# -eq 1 ] || { log_error "保护模式 sync 不支持额外参数: ${*:2}"; exit 1; }
                    ensure_for_write && run_mutation "正在同步端口保护..." sync_protection_ports || exit 1
                    ;;
                *) log_error "未知的保护模式参数: $1"; exit 1 ;;
            esac
            ;;
        *) log_error "未知参数: $1"; show_help; exit 1 ;;
    esac
}

main "$@"
