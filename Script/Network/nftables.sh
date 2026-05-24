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

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

FORWARDAWS_LOCK_HELD=0

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

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
    if [ -z "$ip" ] && command -v dig >/dev/null 2>&1; then
        ip=$(dig +time=3 +tries=1 +short A "$domain" @1.1.1.1 2>/dev/null | head -n1)
    fi

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

ensure_dependencies() {
    local missing=""
    command -v nft >/dev/null 2>&1 || missing="${missing}${missing:+ }nft"
    command -v flock >/dev/null 2>&1 || missing="${missing}${missing:+ }flock"

    if [ -n "$missing" ]; then
        log_error "缺失依赖: $missing，请先安装: apt install -y nftables util-linux"
        return 1
    fi
}

ensure_runtime_tools() {
    command -v ss >/dev/null 2>&1 || log_warn "未检测到 ss，保护端口自动识别将忽略运行中监听端口"
    command -v dig >/dev/null 2>&1 || log_warn "未检测到 dig，域名解析仅使用 getent"
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR" "$NFT_INCLUDE_DIR"
}

acquire_global_lock() {
    [ "$FORWARDAWS_LOCK_HELD" = "1" ] && return 0
    exec 9>"$GLOBAL_LOCK_FILE" || {
        log_error "无法创建全局锁文件: $GLOBAL_LOCK_FILE"
        return 1
    }
    flock -n 9 || {
        log_error "检测到其他任务正在执行中，请稍后重试"
        return 1
    }
    FORWARDAWS_LOCK_HELD=1
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

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-enabled nftables.service >/dev/null 2>&1; then
            systemctl enable nftables.service >/dev/null 2>&1 && \
                log_info "已启用 nftables.service 开机自启" || \
                log_warn "无法启用 nftables.service，重启后规则可能丢失"
        fi
    fi
}

