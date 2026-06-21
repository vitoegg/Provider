#!/bin/bash

set -o pipefail

SYSCTL_FILE="/etc/sysctl.d/99-network-kernel.conf"
IPV6="yes"
MODE="apply"
BBR_STATUS="unavailable"
KEYS=()
VALUES=()

log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log "ERR" "$1"; exit 1; }

show_help() {
    cat << EOF
Usage:
  bash kernel.sh [-6 yes|no]
  bash kernel.sh -u

Options:
  -6  IPv6: yes, no. Default: yes
  -u  Remove kernel optimization configuration
  -h  Show this help
EOF
    exit 0
}

trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

require_root() { [[ "$(id -u)" == "0" ]] || die "Root privileges required"; }
validate_args() { [[ "$IPV6" == "yes" || "$IPV6" == "no" ]] || die "Invalid IPv6 value: $IPV6"; }

bbr_supported() {
    command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1 || true
    grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

write_config() {
    install -d "$(dirname "$SYSCTL_FILE")" || die "Failed to create sysctl directory"
    cat > "$SYSCTL_FILE" << 'EOF' || die "Failed to write $SYSCTL_FILE"
# Managed by Provider kernel.sh

# TCP Adjustment
net.ipv4.tcp_slow_start_after_idle = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_fin_timeout = 30
EOF

    if bbr_supported; then
        BBR_STATUS="enabled"
        cat >> "$SYSCTL_FILE" << 'EOF' || die "Failed to write BBR config"

# BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    fi

    if [[ "$IPV6" == "no" ]]; then
        cat >> "$SYSCTL_FILE" << 'EOF' || die "Failed to write IPv6 config"

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    fi
}

read_config() {
    local line key value
    KEYS=()
    VALUES=()
    [[ -f "$SYSCTL_FILE" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(trim "${line%%#*}")
        [[ -z "$line" ]] && continue
        [[ "$line" == *"="* ]] || die "Invalid config line: $line"

        key=$(trim "${line%%=*}")
        value=$(trim "${line#*=}")
        [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid sysctl key: $key"
        [[ -n "$value" ]] || die "Empty value for sysctl key: $key"

        KEYS+=("$key")
        VALUES+=("$value")
    done < "$SYSCTL_FILE"
}

reload_sysctl() { sysctl --system >/dev/null 2>&1 || die "Failed to reload sysctl configuration"; }
sysctl_value() { sysctl -n "$1" 2>/dev/null || true; }

verify_apply() {
    local i key expected actual passed=0 failed=0

    read_config
    for ((i = 0; i < ${#KEYS[@]}; i++)); do
        key=${KEYS[$i]}
        expected=${VALUES[$i]}
        actual=$(sysctl_value "$key")
        if [[ "$actual" == "$expected" ]]; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            log "WARN" "verify: $key expected=$expected actual=${actual:-unavailable}"
        fi
    done

    [[ "$failed" -eq 0 ]] || die "verify failed: passed=$passed failed=$failed"
    log "OK" "verify: passed=$passed failed=0"
}

summary_apply() {
    local bbr="unavailable" ipv6="enabled"
    if [[ "$BBR_STATUS" == "enabled" ]]; then
        bbr="$(sysctl_value net.ipv4.tcp_congestion_control)/$(sysctl_value net.core.default_qdisc)"
    fi
    [[ "$IPV6" == "no" ]] && ipv6="disabled"
    log "OK" "summary: BBR=$bbr IPv6=$ipv6 TCP=applied"
}

apply_profile() {
    validate_args
    require_root
    log "INFO" "mode=apply ipv6=$IPV6 file=$SYSCTL_FILE"
    write_config
    read_config
    log "OK" "write: file saved keys=${#KEYS[@]}"
    reload_sysctl
    log "OK" "apply: system config reloaded"
    verify_apply
    summary_apply
}

remove_profile() {
    require_root
    log "INFO" "mode=remove file=$SYSCTL_FILE"

    if [[ ! -f "$SYSCTL_FILE" ]]; then
        log "OK" "remove: file already absent"
        return 0
    fi

    rm -f "$SYSCTL_FILE" || die "Failed to delete $SYSCTL_FILE"
    log "OK" "remove: file deleted"

    reload_sysctl
    [[ ! -f "$SYSCTL_FILE" ]] || die "remove failed: config file still exists"
    log "OK" "verify: config removed"
    log "WARN" "need to reboot to restore default settings"
    log "OK" "summary: kernel config removed"
}

while getopts ":6:uh" opt; do
    case "$opt" in
        6) IPV6="$OPTARG" ;;
        u) MODE="remove" ;;
        h) show_help ;;
        :) die "Option -$OPTARG requires a value" ;;
        \?) die "Invalid option: -$OPTARG" ;;
    esac
done

case "$MODE" in
    apply) apply_profile ;;
    remove) remove_profile ;;
esac
