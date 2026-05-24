#!/bin/bash

set -o pipefail

SYSCTL_FILE="/etc/sysctl.d/99-network-kernel.conf"

MODE="advanced"
REGION="jp"
QDISC="fq"
IPV6="yes"
RMEM_MAX=""
WMEM_MAX=""
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
  bash kernel.sh [-m mode] [-r region] [-q qdisc] [-6 yes|no] [-R rmem] [-W wmem]
  bash kernel.sh -u

Options:
  -m  Mode: simple, advanced. Default: advanced
  -r  Region: jp, hk, us, custom. Default: jp, ignored in simple mode
  -q  Queue discipline: fq, fq_pie, cake. Default: fq
  -6  IPv6: yes, no. Default: yes
  -R  Custom rmem max, required when -r custom
  -W  Custom wmem max, required when -r custom
  -u  Remove kernel optimization configuration
  -h  Show this help

Examples:
  bash kernel.sh
  bash kernel.sh -m simple -q fq -6 yes
  bash kernel.sh -m advanced -r jp -q fq
  bash kernel.sh -m advanced -r custom -R 33554432 -W 16777216
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

set_region_buffers() {
    case "$REGION" in
        jp) RMEM_MAX="33554432"; WMEM_MAX="16777216" ;;
        hk) RMEM_MAX="12582912"; WMEM_MAX="6291456" ;;
        us) RMEM_MAX="67108864"; WMEM_MAX="33554432" ;;
        *) return 1 ;;
    esac
}

while getopts ":m:r:q:6:R:W:uh" opt; do
    case "$opt" in
        m) MODE="$OPTARG" ;;
        r) REGION="$OPTARG" ;;
        q) QDISC="$OPTARG" ;;
        6) IPV6="$OPTARG" ;;
        R) RMEM_MAX="$OPTARG" ;;
        W) WMEM_MAX="$OPTARG" ;;
        u) REMOVE_CONFIG="yes" ;;
        h) show_help ;;
        :) die "Option -$OPTARG requires a value" ;;
        \?) die "Invalid option: -$OPTARG" ;;
    esac
done

validate_config() {
    contains "$MODE" simple advanced || die "Invalid mode: $MODE"
    contains "$QDISC" fq fq_pie cake || die "Invalid qdisc: $QDISC"
    contains "$IPV6" yes no || die "Invalid IPv6 value: $IPV6"

    if [[ "$MODE" == "simple" ]]; then
        [[ "$REGION" != "jp" ]] && log "WARN" "Region is ignored in simple mode"
        return 0
    fi

    if [[ "$REGION" == "custom" ]]; then
        [[ "$RMEM_MAX" =~ ^[0-9]+$ && "$WMEM_MAX" =~ ^[0-9]+$ ]] || die "Custom region requires numeric -R and -W"
        return 0
    fi

    set_region_buffers || die "Invalid region: $REGION"
}

remove_config() {
    rm -f "$SYSCTL_FILE"

    sysctl --system >/dev/null 2>&1 || log "WARN" "Some sysctl values failed to reload"
    log "OK" "Kernel optimization configuration removed. Reboot recommended."
}

write_sysctl_config() {
    install -d /etc/sysctl.d

    {
        if [[ "$MODE" == "simple" ]]; then
            cat << 'EOF'
# Simple Mode Network
net.ipv4.tcp_mtu_probing = 1
EOF
        else
            cat << EOF
# Network Core
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 8192
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX

# TCP Buffer
net.ipv4.tcp_rmem = 4096 262144 $RMEM_MAX
net.ipv4.tcp_wmem = 4096 262144 $WMEM_MAX

# TCP Connection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# TCP Performance
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_slow_start_after_idle = 0

# ECN
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_ecn_fallback = 1

# Local Port Range
net.ipv4.ip_local_port_range = 10000 65535
EOF
        fi

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
net.core.default_qdisc = $QDISC
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
    local congestion qdisc_actual ipv6_actual rmem_actual wmem_actual

    if [[ "$MODE" == "advanced" ]]; then
        rmem_actual=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || true)
        wmem_actual=$(cat /proc/sys/net/core/wmem_max 2>/dev/null || true)
        [[ "$rmem_actual" == "$RMEM_MAX" && "$wmem_actual" == "$WMEM_MAX" ]] \
            && log "OK" "Buffer sizes applied" \
            || log "WARN" "Buffer sizes may require reboot"
    fi

    if [[ "$BBR_ENABLED" == "yes" ]]; then
        qdisc_actual=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || true)
        congestion=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
        [[ "$qdisc_actual" == "$QDISC" && "$congestion" == "bbr" ]] \
            && log "OK" "BBR and $QDISC applied" \
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
log "INFO" "Mode=$MODE Region=$REGION Qdisc=$QDISC IPv6=$IPV6"

[[ "$(id -u)" == "0" ]] || die "Root privileges required"

log "INFO" "Writing sysctl configuration to $SYSCTL_FILE"
write_sysctl_config
apply_config
verify_config

log "OK" "Optimization completed. Reboot recommended."
