#!/bin/bash

# ============================================================================
# NFTables 端口转发与保护管理工具
# 架构：状态文件是唯一真相源，每次变更全量渲染 nft ruleset 并原子应用
# 运行环境：Debian/Ubuntu，依赖 bash、nftables、util-linux、procfs
# ============================================================================

set -o pipefail

readonly LEGACY_TABLE_NAME="forwardaws"
readonly NAT_TABLE_NAME="forwardaws_nat"
readonly FILTER_TABLE_NAME="forwardaws_filter"

readonly CHAIN_PREROUTING="prerouting"
readonly CHAIN_POSTROUTING="postrouting"
readonly CHAIN_OUTPUT="output"
readonly CHAIN_INPUT="input"
readonly CHAIN_FORWARD="forward"

readonly NFT_MAIN_CONFIG_FILE="/etc/nftables.conf"
readonly NFT_INCLUDE_DIR="/etc/nftables.d"
readonly FORWARDAWS_RULES_FILE="${NFT_INCLUDE_DIR}/forwardaws.nft"
readonly STATE_DIR="/etc/forwardaws"
readonly RULES_STATE_FILE="${STATE_DIR}/rules.db"
readonly LEGACY_DDNS_STATE_FILE="${STATE_DIR}/ddns-rules.db"
readonly CONFIG_FILE="${STATE_DIR}/config.env"
readonly GLOBAL_LOCK_FILE="/run/forwardaws.lock"
readonly IPV4_FORWARD_SYSCTL_FILE="/etc/sysctl.d/99-forwardaws.conf"

readonly DDNS_SERVICE_NAME="forwardaws-ddns.service"
readonly DDNS_TIMER_NAME="forwardaws-ddns.timer"
readonly PROTECT_SERVICE_NAME="forwardaws-protect.service"
readonly PROTECT_TIMER_NAME="forwardaws-protect.timer"

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

log_info()  { printf '%b\n' "${GREEN}[INFO]${NC} $1"; }
log_warn()  { printf '%b\n' "${YELLOW}[WARNING]${NC} $1" >&2; }
log_error() { printf '%b\n' "${RED}[ERROR]${NC} $1" >&2; }

quiet_mode() {
    [ "${FORWARDAWS_QUIET:-0}" = "1" ]
}

log_info_noisy() {
    quiet_mode || log_info "$1"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_ip_address() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1

    local IFS='.'
    local octet
    local -a octets
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
}

validate_domain_name() {
    local domain="$1"
    [ -n "$domain" ] || return 1
    [ "${#domain}" -le 253 ] || return 1
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

resolve_ddns_ipv4() {
    local domain="$1"
    local ip=""

    ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk '/STREAM/ {print $1; exit}')

    validate_ip_address "$ip" || return 1
    echo "$ip"
}

format_epoch_time() {
    local ts="$1"
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
        date -d "@$ts" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || echo "$ts"
    else
        echo "$ts"
    fi
}

get_script_absolute_path() {
    local resolved=""

    if command -v readlink >/dev/null 2>&1; then
        resolved=$(readlink -f "$0" 2>/dev/null)
    fi
    if [ -z "$resolved" ] && command -v realpath >/dev/null 2>&1; then
        resolved=$(realpath "$0" 2>/dev/null)
    fi
    if [ -z "$resolved" ]; then
        local base_dir
        base_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
        resolved="${base_dir}/$(basename "$0")"
    fi

    echo "$resolved"
}

require_root() {
    [ "$EUID" -eq 0 ] && return 0
    log_error "此操作必须以 root 权限运行"
    return 1
}

ensure_supported_bash() {
    local major="${BASH_VERSINFO[0]:-0}"
    if [ "$major" -lt 3 ]; then
        log_error "此脚本要求 Bash >= 3（当前: ${BASH_VERSION:-unknown}）"
        return 1
    fi
}

APT_UPDATED=0

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
    local command_name
    local package_name

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
    local lock_wait="${FORWARDAWS_LOCK_WAIT:-0}"
    local lock_error="检测到其他任务正在执行中，请稍后重试"

    [ "$FORWARDAWS_LOCK_HELD" = "1" ] && return 0
    exec 9>"$GLOBAL_LOCK_FILE" || {
        log_error "无法创建全局锁文件: $GLOBAL_LOCK_FILE"
        return 1
    }

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
    if ! systemctl is-enabled nftables.service >/dev/null 2>&1; then
        systemctl enable nftables.service >/dev/null 2>&1 && \
            log_info_noisy "已启用 nftables.service 开机自启" || \
            log_warn "无法启用 nftables.service，重启后规则可能丢失"
    fi
}

nft_main_config_has_forwardaws_include() {
    [ -f "$NFT_MAIN_CONFIG_FILE" ] || return 1
    grep -Eq '^[[:space:]]*include[[:space:]]+"(/etc/nftables\.d/\*\.nft|/etc/nftables\.d/forwardaws\.nft)"' "$NFT_MAIN_CONFIG_FILE"
}

ensure_nft_main_config_include() {
    local include_line='include "/etc/nftables.d/*.nft"'

    if ! nft_main_config_has_forwardaws_include; then
        touch "$NFT_MAIN_CONFIG_FILE" 2>/dev/null || {
            log_error "无法访问主配置文件: $NFT_MAIN_CONFIG_FILE"
            return 1
        }
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
        grep -q 'net.ipv4.ip_forward=1' "$IPV4_FORWARD_SYSCTL_FILE" 2>/dev/null && \
        return 1
    return 0
}

