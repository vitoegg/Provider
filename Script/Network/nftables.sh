#!/bin/bash
# rules.db 与 config.env 是声明真值；每次变更都生成并原子应用完整 nftables ruleset。
# 运行环境为 Debian/Ubuntu，依赖 bash、nftables、util-linux、iproute2 与 procfs。
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
readonly WHITELIST_SERVICE_NAME="forwardaws-whitelist.service"
readonly WHITELIST_PATH_NAME="forwardaws-whitelist.path"
readonly PROVIDERDNS_CONSUMER="forwardaws"
PROVIDERDNS_BIN="${PROVIDERDNS_BIN:-}"
readonly PROVIDERDNS_LOCAL_NAME="providerdns.sh"
readonly DEFAULT_EXCLUDE_PORTS="53"
readonly SERVICE_ALLOW_MARK="0x40000000"
SYSTEMD_UNITS_CHANGED=0
PARSED_PROTECT=0
PARSED_WHITELIST_SET=0
PARSED_WHITELIST=""
PARSED_PING_SET=0
PARSED_PING=""
PARSED_RULES=()
RESOLVED_PING_IPV4=""
TX_DIR="" TX_RULES="" TX_PROTECTION=0 TX_WHITELIST=any
TX_WHITELIST_FILE="" TX_WHITELIST_FILE_PREV="" TX_PING=any
log_info() {
    [ "${FORWARDAWS_QUIET:-${QUIET:-0}}" = "1" ] || printf '[INFO] %s\n' "$*"
}
log_warning() {
    printf '[WARNING] %s\n' "$*" >&2
}
log_error() {
    printf '[ERROR] %s\n' "$*" >&2
}
show_help() {
    cat << EOF
用法:
  $0 --help|-h
  $0 --list|-l
  $0 --add|-a <规则> [规则 ...] [--protect [whitelist=<值>] [ping=<值>]]
  $0 --delete|-d <规则> [规则 ...] [--protect [whitelist=<值>] [ping=<值>]]
  $0 --replace|-r <规则> [规则 ...] [--protect [whitelist=<值>] [ping=<值>]]
  $0 --protect [whitelist=<值>] [ping=<值>]
  $0 --sync
  $0 --clean <ping|whitelist|forward|protect|all>
规则格式:
  <源端口>:<目标(IPv4/域名)>:<目标端口>[:SNAT_IP[:MSS]]
保护值:
  whitelist=any|off|<绝对路径>.nft
  ping=any|off|<IPv4或域名逗号列表>
EOF
}
# CLI 与声明校验
require_arg_count() {
    local expected="$1" message="$2"
    shift 2
    [ "$#" -eq "$expected" ] && return 0
    log_error "$message"
    return 1
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
    if [ -L "$input" ]; then
        log_error "whitelist 不允许使用符号链接: $input"
        return 1
    fi
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
    if [ "$path" = "$FORWARDAWS_RULES_FILE" ]; then
        log_error "whitelist 不允许覆盖脚本自有文件: $path"
        return 1
    fi
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
validate_whitelist_spec() {
    case "$1" in
        any|off)
            printf '%s\n' "$1"
            ;;
        *)
            normalize_whitelist_path "$1"
            ;;
    esac
}
parse_rule() {
    local rule_string="$1" src_port target dest_port snat_ip mss
    [[ "$rule_string" =~ ^[^:]+:[^:]+:[^:]+(:[^:]+(:[^:]+)?)?$ ]] || {
        log_error "规则格式错误: $rule_string"
        log_error "正确格式: 端口:目标(IPv4/域名):端口[:SNAT_IP[:MSS]]"
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
            log_error "不再支持本地转发: $target"
            return 1
            ;;
    esac
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
    PARSED_SRC_PORT="$src_port"
    PARSED_DEST_PORT="$dest_port"
    PARSED_SNAT_IP="$snat_ip"
    PARSED_MSS="$mss"
}
parse_protect_fields() {
    local arg value
    PARSED_WHITELIST_SET=0
    PARSED_WHITELIST=""
    PARSED_PING_SET=0
    PARSED_PING=""
    for arg in "$@"; do
        case "$arg" in
            whitelist=*)
                if [ "$PARSED_WHITELIST_SET" -ne 0 ]; then
                    log_error "whitelist 只能指定一次"
                    return 1
                fi
                value="${arg#whitelist=}"
                if [ -z "$value" ]; then
                    log_error "whitelist 值不能为空"
                    return 1
                fi
                PARSED_WHITELIST=$(validate_whitelist_spec "$value") || return 1
                PARSED_WHITELIST_SET=1
                ;;
            ping=*)
                if [ "$PARSED_PING_SET" -ne 0 ]; then
                    log_error "ping 只能指定一次"
                    return 1
                fi
                value="${arg#ping=}"
                if ! validate_ping_spec "$value"; then
                    log_error "ping 值无效: $value"
                    return 1
                fi
                PARSED_PING="$value"
                PARSED_PING_SET=1
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
    PARSED_WHITELIST_SET=0
    PARSED_WHITELIST=""
    PARSED_PING_SET=0
    PARSED_PING=""
    while [ $# -gt 0 ]; do
        arg="$1"
        shift
        if [ "$arg" = "--protect" ]; then
            PARSED_PROTECT=1
            parse_protect_fields "$@" || return 1
            break
        fi
        parse_rule "$arg" || return 1
        PARSED_RULES+=("$arg")
    done
    if [ "${#PARSED_RULES[@]}" -eq 0 ]; then
        log_error "未提供任何规则"
        return 1
    fi
}
format_domain_status() {
    local status="${1:-}"
    [ "$status" != "ok" ] || status="正常"
    [ "$status" != "pending" ] || status="待解析"
    [ "$status" != "failed" ] || status="解析失败"
    printf '%s\n' "${status:-未知}"
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
    PROVIDERDNS_QUIET=1 PROVIDERDNS_LOCK_WAIT="${PROVIDERDNS_LOCK_WAIT:-10}" run_providerdns --refresh
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
    command -v readlink >/dev/null 2>&1 || missing+=(coreutils)
    command -v stat >/dev/null 2>&1 || missing+=(coreutils)
    [ "${#missing[@]}" -gt 0 ] || return 0
    command -v apt-get >/dev/null 2>&1 || {
        log_error "缺少依赖且未检测到 apt-get：${missing[*]}"
        return 1
    }
    FORWARDAWS_QUIET=0 QUIET=0 log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || {
        log_error "软件包索引更新失败"
        return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 || {
        log_error "依赖安装失败：${missing[*]}"
        return 1
    }
    FORWARDAWS_QUIET=0 QUIET=0 log_info "已安装依赖：${missing[*]}"
}
acquire_global_lock() {
    local lock_wait="${FORWARDAWS_LOCK_WAIT:-0}" lock_error="检测到其他任务正在执行中，请稍后重试"
    exec 9>"$GLOBAL_LOCK_FILE" || {
        log_error "无法创建全局锁文件: $GLOBAL_LOCK_FILE"
        return 1
    }
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
ensure_for_write() {
    require_root || return 1
    ensure_dependencies || return 1
    acquire_global_lock || return 1
    mkdir -p "$STATE_DIR" "$NFT_INCLUDE_DIR" || return 1
    rm -rf "${STATE_DIR:?}"/.tx.* 2>/dev/null || true
    converge_owned_files || return 1
    [ -f "$RULES_STATE_FILE" ] || : > "$RULES_STATE_FILE"
}
converge_owned_files() {
    local whitelist
    whitelist=$(get_config_value PROTECT_WHITELIST_FILE '')
    find "$STATE_DIR" -maxdepth 1 -type f \
        ! -name "$(basename "$RULES_STATE_FILE")" ! -name "$(basename "$CONFIG_FILE")" \
        -delete 2>/dev/null || true
    find "$NFT_INCLUDE_DIR" -maxdepth 1 -type f -name 'forwardaws*' \
        ! -name "$(basename "$FORWARDAWS_RULES_FILE")" ! -path "$whitelist" \
        -delete 2>/dev/null || true
}
get_config_value() {
    local key="$1" default="$2"
    if [ ! -f "$CONFIG_FILE" ]; then
        printf '%s\n' "$default"
        return 0
    fi
    awk -F= -v k="$key" -v d="$default" \
        '$1==k { print substr($0, index($0, "=")+1); found=1; exit } END { if (!found) print d }' \
        "$CONFIG_FILE"
}
load_config() {
    CURRENT_PROTECTION=$(get_config_value PROTECTION_ENABLED 0)
    CURRENT_WHITELIST=$(get_config_value PROTECT_WHITELIST any)
    CURRENT_WHITELIST_FILE=$(get_config_value PROTECT_WHITELIST_FILE '')
    CURRENT_PING=$(get_config_value PROTECT_PING '')
    if [ -z "$CURRENT_PING" ]; then
        CURRENT_PING=$(get_config_value PROTECT_NOPING any)
        [ "$CURRENT_PING" != 0 ] || CURRENT_PING=any
        [ "$CURRENT_PING" != 1 ] || CURRENT_PING=off
    fi
    [[ "$CURRENT_PROTECTION" =~ ^[01]$ ]] || {
        log_error "保护状态文件无效"
        return 1
    }
    case "$CURRENT_WHITELIST" in
        any|off|/*.nft) ;;
        *)
            log_error "whitelist 状态无效: $CURRENT_WHITELIST"
            return 1
            ;;
    esac
    validate_ping_spec "$CURRENT_PING" || {
        log_error "ping 状态无效: $CURRENT_PING"
        return 1
    }
}
nft_main_config_include_line() {
    printf 'include "%s"\n' "$FORWARDAWS_RULES_FILE"
}
nft_main_config_owned_line() {
    [ -f "$NFT_MAIN_CONFIG_FILE" ] || return 0
    awk -v marker="$NFT_INCLUDE_MARKER" '
        found { print; exit }
        $0==marker { found=1 }
    ' "$NFT_MAIN_CONFIG_FILE"
}
nft_main_config_has_foreign_include() {
    [ -f "$NFT_MAIN_CONFIG_FILE" ] || return 1
    awk -v marker="$NFT_INCLUDE_MARKER" -v dir="$NFT_INCLUDE_DIR" '
        $0==marker { skip=1; next }
        skip { skip=0; next }
        $0 ~ "^[[:space:]]*include[[:space:]]+\"?" dir "/(\\*|forwardaws)[.]nft\"?[[:space:]]*$" { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$NFT_MAIN_CONFIG_FILE"
}
nft_main_config_include_is_current() {
    local owned
    owned=$(nft_main_config_owned_line)
    if [ -n "$owned" ]; then
        [ "$owned" = "$(nft_main_config_include_line)" ]
        return
    fi
    nft_main_config_has_foreign_include
}
remove_own_include_block() {
    awk -v marker="$NFT_INCLUDE_MARKER" '
        $0==marker { skip=1; next }
        skip { skip=0; next }
        { print }
    ' "$NFT_MAIN_CONFIG_FILE" > "$1"
}
ensure_nft_main_config_include() (
    local tmp
    if ! nft_main_config_include_is_current; then
        tmp=$(mktemp "${NFT_MAIN_CONFIG_FILE}.XXXXXX") || return 1
        trap 'rm -f "$tmp"' EXIT
        if [ -e "$NFT_MAIN_CONFIG_FILE" ]; then
            remove_own_include_block "$tmp" || return 1
        else
            chmod 644 "$tmp" 2>/dev/null || true
        fi
        printf '\n%s\n%s\n' "$NFT_INCLUDE_MARKER" "$(nft_main_config_include_line)" >> "$tmp" || {
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
        systemctl enable nftables.service >/dev/null 2>&1 &&
            log_info "已启用系统服务：nftables.service" ||
            log_warning "无法启用 nftables.service，重启后规则可能丢失"
    fi
)
ensure_ipv4_forwarding_enabled() {
    local current tmp persistent_changed=0
    current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf '0\n')
    if ! grep -q 'net.ipv4.ip_forward=1' "$IPV4_FORWARD_SYSCTL_FILE" 2>/dev/null; then
        tmp=$(mktemp "${IPV4_FORWARD_SYSCTL_FILE}.XXXXXX") || return 1
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
    [ "$persistent_changed" -eq 0 ] || log_info "已持久化 IPv4 转发配置：$IPV4_FORWARD_SYSCTL_FILE"
    [ "$current" = "1" ] || log_info "已启用 IPv4 转发"
}
ipv4_forwarding_needs_update() {
    local current
    current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || current=0
    [ "$current" != "1" ] ||
        ! grep -q 'net.ipv4.ip_forward=1' "$IPV4_FORWARD_SYSCTL_FILE" 2>/dev/null
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
    if ! command -v sshd >/dev/null 2>&1; then
        printf '\n'
        return 0
    fi
    config=$(sshd -T 2>/dev/null) || {
        log_error "无法读取 SSH 生效配置，拒绝应用端口保护"
        return 1
    }
    ports=$(printf '%s\n' "$config" |
        awk '$1 == "port" && $2 ~ /^[0-9]+$/ && $2 >= 1 && $2 <= 65535 { print $2 }' |
        sort -un | tr '\n' ',' | sed 's/,$//')
    [ -n "$ports" ] || {
        log_error "SSH 生效配置未包含有效端口，拒绝应用端口保护"
        return 1
    }
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
    local listeners protocol endpoint parsed addr port family dual
    local v4_tcp="" v4_udp="" v6_tcp="" v6_udp=""
    if ! command -v ss >/dev/null 2>&1; then
        log_error "缺少依赖命令：ss"
        return 1
    fi
    listeners=$(ss -H -lntu 2>/dev/null) || {
        log_error "无法检测监听端口，拒绝应用端口保护"
        return 1
    }
    dual=both
    [ "$(sysctl -n net.ipv6.bindv6only 2>/dev/null)" != "1" ] || dual=v6
    while IFS='|' read -r protocol endpoint; do
        [ -n "$endpoint" ] || continue
        parsed=$(parse_local_endpoint "$endpoint")
        IFS='|' read -r addr port <<< "$parsed"
        validate_port "$port" || continue
        [[ "$addr" == "::1" || "$addr" =~ ^127\. ]] && continue
        case "$addr" in
            \*) family=both ;;
            ::) family="$dual" ;;
            *:*) family=v6 ;;
            *) family=v4 ;;
        esac
        case "${protocol}:${family}" in
            tcp:v4) v4_tcp="${v4_tcp}${v4_tcp:+,}${port}" ;;
            tcp:v6) v6_tcp="${v6_tcp}${v6_tcp:+,}${port}" ;;
            udp:v4) v4_udp="${v4_udp}${v4_udp:+,}${port}" ;;
            udp:v6) v6_udp="${v6_udp}${v6_udp:+,}${port}" ;;
            tcp:both)
                v4_tcp="${v4_tcp}${v4_tcp:+,}${port}"
                v6_tcp="${v6_tcp}${v6_tcp:+,}${port}"
                ;;
            udp:both)
                v4_udp="${v4_udp}${v4_udp:+,}${port}"
                v6_udp="${v6_udp}${v6_udp:+,}${port}"
                ;;
        esac
    done < <(printf '%s\n' "$listeners" | awk '{ print $1 "|" $(NF - 1) }')
    printf '%s|%s|%s|%s\n' \
        "$(normalize_ports "$v4_tcp")" "$(normalize_ports "$v4_udp")" \
        "$(normalize_ports "$v6_tcp")" "$(normalize_ports "$v6_udp")"
}
get_auto_allow_ports() {
    local ssh_ports runtime_ports exclude_ports port v4_tcp v4_udp v6_tcp v6_udp
    local -a ssh_ports_arr
    ssh_ports=$(detect_ssh_ports) || return 1
    runtime_ports=$(detect_runtime_public_ports) || return 1
    IFS='|' read -r v4_tcp v4_udp v6_tcp v6_udp <<< "$runtime_ports"
    exclude_ports="$DEFAULT_EXCLUDE_PORTS"
    [ -z "${FORWARDAWS_EXCLUDE_PORTS:-}" ] || exclude_ports="${exclude_ports},${FORWARDAWS_EXCLUDE_PORTS}"
    exclude_ports=$(filter_ports "$exclude_ports")
    v4_tcp=$(filter_ports "$v4_tcp" "$exclude_ports")
    v4_udp=$(filter_ports "$v4_udp" "${exclude_ports},68")
    v6_tcp=$(filter_ports "$v6_tcp" "$exclude_ports")
    v6_udp=$(filter_ports "$v6_udp" "${exclude_ports},546")
    IFS=',' read -ra ssh_ports_arr <<< "$ssh_ports"
    for port in "${ssh_ports_arr[@]}"; do
        validate_port "$port" || continue
        v4_tcp=$(normalize_ports "${v4_tcp},${port}")
        v6_tcp=$(normalize_ports "${v6_tcp},${port}")
    done
    printf '%s|%s|%s|%s\n' "$v4_tcp" "$v4_udp" "$v6_tcp" "$v6_udp"
}
format_allow_ports() {
    local ports="${1//|/,}"
    ports=$(normalize_ports "$ports")
    printf '%s\n' "${ports:-无}"
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
            } else if (result=="none") result="port_conflict"
        }
        END { print result }
    ' "$file"
}
state_has_remote_rules() {
    [ -s "$1" ] || return 1
    awk -F'|' '
        NF>=8 && $2=="remote" && $6 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { found=1; exit }
        END { exit(found ? 0 : 1) }
    ' "$1"
}
# 候选补全与 ruleset 渲染
collect_domains() {
    local state_file="$1" ping_spec="$2" item
    local -a items
    {
        [ ! -s "$state_file" ] || awk -F'|' 'NF>=8 && $5=="domain" { print $3 }' "$state_file"
        case "$ping_spec" in
            any|off|"") ;;
            *)
                IFS=',' read -ra items <<< "$ping_spec"
                for item in "${items[@]}"; do
                    if validate_domain_name "$item"; then
                        printf '%s\n' "$item"
                    fi
                done
                ;;
        esac
    } | sort -u
}
sync_providerdns_subscription() (
    local state_file="$1" ping_spec="$2" domains_file
    domains_file=$(mktemp /tmp/forwardaws-domains.XXXXXX) || return 1
    trap 'rm -f "$domains_file"' EXIT
    collect_domains "$state_file" "$ping_spec" > "$domains_file" || return 1
    if [ ! -s "$domains_file" ]; then
        providerdns_unset_forwardaws
        return
    fi
    providerdns_set_forwardaws "$domains_file"
)
filter_candidate_domain_cache() {
    local candidate="$1" next now record ip
    local src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss
    next=$(mktemp "${candidate}.XXXXXX") || return 1
    now=$(date +%s)
    while IFS='|' read -r src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss; do
        [ -n "$src_port$mode$target$dest_port" ] || continue
        if [ "$target_type" = "domain" ]; then
            record=$(run_providerdns --cache "$target" 2>/dev/null)
            IFS=$'\t' read -r _ ip status _ <<< "$record"
            if ! validate_ip_address "$ip"; then
                log_error "域名 ${target} 没有有效 IPv4，取消本次变更"
                rm -f "$next"
                return 1
            fi
            [ "$ip" = "$resolved_ip" ] || { resolved_ip="$ip"; updated_at="$now"; }
        fi
        make_state_line "$src_port" "$mode" "$target" "$dest_port" "$target_type" \
            "$resolved_ip" "$status" "$updated_at" "$snat_ip" "$mss" >> "$next"
    done < "$candidate"
    mv "$next" "$candidate"
}
resolve_ping_sources() {
    local spec="$1" item record ip result_file
    local -a items
    RESOLVED_PING_IPV4=""
    case "$spec" in
        any|off)
            return 0
            ;;
    esac
    result_file=$(mktemp /tmp/forwardaws-ping.XXXXXX) || return 1
    IFS=',' read -ra items <<< "$spec"
    for item in "${items[@]}"; do
        if validate_ip_address "$item"; then
            printf '%s\n' "$item" >> "$result_file"
            continue
        fi
        record=$(run_providerdns --cache "$item" 2>/dev/null) || {
            log_error "Ping 域名 ${item} 没有当前或历史有效 IPv4"
            rm -f "$result_file"
            return 1
        }
        IFS=$'\t' read -r _ ip _ _ <<< "$record"
        validate_ip_address "$ip" || {
            log_error "Ping 域名 ${item} 没有当前或历史有效 IPv4"
            rm -f "$result_file"
            return 1
        }
        printf '%s\n' "$ip" >> "$result_file"
    done
    RESOLVED_PING_IPV4=$(sort -u "$result_file" | awk 'NF { printf "%s%s", sep, $0; sep="," } END { print "" }')
    rm -f "$result_file"
    [ -n "$RESOLVED_PING_IPV4" ]
}
prepare_candidate() {
    local candidate="$1" ping_spec="$2" refresh="$3"
    sync_providerdns_subscription "$candidate" "$ping_spec" || return 1
    if [ -n "$(collect_domains "$candidate" "$ping_spec")" ]; then
        require_providerdns || return 1
        if [ "$refresh" = "1" ]; then
            log_info "正在刷新域名解析"
            providerdns_refresh || return 1
        fi
        filter_candidate_domain_cache "$candidate" || return 1
    fi
    resolve_ping_sources "$ping_spec"
}
list_owned_nft_tables() {
    command -v nft >/dev/null 2>&1 || return 0
    { nft list tables 2>/dev/null || true; } |
        awk '$1=="table" && $3 ~ /^for?wardaws/ { print $2 "\t" $3 }'
}
nft_purge_prelude() {
    {
        [ "$#" -eq 0 ] || printf '%s\n' "$@"
        list_owned_nft_tables
    } | sort -u | awk -F'\t' 'NF==2 { printf "table %s %s\ndelete table %s %s\n", $1, $2, $1, $2 }'
}
render_ruleset() {
    local state_file="$1" protect_flag="$2" whitelist="$3" ping_spec="$4"
    local ping_ips="$5" output_file="$6" allow_ports="${7:-}" purge
    purge=$(nft_purge_prelude $'ip\t'"$NAT_TABLE_NAME" $'inet\t'"$FILTER_TABLE_NAME") || return 1
    FORWARDAWS_PURGE="$purge" awk -F'|' -v nat="$NAT_TABLE_NAME" -v filter="$FILTER_TABLE_NAME" \
        -v protect="$protect_flag" -v whitelist="$whitelist" -v ping="$ping_spec" \
        -v ping_ips="$ping_ips" -v allow="$allow_ports" -v service_mark="$SERVICE_ALLOW_MARK" '
        function rule(s) { return "        " s "\n" }
        NF>=8 && $2=="remote" && $6 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
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
                if (whitelist=="any") {
                    if (ports[1]!="") print "        meta nfproto ipv4 tcp dport { " ports[1] " } accept"
                    if (ports[2]!="") print "        meta nfproto ipv4 udp dport { " ports[2] " } accept"
                    if (ports[3]!="") print "        meta nfproto ipv6 tcp dport { " ports[3] " } accept"
                    if (ports[4]!="") print "        meta nfproto ipv6 udp dport { " ports[4] " } accept"
                } else if (whitelist ~ /^\//) {
                    if (ports[1]!="") print "        ip saddr @whitelist4 meta nfproto ipv4 tcp dport { " ports[1] " } accept"
                    if (ports[2]!="") print "        ip saddr @whitelist4 meta nfproto ipv4 udp dport { " ports[2] " } accept"
                }
                print "    }"
            }
            print "    chain forward {\n        type filter hook forward priority 0; policy drop;"
            print "        ct state invalid drop"
            if (whitelist=="off") {
                print "        ct state established,related accept"
            } else if (whitelist ~ /^\//) {
                print "        ct state established,related accept"
                print "        ct status dnat ip saddr @whitelist4 accept"
            } else {
                print "        ct status dnat accept"
                print "        ct state related accept"
            }
            print "    }\n}"
        }
    ' "$state_file" > "$output_file"
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
apply_candidate_state() (
    local candidate_state="$1" protect_flag="$2" whitelist="$3" whitelist_file="$4"
    local ping_spec="$5" ping_ips="$6" desc="$7" force_apply="$8" protect_ports="${9:-}"
    local work_dir nft_tmp state_tmp config_tmp
    local rules_changed=0 state_changed=0 config_changed=0 include_missing=0 live_missing=0 forwarding_needs_update=0
    work_dir=$(dirname "$candidate_state")
    nft_tmp="${work_dir}/forwardaws.nft"
    state_tmp="${work_dir}/rules.db"
    config_tmp="${work_dir}/config.env"
    render_ruleset "$candidate_state" "$protect_flag" "$whitelist" "$ping_spec" \
        "$ping_ips" "$nft_tmp" "$protect_ports" || return 1
    cp "$candidate_state" "$state_tmp" || return 1
    printf 'PROTECTION_ENABLED=%s\nPROTECT_WHITELIST=%s\nPROTECT_WHITELIST_FILE=%s\nPROTECT_PING=%s\n' \
        "$protect_flag" "$whitelist" "$whitelist_file" "$ping_spec" > "$config_tmp" || return 1
    cmp -s "$nft_tmp" "$FORWARDAWS_RULES_FILE" || rules_changed=1
    cmp -s "$state_tmp" "$RULES_STATE_FILE" || state_changed=1
    cmp -s "$config_tmp" "$CONFIG_FILE" || config_changed=1
    nft_main_config_include_is_current || include_missing=1
    if [ "$rules_changed" -eq 0 ]; then
        nft list table ip "$NAT_TABLE_NAME" >/dev/null 2>&1 &&
            nft list table inet "$FILTER_TABLE_NAME" >/dev/null 2>&1 || live_missing=1
    fi
    if state_has_remote_rules "$candidate_state" && ipv4_forwarding_needs_update; then
        forwarding_needs_update=1
    fi
    if [ "$rules_changed" -eq 1 ] || [ "$live_missing" -eq 1 ] || [ "$force_apply" -eq 1 ]; then
        run_nft_file -c "预检" "$nft_tmp" "$desc" || return 1
    fi
    if [ "$state_changed" -eq 1 ] && ! mv "$state_tmp" "$RULES_STATE_FILE"; then
        log_error "状态文件发布失败，运行规则未变：$RULES_STATE_FILE"
        return 1
    fi
    if [ "$config_changed" -eq 1 ] && ! mv "$config_tmp" "$CONFIG_FILE"; then
        log_error "配置文件发布失败，运行规则未变：$CONFIG_FILE"
        return 1
    fi
    if [ "$rules_changed" -eq 1 ]; then
        mv "$nft_tmp" "$FORWARDAWS_RULES_FILE" || {
            log_error "持久规则发布失败，运行规则未变：$FORWARDAWS_RULES_FILE"
            return 1
        }
        chmod 600 "$FORWARDAWS_RULES_FILE" 2>/dev/null || true
    fi
    if [ "$include_missing" -eq 1 ] || [ "$rules_changed" -eq 1 ]; then
        ensure_nft_main_config_include || return 1
    fi
    if [ "$rules_changed" -eq 1 ] || [ "$live_missing" -eq 1 ] || [ "$force_apply" -eq 1 ]; then
        run_nft_file "" "应用" "$FORWARDAWS_RULES_FILE" "$desc" || {
            log_error "持久状态已发布，但运行规则未应用；修复后请执行 --sync"
            return 1
        }
    fi
    [ "$forwarding_needs_update" -eq 0 ] || ensure_ipv4_forwarding_enabled
)
write_systemd_unit_if_changed() {
    local target_file="$1" tmp_file
    tmp_file=$(mktemp "${target_file}.XXXXXX") || return 1
    if ! cat > "$tmp_file"; then
        rm -f "$tmp_file"
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
list_owned_unit_files() {
    [ -d "$SYSTEMD_SYSTEM_DIR" ] || return 0
    find "$SYSTEMD_SYSTEM_DIR" -maxdepth 2 -name 'forwardaws-*' \
        \( -type f -o -type l \) 2>/dev/null
}
converge_systemd_units() {
    local path name failed=0 desired=" $* "
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        name=$(basename "$path")
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
    SYSTEMD_UNITS_CHANGED=0
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
append_rule_to_state() {
    local candidate="$1" rule="$2" now="$3" duplicate_mode="$4" status
    parse_rule "$rule" || return 1
    status=$(state_rule_status "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" \
        "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_SNAT_IP" "$PARSED_MSS")
    case "$status" in
        exact)
            [ "$duplicate_mode" = "skip" ] && return 2
            log_error "重复规则: $rule"
            return 1
            ;;
        base|port_conflict)
            log_error "规则冲突: $rule"
            return 1
            ;;
    esac
    make_state_line "$PARSED_SRC_PORT" "$PARSED_MODE" "$PARSED_TARGET" "$PARSED_DEST_PORT" \
        "$PARSED_TYPE" "$PARSED_IP" "$PARSED_STATUS" "$now" "$PARSED_SNAT_IP" "$PARSED_MSS" >> "$candidate"
}
remove_rule_from_state() (
    local candidate="$1" rule="$2" next status
    parse_rule "$rule" || return 1
    status=$(state_rule_status "$candidate" "$PARSED_SRC_PORT" "$PARSED_MODE" \
        "$PARSED_TARGET" "$PARSED_DEST_PORT" "$PARSED_SNAT_IP" "$PARSED_MSS")
    if [ "$status" != "exact" ] && [ "$status" != "base" ]; then
        return 2
    fi
    next=$(mktemp "${candidate}.XXXXXX") || return 1
    awk -F'|' -v sp="$PARSED_SRC_PORT" -v mode="$PARSED_MODE" -v target="$PARSED_TARGET" -v dp="$PARSED_DEST_PORT" \
        'NF>=8 && !($1==sp && $2==mode && $3==target && $4==dp) { print }' "$candidate" > "$next" || {
        rm -f "$next"
        return 1
    }
    mv "$next" "$candidate"
)
# 单一候选事务
sanitize_state_file() {
    local file="$1" next
    [ -s "$file" ] || return 0
    next=$(mktemp "${file}.XXXXXX") || return 1
    awk -F'|' '
        NF>=8 && $2=="remote" && $1 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { print; next }
        NF { printf "[WARNING] 丢弃不合规状态行: %s\n", $0 > "/dev/stderr" }
    ' "$file" > "$next" || {
        rm -f "$next"
        return 1
    }
    mv "$next" "$file"
}
transaction_open() {
    TX_DIR=$(mktemp -d "${STATE_DIR}/.tx.XXXXXX") || return 1
    TX_RULES="${TX_DIR}/candidate.db"
    if ! cp "$RULES_STATE_FILE" "$TX_RULES" || ! sanitize_state_file "$TX_RULES" || ! load_config; then
        rm -rf "$TX_DIR"
        return 1
    fi
    TX_PROTECTION="$CURRENT_PROTECTION"
    TX_WHITELIST="$CURRENT_WHITELIST"
    TX_WHITELIST_FILE="$CURRENT_WHITELIST_FILE"
    TX_WHITELIST_FILE_PREV="$CURRENT_WHITELIST_FILE"
    TX_PING="$CURRENT_PING"
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
    [[ "$1" != /* ]] || TX_WHITELIST_FILE="$1"
}
transaction_commit() {
    local desc="$1" refresh="${2:-0}" force_apply="${3:-0}" ports=""
    if [ "$TX_PROTECTION" = "1" ]; then
        if [[ "$TX_WHITELIST" == /* ]]; then
            TX_WHITELIST=$(normalize_whitelist_path "$TX_WHITELIST") || return 1
        fi
        ports=$(get_auto_allow_ports) || return 1
        [ -n "${ports//|/}" ] || {
            log_error "保护端口列表为空，拒绝启用保护"
            return 1
        }
    fi
    prepare_candidate "$TX_RULES" "$TX_PING" "$refresh" || return 1
    apply_candidate_state "$TX_RULES" "$TX_PROTECTION" "$TX_WHITELIST" \
        "$TX_WHITELIST_FILE" "$TX_PING" "$RESOLVED_PING_IPV4" "$desc" "$force_apply" "$ports" || return 1
    reconcile_systemd_units "$TX_PROTECTION" "$TX_WHITELIST" || {
        log_error "nft 规则与持久状态已生效，但 systemd 单元未对齐；修复后请执行 --sync"
        return 1
    }
    if [ -n "$TX_WHITELIST_FILE_PREV" ] && [ "$TX_WHITELIST_FILE_PREV" != "$TX_WHITELIST_FILE" ]; then
        reclaim_whitelist_file "$TX_WHITELIST_FILE_PREV" ||
            log_warning "旧 whitelist 文件未能回收：$TX_WHITELIST_FILE_PREV"
    fi
}
rule_batch() (
    local action="$1" protect_clause="$2" whitelist_set="$3" whitelist_arg="$4"
    local ping_set="$5" ping_arg="$6"
    shift 6
    local now rule rc operation duplicate_mode is_delete=0 success=0 skipped=0
    transaction_open || return 1
    trap 'rm -rf "$TX_DIR"' EXIT
    if [ "$protect_clause" -eq 1 ]; then
        TX_PROTECTION=1
        [ "$whitelist_set" -eq 0 ] || transaction_set_whitelist "$whitelist_arg"
        [ "$ping_set" -eq 0 ] || TX_PING="$ping_arg"
    fi
    case "$action" in
        add|--add|-a)
            operation="添加"
            duplicate_mode=skip
            ;;
        delete|--delete|-d)
            operation="删除"
            is_delete=1
            ;;
        replace|--replace|-r)
            operation="替换"
            duplicate_mode=fail
            : > "$TX_RULES"
            ;;
    esac
    now=$(date +%s)
    for rule in "$@"; do
        if [ "$is_delete" -eq 1 ]; then
            remove_rule_from_state "$TX_RULES" "$rule"
            rc=$?
        else
            append_rule_to_state "$TX_RULES" "$rule" "$now" "$duplicate_mode"
            rc=$?
        fi
        case "$rc" in
            0)
                success=$((success + 1))
                ;;
            2)
                skipped=$((skipped + 1))
                ;;
            *)
                log_error "批次校验失败，已取消所有变更"
                return 1
                ;;
        esac
    done
    transaction_commit "${operation}转发规则" 1 || return 1
    if [ "$success" -eq 0 ]; then
        log_info "没有规则变化"
    elif [ "$skipped" -eq 0 ]; then
        log_info "已${operation} ${success} 条转发规则"
    else
        log_info "已${operation} ${success} 条转发规则，跳过 ${skipped} 条"
    fi
)
run_protect() (
    local whitelist_set="$1" whitelist_arg="$2" ping_set="$3" ping_arg="$4"
    transaction_open || return 1
    trap 'rm -rf "$TX_DIR"' EXIT
    TX_PROTECTION=1
    [ "$whitelist_set" -eq 0 ] || transaction_set_whitelist "$whitelist_arg"
    [ "$ping_set" -eq 0 ] || TX_PING="$ping_arg"
    transaction_commit "开启保护" 1 || return 1
    log_info "保护已启用"
)
run_sync() (
    local source="${FORWARDAWS_SYNC_SOURCE:-manual}" refresh=0 force_apply=0
    case "$source" in
        manual)
            refresh=1
            force_apply=1
            ;;
        whitelist)
            force_apply=1
            ;;
        providerdns|timer) ;;
        *)
            log_error "无效的同步来源: $source"
            return 1
            ;;
    esac
    transaction_open || return 1
    trap 'rm -rf "$TX_DIR"' EXIT
    if [ "$source" = whitelist ] && ! [[ "$TX_WHITELIST" == /* ]]; then
        return 0
    fi
    transaction_commit "同步规则" "$refresh" "$force_apply" || return 1
    log_info "规则同步完成"
)
run_clean_scope() (
    local scope="$1" message
    transaction_open || return 1
    trap 'rm -rf "$TX_DIR"' EXIT
    case "$scope" in
        ping)
            TX_PING=any
            message="Ping 限制已清理"
            ;;
        whitelist)
            TX_WHITELIST=any
            message="Whitelist 限制已清理"
            ;;
        forward)
            : > "$TX_RULES"
            message="转发规则已清理"
            ;;
        protect)
            TX_PROTECTION=0
            TX_WHITELIST=any
            TX_PING=any
            message="保护规则已清理"
            ;;
    esac
    transaction_commit "清理 ${scope}" || return 1
    log_info "$message"
)
# 销毁、展示与 CLI 调度
purge_owned_nft_tables() (
    local nft_tmp prelude
    command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1 || {
        log_error "无法读取 nftables 状态，live 表未确认清理"
        return 1
    }
    prelude=$(nft_purge_prelude) || return 1
    [ -n "$prelude" ] || return 0
    nft_tmp=$(mktemp /tmp/forwardaws-cleanup.XXXXXX) || return 1
    trap 'rm -f "$nft_tmp"' EXIT
    printf '%s\n' "$prelude" > "$nft_tmp" || return 1
    run_nft_file "" "清理" "$nft_tmp" "删除 ForwardAWS nftables 表"
)
purge_nft_main_config_include() (
    local tmp
    [ -f "$NFT_MAIN_CONFIG_FILE" ] || return 0
    grep -Fqx "$NFT_INCLUDE_MARKER" "$NFT_MAIN_CONFIG_FILE" || return 0
    tmp=$(mktemp "${NFT_MAIN_CONFIG_FILE}.XXXXXX") || return 1
    trap 'rm -f "$tmp"' EXIT
    remove_own_include_block "$tmp" || return 1
    mv "$tmp" "$NFT_MAIN_CONFIG_FILE" || {
        log_error "写回 nftables 主配置失败: $NFT_MAIN_CONFIG_FILE"
        return 1
    }
)
clean_all() {
    local failed=0 forwarding_persisted=0
    [ ! -e "$IPV4_FORWARD_SYSCTL_FILE" ] || forwarding_persisted=1
    SYSTEMD_UNITS_CHANGED=0
    converge_systemd_units || failed=1
    reload_systemd_if_changed || failed=1
    providerdns_unset_forwardaws || failed=1
    purge_owned_nft_tables || failed=1
    purge_nft_main_config_include || failed=1
    rm -f "$FORWARDAWS_RULES_FILE" "$IPV4_FORWARD_SYSCTL_FILE" || failed=1
    reclaim_whitelist_file "$(get_config_value PROTECT_WHITELIST_FILE '')" || failed=1
    rm -rf "$STATE_DIR" || failed=1
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
unit_script_missing() {
    local script
    script=$(awk -F'"' '/^ExecStart=/ { print $2; exit }' \
        "${SYSTEMD_SYSTEM_DIR}/${1}" 2>/dev/null)
    [ -n "$script" ] && [ ! -f "$script" ]
}
show_protection_status() {
    local ports timer_status="关闭" whitelist_watch="关闭" whitelist_note=""
    load_config || return 1
    printf '%s\n' '本机防护'
    if [ "$CURRENT_PROTECTION" = 1 ]; then
        printf '%s\n' '- 状态：开启'
    else
        printf '%s\n' '- 状态：关闭'
    fi
    [[ "$CURRENT_WHITELIST" != /* ]] ||
        normalize_whitelist_path "$CURRENT_WHITELIST" >/dev/null 2>&1 ||
        whitelist_note="（无效）"
    printf -- '- Whitelist：%s%s\n' "$CURRENT_WHITELIST" "$whitelist_note"
    printf -- '- Ping：%s\n' "$CURRENT_PING"
    if [ "$CURRENT_PROTECTION" = 1 ]; then
        if [ "$EUID" -ne 0 ]; then
            printf -- '- 服务端口：%s\n' '需 root 查询'
        elif ports=$(get_auto_allow_ports); then
            printf -- '- 服务端口：%s\n' "$(format_allow_ports "$ports")"
        else
            printf -- '- 服务端口：%s\n' '查询失败'
        fi
    fi
    if has_systemctl && systemctl is-enabled --quiet "$PROTECT_TIMER_NAME" 2>/dev/null &&
        systemctl is-active --quiet "$PROTECT_TIMER_NAME" 2>/dev/null; then
        timer_status="启用"
        ! unit_script_missing "$PROTECT_SERVICE_NAME" || timer_status="失效（脚本路径已丢失）"
    fi
    if has_systemctl && [[ "$CURRENT_WHITELIST" == /* ]] &&
        systemctl is-enabled --quiet "$WHITELIST_PATH_NAME" 2>/dev/null &&
        systemctl is-active --quiet "$WHITELIST_PATH_NAME" 2>/dev/null; then
        whitelist_watch="启用"
    fi
    printf -- '- 端口同步：%s\n' "$timer_status"
    printf -- '- Whitelist 监控：%s\n' "$whitelist_watch"
}
display_rules() {
    local src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss extra
    printf '%s\n' '端口转发'
    if [ -s "$RULES_STATE_FILE" ]; then
        while IFS='|' read -r src_port mode target dest_port target_type resolved_ip status updated_at snat_ip mss; do
            [ -n "$src_port$mode$target$dest_port" ] || continue
            extra=""
            [ -z "$snat_ip" ] || extra="SNAT：${snat_ip}"
            if [ -n "$mss" ]; then
                [ "$mss" != auto ] || mss="自动"
                extra="${extra}${extra:+，}MSS：${mss}"
            fi
            if [ "$target_type" = domain ]; then
                status=$(format_domain_status "$status")
                extra="解析：${resolved_ip:-未解析}，${status}${extra:+，${extra}}"
            fi
            printf -- '- %s -> %s:%s%s\n' "$src_port" "$target" "$dest_port" "${extra:+（${extra}）}"
        done < "$RULES_STATE_FILE"
    else
        printf '%s\n' '- 无'
    fi
    printf '\n'
    show_protection_status
}
run_mutation() {
    local mode="$1" desc="$2"
    shift 2
    if [ "$mode" = state ]; then
        ensure_for_write || return 1
    else
        require_root || return 1
        command -v flock >/dev/null 2>&1 || {
            log_error "缺少依赖命令：flock"
            return 1
        }
        acquire_global_lock || return 1
    fi
    log_info "$desc"
    "$@"
}
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
            run_mutation state "正在处理 ${#PARSED_RULES[@]} 条转发规则" rule_batch "$action" \
                "$PARSED_PROTECT" "$PARSED_WHITELIST_SET" "$PARSED_WHITELIST" \
                "$PARSED_PING_SET" "$PARSED_PING" "${PARSED_RULES[@]}"
            ;;
        --protect)
            shift
            parse_protect_fields "$@" || return 1
            run_mutation state "正在启用保护" run_protect "$PARSED_WHITELIST_SET" "$PARSED_WHITELIST" \
                "$PARSED_PING_SET" "$PARSED_PING"
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
