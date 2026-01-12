#!/bin/bash
# Linux Kernel Optimization Script
# Optimized for clean environment installation

# ========================================
# Color Definitions & Logging
# ========================================
declare -A CLR=([R]='\033[0;31m' [G]='\033[0;32m' [Y]='\033[1;33m' [B]='\033[0;34m' [P]='\033[0;35m' [C]='\033[0;36m' [W]='\033[1;37m' [N]='\033[0m')

log() {
    local -A map=([info]=C [ok]=G [warn]=Y [err]=R [cfg]=P [stat]=B)
    local c="${CLR[${map[$1]:-C}]}" n="${CLR[N]}"
    echo -e "${c}[${1^^}]${n} ${c}$2${n}"
}

box() { echo -e "${CLR[$1]}┌─────────────────────────────────────────┐${CLR[N]}\n${CLR[$1]}│${CLR[N]}$2${CLR[$1]}│${CLR[N]}\n${CLR[$1]}└─────────────────────────────────────────┘${CLR[N]}"; }

# ========================================
# Configuration Data
# ========================================
declare -A REGIONS=([jp]="33554432:16777216" [hk]="12582912:6291456" [us]="67108864:33554432")
VALID_MODES="simple advanced"
VALID_QDISCS="fq fq_pie cake"
VALID_IPV6="yes no"

# ========================================
# Help Function
# ========================================
show_help() {
    echo
    box W "   ${CLR[C]}Linux Kernel Optimization Script${CLR[N]}    "
    echo -e "\n${CLR[Y]}Usage:${CLR[N]}\n  $0 [-m mode] [-r region] [-q qdisc] [-6 ipv6] [-h]"
    echo -e "\n${CLR[Y]}Options:${CLR[N]}"
    echo -e "  ${CLR[G]}-m${CLR[N]}  Mode ${CLR[C]}(simple, advanced)${CLR[N]} - Default: ${CLR[W]}advanced${CLR[N]}"
    echo -e "  ${CLR[G]}-r${CLR[N]}  Region ${CLR[C]}(jp, hk, us, custom)${CLR[N]} - Default: ${CLR[W]}jp${CLR[N]} ${CLR[Y]}(ignored in simple mode)${CLR[N]}"
    echo -e "  ${CLR[G]}-q${CLR[N]}  Queue discipline ${CLR[C]}(fq, fq_pie, cake)${CLR[N]} - Default: ${CLR[W]}fq${CLR[N]}"
    echo -e "  ${CLR[G]}-6${CLR[N]}  IPv6 ${CLR[C]}(yes=enable, no=disable)${CLR[N]} - Default: ${CLR[W]}yes${CLR[N]}"
    echo -e "  ${CLR[G]}-h${CLR[N]}  Display this help message"
    echo -e "\n${CLR[Y]}Modes:${CLR[N]}"
    echo -e "  ${CLR[W]}simple${CLR[N]}    ${CLR[C]}Configure BBR, queue discipline, and IPv6 only${CLR[N]}"
    echo -e "  ${CLR[W]}advanced${CLR[N]}  ${CLR[C]}Full kernel optimization with buffer tuning${CLR[N]}"
    echo -e "\n${CLR[Y]}Examples:${CLR[N]}"
    echo -e "  ${CLR[W]}$0${CLR[N]}                              ${CLR[C]}# Interactive mode${CLR[N]}"
    echo -e "  ${CLR[W]}$0 -m simple -q fq -6 yes${CLR[N]}       ${CLR[C]}# Simple mode, fq, IPv6 enabled${CLR[N]}"
    echo -e "  ${CLR[W]}$0 -m advanced -r jp -q fq${CLR[N]}      ${CLR[C]}# Advanced, Japan, fq${CLR[N]}"
    echo
    exit 0
}