get_config_value() {
    local key="$1"
    local default="$2"
    [ -f "$CONFIG_FILE" ] || { echo "$default"; return 0; }
    awk -F= -v k="$key" -v d="$default" '$1==k { print $2; found=1; exit } END { if (!found) print d }' "$CONFIG_FILE"
}

get_protection_flag() {
    get_config_value "PROTECTION_ENABLED" "0"
}

write_config_file() {
    local target="$1"
    local protect_flag="$2"

    {
        echo "PROTECTION_ENABLED=${protect_flag}"
    } > "$target"
}

normalize_ports() {
    local ports="$1"
    echo "$ports" | tr -d ' ' | tr ',' '\n' | awk 'NF>0' | sort -un | tr '\n' ',' | sed 's/,$//'
}

is_port_in_list() {
    local port="$1"
    local list="$2"
    [ -n "$port" ] && [ -n "$list" ] && [[ ",$list," == *",$port,"* ]]
}

get_exclude_ports() {
    local combined="$DEFAULT_EXCLUDE_PORTS"
    [ -n "${FORWARDAWS_EXCLUDE_PORTS:-}" ] && combined="${combined},${FORWARDAWS_EXCLUDE_PORTS}"

    local valid_ports=""
    local port=""
    local -a ports_arr
    IFS=',' read -ra ports_arr <<< "$(normalize_ports "$combined")"
    for port in "${ports_arr[@]}"; do
        validate_port "$port" || continue
        valid_ports="${valid_ports}${valid_ports:+,}${port}"
    done

    echo "$valid_ports"
}

apply_exclude_ports_filter() {
    local ports
    local exclude_ports
    local filtered=""
    local port=""
    local -a ports_arr

    ports=$(normalize_ports "$1")
    exclude_ports=$(normalize_ports "$2")
    [ -n "$ports" ] || { echo ""; return 0; }
    [ -n "$exclude_ports" ] || { echo "$ports"; return 0; }

    IFS=',' read -ra ports_arr <<< "$ports"
    for port in "${ports_arr[@]}"; do
        validate_port "$port" || continue
        is_port_in_list "$port" "$exclude_ports" && continue
        filtered="${filtered}${filtered:+,}${port}"
    done

    echo "$filtered"
}

detect_ssh_ports() {
    command -v sshd >/dev/null 2>&1 || { echo ""; return 0; }
    sshd -T 2>/dev/null | awk '$1=="port" && $2 ~ /^[0-9]+$/ && $2>=1 && $2<=65535 { print $2 }' | sort -un | tr '\n' ',' | sed 's/,$//'
}

