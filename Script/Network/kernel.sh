#!/bin/bash

set -o pipefail

SYSCTL_FILE="/etc/sysctl.d/99-network-kernel.conf"
IPV6="yes"
MODE="apply"
CANDIDATE=""

log_info() {
    [ "${QUIET:-0}" = "1" ] || printf '[INFO] %s\n' "$*"
}

log_warning() {
    printf '[WARNING] %s\n' "$*" >&2
}

log_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

fail() {
    log_error "$*"
    exit 1
}

trap 'rm -f "$CANDIDATE"' EXIT

show_help() {
    cat << 'EOF'
用法：
  bash kernel.sh [-6 yes|no|-u]
  -6 yes|no    是否保留 IPv6，默认 yes
  -u           移除内核优化配置
  -h, --help   显示帮助
EOF
}

parse_args() {
    local ipv6_seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -6)
                [ "$#" -ge 2 ] || fail '参数 -6 缺少值'
                [ "$MODE" = "apply" ] || fail '参数 -u 与 -6 不能同时使用'
                ipv6_seen=1
                IPV6="$2"
                shift 2
                ;;
            -u)
                [ "$ipv6_seen" = "0" ] || fail '参数 -u 与 -6 不能同时使用'
                MODE="remove"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                fail "未知参数：$1"
                ;;
        esac
    done
    [ "$IPV6" = "yes" ] || [ "$IPV6" = "no" ] || fail "IPv6 参数无效：$IPV6"
}

require_environment() {
    [ "$(id -u)" = "0" ] || fail '此操作必须以 root 权限运行'
    command -v sysctl >/dev/null 2>&1 || fail '缺少依赖命令：sysctl（请安装 procps）'
}

bbr_supported() {
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi
    grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

render_config() {
    cat > "$1" << 'EOF' || fail '无法生成内核参数配置'
# Managed by Provider kernel.sh
net.ipv4.tcp_slow_start_after_idle = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_fin_timeout = 30
EOF
    if bbr_supported; then
        cat >> "$1" << 'EOF' || fail '无法生成 BBR 配置'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    fi
    if [ "$IPV6" = "no" ]; then
        cat >> "$1" << 'EOF' || fail '无法生成 IPv6 配置'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    fi
}

runtime_matches_config() {
    local file="$1" report="${2:-0}" key operator expected actual failed=0
    while read -r key operator expected; do
        if [[ "$key" == \#* ]]; then
            continue
        fi
        actual="$(sysctl -n "$key" 2>/dev/null || true)"
        if [ "$actual" != "$expected" ]; then
            if [ "$report" = "1" ]; then
                log_warning "内核参数未生效：$key，期望 $expected，实际 ${actual:-不可用}"
            fi
            failed=1
        fi
    done < "$file"
    [ "$failed" = "0" ]
}

apply_profile() {
    local bbr_status="不可用" ipv6_status
    install -d "$(dirname "$SYSCTL_FILE")" || fail '无法创建 sysctl 配置目录'
    CANDIDATE="$(mktemp "${SYSCTL_FILE}.XXXXXX")" || fail '无法创建 sysctl 临时文件'
    render_config "$CANDIDATE"
    chmod 644 "$CANDIDATE" || fail '无法设置 sysctl 配置权限'
    if cmp -s "$CANDIDATE" "$SYSCTL_FILE"; then
        rm -f "$CANDIDATE"
        CANDIDATE=""
        if runtime_matches_config "$SYSCTL_FILE"; then
            log_info '内核网络优化配置未变化，无需重新应用'
            return 0
        fi
    else
        mv "$CANDIDATE" "$SYSCTL_FILE" || fail "无法写入配置：$SYSCTL_FILE"
        CANDIDATE=""
    fi
    if ! sysctl --system >/dev/null 2>&1 || ! runtime_matches_config "$SYSCTL_FILE" 1; then
        log_warning 'sysctl 运行值可能已部分改变，请检查当前值或重启系统'
        fail '内核参数应用或验证失败，请检查当前配置文件'
    fi
    if [ "$IPV6" = "yes" ]; then
        ipv6_status="保留"
    else
        ipv6_status="禁用"
    fi
    if grep -q 'tcp_congestion_control = bbr' "$SYSCTL_FILE"; then
        bbr_status="启用"
    fi
    log_info "内核网络优化已应用（BBR：$bbr_status，IPv6：$ipv6_status）"
}

remove_profile() {
    if [ ! -e "$SYSCTL_FILE" ]; then
        log_info '内核网络优化配置已不存在，无需卸载'
        return 0
    fi
    rm -f "$SYSCTL_FILE" || fail "无法删除配置：$SYSCTL_FILE"
    if ! sysctl --system >/dev/null 2>&1; then
        log_warning 'sysctl 运行值可能已部分改变，请检查当前值或重启系统'
        fail '内核参数卸载失败，请检查当前运行值'
    fi
    log_info '已删除内核网络优化配置'
    log_warning '已写入的内核运行值不会自动恢复，建议重启系统恢复默认值'
}

main() {
    parse_args "$@"
    require_environment
    if [ "$MODE" = "remove" ]; then
        remove_profile
    else
        apply_profile
    fi
}

main "$@"
