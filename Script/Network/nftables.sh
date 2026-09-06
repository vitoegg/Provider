#!/bin/bash
# state.db 是唯一声明真值；forwardaws.nft 是可重新生成的运行规则。
# 运行环境为 Debian/Ubuntu，依赖 Bash 4+、nftables、util-linux、iproute2 与 procfs。
set -o pipefail
readonly NAT_TABLE_NAME="forwardaws_nat"
readonly FILTER_TABLE_NAME="forwardaws_filter"
readonly NFT_MAIN_CONFIG_FILE="/etc/nftables.conf"
readonly NFT_INCLUDE_DIR="/etc/nftables.d"
readonly FORWARDAWS_RULES_FILE="${NFT_INCLUDE_DIR}/forwardaws.nft"
readonly NFT_INCLUDE_MARKER="# Managed by Provider nftables.sh"
readonly STATE_DIR="/etc/forwardaws"
readonly STATE_FILE="${STATE_DIR}/state.db"
readonly RULES_STATE_FILE="${STATE_DIR}/rules.db"
readonly CONFIG_FILE="${STATE_DIR}/config.env"
readonly GLOBAL_LOCK_FILE="/run/forwardaws.lock"
readonly IPV4_FORWARD_SYSCTL_FILE="/etc/sysctl.d/99-forwardaws.conf"
readonly SYSTEMD_SYSTEM_DIR="/etc/systemd/system"
readonly PROTECT_SERVICE_NAME="forwardaws-protect.service"
readonly PROTECT_TIMER_NAME="forwardaws-protect.timer"
readonly WHITELIST_SERVICE_NAME="forwardaws-whitelist.service"
readonly WHITELIST_PATH_NAME="forwardaws-whitelist.path"
readonly PROVIDERDNS_CONSUMER="forwardaws"
PROVIDERDNS_BIN="${PROVIDERDNS_BIN:-}"
readonly PROVIDERDNS_LOCAL_NAME="providerdns.sh"
readonly DEFAULT_EXCLUDE_PORTS="53"
readonly SERVICE_ALLOW_MARK="0x40000000"
SYSTEMD_UNITS_CHANGED=0
PARSED_PROTECT=0
PARSED_WHITELIST=""
PARSED_PING=""
PARSED_RULES=()
TX_DIR="" TX_RULES="" TX_PROTECTION=0 TX_WHITELIST=any
TX_WHITELIST_FILE="" TX_PING=any
TX_DOMAINS_FILE=""
log_info() {
    [ "${FORWARDAWS_QUIET:-${QUIET:-0}}" = "1" ] || printf '[INFO] %s\n' "$*"
}
log_warning() {
    printf '[WARNING] %s\n' "$*" >&2
}
log_error() {
    printf '[ERROR] %s\n' "$*" >&2
}
abort_operation() {
    log_error "$*"
    exit 1
}
require_success() {
    local message="$1"
    shift
    "$@" && return 0
    log_error "$message"
    return 1
}
show_help() {
    cat << EOF
用法:
  $0 --help|-h
  $0 --list|-l
  $0 --add|-a <规则> [规则 ...] [--protect [whitelist=<绝对路径>.nft] [ping=<值>]]
  $0 --delete|-d <规则> [规则 ...] [--protect [whitelist=<绝对路径>.nft] [ping=<值>]]
  $0 --replace|-r <规则> [规则 ...] [--protect [whitelist=<绝对路径>.nft] [ping=<值>]]
  $0 --protect [whitelist=<绝对路径>.nft] [ping=<值>]
  $0 --sync
  $0 --clean <ping|whitelist|forward|protect|all>
规则格式:
  <源端口>:<目标(IPv4/域名)>:<目标端口>[:SNAT_IP[:MSS]]
保护值:
  whitelist=<绝对路径>.nft
  ping=any|off|<IPv4或域名逗号列表>
EOF
}
# CLI 与声明校验
require_arg_count() {
    local expected="$1" message="$2"
    shift 2
    require_success "$message" test "$#" -eq "$expected"
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
validate_domain_name() {
    local domain="$1"
    [[ "$domain" =~ ^[0-9]+([.][0-9]+){3}$ ]] && return 1
    [ -n "$domain" ] && [ "${#domain}" -le 253 ] && \
        [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\
([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}
validate_ping_spec() {
    local spec="$1" item
    local -a items
    case "$spec" in
        any|off)
            return 0
            ;;
        ""|,*|*,|*,,*)
            return 1
            ;;
    esac
    IFS=',' read -ra items <<< "$spec"
    for item in "${items[@]}"; do
        validate_ip_address "$item" || validate_domain_name "$item" || return 1
    done
}
normalize_whitelist_path() {
    local input="$1" path owner mode
    [[ "$input" == /*.nft ]] || {
        log_error "whitelist 必须是绝对 .nft 文件: $input"
        return 1
    }
    require_success "whitelist 不允许使用符号链接: $input" test ! -L "$input" || return 1
    path=$(readlink -f -- "$input" 2>/dev/null) || return 1
    [[ "$path" =~ ^/([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+[.]nft$ ]] || {
        log_error "whitelist 路径包含不支持的字符: $path"
        return 1
    }
    case "$path" in
        /proc/*|/sys/*|/dev/*|/run/*|/tmp/*)
            log_error "whitelist 不允许位于易失或伪文件系统: $path"
            return 1
            ;;
    esac
    require_success "whitelist 不允许覆盖脚本自有文件: $path" test "$path" != "$FORWARDAWS_RULES_FILE" || return 1
    if [ ! -f "$path" ] || [ ! -s "$path" ]; then
        log_error "whitelist 必须是非空普通文件: $path"
        return 1
    fi
    read -r owner mode < <(stat -c '%u %a' -- "$path" 2>/dev/null) || return 1
    if [ "$owner" != "0" ] || (( (8#$mode & 022) != 0 )); then
        log_error "whitelist 必须归 root 所有且禁止 group/other 写入: $path"
        return 1
    fi
    printf '%s\n' "$path"
}
parse_rule() {
    local rule_string="$1" src_port target dest_port snat_ip mss type ip="" status
    [[ "$rule_string" =~ ^[^:]+:[^:]+:[^:]+(:[^:]+(:[^:]+)?)?$ ]] || {
        log_error "规则格式错误: $rule_string"
        log_error "正确格式: 端口:目标(IPv4/域名):端口[:SNAT_IP[:MSS]]"
        return 1
    }
    IFS=':' read -r src_port target dest_port snat_ip mss <<< "$rule_string"
    require_success "无效的源端口: $src_port" validate_port "$src_port" || return 1
    require_success "无效的目标端口: $dest_port" validate_port "$dest_port" || return 1
    if [ -n "$snat_ip" ]; then
        require_success "无效的 SNAT IP: $snat_ip" validate_ip_address "$snat_ip" || return 1
    fi
    if [ -n "$mss" ] && [ "$mss" != "auto" ]; then
        if ! [[ "$mss" =~ ^[0-9]+$ ]] || [ "$mss" -lt 536 ] || [ "$mss" -gt 9000 ]; then
            log_error "无效的 MSS: $mss (必须为 auto 或 536-9000 之间的数字)"
            return 1
        fi
    fi
    case "$target" in
        local|localhost|127.0.0.1)
            log_error "不再支持本地转发: $target"
            return 1
            ;;
    esac
    if validate_ip_address "$target"; then
        type=ipv4 ip="$target" status=ok
    elif validate_domain_name "$target"; then
        type=domain status=pending
    else
        log_error "无效的目标地址: $target"
        return 1
    fi
    # 第 11 列仅用于批次错误提示，不写入持久声明。
    printf -v PARSED_RULE '%s|remote|%s|%s|%s|%s|%s||%s|%s|%s' \
        "$src_port" "$target" "$dest_port" "$type" "$ip" "$status" "$snat_ip" "$mss" "$rule_string"
}
parse_protect_fields() {
    local arg value
    PARSED_WHITELIST=""
    PARSED_PING=""
    for arg in "$@"; do
        case "$arg" in
            whitelist=*)
                require_success "whitelist 只能指定一次" test -z "$PARSED_WHITELIST" || return 1
                value="${arg#whitelist=}"
                require_success "whitelist 值不能为空" test -n "$value" || return 1
                PARSED_WHITELIST=$(normalize_whitelist_path "$value") || return 1
                ;;
            ping=*)
                require_success "ping 只能指定一次" test -z "$PARSED_PING" || return 1
                value="${arg#ping=}"
                require_success "ping 值无效: $value" validate_ping_spec "$value" || return 1
                PARSED_PING="$value"
                ;;
            *)
                log_error "未知的保护参数: $arg"
                return 1
                ;;
        esac
    done
}
parse_rule_command() {
    local arg
    PARSED_PROTECT=0
    PARSED_RULES=()
    parse_protect_fields || return 1
    while [ $# -gt 0 ]; do
        arg="$1"
        shift
        if [ "$arg" = "--protect" ]; then
            PARSED_PROTECT=1
            parse_protect_fields "$@" || return 1
            break
        fi
        parse_rule "$arg" || return 1
        PARSED_RULES+=("$PARSED_RULE")
    done
    require_success "未提供任何规则" test "${#PARSED_RULES[@]}" -gt 0
}
get_script_absolute_path() {
    readlink -f "$0" 2>/dev/null
}
providerdns_bin() {
    local local_path="$PROVIDERDNS_BIN"
    if [ -z "$local_path" ]; then
        local_path=$(get_script_absolute_path) || return 1
        local_path="${local_path%/*}/${PROVIDERDNS_LOCAL_NAME}"
    fi
    [ -f "$local_path" ] || return 1
    printf '%s\n' "$local_path"
}
require_providerdns() {
    providerdns_bin >/dev/null && return 0
    log_error "需要 providerdns.sh：请设置 PROVIDERDNS_BIN，或将 providerdns.sh 放在当前脚本同目录"
    return 1
}
run_providerdns() {
    local bin="${PROVIDERDNS_BIN:-}"
    [ -n "$bin" ] || bin=$(providerdns_bin) || return 1
    [ -f "$bin" ] || return 1
    /bin/bash "$bin" "$@"
}
providerdns_set_forwardaws() {
    local domains_file="$1" script_path hook_command quoted_script_path
    require_providerdns || return 1
    script_path=$(get_script_absolute_path)
    printf -v quoted_script_path '%q' "$script_path"
    hook_command="FORWARDAWS_SYNC_SOURCE=providerdns FORWARDAWS_QUIET=1 "
    hook_command+="FORWARDAWS_LOCK_WAIT=10 /bin/bash ${quoted_script_path} --sync"
    PROVIDERDNS_QUIET=1 run_providerdns --set "$PROVIDERDNS_CONSUMER" "$domains_file" "$hook_command"
}
providerdns_unset_forwardaws() {
    providerdns_bin >/dev/null || {
        log_warning "未找到 providerdns.sh，无法回收 DNS 订阅：${PROVIDERDNS_CONSUMER}"
        return 0
    }
    PROVIDERDNS_QUIET=1 run_providerdns --unset "$PROVIDERDNS_CONSUMER"
}
# 系统依赖与持久状态
require_root() {
    require_success "此操作必须以 root 权限运行" test "$EUID" -eq 0
}
ensure_dependencies() {
    local -a missing=()
    command -v nft >/dev/null 2>&1 || missing+=(nftables)
    command -v flock >/dev/null 2>&1 || missing+=(util-linux)
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    command -v sysctl >/dev/null 2>&1 || missing+=(procps)
    command -v readlink >/dev/null 2>&1 || missing+=(coreutils)
    command -v stat >/dev/null 2>&1 || missing+=(coreutils)
    [ "${#missing[@]}" -gt 0 ] || return 0
    command -v apt-get >/dev/null 2>&1 || abort_operation "缺少依赖且未检测到 apt-get：${missing[*]}"
    FORWARDAWS_QUIET=0 QUIET=0 log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || abort_operation "软件包索引更新失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        abort_operation "依赖安装失败：${missing[*]}"
    FORWARDAWS_QUIET=0 QUIET=0 log_info "已安装依赖：${missing[*]}"
}
acquire_global_lock() {
    local wait="${FORWARDAWS_LOCK_WAIT:-0}" deadline
    [[ "$wait" =~ ^[0-9]+$ ]] || wait=0
    deadline=$((SECONDS + 10#$wait + 1))
    while [ "$SECONDS" -lt "$deadline" ]; do
        exec 9>"$GLOBAL_LOCK_FILE" || return 1
        if [ "$wait" -gt 0 ]; then
            flock -w "$wait" 9
        else
            flock -n 9
        fi || abort_operation "无法获取全局锁，请稍后重试"
        # clean 可删除锁路径；等待者必须确认锁住的是当前路径的 inode。
        [[ "$GLOBAL_LOCK_FILE" -ef /proc/self/fd/9 ]] && return 0
        exec 9>&-
        [ "$wait" -eq 0 ] || wait=$((deadline - SECONDS))
    done
    log_error "全局锁路径持续变化，请稍后重试"
    return 1
}
ensure_for_write() {
    require_root || return 1
    ensure_dependencies || return 1
    acquire_global_lock || return 1
    mkdir -p "$STATE_DIR" "$NFT_INCLUDE_DIR" || return 1
    rm -rf "${STATE_DIR:?}"/.tx.* 2>/dev/null || true
}
converge_owned_files() {
    local whitelist path
    whitelist="$TX_WHITELIST_FILE $PARSED_WHITELIST"
    find "$STATE_DIR" -maxdepth 1 -type f \
        ! -name "${STATE_FILE##*/}" ! -name "${RULES_STATE_FILE##*/}" ! -name "${CONFIG_FILE##*/}" \
        -delete 2>/dev/null || true
    while IFS= read -r path; do
        [[ " $whitelist " == *" $path "* ]] || rm -f -- "$path" || return 1
    done < <(find "$NFT_INCLUDE_DIR" -maxdepth 1 -type f -name 'forwardaws*' \
        ! -name "${FORWARDAWS_RULES_FILE##*/}" 2>/dev/null)
}
load_state() {
    local key value file="$STATE_FILE"
    local -A values=()
    TX_SOURCE="$STATE_FILE"
    if [ ! -f "$STATE_FILE" ]; then
        file="$CONFIG_FILE"
        TX_SOURCE="$RULES_STATE_FILE"
    fi
    [ -f "$file" ] || file=/dev/null
    [ -f "$TX_SOURCE" ] || TX_SOURCE=/dev/null
    while IFS='=' read -r key value || [ -n "$key" ]; do
        [[ "$key" =~ ^(PROTECTION_ENABLED|PROTECT_(WHITELIST|WHITELIST_FILE|PING|NOPING))$ ]] || continue
        [ "${values[$key]+set}" ] || values[$key]="$value"
    done < "$file"
    TX_PROTECTION="${values[PROTECTION_ENABLED]-0}"
    TX_WHITELIST="${values[PROTECT_WHITELIST]-any}"
    TX_WHITELIST_FILE="${values[PROTECT_WHITELIST_FILE]-}"
    TX_PING="${values[PROTECT_PING]:-}"
    if [ -z "$TX_PING" ]; then
        TX_PING="${values[PROTECT_NOPING]-any}"
        [ "$TX_PING" != 0 ] || TX_PING=any
        [ "$TX_PING" != 1 ] || TX_PING=off
    fi
    [ "${1:-validate}" != raw ] || return 0
    require_success "保护状态文件无效" test "$TX_PROTECTION" = 0 -o "$TX_PROTECTION" = 1 || return 1
    [[ "$TX_WHITELIST" = any || "$TX_WHITELIST" = /*.nft ]] || abort_operation "whitelist 状态无效: $TX_WHITELIST"
    require_success "ping 状态无效: $TX_PING" validate_ping_spec "$TX_PING"
}
nft_main_config_include_is_current() {
    [ -f "$NFT_MAIN_CONFIG_FILE" ] || return 1
    awk -v marker="$NFT_INCLUDE_MARKER" -v dir="$NFT_INCLUDE_DIR" \
        -v expected="include \"$FORWARDAWS_RULES_FILE\"" '
        pending && !captured { owned=$0; captured=1 }
        $0==marker { pending=1; next }
        pending { pending=0; next }
        $0 ~ "^[[:space:]]*include[[:space:]]+\"?" dir "/(\\*|forwardaws)[.]nft\"?[[:space:]]*$" { foreign=1 }
        END { exit(owned!="" ? owned!=expected : !foreign) }
    ' "$NFT_MAIN_CONFIG_FILE"
}
remove_own_include_block() {
    awk -v marker="$NFT_INCLUDE_MARKER" '
        $0==marker { skip=1; next }
        skip { skip=0; next }
        { print }
    ' "$NFT_MAIN_CONFIG_FILE"
}
ensure_nft_main_config_include() {
    local content=""
    if ! nft_main_config_include_is_current; then
        if [ -f "$NFT_MAIN_CONFIG_FILE" ]; then
            content=$(remove_own_include_block) || return 1
        fi
        content+=$'\n'"$NFT_INCLUDE_MARKER"$'\n'"include \"$FORWARDAWS_RULES_FILE\""
        write_text_file "$NFT_MAIN_CONFIG_FILE" <<< "$content" || return 1
    fi
    if has_systemctl && ! systemctl is-enabled nftables.service >/dev/null 2>&1; then
        if systemctl enable nftables.service >/dev/null 2>&1; then
            log_info "已启用系统服务：nftables.service"
        else
            log_warning "无法启用 nftables.service，重启后规则可能丢失"
        fi
    fi
}
ensure_ipv4_forwarding_enabled() {
    local current
    current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || current=0
    write_text_file "$IPV4_FORWARD_SYSCTL_FILE" <<< 'net.ipv4.ip_forward=1' || return 1
    [ "$FILE_CHANGED" -eq 0 ] || log_info "已持久化 IPv4 转发配置：$IPV4_FORWARD_SYSCTL_FILE"
    if [ "$current" != 1 ]; then
        require_success "无法启用 net.ipv4.ip_forward=1，远程端口转发无法生效" \
            sysctl -w net.ipv4.ip_forward=1 >/dev/null || return 1
        log_info "已启用 IPv4 转发"
    fi
}
get_auto_allow_ports() {
    local ssh_config="" ssh_ports="" key port listeners dual=both
    if command -v sshd >/dev/null 2>&1; then
        ssh_config=$(sshd -T 2>/dev/null) || abort_operation "无法读取 SSH 生效配置，拒绝应用端口保护"
        while read -r key port _; do
            if [ "$key" = port ] && validate_port "$port"; then
                ssh_ports+="${port},"
            fi
        done <<< "$ssh_config"
        [ -n "$ssh_ports" ] || abort_operation "SSH 生效配置未包含有效端口，拒绝应用端口保护"
    fi
    command -v ss >/dev/null 2>&1 || abort_operation "缺少依赖命令：ss"
    listeners=$(ss -H -lntu 2>/dev/null) || abort_operation "无法检测监听端口，拒绝应用端口保护"
    [ "$(sysctl -n net.ipv6.bindv6only 2>/dev/null)" != 1 ] || dual=v6
    # 一次扫描监听项，按地址族/协议去重；SSH 端口最后加入，不受排除列表影响。
    printf '%s\n' "$listeners" | awk -v ssh="$ssh_ports" -v dual="$dual" \
        -v exclude="${DEFAULT_EXCLUDE_PORTS},${FORWARDAWS_EXCLUDE_PORTS:-}" '
        function valid(p) { return p ~ /^[0-9]+$/ && p+0 >= 1 && p+0 <= 65535 }
        function add(group, port) {
            if (!((group SUBSEP (port+0)) in ports)) ports[group,port+0]=port
        }
        BEGIN {
            gsub(/ /, "", exclude)
            n=split(exclude, values, ",")
            for (i=1; i<=n; i++) {
                p=values[i]
                if (valid(p) && !((p+0) in excluded)) excluded[p+0]=p
            }
        }
        NF>=2 {
            protocol=$1; endpoint=$(NF-1)
            port=endpoint; sub(/^.*:/, "", port)
            address=endpoint; sub(/:[^:]*$/, "", address)
            sub(/^\[/, "", address); sub(/\]$/, "", address); sub(/%.*/, "", address)
            if (!valid(port) || address=="::1" || address ~ /^127[.]/) next
            if (protocol!="tcp" && protocol!="udp") next
            family=(address=="*" ? "both" : address=="::" ? dual : index(address, ":") ? "v6" : "v4")
            group=(protocol=="tcp" ? 1 : 2)
            if (family!="v6") add(group, port)
            if (family!="v4") add(group+2, port)
        }
        END {
            for (key in ports) {
                split(key, parts, SUBSEP); group=parts[1]; port=ports[key]
                if (("" port)==("" excluded[port+0]) || (group==2 && port=="68") || (group==4 && port=="546"))
                    delete ports[key]
            }
            n=split(ssh, fields, ",")
            for (i=1; i<=n; i++) if (valid(fields[i])) {
                add(1, fields[i]); add(3, fields[i])
            }
            for (key in ports) {
                split(key, parts, SUBSEP)
                print parts[1], ports[key]
            }
        }
    ' | sort -k1,1n -k2,2n | awk '
        { ports[$1]=ports[$1] (ports[$1]!="" ? "," : "") $2 }
        END { printf "%s|%s|%s|%s\n", ports[1], ports[2], ports[3], ports[4] }
    '
}
# 候选补全与 ruleset 渲染
sync_providerdns_subscription() {
    if [ -s "$TX_DOMAINS_FILE" ]; then
        providerdns_set_forwardaws "$TX_DOMAINS_FILE"
    else
        providerdns_unset_forwardaws
    fi
}
snapshot_candidate() {
    local candidate="$1" ping_spec="$2" refresh="$3" mode=cache
    local PROVIDERDNS_BIN="${PROVIDERDNS_BIN:-}"
    TX_DOMAINS_FILE="${candidate}.domains"
    TX_CACHE_FILE="${candidate}.cache"
    : > "$TX_CACHE_FILE" || return 1
    if [ -s "$TX_DOMAINS_FILE" ]; then
        require_providerdns || return 1
        PROVIDERDNS_BIN=$(providerdns_bin) || return 1
        [ "$refresh" != 1 ] || mode=refresh
        PROVIDERDNS_QUIET=1 PROVIDERDNS_LOCK_WAIT="${PROVIDERDNS_LOCK_WAIT:-10}" \
            run_providerdns --snapshot "$mode" "$TX_DOMAINS_FILE" > "$TX_CACHE_FILE" || return 1
    fi
}
list_owned_nft_tables() {
    nft list tables 2>/dev/null |
        awk '$1=="table" && $3 ~ /^for?wardaws/ { print $2 "\t" $3 }'
}
nft_purge_prelude() {
    printf '%s\n' "$@" | sort -u |
        awk -F'\t' 'NF==2 { printf "table %s %s\ndelete table %s %s\n", $1, $2, $1, $2 }'
}
compile_candidate() {
    local purge
    purge=$(nft_purge_prelude $'ip\t'"$NAT_TABLE_NAME" $'inet\t'"$FILTER_TABLE_NAME" "$4") || return 1
    FORWARDAWS_PURGE="$purge" awk -F'|' -v nat="$NAT_TABLE_NAME" -v filter="$FILTER_TABLE_NAME" \
        -v protect="$TX_PROTECTION" -v whitelist="$TX_WHITELIST" -v ping="$TX_PING" \
        -v allow="${5:-}" -v service_mark="$SERVICE_ALLOW_MARK" -v now="$(date +%s)" \
        -v owner="$TX_WHITELIST_FILE" -v state_output="$2" -v metadata="$3" '
        function valid_ip(ip, parts, n, i) {
            if (ip !~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) return 0
            n=split(ip, parts, ".")
            for (i=1; i<=n; i++) if (parts[i]+0>255) return 0
            return n==4
        }
        function reject(target) {
            printf "[ERROR] 域名 %s 没有当前或历史有效 IPv4，取消本次变更\n", target > "/dev/stderr"
            failed=1; exit 1
        }
        function sort_ips(left, right, i, j, pivot, value) {
            i=left; j=right; pivot=addresses[int((left+right)/2)]
            while (i<=j) {
                while (addresses[i]<pivot) i++
                while (addresses[j]>pivot) j--
                if (i<=j) { value=addresses[i]; addresses[i++]=addresses[j]; addresses[j--]=value }
            }
            if (left<j) sort_ips(left, j)
            if (i<right) sort_ips(i, right)
        }
        BEGIN {
            OFS="|"
            printf "PROTECTION_ENABLED=%s\nPROTECT_WHITELIST=%s\nPROTECT_WHITELIST_FILE=%s\nPROTECT_PING=%s\n", \
                protect, whitelist, owner, ping > state_output
        }
        FILENAME==ARGV[1] {
            split($0, cache, "\t")
            ip[cache[1]]=cache[2]; status[cache[1]]=cache[3]
            valid[cache[1]]=valid_ip(cache[2])
            next
        }
        NF>=8 {
            if ($5=="domain") {
                if (!valid[$3]) reject($3)
                if ($6!=ip[$3]) $8=now
                $6=ip[$3]; $7=status[$3]
            }
            print > state_output
        }
        function rule(s) { return "        " s "\n" }
        NF>=8 && $2=="remote" && $6 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
            has_forward=1
            pre=pre rule("fib daddr type local tcp dport " $1 " dnat to " $6 ":" $4) \
                rule("fib daddr type local udp dport " $1 " dnat to " $6 ":" $4)
            if ($9!="") {
                post=post rule("ct status dnat ip daddr " $6 " tcp dport " $4 " snat to " $9) \
                    rule("ct status dnat ip daddr " $6 " udp dport " $4 " snat to " $9)
            } else {
                post=post rule("ct status dnat ip daddr " $6 " tcp dport " $4 " masquerade") \
                    rule("ct status dnat ip daddr " $6 " udp dport " $4 " masquerade")
            }
            if ($10!="") {
                value=($10=="auto" ? "rt mtu" : $10)
                mss=mss rule("ct status dnat ip daddr " $6 " tcp dport " $4 \
                    " tcp flags syn tcp option maxseg size set " value)
            }
        }
        END {
            if (failed) exit 1
            if (ping!="any" && ping!="off") {
                n=split(ping, targets, ",")
                for (i=1; i<=n; i++) {
                    address=(valid_ip(targets[i]) ? targets[i] : ip[targets[i]])
                    if (!valid_ip(address)) reject(targets[i])
                    if (!seen[address]++) addresses[++count]=address
                }
                if (count>1) sort_ips(1, count)
                ping_ips=""
                for (i=1; i<=count; i++) ping_ips=ping_ips (i>1 ? "," : "") addresses[i]
            }
            print has_forward+0, ping_ips > metadata
            split(allow, ports, "|")
            print "#!/usr/sbin/nft -f"
            print "# forwardaws generated by nftables.sh"
            printf "\n%s\n", ENVIRON["FORWARDAWS_PURGE"]
            print "\ntable ip " nat " {\n    chain prerouting {\n" \
                "        type nat hook prerouting priority -100; policy accept;"
            printf "%s", pre
            print "    }\n\n    chain postrouting {\n        type nat hook postrouting priority 100; policy accept;"
            printf "%s", post
            print "    }\n}"
            print "\ntable inet " filter " {"
            if (whitelist ~ /^\//) print "    include \"" whitelist "\""
            if (mss!="") {
                print "    chain forward_mss {\n        type filter hook forward priority -150; policy accept;"
                printf "%s", mss
                print "    }"
            }
            if (protect=="1") {
                print "    chain input {\n        type filter hook input priority 0; policy drop;"
                print "        iifname \"lo\" accept"
                print "        meta mark & " service_mark " != 0 meta mark set meta mark & 0xbfffffff accept"
                print "        ct state established,related accept"
                if (ping=="off") {
                    print "        ip protocol icmp icmp type echo-request drop"
                    print "        meta l4proto ipv6-icmp icmpv6 type echo-request drop"
                } else if (ping!="any") {
                    print "        ip saddr { " ping_ips " } ip protocol icmp icmp type echo-request accept"
                    print "        ip protocol icmp icmp type echo-request drop"
                    print "        meta l4proto ipv6-icmp icmpv6 type echo-request drop"
                }
                print "        ip protocol icmp accept\n        meta l4proto ipv6-icmp accept"
                print "        meta nfproto ipv4 udp sport 67 udp dport 68 limit rate 20/second accept"
                print "        ip6 saddr fe80::/10 udp sport 547 udp dport 546 limit rate 20/second accept"
                if (whitelist ~ /^\//) {
                    if (ports[1]!="") print "        ip saddr @whitelist4 meta nfproto ipv4 tcp dport { " ports[1] " } accept"
                    if (ports[2]!="") print "        ip saddr @whitelist4 meta nfproto ipv4 udp dport { " ports[2] " } accept"
                } else {
                    if (ports[1]!="") print "        meta nfproto ipv4 tcp dport { " ports[1] " } accept"
                    if (ports[2]!="") print "        meta nfproto ipv4 udp dport { " ports[2] " } accept"
                    if (ports[3]!="") print "        meta nfproto ipv6 tcp dport { " ports[3] " } accept"
                    if (ports[4]!="") print "        meta nfproto ipv6 udp dport { " ports[4] " } accept"
                }
                print "    }"
            }
            print "    chain forward {\n        type filter hook forward priority 0; policy drop;"
            print "        ct state invalid drop"
            if (whitelist ~ /^\//) {
                print "        ct state established,related accept"
                print "        ct status dnat ip saddr @whitelist4 accept"
            } else {
                print "        ct status dnat accept"
                print "        ct state related accept"
            }
            print "    }\n}"
        }
    ' "$TX_CACHE_FILE" "$TX_RULES" > "$1"
}
run_nft_file() {
    local check_flag="$1" label="$2" file="$3" desc="$4" output
    local -a args=()
    [ -z "$check_flag" ] || args+=("$check_flag")
    if output=$(nft "${args[@]}" -f "$file" 2>&1); then
        return 0
    fi
    log_error "nft ${label}失败: $desc"
    if [ -n "$output" ]; then
        log_error "$output"
    fi
    return 1
}
publish_file() {
    local source="$1" target="$2"
    cmp -s "$source" "$target" && return 0
    chmod 600 "$source" && mv "$source" "$target"
}
apply_candidate_state() {
    local desc="$1" force_apply="$2" protect_ports="${3:-}" tables
    local nft_tmp="$TX_DIR/forwardaws.nft" state_tmp="$TX_DIR/state.db" has_forward
    local metadata="$TX_DIR/compiled.meta"
    local rules_changed=0 include_missing=0 live_missing=0
    tables=$(list_owned_nft_tables) || abort_operation "无法读取 nftables 状态，取消本次变更"
    compile_candidate "$nft_tmp" "$state_tmp" "$metadata" "$tables" "$protect_ports" || return 1
    IFS='|' read -r has_forward _ < "$metadata" || return 1
    cmp -s "$nft_tmp" "$FORWARDAWS_RULES_FILE" || rules_changed=1
    nft_main_config_include_is_current || include_missing=1
    if [ "$rules_changed" -eq 0 ]; then
        if [[ $'\n'"$tables"$'\n' != *$'\nip\t'"$NAT_TABLE_NAME"$'\n'* ||
              $'\n'"$tables"$'\n' != *$'\ninet\t'"$FILTER_TABLE_NAME"$'\n'* ]]; then
            live_missing=1
        fi
    fi
    if [ "$rules_changed" -eq 1 ] || [ "$live_missing" -eq 1 ] || [ "$force_apply" -eq 1 ]; then
        run_nft_file -c "预检" "$nft_tmp" "$desc" || return 1
    fi
    require_success "声明发布失败，运行规则未变" publish_file "$state_tmp" "$STATE_FILE" || return 1
    if [ "$rules_changed" -eq 1 ]; then
        require_success "规则产物发布失败，声明已提交；修复后请执行 --sync" \
            publish_file "$nft_tmp" "$FORWARDAWS_RULES_FILE" || return 1
    fi
    require_success "DNS 订阅未对齐，声明已提交；修复后请执行 --sync" \
        sync_providerdns_subscription || return 1
    require_success "旧声明文件未能回收；修复后请执行 --sync" \
        rm -f "$RULES_STATE_FILE" "$CONFIG_FILE" || return 1
    if [ "$include_missing" -eq 1 ] || [ "$rules_changed" -eq 1 ]; then
        ensure_nft_main_config_include || return 1
    fi
    if [ "$rules_changed" -eq 1 ] || [ "$live_missing" -eq 1 ] || [ "$force_apply" -eq 1 ]; then
        run_nft_file "" "应用" "$FORWARDAWS_RULES_FILE" "$desc" || abort_operation "持久状态已发布，但运行规则未应用；修复后请执行 --sync"
    fi
    if [ "$has_forward" -eq 1 ]; then
        ensure_ipv4_forwarding_enabled || return 1
    fi
}
# 小型系统配置按内容比较后原子发布，未变化时不分配临时文件。
write_text_file() {
    local target="$1" content tmp
    FILE_CHANGED=0
    content=$(cat) || return 1
    if [ -f "$target" ] && [ "$(<"$target")" = "$content" ]; then
        return 0
    fi
    tmp=$(mktemp "${target}.XXXXXX") || return 1
    if ! printf '%s' "$content${content:+$'\n'}" > "$tmp" || ! chmod 644 "$tmp" || ! mv "$tmp" "$target"; then
        rm -f "$tmp"
        log_error "配置发布失败: $target"
        return 1
    fi
    FILE_CHANGED=1
}
write_systemd_unit_if_changed() {
    write_text_file "$1" || return 1
    [ "$FILE_CHANGED" -eq 0 ] || SYSTEMD_UNITS_CHANGED=1
}
list_owned_unit_files() {
    [ -d "$SYSTEMD_SYSTEM_DIR" ] || return 0
    find "$SYSTEMD_SYSTEM_DIR" -maxdepth 2 -name 'forwardaws-*' \
        \( -type f -o -type l \) 2>/dev/null
}
converge_systemd_units() {
    local path name failed=0 desired=" $* "
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        name="${path##*/}"
        [[ "$desired" != *" ${name} "* ]] || continue
        if has_systemctl; then
            disable_unit_if_active "$name" || failed=1
            systemctl reset-failed "$name" >/dev/null 2>&1 || true
        fi
        if [ -e "$path" ] || [ -L "$path" ]; then
            rm -f "$path" || {
                log_error "无法删除 systemd 文件：$path"
                failed=1
                continue
            }
        fi
        SYSTEMD_UNITS_CHANGED=1
    done < <(list_owned_unit_files)
    return "$failed"
}
reload_systemd_if_changed() {
    [ "$SYSTEMD_UNITS_CHANGED" -eq 1 ] && has_systemctl || return 0
    systemctl daemon-reload >/dev/null 2>&1 && return 0
    log_error "systemd daemon-reload 失败"
    return 1
}
# systemd 生命周期
install_sync_service() {
    local name="$1" source="$2" script_path service_file
    script_path=$(get_script_absolute_path) || return 1
    service_file="${SYSTEMD_SYSTEM_DIR}/${name}"
    write_systemd_unit_if_changed "$service_file" << EOF || return 1
[Unit]
Description=ForwardAWS ${source} sync service
After=network-online.target nftables.service
Wants=network-online.target
[Service]
Type=oneshot
Environment=FORWARDAWS_SYNC_SOURCE=${source}
Environment=FORWARDAWS_QUIET=1
Environment=FORWARDAWS_LOCK_WAIT=10
ExecStart=/bin/bash "${script_path}" --sync
EOF
}
install_protection_units() {
    local timer_file="${SYSTEMD_SYSTEM_DIR}/${PROTECT_TIMER_NAME}"
    install_sync_service "$PROTECT_SERVICE_NAME" timer || return 1
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
install_whitelist_units() {
    local whitelist="$1" path_file="${SYSTEMD_SYSTEM_DIR}/${WHITELIST_PATH_NAME}"
    install_sync_service "$WHITELIST_SERVICE_NAME" whitelist || return 1
    write_systemd_unit_if_changed "$path_file" << EOF
[Unit]
Description=Watch ForwardAWS whitelist
[Path]
PathChanged=${whitelist}
Unit=${WHITELIST_SERVICE_NAME}
[Install]
WantedBy=paths.target
EOF
}
has_systemctl() {
    command -v systemctl >/dev/null 2>&1
}
unit_enabled_or_active() {
    systemctl is-enabled --quiet "$1" 2>/dev/null || systemctl is-active --quiet "$1" 2>/dev/null
}
disable_unit_if_active() {
    unit_enabled_or_active "$1" || return 0
    systemctl disable --now --no-reload "$1" >/dev/null 2>&1 || {
        log_error "无法停用系统单元：$1"
        return 1
    }
}
enable_managed_unit() {
    systemctl is-enabled --quiet "$1" 2>/dev/null &&
        systemctl is-active --quiet "$1" 2>/dev/null && return 0
    systemctl enable --now --no-reload "$1" >/dev/null 2>&1 &&
        systemctl is-active --quiet "$1" 2>/dev/null && return 0
    log_error "$2"
    return 1
}
reconcile_systemd_units() {
    local protect_flag="$1" whitelist="$2" want_whitelist=0
    [ "$protect_flag" != "1" ] || [[ "$whitelist" != /* ]] || want_whitelist=1
    if [ "$protect_flag" = "1" ] && ! has_systemctl; then
        log_error "未检测到 systemctl，无法启用保护同步"
        return 1
    fi
    SYSTEMD_UNITS_CHANGED="${3:-0}"
    local -a desired=()
    if [ "$protect_flag" = "1" ]; then
        install_protection_units || return 1
        desired+=("$PROTECT_SERVICE_NAME" "$PROTECT_TIMER_NAME")
    fi
    if [ "$want_whitelist" -eq 1 ]; then
        install_whitelist_units "$whitelist" || return 1
        desired+=("$WHITELIST_SERVICE_NAME" "$WHITELIST_PATH_NAME")
    fi
    converge_systemd_units "${desired[@]}" || return 1
    reload_systemd_if_changed || return 1
    if [ "$protect_flag" = "1" ]; then
        enable_managed_unit "$PROTECT_TIMER_NAME" "启用保护同步定时器失败" || return 1
    fi
    if [ "$want_whitelist" -eq 1 ]; then
        enable_managed_unit "$WHITELIST_PATH_NAME" "启用 whitelist 文件监控失败" || return 1
    fi
}
# 单一候选事务
transaction_open() {
    local path
    local -a owners=()
    TX_DIR=$(mktemp -d "${STATE_DIR}/.tx.XXXXXX") || return 1
    TX_RULES="${TX_DIR}/candidate.db"
    load_state || return 1
    converge_owned_files || return 1
    read -ra owners <<< "$TX_WHITELIST_FILE"
    TX_WHITELIST_FILE="${owners[0]:-}"
    for path in "${owners[@]:1}"; do
        [ ! -e "$path" ] || TX_WHITELIST_FILE+=" $path"
    done
}

reclaim_whitelist_file() {
    local path="$1"
    [ -n "$path" ] && [ -e "$path" ] || return 0
    if ! [[ "$path" =~ ^/([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+[.]nft$ ]] ||
        [ "$path" = "$FORWARDAWS_RULES_FILE" ]; then
        log_error "拒绝删除无效的 whitelist owner 路径：$path"
        return 1
    fi
    rm -f -- "$path" || {
        log_error "无法删除 whitelist 文件：$path"
        return 1
    }
    log_info "已回收不再使用的 whitelist 文件：$path"
}
transaction_set_whitelist() {
    TX_WHITELIST="$1"
    if [[ "$1" == /* ]]; then
        TX_WHITELIST_FILE=" $TX_WHITELIST_FILE "
        TX_WHITELIST_FILE="${TX_WHITELIST_FILE// $1 / }"
        TX_WHITELIST_FILE="${TX_WHITELIST_FILE# }"
        TX_WHITELIST_FILE="${TX_WHITELIST_FILE% }"
        TX_WHITELIST_FILE="$1${TX_WHITELIST_FILE:+ $TX_WHITELIST_FILE}"
    fi
}
transaction_commit() {
    local desc="$1" refresh="${2:-0}" force_apply="${3:-0}" ports="" path
    if [ "$TX_PROTECTION" = "1" ]; then
        if [[ "$TX_WHITELIST" == /* ]]; then
            TX_WHITELIST=$(normalize_whitelist_path "$TX_WHITELIST") || return 1
        fi
        ports=$(get_auto_allow_ports) || return 1
        [ -n "${ports//|/}" ] || abort_operation "保护端口列表为空，拒绝启用保护"
    fi
    snapshot_candidate "$TX_RULES" "$TX_PING" "$refresh" || return 1
    apply_candidate_state "$desc" "$force_apply" "$ports" || return 1
    reconcile_systemd_units "$TX_PROTECTION" "$TX_WHITELIST" "$force_apply" ||
        abort_operation "nft 规则与持久状态已生效，但 systemd 单元未对齐；修复后请执行 --sync"
    local -a owners=()
    read -ra owners <<< "$TX_WHITELIST_FILE"
    for path in "${owners[@]:1}"; do
        reclaim_whitelist_file "$path" || return 1
    done
}
rule_batch() {
    local action="$1" operation counts success skipped now
    TX_DOMAINS_FILE="${TX_RULES}.domains"
    case "$action" in
        --add|-a)
            action=add operation="添加"
            ;;
        --delete|-d)
            action=delete operation="删除"
            ;;
        --replace|-r)
            action=replace operation="替换"
            ;;
    esac
    now=$(date +%s)
    # 端口索引只存在于本次批处理；保留原始行顺序和同端口匹配优先级。
    counts=$(printf '%s\n' "${PARSED_RULES[@]}" | awk -F'|' -v OFS='|' \
        -v action="$action" -v now="$now" -v output="$TX_RULES" \
        -v ping="$TX_PING" -v domains_file="$TX_DOMAINS_FILE" '
        function emit(line, fields) {
            print line > output
            split(line, fields, "|")
            if (fields[5]=="domain") domains[fields[3]]=1
        }
        BEGIN { printf "" > output; printf "" > domains_file }
        function append(line, port) {
            rows[++count]=line
            link[count]=head[port+0]; head[port+0]=count
        }
        FILENAME!="-" {
            if ($0 ~ /^(PROTECTION_ENABLED|PROTECT_WHITELIST|PROTECT_WHITELIST_FILE|PROTECT_PING)=/) next
            if (NF>=8 && $2=="remote" && $1 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/) {
                if (action=="keep") emit($0)
                else if (action!="replace" && action!="clear") append($0, $1)
            } else if (NF) printf "[WARNING] 丢弃不合规状态行: %s\n", $0 > "/dev/stderr"
            next
        }
        action=="keep" || action=="clear" { next }
        {
            match_kind="none"
            for (i=head[$1+0]; i; i=link[i]) {
                if (!(i in rows)) continue
                split(rows[i], old, "|")
                if (old[2]==$2 && old[3]==$3 && old[4]==$4) {
                    if (action=="delete") { delete rows[i]; match_kind="base" }
                    else if (old[9]==$9 && old[10]==$10) { match_kind="exact"; break }
                    else match_kind="base"
                } else if (match_kind=="none") match_kind="port_conflict"
            }
            if (action=="delete") {
                if (match_kind=="base") success++; else skipped++
            } else if (match_kind=="exact" && action=="add") skipped++
            else if (match_kind!="none") {
                printf "[ERROR] %s: %s\n", (match_kind=="exact" ? "重复规则" : "规则冲突"), $11 > "/dev/stderr"
                failed=1; exit 1
            } else {
                NF=10; $8=now
                append($0, $1); success++
            }
        }
        END {
            if (failed) exit 1
            for (i=1; i<=count; i++) if (i in rows) emit(rows[i])
            if (ping!="any" && ping!="off") {
                n=split(ping, targets, ",")
                for (i=1; i<=n; i++) if (targets[i] !~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) domains[targets[i]]=1
            }
            for (domain in domains) print domain > domains_file
            print success+0, skipped+0
        }
    ' "$TX_SOURCE" -) || abort_operation "批次校验失败，已取消所有变更"
    sort -u "$TX_DOMAINS_FILE" -o "$TX_DOMAINS_FILE" || return 1
    [[ "$action" != keep && "$action" != clear ]] || return 0
    IFS='|' read -r success skipped <<< "$counts"
    TX_DESC="${operation}转发规则"
    if [ "$success" -eq 0 ]; then
        TX_MESSAGE="没有规则变化"
    elif [ "$skipped" -eq 0 ]; then
        TX_MESSAGE="已${operation} ${success} 条转发规则"
    else
        TX_MESSAGE="已${operation} ${success} 条转发规则，跳过 ${skipped} 条"
    fi
}
run_rule_action() {
    TX_ACTION="$1" TX_REFRESH=1
    [ "$PARSED_PROTECT" -eq 0 ] || run_protect
}
run_protect() {
    TX_PROTECTION=1
    [ -z "$PARSED_WHITELIST" ] || transaction_set_whitelist "$PARSED_WHITELIST"
    [ -z "$PARSED_PING" ] || TX_PING="$PARSED_PING"
    TX_REFRESH=1 TX_DESC="开启保护" TX_MESSAGE="保护已启用"
}
run_sync() {
    local source="${FORWARDAWS_SYNC_SOURCE:-manual}"
    case "$source" in
        manual)
            TX_REFRESH=1
            TX_FORCE=1
            ;;
        whitelist)
            TX_FORCE=1
            ;;
        providerdns|timer)
            ;;
        *)
            log_error "无效的同步来源: $source"
            return 1
            ;;
    esac
    if [ "$source" = whitelist ] && ! [[ "$TX_WHITELIST" == /* ]]; then
        TX_SKIP=1
    fi
    TX_DESC="同步规则" TX_MESSAGE="规则同步完成"
}
run_clean_scope() {
    local scope="$1"
    case "$scope" in
        ping)
            TX_PING=any
            TX_MESSAGE="Ping 限制已清理"
            ;;
        whitelist)
            TX_WHITELIST=any
            TX_MESSAGE="Whitelist 限制已清理"
            ;;
        forward)
            TX_ACTION=clear
            TX_MESSAGE="转发规则已清理"
            ;;
        protect)
            TX_PROTECTION=0
            TX_WHITELIST=any
            TX_PING=any
            TX_MESSAGE="保护规则已清理"
            ;;
    esac
    TX_DESC="清理 ${scope}"
}
# 销毁、展示与 CLI 调度
purge_owned_nft_tables() (
    local nft_tmp prelude
    prelude=$(list_owned_nft_tables) || {
        log_error "无法读取 nftables 状态，live 表未确认清理"
        return 1
    }
    prelude=$(nft_purge_prelude "$prelude") || return 1
    [ -n "$prelude" ] || return 0
    nft_tmp=$(mktemp /tmp/forwardaws-cleanup.XXXXXX) || return 1
    trap 'rm -f "$nft_tmp"' EXIT
    printf '%s\n' "$prelude" > "$nft_tmp" || return 1
    run_nft_file "" "清理" "$nft_tmp" "删除 ForwardAWS nftables 表"
)
purge_nft_main_config_include() {
    local content
    [ -f "$NFT_MAIN_CONFIG_FILE" ] || return 0
    grep -Fqx "$NFT_INCLUDE_MARKER" "$NFT_MAIN_CONFIG_FILE" || return 0
    content=$(remove_own_include_block) || return 1
    write_text_file "$NFT_MAIN_CONFIG_FILE" <<< "$content"
}
clean_all() {
    local failed=0 forwarding_persisted=0 path
    local -a owners=()
    load_state raw || return 1
    [ ! -e "$IPV4_FORWARD_SYSCTL_FILE" ] || forwarding_persisted=1
    SYSTEMD_UNITS_CHANGED=0
    converge_systemd_units || failed=1
    reload_systemd_if_changed || failed=1
    providerdns_unset_forwardaws || failed=1
    purge_owned_nft_tables || failed=1
    purge_nft_main_config_include || failed=1
    rm -f "$FORWARDAWS_RULES_FILE" "$IPV4_FORWARD_SYSCTL_FILE" || failed=1
    read -ra owners <<< "$TX_WHITELIST_FILE"
    for path in "${owners[@]}"; do
        reclaim_whitelist_file "$path" || failed=1
    done
    if [ "$failed" -eq 0 ]; then
        rm -rf "$STATE_DIR" || failed=1
    fi
    rmdir "$NFT_INCLUDE_DIR" 2>/dev/null || true
    [ "$forwarding_persisted" -eq 0 ] ||
        log_warning "已删除 IPv4 转发持久配置，当前 net.ipv4.ip_forward live 值未复位"
    if [ "$failed" -eq 0 ]; then
        log_info "ForwardAWS 全部资源已清理"
    else
        log_error "ForwardAWS 清理未完全完成"
    fi
    rm -f "$GLOBAL_LOCK_FILE" || failed=1
    return "$failed"
}
get_allowed_ports_from_ruleset() {
    [ -r "$FORWARDAWS_RULES_FILE" ] || abort_operation "无法读取已发布的防护规则：$FORWARDAWS_RULES_FILE"
    awk '
        /^[[:space:]]*(ip saddr @whitelist4[[:space:]]+)?meta nfproto ipv[46][[:space:]]+(tcp|udp)[[:space:]]+dport[[:space:]]+\{[[:space:]][0-9,]+[[:space:]]\}[[:space:]]+accept[[:space:]]*$/ {
            line=$0
            sub(/^.*dport[[:space:]]+\{[[:space:]]*/, "", line)
            sub(/[[:space:]]*\}[[:space:]]+accept[[:space:]]*$/, "", line)
            gsub(/[[:space:]]/, "", line)
            count=split(line, ports, ",")
            for (i=1; i<=count; i++) print ports[i]
        }
    ' "$FORWARDAWS_RULES_FILE" | sort -un |
        awk 'NF { printf "%s%s", separator, $0; separator="," } END { print "" }'
}
display_rules() {
    local src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss extra
    local allowed_ports="" whitelist_note="" rules
    local -A status_labels=([ok]=正常 [pending]=待解析 [failed]=解析失败)
    load_state || return 1
    rules=$(awk -F'|' 'NF>=8' "$TX_SOURCE") || return 1
    if [ "$TX_PROTECTION" = 1 ]; then
        allowed_ports=$(get_allowed_ports_from_ruleset) || return 1
        [ -n "$allowed_ports" ] || allowed_ports="无"
    fi
    if [ -z "$rules" ] && [ "$TX_PROTECTION" != 1 ]; then
        printf '%s\n' '无'
        return 0
    fi
    if [ -n "$rules" ]; then
        printf '%s\n' '端口转发'
        while IFS='|' read -r src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss; do
            [ -n "$src_port$mode$target$dest_port" ] || continue
            extra=""
            [ -z "$snat_ip" ] || extra="SNAT：${snat_ip}"
            if [ -n "$mss" ]; then
                [ "$mss" != auto ] || mss="自动"
                extra="${extra}${extra:+，}MSS：${mss}"
            fi
            if [ "$target_type" = domain ]; then
                status="${status_labels[${status:-unknown}]:-${status:-未知}}"
                extra="解析：${resolved_ip:-未解析}，${status}${extra:+，${extra}}"
            fi
            printf -- '- %s -> %s:%s%s\n' "$src_port" "$target" "$dest_port" "${extra:+（${extra}）}"
        done <<< "$rules"
    fi
    if [ "$TX_PROTECTION" = 1 ]; then
        [ -z "$rules" ] || printf '\n'
        printf '%s\n' '本机防护'
        printf -- '- 放行端口：%s\n' "$allowed_ports"
        if [[ "$TX_WHITELIST" == /* ]]; then
            normalize_whitelist_path "$TX_WHITELIST" >/dev/null 2>&1 || whitelist_note="（无效）"
            printf -- '- Whitelist：%s%s\n' "$TX_WHITELIST" "$whitelist_note"
        fi
        [ "$TX_PING" = any ] || printf -- '- Ping：%s\n' "$TX_PING"
    fi
}
run_mutation() (
    local mode="$1" desc="$2"
    local TX_DESC="$2" TX_MESSAGE="" TX_REFRESH=0 TX_FORCE=0 TX_SKIP=0 TX_ACTION=keep
    shift 2
    if [ "$mode" = state ]; then
        ensure_for_write || return 1
    else
        require_root || return 1
        command -v flock >/dev/null 2>&1 || abort_operation "缺少依赖命令：flock"
        acquire_global_lock || return 1
    fi
    log_info "$desc"
    if [ "$mode" = state ]; then
        trap '[ -z "$TX_DIR" ] || rm -rf "$TX_DIR"' EXIT
        transaction_open || return 1
        trap 'exit 130' INT
        trap 'exit 143' TERM
    fi
    "$@" || return 1
    [ "$mode" = state ] && [ "$TX_SKIP" -eq 0 ] || return 0
    rule_batch "$TX_ACTION" || return 1
    transaction_commit "$TX_DESC" "$TX_REFRESH" "$TX_FORCE" || return 1
    log_info "$TX_MESSAGE"
)
main() {
    local action scope
    if [ $# -eq 0 ]; then
        log_error "请使用参数模式执行，例如: $0 --help"
        show_help
        return 1
    fi
    case "$1" in
        --help|-h)
            shift
            require_arg_count 0 "--help 不接受额外参数" "$@" || return 1
            show_help
            ;;
        --list|-l)
            shift
            require_arg_count 0 "--list 不接受额外参数" "$@" || return 1
            display_rules
            ;;
        --add|-a|--delete|-d|--replace|-r)
            action="$1"
            shift
            parse_rule_command "$@" || return 1
            run_mutation state "正在处理 ${#PARSED_RULES[@]} 条转发规则" run_rule_action "$action"
            ;;
        --protect)
            shift
            parse_protect_fields "$@" || return 1
            run_mutation state "正在启用保护" run_protect
            ;;
        --sync)
            shift
            require_arg_count 0 "--sync 不接受额外参数" "$@" || return 1
            run_mutation state "正在同步 ForwardAWS" run_sync
            ;;
        --clean)
            shift
            require_arg_count 1 "--clean 必须指定一个清理范围" "$@" || return 1
            scope="$1"
            case "$scope" in
                ping|whitelist|forward|protect)
                    run_mutation state "正在清理 ${scope}" run_clean_scope "$scope"
                    ;;
                all)
                    run_mutation clean "正在清理全部 ForwardAWS 资源" clean_all
                    ;;
                *)
                    log_error "未知的清理范围: $scope"
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