parse_local_endpoint() {
    local endpoint="$1"
    local addr="$endpoint"
    local port=""

    if [[ "$endpoint" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
        addr="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        addr="${endpoint%:*}"
        port="${endpoint##*:}"
    fi

    addr="${addr%%\%*}"
    echo "${addr}|${port}"
}

is_loopback_address() {
    local addr="$1"
    [[ "$addr" == "::1" ]] && return 0
    [[ "$addr" =~ ^127\. ]] && return 0
    return 1
}

detect_runtime_public_ports() {
    command -v ss >/dev/null 2>&1 || {
        log_error "缺失依赖: ss"
        return 1
    }

    local ports=""
    local endpoint=""
    while IFS= read -r endpoint; do
        [ -n "$endpoint" ] || continue

        local parsed=""
        local addr=""
        local port=""
        parsed=$(parse_local_endpoint "$endpoint")
        IFS='|' read -r addr port <<< "$parsed"

        validate_port "$port" || continue
        is_loopback_address "$addr" && continue
        ports="${ports}${ports:+,}${port}"
    done < <(
        ss -H -ltn 2>/dev/null | awk '{print $(NF-1)}'
    )

    normalize_ports "$ports"
}

get_forwarding_ports_from_file() {
    local file="$1"
    [ -s "$file" ] || { echo ""; return 0; }
    awk -F'|' 'NF>=8 && $1 ~ /^[0-9]+$/ { print $1 }' "$file" | sort -un | tr '\n' ',' | sed 's/,$//'
}

get_auto_allow_ports() {
    local state_file="${1:-$RULES_STATE_FILE}"
    local ssh_ports
    local forward_ports
    local runtime_ports
    local exclude_ports
    local merged
    local filtered
    local port
    local -a ssh_ports_arr

    ssh_ports=$(detect_ssh_ports)
    forward_ports=$(get_forwarding_ports_from_file "$state_file")
    runtime_ports=$(detect_runtime_public_ports) || return 1
    exclude_ports=$(get_exclude_ports)

    merged="$ssh_ports"
    [ -n "$forward_ports" ] && merged="${merged},${forward_ports}"
    [ -n "$runtime_ports" ] && merged="${merged},${runtime_ports}"
    merged=$(normalize_ports "$merged")

    filtered=$(apply_exclude_ports_filter "$merged" "$exclude_ports")
    IFS=',' read -ra ssh_ports_arr <<< "$ssh_ports"
    for port in "${ssh_ports_arr[@]}"; do
        validate_port "$port" || continue
        is_port_in_list "$port" "$filtered" || filtered=$(normalize_ports "${filtered},${port}")
    done

    echo "$filtered"
}

# 解析规则，输出全局变量：
# PARSED_SRC_PORT / PARSED_MODE / PARSED_TARGET / PARSED_DEST_PORT / PARSED_TYPE / PARSED_IP / PARSED_SNAT_IP / PARSED_MSS
parse_rule() {
    local rule_string="$1"
    local resolve_domain="${2:-1}"

    PARSED_SRC_PORT=""
    PARSED_MODE=""
    PARSED_TARGET=""
    PARSED_DEST_PORT=""
    PARSED_TYPE=""
    PARSED_IP=""
    PARSED_SNAT_IP=""
    PARSED_MSS=""

    if [[ ! "$rule_string" =~ ^[^:]+:[^:]+:[^:]+(:[^:]+(:[^:]+)?)?$ ]]; then
        log_error "规则格式错误: $rule_string (正确格式: 端口:目标(IPv4/域名/local):端口[:SNAT_IP[:MSS]])"
        return 1
    fi

    local src_port=""
    local target=""
    local dest_port=""
    local snat_ip=""
    local mss=""
    IFS=':' read -r src_port target dest_port snat_ip mss <<< "$rule_string"

    validate_port "$src_port" || {
        log_error "无效的源端口: $src_port"
        return 1
    }
    validate_port "$dest_port" || {
        log_error "无效的目标端口: $dest_port"
        return 1
    }
    if [ -n "$snat_ip" ]; then
        validate_ip_address "$snat_ip" || {
            log_error "无效的 SNAT IP: $snat_ip"
            return 1
        }
    fi
    if [ -n "$mss" ]; then
        if [ "$mss" = "auto" ]; then
            :
        elif ! [[ "$mss" =~ ^[0-9]+$ ]] || [ "$mss" -lt 536 ] || [ "$mss" -gt 9000 ]; then
            log_error "无效的 MSS: $mss (必须为 auto 或 536-9000 之间的数字)"
            return 1
        fi
    fi

    if [[ "$target" == "local" || "$target" == "localhost" || "$target" == "127.0.0.1" ]]; then
        if [ -n "$snat_ip$mss" ]; then
            log_error "本地转发不支持 SNAT/MSS 扩展字段: $rule_string"
            return 1
        fi
        PARSED_MODE="local"
        PARSED_TARGET="127.0.0.1"
        PARSED_TYPE="local"
        PARSED_IP="127.0.0.1"
    elif validate_ip_address "$target"; then
        PARSED_MODE="remote"
        PARSED_TARGET="$target"
        PARSED_TYPE="ipv4"
        PARSED_IP="$target"
    elif validate_domain_name "$target"; then
        PARSED_MODE="remote"
        PARSED_TARGET="$target"
        PARSED_TYPE="domain"
        if [ "$resolve_domain" = "1" ]; then
            PARSED_IP=$(resolve_ddns_ipv4 "$target") || {
                log_error "域名解析失败: $target"
                return 1
            }
        fi
    else
        log_error "无效的目标地址: $target"
        return 1
    fi

    PARSED_SRC_PORT="$src_port"
    PARSED_DEST_PORT="$dest_port"
    PARSED_SNAT_IP="$snat_ip"
    PARSED_MSS="$mss"
}

make_state_line() {
    local src_port="$1"
    local mode="$2"
    local target="$3"
    local dest_port="$4"
    local target_type="$5"
    local resolved_ip="$6"
    local status="$7"
    local updated_at="$8"
    local snat_ip="${9:-}"
    local mss="${10:-}"
    echo "${src_port}|${mode}|${target}|${dest_port}|${target_type}|${resolved_ip}|${status}|${updated_at}|${snat_ip}|${mss}"
}

state_rule_exact_exists() {
    local file="$1"
    local src_port="$2"
    local mode="$3"
    local target="$4"
    local dest_port="$5"
    local snat_ip="${6:-}"
    local mss="${7:-}"

    [ -s "$file" ] || return 1
    awk -F'|' -v sp="$src_port" -v mode="$mode" -v target="$target" -v dp="$dest_port" -v snat="$snat_ip" -v mss="$mss" \
        'NF>=8 && $1==sp && $2==mode && $3==target && $4==dp && $9==snat && $10==mss { found=1; exit } END { exit(found ? 0 : 1) }' "$file"
}

state_base_rule_exists() {
    local file="$1"
    local src_port="$2"
    local mode="$3"
    local target="$4"
    local dest_port="$5"

    [ -s "$file" ] || return 1
    awk -F'|' -v sp="$src_port" -v mode="$mode" -v target="$target" -v dp="$dest_port" \
        'NF>=8 && $1==sp && $2==mode && $3==target && $4==dp { found=1; exit } END { exit(found ? 0 : 1) }' "$file"
}

state_port_conflicts() {
    local file="$1"
    local src_port="$2"
    local mode="$3"
    local target="$4"
    local dest_port="$5"

    [ -s "$file" ] || return 1
    awk -F'|' -v sp="$src_port" -v mode="$mode" -v target="$target" -v dp="$dest_port" '
        NF>=8 && $1==sp && !($2==mode && $3==target && $4==dp) { found=1; exit }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

state_domain_count() {
    local file="${1:-$RULES_STATE_FILE}"
    [ -s "$file" ] || { echo 0; return 0; }
    awk -F'|' 'NF>=8 && $5=="domain" { count++ } END { print count+0 }' "$file"
}

state_has_remote_rules() {
    local file="$1"
    [ -s "$file" ] || return 1
    awk -F'|' 'NF>=8 && $2=="remote" { found=1; exit } END { exit(found ? 0 : 1) }' "$file"
}

migrate_legacy_ddns_state() {
    [ ! -f "$RULES_STATE_FILE" ] || return 0
    [ -s "$LEGACY_DDNS_STATE_FILE" ] || return 0

    local tmp_file="${RULES_STATE_FILE}.migrate.$$"
    local migrated=0
    ensure_state_dir || return 1

    while IFS='|' read -r src_port domain dest_port last_ip status updated_at; do
        validate_port "$src_port" || continue
        validate_port "$dest_port" || continue
        validate_domain_name "$domain" || continue
        validate_ip_address "$last_ip" || continue
        make_state_line "$src_port" "remote" "$domain" "$dest_port" "domain" "$last_ip" "${status:-ok}" "${updated_at:-$(date +%s)}" >> "$tmp_file"
        migrated=$((migrated + 1))
    done < "$LEGACY_DDNS_STATE_FILE"

    if [ "$migrated" -gt 0 ]; then
        mv "$tmp_file" "$RULES_STATE_FILE" || {
            rm -f "$tmp_file"
            return 1
        }
        log_info "已从旧 DDNS 状态迁移 ${migrated} 条域名规则"
    else
        rm -f "$tmp_file"
    fi
}

prepare_state_file() {
    ensure_state_dir || return 1
    migrate_legacy_ddns_state || return 1
    [ -f "$RULES_STATE_FILE" ] || : > "$RULES_STATE_FILE"
}

copy_current_state_to() {
    local target="$1"
    prepare_state_file || return 1
    cp "$RULES_STATE_FILE" "$target"
}

render_delete_headers() {
    cat << EOF
#!/usr/sbin/nft -f
# forwardaws generated by nftables.sh

table ip ${LEGACY_TABLE_NAME}
delete table ip ${LEGACY_TABLE_NAME}
table ip6 ${LEGACY_TABLE_NAME}
delete table ip6 ${LEGACY_TABLE_NAME}
table ip ${NAT_TABLE_NAME}
delete table ip ${NAT_TABLE_NAME}
table inet ${FILTER_TABLE_NAME}
delete table inet ${FILTER_TABLE_NAME}
EOF
}

render_nat_table() {
    local state_file="$1"

    cat << EOF

table ip ${NAT_TABLE_NAME} {
    chain ${CHAIN_PREROUTING} {
        type nat hook prerouting priority -100; policy accept;
EOF

    awk -F'|' 'NF>=8 && $2=="remote" && $6 ~ /^[0-9.]+$/ {
        printf "        tcp dport %s dnat to %s:%s\n", $1, $6, $4
        printf "        udp dport %s dnat to %s:%s\n", $1, $6, $4
    }' "$state_file"

    cat << EOF
    }

    chain ${CHAIN_OUTPUT} {
        type nat hook output priority -100; policy accept;
EOF

    awk -F'|' 'NF>=8 && $2=="local" && $6 ~ /^[0-9.]+$/ {
        printf "        tcp dport %s dnat to %s:%s\n", $1, $6, $4
        printf "        udp dport %s dnat to %s:%s\n", $1, $6, $4
    }' "$state_file"

    cat << EOF
    }

    chain ${CHAIN_POSTROUTING} {
        type nat hook postrouting priority 100; policy accept;
EOF

    awk -F'|' 'NF>=8 && $2=="remote" && $6 ~ /^[0-9.]+$/ {
        if ($9 != "") {
            printf "        ip daddr %s tcp dport %s snat to %s\n", $6, $4, $9
            printf "        ip daddr %s udp dport %s snat to %s\n", $6, $4, $9
        } else {
            printf "        ct status dnat ip daddr %s tcp dport %s masquerade\n", $6, $4
            printf "        ct status dnat ip daddr %s udp dport %s masquerade\n", $6, $4
        }
    }' "$state_file"

    cat << EOF
    }
}
EOF
}

