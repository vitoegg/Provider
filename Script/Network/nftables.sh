#!/bin/bash

# ============================================================================
# NFTables 端口转发与保护管理工具
# 用途：管理 Linux 系统上的端口转发规则和防火墙保护
# 功能：
#   - 端口转发：本地转发和远程转发
#   - 端口保护：防火墙过滤，仅允许指定端口访问
#   - 联动机制：添加转发规则时自动开启保护
# ============================================================================

set -o pipefail

# ============================================================================
# 常量定义
# ============================================================================

# NFTables 表和链名称（IPv4/IPv6 共用同名表）
readonly TABLE_NAME="fowardaws"
readonly CHAIN_PREROUTING="prerouting"
readonly CHAIN_POSTROUTING="postrouting"
readonly CHAIN_OUTPUT="output"
readonly CHAIN_INPUT="input"

# 配置文件路径
readonly NFT_MAIN_CONFIG_FILE="/etc/nftables.conf"
readonly NFT_INCLUDE_DIR="/etc/nftables.d"
readonly FORWARDAWS_RULES_FILE="${NFT_INCLUDE_DIR}/forwardaws.nft"
readonly DDNS_STATE_DIR="/etc/forwardaws"
readonly DDNS_STATE_FILE="${DDNS_STATE_DIR}/ddns-rules.db"
readonly GLOBAL_LOCK_FILE="/run/forwardaws.lock"
readonly DDNS_SERVICE_NAME="forwardaws-ddns.service"
readonly DDNS_TIMER_NAME="forwardaws-ddns.timer"
readonly PROTECT_SERVICE_NAME="forwardaws-protect.service"
readonly PROTECT_TIMER_NAME="forwardaws-protect.timer"
readonly DEFAULT_EXCLUDE_PORTS="53"
readonly FORWARDAWS_TIMEZONE="Asia/Shanghai"
readonly FORWARDAWS_TIMEZONE_FALLBACK="UTC-8"

# 脚本内时间统一使用 UTC+8
if TZ="$FORWARDAWS_TIMEZONE" date +%s >/dev/null 2>&1; then
    export TZ="$FORWARDAWS_TIMEZONE"
else
    export TZ="$FORWARDAWS_TIMEZONE_FALLBACK"
fi

# 输出颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

FORWARDAWS_LOCK_HELD=0
FORWARDAWS_NFT_MUTATED=0