# ========================================
# Generic Menu Function
# ========================================
show_menu() {
    local title=$1 var_name=$2 color=$3
    shift 3
    local options=("$@") choice

    while true; do
        echo
        box "$color" "        ${CLR[W]}$title${CLR[N]}              "
        echo
        for i in "${!options[@]}"; do
            echo -e "  ${CLR[G]}$((i+1)).${CLR[N]} ${CLR[W]}${options[$i]%%|*}${CLR[N]}  ${CLR[C]}${options[$i]#*|}${CLR[N]}"
        done
        echo
        echo -e -n "${CLR[Y]}Please select (1-${#options[@]}): ${CLR[N]}"
        read -r choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
            local selected="${options[$((choice-1))]%%|*}"
            # Handle special case for custom region
            if [[ "$selected" == "Custom Values" ]]; then
                echo -e -n "${CLR[C]}Enter Rmem value: ${CLR[N]}"
                read -r RMEM_MAX
                echo -e -n "${CLR[C]}Enter Wmem value: ${CLR[N]}"
                read -r WMEM_MAX
                if ! [[ "$RMEM_MAX" =~ ^[0-9]+$ && "$WMEM_MAX" =~ ^[0-9]+$ ]]; then
                    log err "Please enter valid numeric values"
                    continue
                fi
                eval "$var_name=custom"
                log cfg "Custom values set - Rmem: $RMEM_MAX, Wmem: $WMEM_MAX"
            else
                # Extract the value (lowercase first word)
                local val="${selected%% *}"
                val="${val,,}"
                # Handle IPv6 special mapping
                [[ "$var_name" == "DISABLE_IPV6" ]] && { [[ "$val" == "keep" ]] && val="no" || val="yes"; }
                eval "$var_name=\"$val\""
                log cfg "$title: $selected"
            fi
            break
        else
            log err "Invalid option. Please select 1-${#options[@]}."
        fi
    done
}

# ========================================
# Menu Option Definitions
# ========================================
show_mode_menu()   { show_menu "Configuration Mode" MODE W "Simple Mode|(BBR + Queue + IPv6 only)" "Advanced Mode|(Full kernel optimization)"; }
show_region_menu() { show_menu "Region Configuration" REGION P "JP Config|(Rmem: 33554432, Wmem: 16777216)" "HK Config|(Rmem: 12582912, Wmem: 6291456)" "US Config|(Rmem: 67108864, Wmem: 33554432)" "Custom Values|"; }
show_qdisc_menu()  { show_menu "Queue Discipline" QDISC C "fq|(Fair Queue - Default)" "fq_pie|(Fair Queue with PIE)" "cake|(Common Applications Kept Enhanced)"; }
show_ipv6_menu()   { show_menu "IPv6 Configuration" DISABLE_IPV6 B "Keep IPv6 Enabled|" "Disable IPv6|"; }

# ========================================
# Parameter Parsing
# ========================================
MODE="" REGION="" QDISC="" DISABLE_IPV6=""

parse_opt() {
    local val=$1 default=$2
    [[ -z "$val" || "$val" == -* ]] && echo "$default" || echo "$val"
}

while getopts ":m:r:q:6:h" opt; do
    case $opt in
        m) MODE=$(parse_opt "$OPTARG" "advanced"); [[ "$OPTARG" == -* ]] && ((OPTIND--)) ;;
        r) REGION=$(parse_opt "$OPTARG" "jp"); [[ "$OPTARG" == -* ]] && ((OPTIND--)) ;;
        q) QDISC=$(parse_opt "$OPTARG" "fq"); [[ "$OPTARG" == -* ]] && ((OPTIND--)) ;;
        6) 
            tmp=$(parse_opt "$OPTARG" "yes")
            [[ "$OPTARG" == -* ]] && ((OPTIND--))
            DISABLE_IPV6=$([[ "$tmp" == "yes" ]] && echo "no" || echo "yes")
            ;;
        h) show_help ;;
        :) case $OPTARG in
               m) MODE="advanced" ;; r) REGION="jp" ;; q) QDISC="fq" ;; 6) DISABLE_IPV6="no" ;;
           esac ;;
        \?) log err "Invalid option: -$OPTARG"; show_help ;;
    esac
done

# ========================================
# Root Privilege Check
# ========================================
[[ "$(id -u)" != "0" ]] && { echo; log err "Root privileges required"; exit 1; }

# ========================================
# Configuration Validation
# ========================================
echo
log info "Collecting configuration parameters..."

validate_or_menu() {
    local var_name=$1 value=$2 valid=$3 menu_func=$4 msg=$5
    if [[ -z "$value" ]]; then
        $menu_func
    elif [[ ! " $valid " =~ " $value " ]]; then
        log warn "Invalid $msg '$value'. Valid options: $valid"
        $menu_func
    else
        log cfg "$msg: $value"
    fi
}