render_filter_table() {
    local state_file="$1"
    local protect_flag="$2"
    local allow_ports="${3:-}"
    local remote_ips
    local has_mss

    remote_ips=$(awk -F'|' 'NF>=8 && $2=="remote" && $6 ~ /^[0-9.]+$/ { print $6 }' "$state_file" | sort -u | tr '\n' ',' | sed 's/,$//')
    has_mss=$(awk -F'|' 'NF>=10 && $10 != "" { found=1; exit } END { print found ? 1 : 0 }' "$state_file")

    if [ "$protect_flag" != "1" ] && [ -z "$remote_ips" ] && [ "$has_mss" != "1" ]; then
        return 0
    fi

    cat << EOF

table inet ${FILTER_TABLE_NAME} {
EOF

    if [ "$has_mss" = "1" ]; then
        cat << EOF
    chain forward_mss {
        type filter hook forward priority -150; policy accept;
EOF

        awk -F'|' 'NF>=10 && $2=="remote" && $6 ~ /^[0-9.]+$/ && $10 != "" {
            if ($10 == "auto") {
                printf "        ip daddr %s tcp dport %s tcp flags syn tcp option maxseg size set rt mtu\n", $6, $4
            } else {
                printf "        ip daddr %s tcp dport %s tcp flags syn tcp option maxseg size set %s\n", $6, $4, $10
            }
        }' "$state_file"

        cat << EOF
    }
EOF
    fi

    if [ "$protect_flag" = "1" ]; then
        [ -n "$allow_ports" ] || allow_ports=$(get_auto_allow_ports "$state_file") || return 1
        if [ -z "$allow_ports" ]; then
            log_error "保护端口列表为空，拒绝渲染保护链"
            return 1
        fi

        cat << EOF
    chain ${CHAIN_INPUT} {
        type filter hook input priority 0; policy drop;
        iifname "lo" accept
        ct state established,related accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        tcp dport { ${allow_ports} } accept
        udp dport { ${allow_ports} } accept
    }
EOF
    fi

    if [ -n "$remote_ips" ]; then
        cat << EOF
    chain ${CHAIN_FORWARD} {
        type filter hook forward priority 0; policy accept;
        ct state established,related accept
EOF

        awk -F'|' 'NF>=8 && $2=="remote" && $6 ~ /^[0-9.]+$/ {
            printf "        ct status dnat ip daddr %s tcp dport %s accept\n", $6, $4
            printf "        ct status dnat ip daddr %s udp dport %s accept\n", $6, $4
        }' "$state_file"

        cat << EOF
    }
