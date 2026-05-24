#!/bin/bash

set -o pipefail

SYSCTL_FILE="/etc/sysctl.d/99-network-kernel.conf"

IPV6="yes"
REMOVE_CONFIG="no"

log() {
    printf '[%s] %s\n' "$1" "$2"
}

die() {
    log "ERR" "$1"
    exit 1
}

show_help() {
    cat << EOF
Usage:
  bash kernel.sh [-6 yes|no]
  bash kernel.sh -u

Options:
  -6  IPv6: yes, no. Default: yes
  -u  Remove kernel optimization configuration
  -h  Show this help

Examples:
  bash kernel.sh
  bash kernel.sh -6 no
  bash kernel.sh -u
EOF
    exit 0
}

contains() {
    local value=$1
    shift

    local item
    for item in "$@"; do
        [[ "$item" == "$value" ]] && return 0
    done

    return 1
}

while getopts ":6:uh" opt; do
    case "$opt" in
        6) IPV6="$OPTARG" ;;
        u) REMOVE_CONFIG="yes" ;;
        h) show_help ;;
        :) die "Option -$OPTARG requires a value" ;;
        \?) die "Invalid option: -$OPTARG" ;;
    esac
done

validate_config() {
    contains "$IPV6" yes no || die "Invalid IPv6 value: $IPV6"
}

remove_config() {
    rm -f "$SYSCTL_FILE"

    sysctl --system >/dev/null 2>&1 || log "WARN" "Some sysctl values failed to reload"
    log "OK" "Kernel optimization configuration removed. Reboot recommended."
}

write_sysctl_config() {
    install -d /etc/sysctl.d

    {
        cat << 'EOF'
# TCP Baseline
net.ipv4.tcp_syncookies = 1

# TCP Performance
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0

# ECN
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_ecn_fallback = 1
EOF

        if [[ "$IPV6" == "no" ]]; then
            cat << 'EOF'

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        fi

        if modprobe tcp_bbr 2>/dev/null && grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            cat << EOF

# BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
            BBR_ENABLED="yes"
        else
            BBR_ENABLED="no"
        fi
    } > "$SYSCTL_FILE"
}

apply_config() {
    sysctl --system >/dev/null 2>&1 || log "WARN" "Some sysctl values failed to apply"
}

verify_config() {
    local congestion qdisc_actual ipv6_actual

    if [[ "$BBR_ENABLED" == "yes" ]]; then
        qdisc_actual=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || true)
        congestion=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
        [[ "$qdisc_actual" == "fq" && "$congestion" == "bbr" ]] \
            && log "OK" "BBR and fq applied" \
            || log "WARN" "BBR configuration may require reboot"
    else
        log "WARN" "BBR is not available"
    fi

    if [[ "$IPV6" == "no" ]]; then
        ipv6_actual=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)
        [[ "$ipv6_actual" == "1" ]] && log "OK" "IPv6 disabled" || log "WARN" "IPv6 disable may require reboot"
    else
        log "OK" "IPv6 remains enabled"
    fi
}

if [[ "$REMOVE_CONFIG" == "yes" ]]; then
    [[ "$(id -u)" == "0" ]] || die "Root privileges required"
    remove_config
    exit 0
fi

validate_config
log "INFO" "IPv6=$IPV6"

[[ "$(id -u)" == "0" ]] || die "Root privileges required"

log "INFO" "Writing sysctl configuration to $SYSCTL_FILE"
write_sysctl_config
apply_config
verify_config

log "OK" "Optimization completed. Reboot recommended."