# Validate mode
validate_or_menu MODE "$MODE" "$VALID_MODES" show_mode_menu "mode"

# Validate region (advanced mode only)
if [[ "$MODE" == "simple" ]]; then
    [[ -n "$REGION" ]] && log warn "Region parameter ignored in simple mode"
else
    if [[ -n "$REGION" ]]; then
        if [[ "$REGION" == "custom" ]]; then
            log err "Custom region requires interactive input"
            show_region_menu
        elif [[ -n "${REGIONS[$REGION]}" ]]; then
            IFS=: read -r RMEM_MAX WMEM_MAX <<< "${REGIONS[$REGION]}"
            log cfg "Region: $REGION (Rmem: $RMEM_MAX, Wmem: $WMEM_MAX)"
        else
            log warn "Invalid region '$REGION'. Valid options: jp, hk, us, custom"
            show_region_menu
        fi
    else
        show_region_menu
    fi
    # Set RMEM/WMEM from REGIONS if not custom
    [[ "$REGION" != "custom" && -z "$RMEM_MAX" ]] && IFS=: read -r RMEM_MAX WMEM_MAX <<< "${REGIONS[$REGION]}"
fi

# Validate qdisc
validate_or_menu QDISC "$QDISC" "$VALID_QDISCS" show_qdisc_menu "qdisc"

# Validate IPv6
if [[ -z "$DISABLE_IPV6" ]]; then
    show_ipv6_menu
elif [[ ! "$DISABLE_IPV6" =~ ^(yes|no)$ ]]; then
    log warn "Invalid IPv6 value. Valid options: yes, no"
    show_ipv6_menu
fi

# ========================================
# Configuration Summary
# ========================================
IPV6_STATUS=$([[ "$DISABLE_IPV6" == "yes" ]] && echo "Disabled" || echo "Enabled")
MODE_DISPLAY=$([[ "$MODE" == "simple" ]] && echo "Simple" || echo "Advanced")

echo
box G "       ${CLR[W]}Configuration Summary${CLR[N]}            "
echo
echo -e "  ${CLR[C]}Mode${CLR[N]}               ${CLR[W]}$MODE_DISPLAY${CLR[N]}"
[[ "$MODE" == "advanced" ]] && {
    echo -e "  ${CLR[C]}Region${CLR[N]}             ${CLR[W]}${REGION^^}${CLR[N]}"
    echo -e "  ${CLR[C]}Rmem Max${CLR[N]}           ${CLR[W]}$RMEM_MAX${CLR[N]}"
    echo -e "  ${CLR[C]}Wmem Max${CLR[N]}           ${CLR[W]}$WMEM_MAX${CLR[N]}"
}
echo -e "  ${CLR[C]}Queue Discipline${CLR[N]}   ${CLR[W]}$QDISC${CLR[N]}"
echo -e "  ${CLR[C]}IPv6${CLR[N]}               ${CLR[W]}$IPV6_STATUS${CLR[N]}"
echo

# ========================================
# Start Optimization
# ========================================
echo
log info "Starting Linux kernel optimization ($MODE_DISPLAY mode)..."

# ========================================
# File Descriptor Limits (Advanced mode only)
# ========================================
if [[ "$MODE" == "advanced" ]]; then
    echo
    log info "Configuring file descriptor limits..."

    cat > /etc/security/limits.conf << 'EOF'
*     soft   nofile    131072
*     hard   nofile    131072
*     soft   nproc     131072
*     hard   nproc     131072
*     soft   core      131072
*     hard   core      131072
*     hard   memlock   unlimited
*     soft   memlock   unlimited

root  soft   nofile    131072
root  hard   nofile    131072
root  soft   nproc     131072
root  hard   nproc     131072
root  soft   core      131072
root  hard   core      131072
root  hard   memlock   unlimited
root  soft   memlock   unlimited
EOF

    echo tls >> /usr/lib/modules-load.d/tls-loader.conf
    log ok "TLS module enabled"

    [[ -f /etc/pam.d/common-session ]] && echo "session required pam_limits.so" >> /etc/pam.d/common-session
    log ok "File descriptor limits configured"