EOF
    fi

    echo "}"
}

render_ruleset() {
    local state_file="$1"
    local protect_flag="$2"
    local output_file="$3"
    local protect_ports="${4:-}"

    {
        render_delete_headers
        render_nat_table "$state_file"
        render_filter_table "$state_file" "$protect_flag" "$protect_ports"
    } > "$output_file"
}

run_nft_file() {
    local check_flag="$1"
    local label="$2"
    local file="$3"
    local desc="$4"
    local output

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
    local candidate_state="$1"
    local protect_flag="$2"
    local desc="$3"
    local protect_ports="${4:-}"
    local nft_tmp
    local state_tmp
    local config_tmp
    local rules_changed=0
    local include_missing=0
    local forwarding_needs_update=0

    ensure_state_dir || return 1
    if [ "$protect_flag" = "1" ] && [ -z "$protect_ports" ]; then
        protect_ports=$(get_auto_allow_ports "$candidate_state") || return 1
    fi

    nft_tmp="${FORWARDAWS_RULES_FILE}.tmp.$$"
    render_ruleset "$candidate_state" "$protect_flag" "$nft_tmp" "$protect_ports" || {
        rm -f "$nft_tmp"
        return 1
    }

    if state_has_remote_rules "$candidate_state"; then
        ipv4_forwarding_needs_update && forwarding_needs_update=1
    fi

    state_tmp="${RULES_STATE_FILE}.tmp.$$"
    config_tmp="${CONFIG_FILE}.tmp.$$"
    cp "$candidate_state" "$state_tmp" || {
        rm -f "$nft_tmp" "$state_tmp"
        log_error "写入状态临时文件失败"
        return 1
    }
    write_config_file "$config_tmp" "$protect_flag" || {
        rm -f "$nft_tmp" "$state_tmp" "$config_tmp"
        log_error "写入配置临时文件失败"
        return 1
    }

    cmp -s "$nft_tmp" "$FORWARDAWS_RULES_FILE" || rules_changed=1
    nft_main_config_has_forwardaws_include || include_missing=1

    if [ "$rules_changed$include_missing$forwarding_needs_update" = "000" ] && \
        cmp -s "$state_tmp" "$RULES_STATE_FILE" && cmp -s "$config_tmp" "$CONFIG_FILE"; then
        rm -f "$nft_tmp" "$state_tmp" "$config_tmp"
        return 0
    fi

    if [ "$rules_changed" -eq 1 ]; then
        run_nft_file "-c" "预检" "$nft_tmp" "$desc" || { rm -f "$nft_tmp" "$state_tmp" "$config_tmp"; return 1; }
    fi

    if [ "$forwarding_needs_update" -eq 1 ]; then
        ensure_ipv4_forwarding_enabled || { rm -f "$nft_tmp" "$state_tmp" "$config_tmp"; return 1; }
    fi

    if [ "$rules_changed" -eq 1 ]; then
        run_nft_file "" "应用" "$nft_tmp" "$desc" || {
            rm -f "$nft_tmp" "$state_tmp" "$config_tmp"
            return 1
        }
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

install_systemd_units_if_needed() {
    local service_name="$1"
    local timer_name="$2"
    local service_desc="$3"
    local timer_desc="$4"
    local exec_args="$5"
    local script_path
    local service_file="/etc/systemd/system/${service_name}"
    local timer_file="/etc/systemd/system/${timer_name}"

    command -v systemctl >/dev/null 2>&1 || return 1
    script_path=$(get_script_absolute_path)
    [ -n "$script_path" ] || {
        log_error "无法确定脚本绝对路径，systemd 定时器安装失败"
        return 1
    }

    cat > "$service_file" << EOF || { log_error "写入 systemd service 失败: $service_file"; return 1; }
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

    cat > "$timer_file" << EOF || { log_error "写入 systemd timer 失败: $timer_file"; return 1; }
[Unit]
Description=${timer_desc}

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=${service_name}

[Install]
WantedBy=timers.target
EOF

    chmod 644 "$service_file" "$timer_file" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1
}

has_systemctl() {
    command -v systemctl >/dev/null 2>&1
}

enable_timer_if_available() {
    local service_name="$1"
    local timer_name="$2"
    local service_desc="$3"
    local timer_desc="$4"
    local exec_args="$5"
    local success_msg="$6"
    local fail_msg="$7"

    has_systemctl || { log_error "未检测到 systemctl，无法启用自动同步"; return 1; }
    install_systemd_units_if_needed "$service_name" "$timer_name" "$service_desc" "$timer_desc" "$exec_args" || return 1
    if systemctl is-enabled --quiet "$timer_name" 2>/dev/null && systemctl is-active --quiet "$timer_name" 2>/dev/null; then
        return 0
    fi

    if systemctl enable --now "$timer_name" >/dev/null 2>&1; then
        log_info_noisy "$success_msg"
        return 0
    fi

    log_warn "$fail_msg"
    return 1
}

disable_timer_if_available() {
    local timer_name="$1"
    local success_msg="$2"

    has_systemctl || return 0
    if systemctl disable --now "$timer_name" >/dev/null 2>&1; then
        log_info_noisy "$success_msg"
    fi
}

reconcile_timers() {
    local domain_count
    local protect_flag

    domain_count=$(state_domain_count "$RULES_STATE_FILE")
    protect_flag=$(get_protection_flag)

    if [ "$domain_count" -gt 0 ]; then
        enable_timer_if_available \
            "$DDNS_SERVICE_NAME" \
            "$DDNS_TIMER_NAME" \
            "ForwardAWS DDNS sync service" \
            "Run ForwardAWS DDNS sync every 60 seconds" \
            "--ddns-sync" \
            "DDNS 定时同步已启用" \
            "启用 DDNS 定时同步失败，请手动检查 systemd 状态"
    else
        disable_timer_if_available "$DDNS_TIMER_NAME" "无 DDNS 域名规则，已停用 DDNS 定时同步"
    fi

    if [ "$protect_flag" = "1" ]; then
        enable_timer_if_available \
            "$PROTECT_SERVICE_NAME" \
            "$PROTECT_TIMER_NAME" \
            "ForwardAWS protection sync service" \
            "Run ForwardAWS protection sync every 60 seconds" \
            "--protect sync" \
            "保护端口自动同步已启用" \
            "启用保护同步定时器失败，请手动检查 systemd 状态"
    else
        disable_timer_if_available "$PROTECT_TIMER_NAME" "保护端口自动同步已停用"
    fi
}

get_protect_timer_status() {
    has_systemctl || { echo "unavailable"; return 0; }
    systemctl is-active --quiet "$PROTECT_TIMER_NAME" && { echo "active"; return 0; }
    echo "inactive"
}

append_rule_to_state() {
    local candidate="$1"
    local rule="$2"
    local now="$3"
    local duplicate_mode="$4"

    parse_rule "$rule" 1 || return 1
    if state_rule_exact_exists "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_SNAT_IP" "$PARSED_MSS"; then
        [ "$duplicate_mode" = "skip" ] && { log_warn "规则已存在，跳过: $rule"; return 2; }
        log_error "重复规则: $rule"
        return 1
    fi
    if state_port_conflicts "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT"; then
        [ "$duplicate_mode" = "skip" ] && log_error "端口冲突，跳过: $rule" || log_error "端口冲突: $rule"
        return 1
    fi
    make_state_line "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_TYPE" "$PARSED_IP" "ok" "$now" "$PARSED_SNAT_IP" "$PARSED_MSS" >> "$candidate"
}

remove_rule_from_state() {
    local candidate="$1"
    local rule="$2"
    local next_candidate

    parse_rule "$rule" 0 || return 1
    if ! state_base_rule_exists "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT"; then
        log_warn "规则不存在，跳过: $rule"
        return 2
    fi
    next_candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 3
    awk -F'|' -v sp="$PARSED_SRC_PORT" -v mode="$PARSED_MODE" -v target="$PARSED_TARGET" -v dp="$PARSED_DEST_PORT" \
        'NF>=8 && !($1==sp && $2==mode && $3==target && $4==dp) { print $0 }' "$candidate" > "$next_candidate" || {
        rm -f "$next_candidate"
        return 3
    }
    mv "$next_candidate" "$candidate" || return 3
}

finish_rule_batch() {
    local candidate="$1"
    local success="$2"
    local skipped="$3"
    local failed="$4"
    local protect_flag="$5"
    local desc="$6"
    local action="$7"
    local empty_action="$8"
    local show_status="${9:-0}"

    if [ "$success" -gt 0 ]; then
        apply_candidate_state "$candidate" "$protect_flag" "$desc" || { rm -f "$candidate"; return 1; }
        log_info "${action}完成: 成功 ${success} 条，跳过 ${skipped} 条，失败 ${failed} 条"
        reconcile_timers
        [ "$show_status" = "1" ] && show_protection_status
    else
        log_warn "没有${empty_action}: 跳过 ${skipped} 条，失败 ${failed} 条"
    fi

    rm -f "$candidate"
    [ "$failed" -eq 0 ]
}

add_rule_batch() {
    local -a rules=("$@")
    local candidate
    local now
    local success=0
    local skipped=0
    local failed=0
    local rule

    [ ${#rules[@]} -gt 0 ] || { log_error "未提供任何规则"; return 1; }
    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    copy_current_state_to "$candidate" || { rm -f "$candidate"; return 1; }
    now=$(date +%s)

    for rule in "${rules[@]}"; do
        log_info "处理规则: $rule"
        append_rule_to_state "$candidate" "$rule" "$now" "skip"
        case $? in
            0) success=$((success + 1)) ;;
            2) skipped=$((skipped + 1)) ;;
            3) rm -f "$candidate"; return 1 ;;
            *) failed=$((failed + 1)) ;;
        esac
    done

    finish_rule_batch "$candidate" "$success" "$skipped" "$failed" "1" "批量添加转发规则" "批量添加" "新增规则" "1"
}