# ============================================================================
# 日志函数
# ============================================================================

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug()   { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# ============================================================================
# 工具函数
# ============================================================================

# 验证端口号是否有效 (1-65535)
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# 验证 IP 地址格式和范围
validate_ip_address() {
    local ip="$1"
    
    # 检查基本格式
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    
    # 检查每个八位字节范围
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
    return 0
}

# 验证域名格式
validate_domain_name() {
    local domain="$1"

    [ -n "$domain" ] || return 1
    [ "${#domain}" -le 253 ] || return 1

    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

# 解析 DDNS 域名到 IPv4（主 IP 优先）
resolve_ddns_ipv4() {
    local domain="$1"
    local ip=""

    ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk '/STREAM/ {print $1; exit}')
    if [ -z "$ip" ] && command -v dig >/dev/null 2>&1; then
        ip=$(dig +short A "$domain" @1.1.1.1 2>/dev/null | head -n1)
    fi

    validate_ip_address "$ip" || return 1
    echo "$ip"
}

# 获取脚本绝对路径
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

# 确保 DDNS 状态文件存在
ensure_ddns_state() {
    mkdir -p "$DDNS_STATE_DIR" && touch "$DDNS_STATE_FILE"
}

# 记录运行时规则是否发生变更
mark_nft_mutated() {
    FORWARDAWS_NFT_MUTATED=1
}

reset_nft_mutation_flag() {
    FORWARDAWS_NFT_MUTATED=0
}

# 获取全局状态锁（所有变更入口共用）
acquire_global_lock() {
    [ "$FORWARDAWS_LOCK_HELD" = "1" ] && return 0

    if ! command -v flock >/dev/null 2>&1; then
        return 0
    fi

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

# 备份当前 forwardaws 表（ip/ip6）用于失败回滚
snapshot_forwardaws_tables() {
    local snapshot_dir
    snapshot_dir=$(mktemp -d /tmp/forwardaws-snapshot.XXXXXX) || {
        log_error "创建规则快照目录失败"
        return 1
    }

    if nft list table ip "$TABLE_NAME" >/dev/null 2>&1; then
        nft list table ip "$TABLE_NAME" > "${snapshot_dir}/ip.nft" 2>/dev/null || {
            rm -rf "$snapshot_dir"
            log_error "备份 IPv4 规则表失败"
            return 1
        }
    fi

    if nft list table ip6 "$TABLE_NAME" >/dev/null 2>&1; then
        nft list table ip6 "$TABLE_NAME" > "${snapshot_dir}/ip6.nft" 2>/dev/null || {
            rm -rf "$snapshot_dir"
            log_error "备份 IPv6 规则表失败"
            return 1
        }
    fi

    if [ -f "$DDNS_STATE_FILE" ]; then
        cp "$DDNS_STATE_FILE" "${snapshot_dir}/ddns-rules.db" 2>/dev/null || {
            rm -rf "$snapshot_dir"
            log_error "备份 DDNS 状态文件失败"
            return 1
        }
    fi

    echo "$snapshot_dir"
}

cleanup_snapshot_dir() {
    local snapshot_dir="$1"
    [ -n "$snapshot_dir" ] && [ -d "$snapshot_dir" ] && rm -rf "$snapshot_dir"
}

# 回滚 forwardaws 表到快照状态
restore_forwardaws_tables() {
    local snapshot_dir="$1"
    [ -d "$snapshot_dir" ] || return 1

    nft list table ip "$TABLE_NAME" >/dev/null 2>&1 && \
        nft delete table ip "$TABLE_NAME" >/dev/null 2>&1
    nft list table ip6 "$TABLE_NAME" >/dev/null 2>&1 && \
        nft delete table ip6 "$TABLE_NAME" >/dev/null 2>&1

    if [ -s "${snapshot_dir}/ip.nft" ]; then
        nft -f "${snapshot_dir}/ip.nft" >/dev/null 2>&1 || return 1
    fi

    if [ -s "${snapshot_dir}/ip6.nft" ]; then
        nft -f "${snapshot_dir}/ip6.nft" >/dev/null 2>&1 || return 1
    fi

    if [ -f "${snapshot_dir}/ddns-rules.db" ]; then
        mkdir -p "$DDNS_STATE_DIR" || return 1
        cp "${snapshot_dir}/ddns-rules.db" "$DDNS_STATE_FILE" 2>/dev/null || return 1
    else
        rm -f "$DDNS_STATE_FILE"
    fi
}

# 统一执行“变更 + 持久化 + 失败回滚”
run_mutation_with_persistence() {
    local desc="$1"
    shift

    local snapshot_dir=""
    snapshot_dir=$(snapshot_forwardaws_tables) || return 1
    reset_nft_mutation_flag

    "$@"
    local action_rc=$?

    if [ $action_rc -ne 0 ]; then
        if [ "$FORWARDAWS_NFT_MUTATED" = "1" ]; then
            log_warn "操作失败，正在回滚运行时规则..."
            if ! restore_forwardaws_tables "$snapshot_dir"; then
                cleanup_snapshot_dir "$snapshot_dir"
                log_error "回滚失败，请立即手动检查 nftables 状态"
                return 1
            fi
        fi
        cleanup_snapshot_dir "$snapshot_dir"
        return $action_rc
    fi

    if [ "$FORWARDAWS_NFT_MUTATED" != "1" ]; then
        cleanup_snapshot_dir "$snapshot_dir"
        return 0
    fi

    if save_rules; then
        cleanup_snapshot_dir "$snapshot_dir"
        return 0
    fi

    log_error "持久化失败，正在回滚运行时规则..."
    if ! restore_forwardaws_tables "$snapshot_dir"; then
        cleanup_snapshot_dir "$snapshot_dir"
        log_error "回滚失败，请立即手动检查 nftables 状态"
        return 1
    fi

    if ! save_rules; then
        log_warn "运行时规则已回滚，但持久化文件仍写入失败，请检查权限"
    fi

    cleanup_snapshot_dir "$snapshot_dir"
    log_error "操作已回滚: $desc"
    return 1
}

run_locked_mutation_with_persistence() {
    local desc="$1"
    shift
    acquire_global_lock || return 1
    run_mutation_with_persistence "$desc" "$@"
}

# 统计 DDNS 域名规则数量
ddns_state_count_domains() {
    [ -f "$DDNS_STATE_FILE" ] || { echo 0; return 0; }
    awk -F'|' 'NF>=3 && $1 ~ /^[0-9]+$/ && $2 != "" && $3 ~ /^[0-9]+$/ { count++ } END { print count+0 }' "$DDNS_STATE_FILE"
}

# 写入或更新一条 DDNS 规则状态
ddns_state_upsert() {
    local src_port="$1"
    local domain="$2"
    local dest_port="$3"
    local last_ip="$4"
    local status="$5"
    local updated_at="${6:-$(date +%s)}"

    ensure_ddns_state || return 1

    local tmp_file="${DDNS_STATE_FILE}.tmp.$$"
    awk -F'|' -v sp="$src_port" -v dm="$domain" -v dp="$dest_port" \
        'NF>0 && !(NF>=3 && $1==sp && $2==dm && $3==dp) { print $0 }' \
        "$DDNS_STATE_FILE" > "$tmp_file" 2>/dev/null || {
        rm -f "$tmp_file"
        return 1
    }

    echo "${src_port}|${domain}|${dest_port}|${last_ip}|${status}|${updated_at}" >> "$tmp_file"
    if ! mv "$tmp_file" "$DDNS_STATE_FILE"; then
        rm -f "$tmp_file"
        log_error "写入 DDNS 状态文件失败"
        return 1
    fi
}

# 清空 DDNS 状态
clear_ddns_state() {
    [ -f "$DDNS_STATE_FILE" ] || return 0
    : > "$DDNS_STATE_FILE"
}

# 格式化时间戳
format_epoch_time() {
    local ts="$1"
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
        date -d "@$ts" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || echo "$ts"
    else
        echo "$ts"
    fi
}

# 安装 systemd service/timer 单元
install_systemd_units_if_needed() {
    local service_name="$1"
    local timer_name="$2"
    local service_desc="$3"
    local timer_desc="$4"
    local exec_args="$5"

    command -v systemctl >/dev/null 2>&1 || return 1

    local script_path
    script_path=$(get_script_absolute_path)
    [ -n "$script_path" ] || {
        log_error "无法确定脚本绝对路径，systemd 定时器安装失败"
        return 1
    }

    cat > "/etc/systemd/system/${service_name}" << EOF
[Unit]
Description=${service_desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${script_path} ${exec_args}
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

# 安装 DDNS systemd 单元
install_ddns_systemd_units_if_needed() {
    install_systemd_units_if_needed \
        "$DDNS_SERVICE_NAME" \
        "$DDNS_TIMER_NAME" \
        "ForwardAWS DDNS sync service" \
        "Run ForwardAWS DDNS sync every 60 seconds" \
        "--ddns-sync"
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

# 按需启用 DDNS 定时器
enable_ddns_timer_if_needed() {
    local domain_count
    domain_count=$(ddns_state_count_domains)
    [ "$domain_count" -gt 0 ] || return 0

    enable_timer_with_fallback \
        "$DDNS_TIMER_NAME" \
        "install_ddns_systemd_units_if_needed" \
        "未检测到 systemctl，跳过内置定时器" \
        "--ddns-sync" \
        "DDNS 定时同步已启用" \
        "启用 DDNS 定时同步失败，请手动检查 systemd 状态"
}

# 当无域名规则时停用 DDNS 定时器
disable_ddns_timer_if_no_domain_rules() {
    local domain_count
    domain_count=$(ddns_state_count_domains)
    [ "$domain_count" -eq 0 ] || return 0

    disable_timer_if_available \
        "$DDNS_TIMER_NAME" \
        "无 DDNS 域名规则，已停用 DDNS 定时同步"
}

# 根据 DDNS 规则状态协调定时器开关
reconcile_ddns_timer_state() {
    local domain_count
    domain_count=$(ddns_state_count_domains)

    if [ "$domain_count" -gt 0 ]; then
        enable_ddns_timer_if_needed
    else
        disable_ddns_timer_if_no_domain_rules
    fi
}

install_protect_systemd_units_if_needed() {
    install_systemd_units_if_needed \
        "$PROTECT_SERVICE_NAME" \
        "$PROTECT_TIMER_NAME" \
        "ForwardAWS protection sync service" \
        "Run ForwardAWS protection sync every 60 seconds" \
        "--protect sync"
}

enable_protect_timer_if_needed() {
    enable_timer_with_fallback \
        "$PROTECT_TIMER_NAME" \
        "install_protect_systemd_units_if_needed" \
        "未检测到 systemctl，跳过内置保护同步定时器" \
        "--protect sync" \
        "保护端口自动同步已启用" \
        "启用保护同步定时器失败，请手动检查 systemd 状态"
}

disable_protect_timer_if_needed() {
    disable_timer_if_available \
        "$PROTECT_TIMER_NAME" \
        "保护端口自动同步已停用"
}

get_protect_timer_status() {
    has_systemctl || { echo "unavailable"; return 0; }
    systemctl is-active --quiet "$PROTECT_TIMER_NAME" && { echo "active"; return 0; }
    echo "inactive"
}

# 规范化端口列表格式（去除空格，去重，排序）
normalize_ports() {
    local ports="$1"
    echo "$ports" | tr -d ' ' | tr ',' '\n' | sort -un | tr '\n' ',' | sed 's/,$//'
}

is_port_in_list() {
    local port="$1"
    local list="$2"
    [ -n "$port" ] && [ -n "$list" ] && [[ ",$list," == *",$port,"* ]]
}

get_exclude_ports() {
    local combined="$DEFAULT_EXCLUDE_PORTS"
    local extra="${FORWARDAWS_EXCLUDE_PORTS:-}"
    [ -n "$extra" ] && combined="${combined},${extra}"
    combined=$(normalize_ports "$combined")

    local valid_ports=""
    local port=""
    local -a ports_arr=()
    IFS=',' read -ra ports_arr <<< "$combined"
    for port in "${ports_arr[@]}"; do
        validate_port "$port" || continue
        valid_ports="${valid_ports}${valid_ports:+,}${port}"
    done

    echo "$valid_ports"
}

apply_exclude_ports_filter() {
    local ports="$1"
    local exclude_ports="$2"
    ports=$(normalize_ports "$ports")
    exclude_ports=$(normalize_ports "$exclude_ports")
    [ -n "$ports" ] || { echo ""; return 0; }
    [ -n "$exclude_ports" ] || { echo "$ports"; return 0; }

    local filtered=""
    local port=""
    local -a ports_arr=()
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

    if ! validate_port "$port"; then
        port="22"
    fi
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

        local parsed
        local addr
        local port
        parsed=$(parse_local_endpoint "$endpoint")
        IFS='|' read -r addr port <<< "$parsed"

        validate_port "$port" || continue
        is_loopback_address "$addr" && continue

        ports="${ports}${ports:+,}${port}"
    done < <(
        {
            ss -H -ltnu4 2>/dev/null
            ss -H -ltnu6 2>/dev/null
        } | awk '{print $5}'
    )

    normalize_ports "$ports"
}

get_auto_allow_ports() {
    local ssh_port
    local forward_ports
    local runtime_ports
    local exclude_ports
    local merged
    local filtered

    ssh_port=$(detect_ssh_port)
    forward_ports=$(get_forwarding_ports)
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

require_root() {
    [ "$EUID" -eq 0 ] && return 0
    log_error "此操作必须以 root 权限运行"
    return 1
}

ensure_nft_installed() {
    command -v nft >/dev/null 2>&1 && return 0
    log_error "未检测到 nft 命令，请先安装 nftables"
    return 1
}

ensure_root_and_nft() {
    require_root || return 1
    ensure_nft_installed || return 1
}

ensure_supported_bash() {
    local major="${BASH_VERSINFO[0]:-0}"
    local minor="${BASH_VERSINFO[1]:-0}"

    if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 3 ]; }; then
        log_error "此脚本要求 Bash >= 4.3（当前: ${BASH_VERSION:-unknown}）"
        return 1
    fi
}

nft_main_config_has_forwardaws_include() {
    [ -f "$NFT_MAIN_CONFIG_FILE" ] || return 1
    grep -Eq '^[[:space:]]*include[[:space:]]+"(/etc/nftables\.d/\*\.nft|/etc/nftables\.d/forwardaws\.nft)"' "$NFT_MAIN_CONFIG_FILE"
}

ensure_nft_main_config_include() {
    local include_line='include "/etc/nftables.d/*.nft"'

    nft_main_config_has_forwardaws_include && return 0

    touch "$NFT_MAIN_CONFIG_FILE" 2>/dev/null || {
        log_error "无法访问主配置文件: $NFT_MAIN_CONFIG_FILE"
        return 1
    }

    nft_main_config_has_forwardaws_include && return 0

    printf '\n%s\n' "$include_line" >> "$NFT_MAIN_CONFIG_FILE" 2>/dev/null || {
        log_error "写入主配置 include 失败: $NFT_MAIN_CONFIG_FILE"
        return 1
    }
}

run_nft_transaction() {
    local desc="$1"
    shift
    local -a commands=("$@")
    [ ${#commands[@]} -gt 0 ] || return 0

    local tmp_file
    tmp_file=$(mktemp /tmp/forwardaws-nft.XXXXXX) || {
        log_error "创建 nft 事务文件失败"
        return 1
    }

    {
        for cmd in "${commands[@]}"; do
            echo "$cmd"
        done
    } > "$tmp_file"

    local nft_output=""
    nft_output=$(nft -f "$tmp_file" 2>&1)
    local nft_rc=$?
    rm -f "$tmp_file"

    if [ $nft_rc -ne 0 ]; then
        log_error "nft 事务执行失败 (${desc})"
        [ -n "$nft_output" ] && log_error "$nft_output"
        return 1
    fi
    mark_nft_mutated
    return 0
}

ensure_ipv4_forwarding_enabled() {
    local current
    current=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
    [ "$current" = "1" ] && return 0

    if command -v sysctl >/dev/null 2>&1 && sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
        log_info "已启用 net.ipv4.ip_forward=1（运行时）"
        return 0
    fi

    if echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null; then
        log_info "已启用 /proc/sys/net/ipv4/ip_forward"
        return 0
    fi

    log_warn "无法自动启用 IP 转发，远程端口转发可能无法生效"
    return 1
}

# ============================================================================
# 核心函数
# ============================================================================

table_exists() {
    local family="$1"
    awk -v fam="$family" -v table="$TABLE_NAME" '
        $1=="table" && $2==fam && $3==table { found=1; exit }
        END { exit(found ? 0 : 1) }
    ' < <(nft list tables "$family" 2>/dev/null)
}

chain_exists() {
    local family="$1"
    local chain="$2"
    nft list chain "$family" "$TABLE_NAME" "$chain" >/dev/null 2>&1
}

# 通用表存在性检查
ensure_table_family() {
    local family="$1"
    table_exists "$family" && return 0
    run_nft_transaction "创建 ${family} 表 ${TABLE_NAME}" \
        "add table $family $TABLE_NAME"
}

# 确保 IPv4 NAT 表与基础链存在
ensure_nat_table_v4() {
    ensure_table_family ip || return 1

    local -a commands=()
    chain_exists ip "$CHAIN_PREROUTING" || \
        commands+=("add chain ip $TABLE_NAME $CHAIN_PREROUTING { type nat hook prerouting priority -100; }")
    chain_exists ip "$CHAIN_POSTROUTING" || \
        commands+=("add chain ip $TABLE_NAME $CHAIN_POSTROUTING { type nat hook postrouting priority 100; }")

    [ ${#commands[@]} -eq 0 ] && return 0
    run_nft_transaction "创建 IPv4 NAT 基础链" "${commands[@]}"
}

# 确保 output 链存在（用于本地转发）
ensure_output_chain() {
    ensure_nat_table_v4 || return 1
    chain_exists ip "$CHAIN_OUTPUT" && return 0

    run_nft_transaction "创建 IPv4 OUTPUT NAT 链" \
        "add chain ip $TABLE_NAME $CHAIN_OUTPUT { type nat hook output priority -100; }"
}

ensure_nft_base_structures() {
    ensure_output_chain || return 1
    ensure_table_family ip6 || return 1
}

# 保存当前规则集到配置文件
save_rules() {
    mkdir -p "$NFT_INCLUDE_DIR" || {
        log_error "无法创建持久化目录: $NFT_INCLUDE_DIR"
        return 1
    }

    local tmp_file="${FORWARDAWS_RULES_FILE}.tmp.$$"
    {
        echo "#!/usr/sbin/nft -f"
        echo "# forwardaws generated at $(date +'%Y-%m-%dT%H:%M:%S%z')"
        echo
        nft list table ip "$TABLE_NAME" 2>/dev/null || true
        echo
        nft list table ip6 "$TABLE_NAME" 2>/dev/null || true
    } > "$tmp_file" || {
        rm -f "$tmp_file"
        log_error "生成持久化规则文件失败"
        return 1
    }

    if ! mv "$tmp_file" "$FORWARDAWS_RULES_FILE"; then
        rm -f "$tmp_file"
        log_error "写入持久化规则文件失败: $FORWARDAWS_RULES_FILE"
        return 1
    fi

    chmod 600 "$FORWARDAWS_RULES_FILE" 2>/dev/null || true
    ensure_nft_main_config_include || return 1
}

# 检测保护模式是否已开启
chain_input_has_policy_drop() {
    local family="$1"
    local chain_dump=""
    chain_dump=$(nft list chain "$family" "$TABLE_NAME" "$CHAIN_INPUT" 2>/dev/null) || return 1
    [[ "$chain_dump" == *"policy drop"* ]]
}

is_protection_enabled() {
    chain_input_has_policy_drop ip && return 0
    chain_input_has_policy_drop ip6 && return 0
    return 1
}

# 从转发规则中提取所有源端口
get_forwarding_ports() {
    local prerouting_ports
    local output_ports
    prerouting_ports=$(nft list chain ip "$TABLE_NAME" "$CHAIN_PREROUTING" 2>/dev/null | \
        awk '/dnat to/ { for (i=1; i<=NF; i++) if ($i=="dport") { print $(i+1); break } }' | \
        grep -E '^[0-9]+$' | sort -un)
    output_ports=$(nft list chain ip "$TABLE_NAME" "$CHAIN_OUTPUT" 2>/dev/null | \
        awk '/dnat to/ { for (i=1; i<=NF; i++) if ($i=="dport") { print $(i+1); break } }' | \
        grep -E '^[0-9]+$' | sort -un)

    echo -e "${prerouting_ports}\n${output_ports}" | awk 'NF>0' | sort -un | tr '\n' ',' | sed 's/,$//'
}

# ============================================================================
# 规则管理函数
# ============================================================================

# 验证并解析转发规则，返回格式: local_port:dest_value:dest_port:is_local:target_type
validate_rule() {
    local rule_string="$1"
    
    # 检查规则格式是否为 端口:目标:端口
    if [[ ! "$rule_string" =~ ^[^:]+:[^:]+:[^:]+$ ]]; then
        log_error "规则格式错误: $rule_string (正确格式: 端口:目标(IPv4/域名/local):端口)"
        return 1
    fi
    
    local local_port=""
    local dest_value=""
    local dest_port=""
    IFS=':' read -r local_port dest_value dest_port <<< "$rule_string"
    local is_local="false"
    local target_type="ipv4"
    
    # 验证源端口
    if ! validate_port "$local_port"; then
        log_error "无效的源端口: $local_port (必须在 1-65535 之间)"
        return 1
    fi
    
    # 处理本地转发标识
    if [[ "$dest_value" == "local" || "$dest_value" == "localhost" || "$dest_value" == "127.0.0.1" ]]; then
        dest_value="127.0.0.1"
        is_local="true"
        target_type="local"
    elif validate_ip_address "$dest_value"; then
        target_type="ipv4"
    elif validate_domain_name "$dest_value"; then
        target_type="domain"
    else
        log_error "无效的目标地址: $dest_value (需为 IPv4/域名/local)"
        return 1
    fi
    
    # 验证目标端口
    if ! validate_port "$dest_port"; then
        log_error "无效的目标端口: $dest_port (必须在 1-65535 之间)"
        return 1
    fi
    
    # 返回解析结果
    echo "${local_port}:${dest_value}:${dest_port}:${is_local}:${target_type}"
    return 0
}

parse_rule_for_forwarding() {
    local rule="$1"
    local -n out_local_port="$2"
    local -n out_dest_value="$3"
    local -n out_dest_port="$4"
    local -n out_is_local="$5"
    local -n out_target_type="$6"
    local -n out_dest_ip="$7"
    local -n out_domain_name="$8"
    local -n out_error_reason="$9"

    out_error_reason=""

    local parsed=""
    if ! parsed=$(validate_rule "$rule"); then
        out_error_reason="格式验证失败"
        return 1
    fi

    IFS=':' read -r out_local_port out_dest_value out_dest_port out_is_local out_target_type <<< "$parsed"
    out_dest_ip="$out_dest_value"
    out_domain_name=""

    if [ "$out_target_type" = "domain" ]; then
        out_domain_name="$out_dest_value"
        out_dest_ip=$(resolve_ddns_ipv4 "$out_domain_name")
        if [ $? -ne 0 ] || [ -z "$out_dest_ip" ]; then
            out_error_reason="域名解析失败"
            return 1
        fi
    fi
}

# 检查规则冲突
chain_has_dnat_for_port() {
    local chain="$1"
    local local_port="$2"

    awk -v sp="$local_port" '
        {
            has_dport=0
            has_dnat=0
            for (i=1; i<=NF; i++) {
                if ($i=="dport" && $(i+1)==sp) {
                    has_dport=1
                }
                if ($i=="dnat" && $(i+1)=="to") {
                    has_dnat=1
                }
            }
            if (has_dport && has_dnat) {
                found=1
                exit
            }
        }
        END { exit(found ? 0 : 1) }
    ' < <(nft list chain ip "$TABLE_NAME" "$chain" 2>/dev/null)
}

chain_has_exact_dnat_rule() {
    local chain="$1"
    local local_port="$2"
    local dest_ip="$3"
    local dest_port="$4"
    local target="${dest_ip}:${dest_port}"

    awk -v sp="$local_port" -v target="$target" '
        {
            has_dport=0
            dnat_target=""
            for (i=1; i<=NF; i++) {
                if ($i=="dport" && $(i+1)==sp) {
                    has_dport=1
                }
                if ($i=="dnat" && $(i+1)=="to") {
                    dnat_target=$(i+2)
                }
            }
            if (has_dport && dnat_target==target) {
                found=1
                exit
            }
        }
        END { exit(found ? 0 : 1) }
    ' < <(nft list chain ip "$TABLE_NAME" "$chain" 2>/dev/null)
}

chain_has_masquerade_for_ip() {
    local ip="$1"

    awk -v ip="$ip" '
        {
            has_target=0
            has_masq=0
            for (i=1; i<=NF; i++) {
                if ($i=="ip" && $(i+1)=="daddr" && $(i+2)==ip) {
                    has_target=1
                }
                if ($i=="masquerade") {
                    has_masq=1
                }
            }
            if (has_target && has_masq) {
                found=1
                exit
            }
        }
        END { exit(found ? 0 : 1) }
    ' < <(nft list chain ip "$TABLE_NAME" "$CHAIN_POSTROUTING" 2>/dev/null)
}

check_rule_conflict() {
    local local_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_local="$4"
    
    # 表不存在则无冲突
    table_exists ip || return 0
    
    if [ "$is_local" = "true" ]; then
        # 本地转发：检查是否与远程转发冲突
        if chain_has_dnat_for_port "$CHAIN_PREROUTING" "$local_port"; then
            log_error "端口冲突: 端口 ${local_port} 已被用于远程转发"
            return 1
        fi
        
        # 检查本地转发规则
        if chain_has_dnat_for_port "$CHAIN_OUTPUT" "$local_port"; then
            if chain_has_exact_dnat_rule "$CHAIN_OUTPUT" "$local_port" "$dest_ip" "$dest_port"; then
                log_warn "本地转发规则已存在: 端口 ${local_port} -> ${dest_ip}:${dest_port}"
            else
                log_error "端口冲突: 本地端口 ${local_port} 已被用于其他转发"
            fi
            return 1
        fi
    else
        # 远程转发：检查是否与本地转发冲突
        if chain_has_dnat_for_port "$CHAIN_OUTPUT" "$local_port"; then
            log_error "端口冲突: 端口 ${local_port} 已被用于本地转发"
            return 1
        fi
        
        # 检查远程转发规则
        if chain_has_dnat_for_port "$CHAIN_PREROUTING" "$local_port"; then
            if chain_has_exact_dnat_rule "$CHAIN_PREROUTING" "$local_port" "$dest_ip" "$dest_port"; then
                log_warn "转发规则已存在: 端口 ${local_port} -> ${dest_ip}:${dest_port}"
            else
                log_error "端口冲突: 端口 ${local_port} 已被用于其他转发"
            fi
            return 1
        fi
    fi
    
    return 0
}

# 应用单条转发规则
apply_single_forwarding_rule() {
    local local_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_local="$4"
    local -a commands=()

    if [ "$is_local" = "true" ]; then
        ensure_output_chain || return 1
        commands+=("add rule ip $TABLE_NAME $CHAIN_OUTPUT tcp dport $local_port dnat to ${dest_ip}:${dest_port}")
        commands+=("add rule ip $TABLE_NAME $CHAIN_OUTPUT udp dport $local_port dnat to ${dest_ip}:${dest_port}")
    else
        ensure_nat_table_v4 || return 1
        ensure_ipv4_forwarding_enabled || true
        commands+=("add rule ip $TABLE_NAME $CHAIN_PREROUTING tcp dport $local_port dnat to ${dest_ip}:${dest_port}")
        commands+=("add rule ip $TABLE_NAME $CHAIN_PREROUTING udp dport $local_port dnat to ${dest_ip}:${dest_port}")

        # 添加 masquerade 规则（如果不存在）
        if ! chain_has_masquerade_for_ip "$dest_ip"; then
            commands+=("add rule ip $TABLE_NAME $CHAIN_POSTROUTING ip daddr $dest_ip masquerade")
        fi
    fi

    run_nft_transaction "添加转发规则 $local_port -> ${dest_ip}:${dest_port}" "${commands[@]}"
}

collect_dnat_rule_handles() {
    local chain="$1"
    local proto="$2"
    local local_port="$3"
    local dest_ip="$4"
    local dest_port="$5"

    nft -a list chain ip "$TABLE_NAME" "$chain" 2>/dev/null | \
        awk -v p="$proto" -v sp="$local_port" -v dp="${dest_ip}:${dest_port}" '
            $1==p && $0 ~ ("dport " sp " ") && $0 ~ ("dnat to " dp) {
                for (i=1; i<=NF; i++) {
                    if ($i=="handle") {
                        print $(i+1);
                        break;
                    }
                }
            }
        '
}

# 按完整条件删除单条转发规则
remove_forwarding_rule_by_tuple() {
    local local_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_local="$4"

    local chain="$CHAIN_PREROUTING"
    [ "$is_local" = "true" ] && chain="$CHAIN_OUTPUT"

    local -a commands=()
    local proto=""
    local handle=""
    for proto in tcp udp; do
        while IFS= read -r handle; do
            [ -n "$handle" ] && commands+=("delete rule ip $TABLE_NAME $chain handle $handle")
        done < <(collect_dnat_rule_handles "$chain" "$proto" "$local_port" "$dest_ip" "$dest_port")
    done

    [ ${#commands[@]} -eq 0 ] && return 0
    run_nft_transaction "删除转发规则 $local_port -> ${dest_ip}:${dest_port}" "${commands[@]}"
}

# 判断目标 IP 是否仍被任意 DNAT 规则引用
chain_has_dnat_target_ip() {
    local chain="$1"
    local ip="$2"

    awk -v ip="$ip" '
        {
            for (i=1; i<=NF; i++) {
                if ($i=="dnat" && $(i+1)=="to") {
                    split($(i+2), parts, ":")
                    if (parts[1]==ip) {
                        found=1
                        exit
                    }
                }
            }
        }
        END { exit(found ? 0 : 1) }
    ' < <(nft list chain ip "$TABLE_NAME" "$chain" 2>/dev/null)
}

is_ip_referenced_by_dnat() {
    local ip="$1"
    chain_has_dnat_target_ip "$CHAIN_PREROUTING" "$ip" && return 0
    chain_has_dnat_target_ip "$CHAIN_OUTPUT" "$ip" && return 0
    return 1
}

# 若目标 IP 无引用则移除对应 masquerade 规则
cleanup_masquerade_if_unused() {
    local ip="$1"
    [ -n "$ip" ] || return 0
    is_ip_referenced_by_dnat "$ip" && return 0

    local -a commands=()
    local handle=""
    while IFS= read -r handle; do
        [ -n "$handle" ] && commands+=("delete rule ip $TABLE_NAME $CHAIN_POSTROUTING handle $handle")
    done < <(
        nft -a list chain ip "$TABLE_NAME" "$CHAIN_POSTROUTING" 2>/dev/null | \
            awk -v ip="$ip" '
                {
                    has_target=0
                    has_masq=0
                    for (i=1; i<=NF; i++) {
                        if ($i=="ip" && $(i+1)=="daddr" && $(i+2)==ip) {
                            has_target=1
                        }
                        if ($i=="masquerade") {
                            has_masq=1
                        }
                        if ($i=="handle") {
                            handle=$(i+1)
                        }
                    }
                    if (has_target && has_masq && handle!="") {
                        print handle
                    }
                }
            '
    )

    [ ${#commands[@]} -eq 0 ] && return 0
    run_nft_transaction "清理未使用 masquerade $ip" "${commands[@]}"
}

# 解析规则集到关联数组
append_chain_rules_to_map() {
    local chain="$1"
    local rule_type="$2"
    local key_suffix="$3"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local proto=""
        local src_port=""
        local dest=""
        if [[ "$line" =~ ^[[:space:]]*(tcp|udp)[[:space:]].*dport[[:space:]]([0-9]+)[[:space:]].*dnat[[:space:]]to[[:space:]]([0-9.]+:[0-9]+) ]]; then
            proto="${BASH_REMATCH[1]}"
            src_port="${BASH_REMATCH[2]}"
            dest="${BASH_REMATCH[3]}"
        else
            continue
        fi

        local key="${src_port}:${dest}${key_suffix}"
        RULE_MAP["$key"]="$dest"
        RULE_TYPE["$key"]="$rule_type"

        if [ -z "${RULE_PROTOCOLS[$key]}" ]; then
            RULE_PROTOCOLS["$key"]="${proto^^}"
        elif [[ "${RULE_PROTOCOLS[$key]}" != *"${proto^^}"* ]]; then
            RULE_PROTOCOLS["$key"]="TCP+UDP"
        fi
    done < <(nft list chain ip "$TABLE_NAME" "$chain" 2>/dev/null | grep "dnat to")
}

parse_ruleset_to_map() {
    declare -gA RULE_MAP RULE_PROTOCOLS RULE_TYPE
    RULE_MAP=() RULE_PROTOCOLS=() RULE_TYPE=()
    
    table_exists ip || return 1

    append_chain_rules_to_map "$CHAIN_PREROUTING" "remote" ""
    append_chain_rules_to_map "$CHAIN_OUTPUT" "local" ":local"
    
    [ ${#RULE_MAP[@]} -gt 0 ]
}

# ============================================================================
# 保护模式函数
# ============================================================================

# 向事务命令列表追加 INPUT 保护链重建命令
append_input_chain_commands() {
    local -n _commands="$1"
    local family="$2"
    local ports="$3"

    chain_exists "$family" "$CHAIN_INPUT" && \
        _commands+=("delete chain $family $TABLE_NAME $CHAIN_INPUT")
    _commands+=("add chain $family $TABLE_NAME $CHAIN_INPUT { type filter hook input priority 0; policy drop; }")
    _commands+=("add rule $family $TABLE_NAME $CHAIN_INPUT iifname \"lo\" accept")
    _commands+=("add rule $family $TABLE_NAME $CHAIN_INPUT ct state established,related accept")

    if [ "$family" = "ip" ]; then
        _commands+=("add rule ip $TABLE_NAME $CHAIN_INPUT ip protocol icmp accept")
    else
        _commands+=("add rule ip6 $TABLE_NAME $CHAIN_INPUT ip6 nexthdr icmpv6 accept")
    fi
    _commands+=("add rule $family $TABLE_NAME $CHAIN_INPUT tcp dport { $ports } accept")
    _commands+=("add rule $family $TABLE_NAME $CHAIN_INPUT udp dport { $ports } accept")
}

# 构建保护规则（核心函数，被其他保护函数调用）
build_protection_rules() {
    local ports="$1"

    ensure_table_family ip || return 1
    ensure_table_family ip6 || return 1

    local -a commands=()
    append_input_chain_commands commands "ip" "$ports"
    append_input_chain_commands commands "ip6" "$ports"

    run_nft_transaction "重建 IPv4/IPv6 保护链" "${commands[@]}"
}

# 获取当前保护链开放端口（优先 IPv4，回退 IPv6）
get_current_protection_ports() {
    local ports
    ports=$(nft list chain ip "$TABLE_NAME" "$CHAIN_INPUT" 2>/dev/null | \
        sed -n 's/.*tcp dport { *\([^}]*\) *}.*/\1/p' | head -1 | tr -d ' ')
    [ -n "$ports" ] && { echo "$ports"; return 0; }
    nft list chain ip6 "$TABLE_NAME" "$CHAIN_INPUT" 2>/dev/null | \
        sed -n 's/.*tcp dport { *\([^}]*\) *}.*/\1/p' | head -1 | tr -d ' '
}

# 同步保护链放行端口（SSH + 转发端口 + 运行中非回环监听端口 - 排除端口）
sync_protection_ports() {
    is_protection_enabled || {
        log_warn "保护模式未开启，跳过端口同步"
        return 0
    }

    local target_ports
    target_ports=$(get_auto_allow_ports)
    [ -n "$target_ports" ] || {
        log_error "自动识别未得到可放行端口，取消同步"
        return 1
    }

    local current_ports
    current_ports=$(get_current_protection_ports)
    if [ "$(normalize_ports "$current_ports")" = "$(normalize_ports "$target_ports")" ]; then
        log_debug "保护端口无变化，跳过重建"
        return 0
    fi

    build_protection_rules "$target_ports" || return 1
    log_info "保护端口已同步: $target_ports"
}

# 开启保护模式（自动识别放行端口）
enable_protection() {
    log_info "正在开启端口保护模式..."

    local all_ports
    all_ports=$(get_auto_allow_ports)
    [ -n "$all_ports" ] || {
        log_error "自动识别未得到可放行端口，取消开启保护"
        return 1
    }

    build_protection_rules "$all_ports" || return 1
    log_info "端口保护已开启，开放端口: $all_ports"

    enable_protect_timer_if_needed || log_warn "保护同步定时器启用失败，请手动检查"
}

# 关闭保护模式
disable_protection() {
    log_info "正在关闭端口保护模式..."
    
    local -a commands=()
    local removed=false
    chain_exists ip "$CHAIN_INPUT" && {
        commands+=("delete chain ip $TABLE_NAME $CHAIN_INPUT")
        removed=true
    }
    chain_exists ip6 "$CHAIN_INPUT" && {
        commands+=("delete chain ip6 $TABLE_NAME $CHAIN_INPUT")
        removed=true
    }
    if [ "$removed" = true ]; then
        run_nft_transaction "关闭端口保护链" "${commands[@]}" || return 1
        log_info "端口保护已关闭"
    else
        log_warn "保护模式未开启"
    fi

    disable_protect_timer_if_needed
}

# 显示保护状态
show_protection_status() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}           端口保护状态${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    if is_protection_enabled; then
        echo -e "保护状态: ${GREEN}已开启${NC}"
        
        local current_ports
        local auto_ports
        local ssh_port
        local forward_ports
        local runtime_ports
        local exclude_ports
        local timer_status

        current_ports=$(get_current_protection_ports)
        auto_ports=$(get_auto_allow_ports)
        ssh_port=$(detect_ssh_port)
        forward_ports=$(get_forwarding_ports)
        runtime_ports=$(detect_runtime_public_ports)
        exclude_ports=$(get_exclude_ports)
        timer_status=$(get_protect_timer_status)

        [ -n "$current_ports" ] && echo -e "当前放行端口: ${YELLOW}$current_ports${NC}"
        [ -n "$auto_ports" ] && echo -e "自动识别端口: ${BLUE}$auto_ports${NC}"
        [ -n "$ssh_port" ] && echo -e "SSH端口: ${BLUE}$ssh_port${NC}"
        [ -n "$forward_ports" ] && echo -e "转发端口: ${YELLOW}$forward_ports${NC}"
        [ -n "$runtime_ports" ] && echo -e "非回环监听端口: ${YELLOW}$runtime_ports${NC}"
        [ -n "$exclude_ports" ] && echo -e "排除端口: ${BLUE}$exclude_ports${NC}"

        case "$timer_status" in
            active) echo -e "自动同步: ${GREEN}已启用${NC}" ;;
            inactive) echo -e "自动同步: ${YELLOW}未启用${NC}" ;;
            *) echo -e "自动同步: ${YELLOW}systemctl 不可用${NC}" ;;
        esac
    else
        echo -e "保护状态: ${RED}未开启${NC}"
        local timer_status
        timer_status=$(get_protect_timer_status)
        case "$timer_status" in
            active) echo -e "自动同步: ${YELLOW}已启用（建议关闭）${NC}" ;;
            inactive) echo -e "自动同步: ${BLUE}未启用${NC}" ;;
            *) echo -e "自动同步: ${YELLOW}systemctl 不可用${NC}" ;;
        esac
    fi
    
    echo -e "${BLUE}========================================${NC}"
}

# ============================================================================
# 业务函数
# ============================================================================

# 显示 DDNS 域名规则状态
show_ddns_rules() {
    if [ ! -s "$DDNS_STATE_FILE" ]; then
        log_warn "未找到 DDNS 域名规则"
        return 0
    fi

    echo -e "${YELLOW}=== DDNS 域名规则状态 ===${NC}"
    local count=1

    while IFS='|' read -r src_port domain dest_port last_ip status updated_at; do
        [ -z "$src_port" ] && continue
        local ts_human
        ts_human=$(format_epoch_time "$updated_at")
        echo -e "${GREEN}${count})${NC} 源端口: ${YELLOW}${src_port}${NC} -> 域名: ${YELLOW}${domain}${NC}:${YELLOW}${dest_port}${NC} 当前IP: ${BLUE}${last_ip:-N/A}${NC} 状态: ${BLUE}${status:-unknown}${NC} 更新时间: ${BLUE}${ts_human}${NC}"
        ((count++))
    done < "$DDNS_STATE_FILE"

    return 0
}

# 同步 DDNS 域名规则到最新解析 IP
sync_ddns_rules() {
    log_info "开始执行 DDNS 同步..."

    if [ ! -s "$DDNS_STATE_FILE" ]; then
        log_warn "未配置 DDNS 域名规则，无需同步"
        disable_ddns_timer_if_no_domain_rules
        return 0
    fi

    ensure_nat_table_v4 || return 1

    local tmp_file="${DDNS_STATE_FILE}.sync.$$"
    : > "$tmp_file" || {
        log_error "无法创建 DDNS 临时状态文件"
        return 1
    }

    local changed_count=0
    local unchanged_count=0
    local failed_count=0

    while IFS='|' read -r src_port domain dest_port last_ip status updated_at; do
        [ -z "$src_port$domain$dest_port" ] && continue

        local now
        now=$(date +%s)

        if ! validate_port "$src_port" || ! validate_port "$dest_port" || ! validate_domain_name "$domain"; then
            log_warn "跳过格式异常的 DDNS 记录: ${src_port}|${domain}|${dest_port}"
            ((failed_count++))
            continue
        fi

        local new_ip=""
        new_ip=$(resolve_ddns_ipv4 "$domain")
        if [ $? -ne 0 ] || [ -z "$new_ip" ]; then
            log_warn "域名解析失败，保留原规则: $domain"
            echo "${src_port}|${domain}|${dest_port}|${last_ip}|resolve_failed|${now}" >> "$tmp_file"
            ((failed_count++))
            continue
        fi

        if [ "$new_ip" = "$last_ip" ] && [ -n "$last_ip" ]; then
            echo "${src_port}|${domain}|${dest_port}|${last_ip}|ok|${now}" >> "$tmp_file"
            ((unchanged_count++))
            continue
        fi

        if [ -n "$last_ip" ]; then
            if ! remove_forwarding_rule_by_tuple "$src_port" "$last_ip" "$dest_port" "false"; then
                log_error "旧规则删除失败，跳过本次更新: ${domain}"
                echo "${src_port}|${domain}|${dest_port}|${last_ip}|remove_failed|${now}" >> "$tmp_file"
                ((failed_count++))
                continue
            fi
        fi

        if apply_single_forwarding_rule "$src_port" "$new_ip" "$dest_port" "false"; then
            cleanup_masquerade_if_unused "$last_ip"
            echo "${src_port}|${domain}|${dest_port}|${new_ip}|ok|${now}" >> "$tmp_file"
            log_info "DDNS 更新成功: ${domain} ${last_ip:-N/A} -> ${new_ip}"
            ((changed_count++))
        else
            log_error "DDNS 更新失败，正在尝试回滚: ${domain}"
            if [ -n "$last_ip" ]; then
                apply_single_forwarding_rule "$src_port" "$last_ip" "$dest_port" "false" >/dev/null 2>&1
            fi
            echo "${src_port}|${domain}|${dest_port}|${last_ip}|apply_failed|${now}" >> "$tmp_file"
            ((failed_count++))
        fi
    done < "$DDNS_STATE_FILE"

    if ! mv "$tmp_file" "$DDNS_STATE_FILE"; then
        rm -f "$tmp_file"
        log_error "写入 DDNS 状态文件失败"
        return 1
    fi
    reconcile_ddns_timer_state

    log_info "DDNS 同步完成: 更新 ${changed_count} 条，未变化 ${unchanged_count} 条，失败 ${failed_count} 条"
}

# 批量添加规则
add_rule_batch() {
    local rules=("$@")
    
    [ ${#rules[@]} -eq 0 ] && { log_error "未提供任何规则"; return 1; }
    
    log_info "准备批量添加 ${#rules[@]} 条转发规则..."
    
    local -a success_rules failed_rules skipped_rules
    
    for rule in "${rules[@]}"; do
        log_info "处理规则: $rule"

        local local_port=""
        local dest_value=""
        local dest_port=""
        local is_local=""
        local target_type=""
        local dest_ip=""
        local domain_name=""
        local parse_error_reason=""
        if ! parse_rule_for_forwarding \
            "$rule" \
            local_port \
            dest_value \
            dest_port \
            is_local \
            target_type \
            dest_ip \
            domain_name \
            parse_error_reason; then
            failed_rules+=("$rule (${parse_error_reason:-解析失败})")
            [ "$parse_error_reason" = "域名解析失败" ] && log_error "域名解析失败: $domain_name"
            continue
        fi
        [ "$target_type" = "domain" ] && log_info "域名解析结果: ${domain_name} -> ${dest_ip}"
        
        # 检查冲突
        if ! check_rule_conflict "$local_port" "$dest_ip" "$dest_port" "$is_local"; then
            skipped_rules+=("$rule (冲突或已存在)")
            continue
        fi
        
        # 应用规则
        if apply_single_forwarding_rule "$local_port" "$dest_ip" "$dest_port" "$is_local"; then
            if [ "$target_type" = "domain" ]; then
                if ! ddns_state_upsert "$local_port" "$domain_name" "$dest_port" "$dest_ip" "ok"; then
                    log_error "DDNS 状态写入失败，正在回滚规则: $rule"
                    remove_forwarding_rule_by_tuple "$local_port" "$dest_ip" "$dest_port" "$is_local"
                    cleanup_masquerade_if_unused "$dest_ip"
                    failed_rules+=("$rule (DDNS 状态写入失败)")
                    continue
                fi
            fi

            success_rules+=("$rule")
            log_debug "规则已添加: $rule"
        else
            failed_rules+=("$rule (应用失败)")
        fi
    done
    
    # 处理结果
    if [ ${#success_rules[@]} -gt 0 ]; then
        # 更新保护模式
        if is_protection_enabled; then
            sync_protection_ports || {
                log_warn "自动同步保护端口失败，请手动执行: $0 --protect sync"
            }
        else
            enable_protection || return 1
        fi
    fi

    reconcile_ddns_timer_state
    
    # 输出摘要
    print_batch_summary success_rules skipped_rules failed_rules
    [ ${#success_rules[@]} -gt 0 ] && show_protection_status
}

# 原子替换规则（全部校验成功后一次提交）
replace_rules_batch() {
    local rules=("$@")
    [ ${#rules[@]} -eq 0 ] && { log_error "未提供任何规则"; return 1; }

    log_info "准备原子替换为 ${#rules[@]} 条新规则..."

    local -A seen_rule_keys=()
    local -A port_mode_map=()
    local -A remote_ips_map=()
    local -a candidate_entries=()
    local -a ddns_entries=()
    local -a failed_rules=()
    local now
    now=$(date +%s)

    local rule=""
    for rule in "${rules[@]}"; do
        local local_port=""
        local dest_value=""
        local dest_port=""
        local is_local=""
        local target_type=""
        local dest_ip=""
        local domain_name=""
        local parse_error_reason=""
        if ! parse_rule_for_forwarding \
            "$rule" \
            local_port \
            dest_value \
            dest_port \
            is_local \
            target_type \
            dest_ip \
            domain_name \
            parse_error_reason; then
            failed_rules+=("$rule (${parse_error_reason:-解析失败})")
            continue
        fi

        local mode="remote"
        [ "$is_local" = "true" ] && mode="local"
        if [ -n "${port_mode_map[$local_port]}" ] && [ "${port_mode_map[$local_port]}" != "$mode" ]; then
            failed_rules+=("$rule (端口 ${local_port} 同时用于本地与远程转发)")
            continue
        fi
        port_mode_map["$local_port"]="$mode"

        local rule_key="${local_port}|${dest_ip}|${dest_port}|${is_local}"
        if [ -n "${seen_rule_keys[$rule_key]}" ]; then
            failed_rules+=("$rule (重复规则)")
            continue
        fi
        seen_rule_keys["$rule_key"]=1
        candidate_entries+=("$rule_key")

        if [ "$is_local" != "true" ]; then
            remote_ips_map["$dest_ip"]=1
        fi

        if [ "$target_type" = "domain" ]; then
            ddns_entries+=("${local_port}|${domain_name}|${dest_port}|${dest_ip}|ok|${now}")
        fi
    done

    if [ ${#failed_rules[@]} -gt 0 ]; then
        log_error "替换前校验失败，已取消所有变更"
        local bad=""
        for bad in "${failed_rules[@]}"; do
            echo -e "  ${RED}✗${NC} $bad"
        done
        return 1
    fi

    [ ${#candidate_entries[@]} -gt 0 ] || { log_error "无可应用的新规则"; return 1; }

    ensure_output_chain || return 1
    if [ ${#remote_ips_map[@]} -gt 0 ]; then
        ensure_ipv4_forwarding_enabled || true
    fi

    local -a commands=()
    commands+=("flush chain ip $TABLE_NAME $CHAIN_PREROUTING")
    commands+=("flush chain ip $TABLE_NAME $CHAIN_POSTROUTING")
    commands+=("flush chain ip $TABLE_NAME $CHAIN_OUTPUT")

    local entry=""
    for entry in "${candidate_entries[@]}"; do
        local local_port dest_ip dest_port is_local
        IFS='|' read -r local_port dest_ip dest_port is_local <<< "$entry"

        if [ "$is_local" = "true" ]; then
            commands+=("add rule ip $TABLE_NAME $CHAIN_OUTPUT tcp dport $local_port dnat to ${dest_ip}:${dest_port}")
            commands+=("add rule ip $TABLE_NAME $CHAIN_OUTPUT udp dport $local_port dnat to ${dest_ip}:${dest_port}")
        else
            commands+=("add rule ip $TABLE_NAME $CHAIN_PREROUTING tcp dport $local_port dnat to ${dest_ip}:${dest_port}")
            commands+=("add rule ip $TABLE_NAME $CHAIN_PREROUTING udp dport $local_port dnat to ${dest_ip}:${dest_port}")
        fi
    done

    local remote_ip=""
    for remote_ip in "${!remote_ips_map[@]}"; do
        commands+=("add rule ip $TABLE_NAME $CHAIN_POSTROUTING ip daddr $remote_ip masquerade")
    done

    run_nft_transaction "原子替换全部转发规则" "${commands[@]}" || return 1

    ensure_ddns_state || return 1
    clear_ddns_state
    local ddns_line=""
    for ddns_line in "${ddns_entries[@]}"; do
        echo "$ddns_line" >> "$DDNS_STATE_FILE"
    done

    if is_protection_enabled; then
        sync_protection_ports || return 1
    else
        enable_protection || return 1
    fi

    reconcile_ddns_timer_state
    log_info "原子替换完成，共应用 ${#candidate_entries[@]} 条规则"
    show_protection_status
}

# 打印批量操作摘要
print_batch_summary() {
    local -n _success=$1 _skipped=$2 _failed=$3
    
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}           批量添加结果摘要${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    echo -e "${GREEN}成功添加: ${#_success[@]} 条${NC}"
    for rule in "${_success[@]}"; do echo -e "  ${GREEN}✓${NC} $rule"; done
    
    if [ ${#_skipped[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}跳过规则: ${#_skipped[@]} 条${NC}"
        for rule in "${_skipped[@]}"; do echo -e "  ${YELLOW}○${NC} $rule"; done
    fi
    
    if [ ${#_failed[@]} -gt 0 ]; then
        echo -e "\n${RED}失败规则: ${#_failed[@]} 条${NC}"
        for rule in "${_failed[@]}"; do echo -e "  ${RED}✗${NC} $rule"; done
    fi
    
    echo -e "${BLUE}========================================${NC}"
}

# 显示当前规则
display_rules() {
    log_info "当前端口转发规则:"

    local has_forward_rules=false
    if parse_ruleset_to_map; then
        has_forward_rules=true
        echo -e "${YELLOW}=== 端口转发规则 ===${NC}"
        local count=1

        for key in "${!RULE_MAP[@]}"; do
            local src_port=$(echo "$key" | cut -d':' -f1)
            local dest="${RULE_MAP[$key]}"
            local protocol="${RULE_PROTOCOLS[$key]}"
            local type="${RULE_TYPE[$key]}"

            if [ "$type" = "local" ]; then
                echo -e "${GREEN}$count)${NC} ${BLUE}[本地]${NC} 端口: ${YELLOW}$src_port${NC} -> ${YELLOW}$dest${NC} (${BLUE}$protocol${NC})"
            else
                echo -e "${GREEN}$count)${NC} 端口: ${YELLOW}$src_port${NC} -> 目标: ${YELLOW}$dest${NC} (${BLUE}$protocol${NC})"
            fi
            ((count++))
        done
    fi

    if [ -s "$DDNS_STATE_FILE" ]; then
        echo ""
        show_ddns_rules
    elif [ "$has_forward_rules" = false ]; then
        log_warn "未找到转发规则"
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
用法:
  $0 --help
  $0 --list
  $0 --add <规则1> [规则2 ...]
  $0 --replace <规则1> [规则2 ...]
  $0 --ddns-sync
  $0 --ddns-list
  $0 --protect on
  $0 --protect off
  $0 --protect status
  $0 --protect sync

规则格式:
  <源端口>:<目标(IPv4/域名/local)>:<目标端口>
EOF
}

# ============================================================================
# 初始化函数
# ============================================================================

initialize_nftables() {
    log_info "正在初始化 nftables 端口转发配置"
    ensure_nft_base_structures || return 1
    ensure_nft_main_config_include || return 1
    log_info "nftables 基础结构检查完成"
}

cmd_add_rules() {
    initialize_nftables || return 1
    add_rule_batch "$@"
}

cmd_replace_rules() {
    initialize_nftables || return 1
    replace_rules_batch "$@"
}

cmd_ddns_sync() {
    initialize_nftables || return 1
    sync_ddns_rules
}

cmd_protect_on() {
    initialize_nftables || return 1
    enable_protection
}

cmd_protect_off() {
    disable_protection
}

cmd_protect_sync() {
    sync_protection_ports
}

# ============================================================================
# 主流程
# ============================================================================

ensure_supported_bash || exit 1

# 命令行参数处理
[ $# -eq 0 ] && { show_help; exit 0; }

case "$1" in
    --help|-h)
        show_help
        ;;
    --list|-l)
        ensure_nft_installed || exit 1
        display_rules || exit 1
        ;;
    --add|-a)
        ensure_root_and_nft || exit 1
        shift
        [ $# -eq 0 ] && { log_error "未提供任何规则。用法: $0 --add 规则1 [规则2 ...]"; show_help; exit 1; }
        run_locked_mutation_with_persistence "批量添加转发规则" cmd_add_rules "$@" || exit 1
        ;;
    --replace|-r)
        ensure_root_and_nft || exit 1
        shift
        [ $# -eq 0 ] && { log_error "未提供任何规则。用法: $0 --replace 规则1 [规则2 ...]"; show_help; exit 1; }
        run_locked_mutation_with_persistence "原子替换转发规则" cmd_replace_rules "$@" || exit 1
        ;;
    --ddns-sync)
        ensure_root_and_nft || exit 1
        run_locked_mutation_with_persistence "DDNS 同步" cmd_ddns_sync || exit 1
        ;;
    --ddns-list)
        show_ddns_rules || exit 1
        ;;
    --protect|-p)
        shift
        [ $# -eq 0 ] && { log_error "未提供保护模式参数。用法: $0 --protect [on|off|status|sync]"; show_help; exit 1; }
        case "$1" in
            on)
                ensure_root_and_nft || exit 1
                run_locked_mutation_with_persistence "开启端口保护" cmd_protect_on || exit 1
                show_protection_status || exit 1
                ;;
            off)
                ensure_root_and_nft || exit 1
                run_locked_mutation_with_persistence "关闭端口保护" cmd_protect_off || exit 1
                show_protection_status || exit 1
                ;;
            status)
                ensure_nft_installed || exit 1
                show_protection_status || exit 1
                ;;
            sync)
                ensure_root_and_nft || exit 1
                run_locked_mutation_with_persistence "同步端口保护" cmd_protect_sync || exit 1
                ;;
            *)      log_error "未知的保护模式参数: $1"; exit 1 ;;
        esac
        ;;
    *)
        log_error "未知参数: $1"
        show_help
        exit 1
        ;;
esac

exit 0