fi

# ========================================
# Kernel Network Parameters
# ========================================
generate_sysctl() {
    # Common: IP forwarding
    echo "# IP Forwarding"
    echo "net.ipv4.ip_forward = 1"

    # Advanced mode: full configuration
    if [[ "$MODE" == "advanced" ]]; then
        cat << EOF

# File System
fs.file-max = 131072
fs.inotify.max_user_instances = 4096

# Network Core
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 8192
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX

# UDP Buffer
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 65536 131072 229376

# TCP Buffer
net.ipv4.tcp_rmem = 4096 262144 $RMEM_MAX
net.ipv4.tcp_wmem = 4096 262144 $WMEM_MAX
net.ipv4.tcp_mem = 65536 131072 229376

# TCP Connection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.tcp_max_orphans = 131072
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fastopen = 3

# TCP Performance
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_notsent_lowat = 32768
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_min_tso_segs = 2
net.ipv4.tcp_early_retrans = 1
net.ipv4.tcp_autocorking = 0

# TCP Security
net.ipv4.tcp_syn_retries = 1
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 0

# IP Parameters
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.route.gc_timeout = 100

# Virtual Memory
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF
    fi

    # IPv6 disable configuration
    if [[ "$DISABLE_IPV6" == "yes" ]]; then
        cat << 'EOF'

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    fi
}

log info "Configuring kernel network parameters..."
generate_sysctl > /etc/sysctl.conf
log ok "Kernel network parameters configured ($MODE_DISPLAY mode)"

# ========================================
# BBR Congestion Control
# ========================================
log info "Configuring BBR congestion control..."

if modprobe tcp_bbr 2>/dev/null && grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    cat >> /etc/sysctl.conf << EOF

# BBR Congestion Control
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = bbr
EOF
    log ok "BBR enabled successfully with qdisc: $QDISC"
else
    log warn "BBR not available or module not supported"
fi

# ========================================
# Apply Configuration
# ========================================
log info "Applying configuration..."

sysctl -p >/dev/null 2>&1 && log ok "sysctl.conf loaded successfully" || log warn "sysctl.conf loading failed"
sysctl --system >/dev/null 2>&1 && log ok "System sysctl configurations loaded" || log warn "System sysctl loading failed"

# ========================================
# Verification
# ========================================
echo
box B "        ${CLR[W]}Verification Results${CLR[N]}             "
echo

verify() {
    local desc=$1 expected=$2 actual=$3 warn_msg=${4:-"may require reboot"}
    [[ "$actual" == "$expected" ]] && log ok "$desc" || log warn "$desc $warn_msg"
}

# Verify buffer sizes (Advanced mode only)
if [[ "$MODE" == "advanced" ]]; then
    rmem_actual=$(cat /proc/sys/net/core/rmem_max 2>/dev/null)
    wmem_actual=$(cat /proc/sys/net/core/wmem_max 2>/dev/null)
    [[ "$rmem_actual" == "$RMEM_MAX" && "$wmem_actual" == "$WMEM_MAX" ]] \
        && log ok "Buffer sizes applied successfully" \
        || log warn "Buffer sizes may not be applied correctly"
fi

# Verify BBR status
if lsmod | grep -q bbr 2>/dev/null; then
    qdisc_actual=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)
    congestion=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    [[ "$qdisc_actual" == "$QDISC" && "$congestion" == "bbr" ]] \
        && log ok "BBR and $QDISC applied successfully" \
        || log warn "BBR configuration may not be applied correctly"
else
    log warn "BBR module not loaded"
fi

# Verify IPv6 status
if [[ "$DISABLE_IPV6" == "yes" ]]; then
    ipv6_actual=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo '0')
    verify "IPv6 disabled" "1" "$ipv6_actual" "(reboot required)"
else
    log ok "IPv6 remains enabled"
fi

# Verify file descriptors (Advanced mode only)
if [[ "$MODE" == "advanced" ]]; then
    fd_limit=$(ulimit -n)
    ((fd_limit >= 131072)) && log ok "File descriptor limits applied successfully" \
        || log warn "File descriptor limits may require relogin or reboot"
fi

echo
log ok "Optimization completed ($MODE_DISPLAY mode). Reboot recommended for all changes to take effect."