delete_rule_batch() {
    local -a rules=("$@")
    local candidate
    local success=0
    local skipped=0
    local failed=0
    local rule

    [ ${#rules[@]} -gt 0 ] || { log_error "未提供任何规则"; return 1; }
    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    copy_current_state_to "$candidate" || { rm -f "$candidate"; return 1; }

    for rule in "${rules[@]}"; do
        log_info "处理规则: $rule"
        remove_rule_from_state "$candidate" "$rule"
        case $? in
            0) success=$((success + 1)) ;;
            2) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done

    finish_rule_batch "$candidate" "$success" "$skipped" "$failed" "$(get_protection_flag)" "批量删除转发规则" "批量删除" "删除规则"
}

replace_rules_batch() {
    local -a rules=("$@")
    local candidate
    local now
    local failed=0
    local rule

    [ ${#rules[@]} -gt 0 ] || { log_error "未提供任何规则"; return 1; }
    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    : > "$candidate"
    now=$(date +%s)

    for rule in "${rules[@]}"; do
        log_info "校验规则: $rule"
        append_rule_to_state "$candidate" "$rule" "$now" "fail" || failed=$((failed + 1))
    done

    if [ "$failed" -gt 0 ]; then
        rm -f "$candidate"
        log_error "替换前校验失败，已取消所有变更"
        return 1
    fi

    apply_candidate_state "$candidate" "1" "原子替换转发规则" || { rm -f "$candidate"; return 1; }
    log_info "原子替换完成，共应用 ${#rules[@]} 条规则"
    rm -f "$candidate"
    reconcile_timers
    show_protection_status
}

sync_ddns_rules() {
    local candidate
    local candidate_changed=0
    local changed=0
    local unchanged=0
    local failed=0
    local now

    prepare_state_file || return 1
    if [ "$(state_domain_count "$RULES_STATE_FILE")" -eq 0 ]; then
        log_info_noisy "未配置 DDNS 域名规则，无需同步"
        reconcile_timers
        return 0
    fi

    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    : > "$candidate"

    while IFS='|' read -r src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss; do
        [ -n "$src_port$mode$target$dest_port" ] || continue
        now=$(date +%s)

        if [ "$target_type" != "domain" ]; then
            make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$resolved_ip" "$status" "$updated_at" "$snat_ip" "$mss" >> "$candidate"
            continue
        fi

        local new_ip=""
        if new_ip=$(resolve_ddns_ipv4 "$target"); then
            if [ "$new_ip" = "$resolved_ip" ] && [ "$status" = "ok" ]; then
                make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$resolved_ip" "ok" "$updated_at" "$snat_ip" "$mss" >> "$candidate"
                unchanged=$((unchanged + 1))
            else
                make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$new_ip" "ok" "$now" "$snat_ip" "$mss" >> "$candidate"
                changed=$((changed + 1))
                log_info "DDNS 更新: ${target} ${resolved_ip:-N/A} -> ${new_ip}"
            fi
        else
            make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" "$resolved_ip" "resolve_failed" "$updated_at" "$snat_ip" "$mss" >> "$candidate"
            failed=$((failed + 1))
            log_warn "域名解析失败，保留原 IP: $target"
        fi
    done < "$RULES_STATE_FILE"

    cmp -s "$candidate" "$RULES_STATE_FILE" || candidate_changed=1

    apply_candidate_state "$candidate" "$(get_protection_flag)" "DDNS 同步" || { rm -f "$candidate"; return 1; }
    rm -f "$candidate"
    if [ "$candidate_changed" -eq 1 ]; then
        log_info "DDNS 同步完成: 更新 ${changed} 条，未变化 ${unchanged} 条，失败 ${failed} 条"
    else
        log_info_noisy "DDNS 同步完成: 无变化，未变化 ${unchanged} 条，失败 ${failed} 条"
    fi
    [ "$failed" -eq 0 ]
}

sync_protection_ports() {
    local candidate
    local protect_flag
    local current_ports

    protect_flag=$(get_protection_flag)
    if [ "$protect_flag" != "1" ]; then
        log_info_noisy "保护模式未开启，跳过端口同步"
        return 0
    fi

    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    copy_current_state_to "$candidate" || { rm -f "$candidate"; return 1; }
    current_ports=$(get_auto_allow_ports "$candidate") || { rm -f "$candidate"; return 1; }

    apply_candidate_state "$candidate" "1" "同步端口保护" "$current_ports" || { rm -f "$candidate"; return 1; }
    rm -f "$candidate"
    log_info_noisy "保护端口同步完成: $current_ports"
}

enable_protection() {
    local candidate
    local current_ports

    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    copy_current_state_to "$candidate" || { rm -f "$candidate"; return 1; }
    current_ports=$(get_auto_allow_ports "$candidate") || { rm -f "$candidate"; return 1; }
    apply_candidate_state "$candidate" "1" "开启端口保护" "$current_ports" || { rm -f "$candidate"; return 1; }
    rm -f "$candidate"
    reconcile_timers
    log_info "端口保护已开启，开放端口: $current_ports"
}

disable_protection() {
    local candidate

    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    copy_current_state_to "$candidate" || { rm -f "$candidate"; return 1; }
    apply_candidate_state "$candidate" "0" "关闭端口保护" || { rm -f "$candidate"; return 1; }
    rm -f "$candidate"
    reconcile_timers
    log_info "端口保护已关闭"
}

show_protection_status() {
    local protect_flag
    local timer_status
    local auto_ports

    prepare_state_file >/dev/null 2>&1 || true
    protect_flag=$(get_protection_flag)
    timer_status=$(get_protect_timer_status)

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}           端口保护状态${NC}"
    echo -e "${BLUE}========================================${NC}"

    if [ "$protect_flag" = "1" ]; then
        auto_ports=$(get_auto_allow_ports "$RULES_STATE_FILE") || return 1
        echo -e "保护状态: ${GREEN}已开启${NC}"
        echo -e "当前放行端口: ${YELLOW}${auto_ports}${NC}"
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

show_ddns_rules() {
    prepare_state_file || return 1
    if [ "$(state_domain_count "$RULES_STATE_FILE")" -eq 0 ]; then
        log_warn "未找到 DDNS 域名规则"
        return 0
    fi

    echo -e "${YELLOW}=== DDNS 域名规则状态 ===${NC}"
    local count=1
    while IFS='|' read -r src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss; do
        [ "$target_type" = "domain" ] || continue
        local extra=""
        [ -n "$snat_ip" ] && extra="${extra} SNAT: ${BLUE}${snat_ip}${NC}"
        [ -n "$mss" ] && extra="${extra} MSS: ${BLUE}${mss}${NC}"
        echo -e "${GREEN}${count})${NC} 源端口: ${YELLOW}${src_port}${NC} -> 域名: ${YELLOW}${target}${NC}:${YELLOW}${dest_port}${NC} 当前IP: ${BLUE}${resolved_ip:-N/A}${NC} 状态: ${BLUE}${status:-unknown}${NC} 更新时间: ${BLUE}$(format_epoch_time "$updated_at")${NC}${extra}"
        count=$((count + 1))
    done < "$RULES_STATE_FILE"
}

display_rules() {
    prepare_state_file || return 1
    if [ ! -s "$RULES_STATE_FILE" ]; then
        log_warn "未找到转发规则"
        return 0
    fi

    echo -e "${YELLOW}=== 端口转发规则 ===${NC}"
    local count=1
    while IFS='|' read -r src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss; do
        [ -n "$src_port$mode$target$dest_port" ] || continue
        local extra=""
        [ -n "$snat_ip" ] && extra="${extra} SNAT: ${BLUE}${snat_ip}${NC}"
        [ -n "$mss" ] && extra="${extra} MSS: ${BLUE}${mss}${NC}"
        if [ "$mode" = "local" ]; then
            echo -e "${GREEN}${count})${NC} ${BLUE}[本地]${NC} 端口: ${YELLOW}${src_port}${NC} -> ${YELLOW}${target}:${dest_port}${NC} (${BLUE}TCP+UDP${NC})"
        elif [ "$target_type" = "domain" ]; then
            echo -e "${GREEN}${count})${NC} 端口: ${YELLOW}${src_port}${NC} -> 域名: ${YELLOW}${target}:${dest_port}${NC} 当前IP: ${BLUE}${resolved_ip:-N/A}${NC} 状态: ${BLUE}${status:-unknown}${NC}${extra}"
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
  $0 --add <规则1> [规则2 ...]
  $0 --delete <规则1> [规则2 ...]
  $0 --replace <规则1> [规则2 ...]
  $0 --ddns-sync
  $0 --ddns-list
  $0 --protect on
  $0 --protect off
  $0 --protect status
  $0 --protect sync

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

ensure_for_read() {
    ensure_supported_bash || return 1
    prepare_state_file || return 1
}

ensure_for_write() {
    ensure_supported_bash || return 1
    require_root || return 1
    ensure_dependencies || return 1
    prepare_state_file || return 1
}

main() {
    ensure_supported_bash || exit 1
    [ $# -eq 0 ] && { show_help; exit 0; }

    case "$1" in
        --help|-h)
            show_help
            ;;
        --list|-l)
            ensure_for_read || exit 1
            display_rules || exit 1
            ;;
        --add|-a)
            shift
            [ $# -eq 0 ] && { log_error "未提供任何规则"; show_help; exit 1; }
            ensure_for_write || exit 1
            run_mutation "准备批量添加 $# 条转发规则..." add_rule_batch "$@" || exit 1
            ;;
        --delete|-d)
            shift
            [ $# -eq 0 ] && { log_error "未提供任何规则"; show_help; exit 1; }
            ensure_for_write || exit 1
            run_mutation "准备批量删除 $# 条转发规则..." delete_rule_batch "$@" || exit 1
            ;;
        --replace|-r)
            shift
            [ $# -eq 0 ] && { log_error "未提供任何规则"; show_help; exit 1; }
            ensure_for_write || exit 1
            run_mutation "准备原子替换为 $# 条新规则..." replace_rules_batch "$@" || exit 1
            ;;
        --ddns-sync)
            ensure_for_write || exit 1
            run_mutation "开始执行 DDNS 同步..." sync_ddns_rules || exit 1
            ;;
        --ddns-list)
            ensure_for_read || exit 1
            show_ddns_rules || exit 1
            ;;
        --protect|-p)
            shift
            [ $# -eq 0 ] && { log_error "未提供保护模式参数"; show_help; exit 1; }
            case "$1" in
                on)
                    ensure_for_write || exit 1
                    run_mutation "正在开启端口保护模式..." enable_protection || exit 1
                    show_protection_status || exit 1
                    ;;
                off)
                    ensure_for_write || exit 1
                    run_mutation "正在关闭端口保护模式..." disable_protection || exit 1
                    show_protection_status || exit 1
                    ;;
                status)
                    ensure_for_read || exit 1
                    show_protection_status || exit 1
                    ;;
                sync)
                    ensure_for_write || exit 1
                    run_mutation "正在同步端口保护..." sync_protection_ports || exit 1
                    ;;
                *)
                    log_error "未知的保护模式参数: $1"
                    exit 1
                    ;;
            esac
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