ensure_ipv4_forwarding_enabled() {
    local current
    current=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")

    if [ "$current" != "1" ]; then
        if command -v sysctl >/dev/null 2>&1 && sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
            log_info "已启用 net.ipv4.ip_forward=1（运行时）"
        elif [ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null; then
            log_info "已启用 /proc/sys/net/ipv4/ip_forward"
        else
            log_warn "无法自动启用 IP 转发，远程端口转发可能无法生效"
            return 1
        fi
    fi

    local sysctl_conf="/etc/sysctl.d/99-forwardaws.conf"
    if [ ! -f "$sysctl_conf" ] || ! grep -q 'net.ipv4.ip_forward=1' "$sysctl_conf" 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" > "$sysctl_conf" 2>/dev/null && \
            log_info "已持久化 net.ipv4.ip_forward=1 至 $sysctl_conf" || \
            log_warn "无法持久化 IP 转发设置，重启后可能失效"
    fi
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

detect_ssh_port() {
    local port=""
    if command -v sshd >/dev/null 2>&1; then
        port=$(sshd -T 2>/dev/null | awk '$1=="port" { print $2; exit }')
    fi
    validate_port "$port" || port="22"
    echo "$port"
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
    command -v ss >/dev/null 2>&1 || { echo ""; return 0; }

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
        {
            ss -H -ltn4 2>/dev/null
            ss -H -ltn6 2>/dev/null
        } | awk '{print $(NF-1)}'
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
    local ssh_port
    local forward_ports
    local runtime_ports
    local exclude_ports
    local merged
    local filtered

    ssh_port=$(detect_ssh_port)
    forward_ports=$(get_forwarding_ports_from_file "$state_file")
    runtime_ports=$(detect_runtime_public_ports)
    exclude_ports=$(get_exclude_ports)

    merged="$ssh_port"
    [ -n "$forward_ports" ] && merged="${merged},${forward_ports}"
    [ -n "$runtime_ports" ] && merged="${merged},${runtime_ports}"
    merged=$(normalize_ports "$merged")

    filtered=$(apply_exclude_ports_filter "$merged" "$exclude_ports")
    if ! is_port_in_list "$ssh_port" "$filtered"; then
        filtered=$(normalize_ports "${filtered},${ssh_port}")
    fi

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
# forwardaws generated at $(date +'%Y-%m-%dT%H:%M:%S%z')

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
    local allow_ports
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
        allow_ports=$(get_auto_allow_ports "$state_file")
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

    {
        render_delete_headers
        render_nat_table "$state_file"
        render_filter_table "$state_file" "$protect_flag"
    } > "$output_file"
}

apply_candidate_state() {
    local candidate_state="$1"
    local protect_flag="$2"
    local desc="$3"
    local nft_tmp
    local state_tmp
    local config_tmp

    ensure_state_dir || return 1

    nft_tmp="${FORWARDAWS_RULES_FILE}.tmp.$$"
    render_ruleset "$candidate_state" "$protect_flag" "$nft_tmp" || {
        rm -f "$nft_tmp"
        return 1
    }

    if state_has_remote_rules "$candidate_state"; then
        ensure_ipv4_forwarding_enabled || true
    fi

    local nft_output=""
    nft_output=$(nft -c -f "$nft_tmp" 2>&1)
    if [ $? -ne 0 ]; then
        rm -f "$nft_tmp"
        log_error "nft 预检失败: $desc"
        [ -n "$nft_output" ] && log_error "$nft_output"
        return 1
    fi

    state_tmp="${RULES_STATE_FILE}.tmp.$$"
    config_tmp="${CONFIG_FILE}.tmp.$$"
    cp "$candidate_state" "$state_tmp" || {
        rm -f "$nft_tmp" "$state_tmp"
        log_error "写入状态临时文件失败"
        return 1
    }
    {
        echo "PROTECTION_ENABLED=${protect_flag}"
    } > "$config_tmp" || {
        rm -f "$nft_tmp" "$state_tmp" "$config_tmp"
        log_error "写入配置临时文件失败"
        return 1
    }

    nft_output=$(nft -f "$nft_tmp" 2>&1)
    if [ $? -ne 0 ]; then
        rm -f "$nft_tmp" "$state_tmp" "$config_tmp"
        log_error "nft 应用失败: $desc"
        [ -n "$nft_output" ] && log_error "$nft_output"
        return 1
    fi

    mv "$nft_tmp" "$FORWARDAWS_RULES_FILE" || {
        rm -f "$state_tmp" "$config_tmp"
        log_error "写入持久化规则文件失败: $FORWARDAWS_RULES_FILE"
        return 1
    }
    chmod 600 "$FORWARDAWS_RULES_FILE" 2>/dev/null || true

    mv "$state_tmp" "$RULES_STATE_FILE" || {
        rm -f "$config_tmp"
        log_error "写入规则状态文件失败: $RULES_STATE_FILE"
        return 1
    }
    mv "$config_tmp" "$CONFIG_FILE" || {
        log_error "写入配置状态文件失败: $CONFIG_FILE"
        return 1
    }

    ensure_nft_main_config_include || return 1
}

install_systemd_units_if_needed() {
    local service_name="$1"
    local timer_name="$2"
    local service_desc="$3"
    local timer_desc="$4"
    local exec_args="$5"
    local script_path

    command -v systemctl >/dev/null 2>&1 || return 1
    script_path=$(get_script_absolute_path)
    [ -n "$script_path" ] || {
        log_error "无法确定脚本绝对路径，systemd 定时器安装失败"
        return 1
    }

    cat > "/etc/systemd/system/${service_name}" << EOF
[Unit]
Description=${service_desc}
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash "${script_path}" ${exec_args}
EOF

    cat > "/etc/systemd/system/${timer_name}" << EOF
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

    systemctl daemon-reload >/dev/null 2>&1
}

install_ddns_systemd_units_if_needed() {
    install_systemd_units_if_needed \
        "$DDNS_SERVICE_NAME" \
        "$DDNS_TIMER_NAME" \
        "ForwardAWS DDNS sync service" \
        "Run ForwardAWS DDNS sync every 60 seconds" \
        "--ddns-sync"
}

install_protect_systemd_units_if_needed() {
    install_systemd_units_if_needed \
        "$PROTECT_SERVICE_NAME" \
        "$PROTECT_TIMER_NAME" \
        "ForwardAWS protection sync service" \
        "Run ForwardAWS protection sync every 60 seconds" \
        "--protect sync"
}

has_systemctl() {
    command -v systemctl >/dev/null 2>&1
}

log_external_scheduler_hint() {
    local exec_args="$1"
    local script_path
    script_path=$(get_script_absolute_path)
    [ -n "$script_path" ] || script_path="$0"
    log_info "可使用外部调度（例如 cron）执行: */1 * * * * /bin/bash ${script_path} ${exec_args}"
}

enable_timer_with_fallback() {
    local timer_name="$1"
    local install_func="$2"
    local no_systemctl_msg="$3"
    local fallback_exec_args="$4"
    local success_msg="$5"
    local fail_msg="$6"

    if ! has_systemctl; then
        log_warn "$no_systemctl_msg"
        log_external_scheduler_hint "$fallback_exec_args"
        return 0
    fi

    "$install_func" || return 1
    if systemctl enable --now "$timer_name" >/dev/null 2>&1; then
        log_info "$success_msg"
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
        log_info "$success_msg"
    fi
}

reconcile_ddns_timer_state() {
    local domain_count
    domain_count=$(state_domain_count "$RULES_STATE_FILE")

    if [ "$domain_count" -gt 0 ]; then
        enable_timer_with_fallback \
            "$DDNS_TIMER_NAME" \
            "install_ddns_systemd_units_if_needed" \
            "未检测到 systemctl，跳过内置 DDNS 定时器" \
            "--ddns-sync" \
            "DDNS 定时同步已启用" \
            "启用 DDNS 定时同步失败，请手动检查 systemd 状态"
    else
        disable_timer_if_available "$DDNS_TIMER_NAME" "无 DDNS 域名规则，已停用 DDNS 定时同步"
    fi
}

reconcile_protect_timer_state() {
    local protect_flag
    protect_flag=$(get_protection_flag)

    if [ "$protect_flag" = "1" ]; then
        enable_timer_with_fallback \
            "$PROTECT_TIMER_NAME" \
            "install_protect_systemd_units_if_needed" \
            "未检测到 systemctl，跳过内置保护同步定时器" \
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

reconcile_timers() {
    reconcile_ddns_timer_state
    reconcile_protect_timer_state
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
        if ! parse_rule "$rule" 1; then
            failed=$((failed + 1))
            continue
        fi

        if state_rule_exact_exists "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_SNAT_IP" "$PARSED_MSS"; then
            log_warn "规则已存在，跳过: $rule"
            skipped=$((skipped + 1))
            continue
        fi
        if state_port_conflicts "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT"; then
            log_error "端口冲突，跳过: $rule"
            failed=$((failed + 1))
            continue
        fi

        make_state_line "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_TYPE" "$PARSED_IP" "ok" "$now" "$PARSED_SNAT_IP" "$PARSED_MSS" >> "$candidate"
        success=$((success + 1))
    done

    if [ "$success" -gt 0 ]; then
        apply_candidate_state "$candidate" "1" "批量添加转发规则" || { rm -f "$candidate"; return 1; }
        log_info "批量添加完成: 成功 ${success} 条，跳过 ${skipped} 条，失败 ${failed} 条"
        reconcile_timers
        show_protection_status
    else
        log_warn "没有新增规则: 跳过 ${skipped} 条，失败 ${failed} 条"
    fi

    rm -f "$candidate"
    [ "$failed" -eq 0 ]
}

delete_rule_batch() {
    local -a rules=("$@")
    local candidate
    local next_candidate
    local success=0
    local skipped=0
    local failed=0
    local rule

    [ ${#rules[@]} -gt 0 ] || { log_error "未提供任何规则"; return 1; }
    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    copy_current_state_to "$candidate" || { rm -f "$candidate"; return 1; }

    for rule in "${rules[@]}"; do
        log_info "处理规则: $rule"
        if ! parse_rule "$rule" 0; then
            failed=$((failed + 1))
            continue
        fi

        if ! state_base_rule_exists "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT"; then
            log_warn "规则不存在，跳过: $rule"
            skipped=$((skipped + 1))
            continue
        fi

        next_candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || { rm -f "$candidate"; return 1; }
        awk -F'|' -v sp="$PARSED_SRC_PORT" -v mode="$PARSED_MODE" -v target="$PARSED_TARGET" -v dp="$PARSED_DEST_PORT" \
            'NF>=8 && !($1==sp && $2==mode && $3==target && $4==dp) { print $0 }' "$candidate" > "$next_candidate" || {
            rm -f "$candidate" "$next_candidate"
            return 1
        }
        mv "$next_candidate" "$candidate"
        success=$((success + 1))
    done

    if [ "$success" -gt 0 ]; then
        apply_candidate_state "$candidate" "$(get_protection_flag)" "批量删除转发规则" || { rm -f "$candidate"; return 1; }
        log_info "批量删除完成: 成功 ${success} 条，跳过 ${skipped} 条，失败 ${failed} 条"
        reconcile_timers
    else
        log_warn "没有删除规则: 跳过 ${skipped} 条，失败 ${failed} 条"
    fi

    rm -f "$candidate"
    [ "$failed" -eq 0 ]
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
        if ! parse_rule "$rule" 1; then
            failed=$((failed + 1))
            continue
        fi
        if state_rule_exact_exists "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_SNAT_IP" "$PARSED_MSS"; then
            log_error "重复规则: $rule"
            failed=$((failed + 1))
            continue
        fi
        if state_port_conflicts "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT"; then
            log_error "端口冲突: $rule"
            failed=$((failed + 1))
            continue
        fi
        make_state_line "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_TYPE" "$PARSED_IP" "ok" "$now" "$PARSED_SNAT_IP" "$PARSED_MSS" >> "$candidate"
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
    local changed=0
    local unchanged=0
    local failed=0
    local now

    prepare_state_file || return 1
    if [ "$(state_domain_count "$RULES_STATE_FILE")" -eq 0 ]; then
        log_warn "未配置 DDNS 域名规则，无需同步"
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

    apply_candidate_state "$candidate" "$(get_protection_flag)" "DDNS 同步" || { rm -f "$candidate"; return 1; }
    rm -f "$candidate"
    reconcile_timers
    log_info "DDNS 同步完成: 更新 ${changed} 条，未变化 ${unchanged} 条，失败 ${failed} 条"
    [ "$failed" -eq 0 ]
}

sync_protection_ports() {
    local candidate
    local protect_flag

    protect_flag=$(get_protection_flag)
    if [ "$protect_flag" != "1" ]; then
        log_warn "保护模式未开启，跳过端口同步"
        return 0
    fi

    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    copy_current_state_to "$candidate" || { rm -f "$candidate"; return 1; }
    apply_candidate_state "$candidate" "1" "同步端口保护" || { rm -f "$candidate"; return 1; }
    rm -f "$candidate"
    reconcile_timers
    log_info "保护端口已同步: $(get_auto_allow_ports "$RULES_STATE_FILE")"
}

enable_protection() {
    local candidate

    candidate=$(mktemp /tmp/forwardaws-state.XXXXXX) || return 1
    copy_current_state_to "$candidate" || { rm -f "$candidate"; return 1; }
    apply_candidate_state "$candidate" "1" "开启端口保护" || { rm -f "$candidate"; return 1; }
    rm -f "$candidate"
    reconcile_timers
    log_info "端口保护已开启，开放端口: $(get_auto_allow_ports "$RULES_STATE_FILE")"
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
        auto_ports=$(get_auto_allow_ports "$RULES_STATE_FILE")
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
    log_info "$desc"
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
    ensure_runtime_tools
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
