#!/bin/bash
# Linux Kernel Optimization Script
# Optimized for clean environment installation

# ========================================
# Color Definitions
# ========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ========================================
# Logging Functions
# ========================================
log_info() {
    echo -e "${CYAN}[INFO]${NC} ${CYAN}$1${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} ${GREEN}$1${NC}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} ${YELLOW}$1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} ${RED}$1${NC}"
}

log_config() {
    echo -e "${PURPLE}[CONFIG]${NC} ${PURPLE}$1${NC}"
}

log_status() {
    echo -e "${BLUE}[STATUS]${NC} ${BLUE}$1${NC}"
}

# ========================================
# Help Function
# ========================================
show_help() {
    echo
    echo -e "${WHITE}Linux Kernel Optimization Script${NC}"
    echo
    echo "Usage: $0 [-r region] [-q qdisc] [-d disable_ipv6] [-h]"
    echo
    echo "Options:"
    echo "  -r  Region configuration (jp, hk, us, custom)"
    echo "  -q  Queue discipline algorithm (fq, fq_pie, cake). Default: fq"
    echo "  -d  Disable IPv6 (yes, no). Default: no"
    echo "  -h  Display this help message"
    echo
    echo "Examples:"
    echo "  $0                         # Interactive mode"
    echo "  $0 -r jp -q fq -d no       # Japan region, fq queue, IPv6 enabled"
    echo "  $0 -r us -q cake -d yes    # US region, cake queue, IPv6 disabled"
    echo
    exit 0
}

# ========================================
# Region Selection Menu
# ========================================
show_region_menu() {
    while true; do
        echo
        echo -e "${PURPLE}╔═══════════════════════════════════════════════════════╗${NC}"
        echo -e "${PURPLE}║${NC}              ${WHITE}Region Configuration${NC}                     ${PURPLE}║${NC}"
        echo -e "${PURPLE}╠═══════════════════════════════════════════════════════╣${NC}"
        echo -e "${PURPLE}║${NC} ${GREEN}1.${NC} ${WHITE}JP Config${NC} ${CYAN}(Rmem: 33554432, Wmem: 16777216)${NC}        ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC} ${GREEN}2.${NC} ${WHITE}HK Config${NC} ${CYAN}(Rmem: 12582912, Wmem: 6291456)${NC}         ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC} ${GREEN}3.${NC} ${WHITE}US Config${NC} ${CYAN}(Rmem: 67108864, Wmem: 33554432)${NC}        ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC} ${GREEN}4.${NC} ${WHITE}Custom Values${NC}                                      ${PURPLE}║${NC}"
        echo -e "${PURPLE}╚═══════════════════════════════════════════════════════╝${NC}"
        echo -e -n "${YELLOW}Please select region (1-4): ${NC}"
        read choice
        
        case $choice in
            1)
                REGION="jp"
                RMEM_MAX=33554432
                WMEM_MAX=16777216
                log_config "JP Configuration selected"
                break
                ;;
            2)
                REGION="hk"
                RMEM_MAX=12582912
                WMEM_MAX=6291456
                log_config "HK Configuration selected"
                break
                ;;
            3)
                REGION="us"
                RMEM_MAX=67108864
                WMEM_MAX=33554432
                log_config "US Configuration selected"
                break
                ;;
            4)
                REGION="custom"
                echo -e -n "${CYAN}Enter Rmem value: ${NC}"
                read RMEM_MAX
                echo -e -n "${CYAN}Enter Wmem value: ${NC}"
                read WMEM_MAX
                
                if ! [[ "$RMEM_MAX" =~ ^[0-9]+$ ]] || ! [[ "$WMEM_MAX" =~ ^[0-9]+$ ]]; then
                    log_error "Please enter valid numeric values"
                    continue
                fi
                
                log_config "Custom values set - Rmem: $RMEM_MAX, Wmem: $WMEM_MAX"
                break
                ;;
            *)
                log_error "Invalid option. Please select 1-4."
                ;;
        esac
    done
}

# ========================================
# Queue Discipline Selection Menu
# ========================================
show_qdisc_menu() {
    while true; do
        echo
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}          ${WHITE}Queue Discipline Configuration${NC}               ${CYAN}║${NC}"
        echo -e "${CYAN}╠═══════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} ${GREEN}1.${NC} ${WHITE}fq${NC} ${CYAN}(Fair Queue - Default)${NC}                         ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC} ${GREEN}2.${NC} ${WHITE}fq_pie${NC} ${CYAN}(Fair Queue with PIE)${NC}                      ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC} ${GREEN}3.${NC} ${WHITE}cake${NC} ${CYAN}(Common Applications Kept Enhanced)${NC}          ${CYAN}║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
        echo -e -n "${YELLOW}Please select qdisc (1-3): ${NC}"
        read choice
        
        case $choice in
            1)
                QDISC="fq"
                log_config "fq qdisc selected"
                break
                ;;
            2)
                QDISC="fq_pie"
                log_config "fq_pie qdisc selected"
                break
                ;;
            3)
                QDISC="cake"
                log_config "cake qdisc selected"
                break
                ;;
            *)
                log_error "Invalid option. Please select 1-3."
                ;;
        esac
    done
}

# ========================================
# IPv6 Configuration Menu
# ========================================
show_ipv6_menu() {
    while true; do
        echo
        echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}               ${WHITE}IPv6 Configuration${NC}                      ${BLUE}║${NC}"
        echo -e "${BLUE}╠═══════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}1.${NC} ${WHITE}Keep IPv6 enabled${NC}                                  ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}2.${NC} ${WHITE}Disable IPv6${NC}                                       ${BLUE}║${NC}"
        echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
        echo -e -n "${YELLOW}Please select IPv6 option (1-2): ${NC}"
        read choice
        
        case $choice in
            1)
                DISABLE_IPV6="no"
                log_config "IPv6 will remain enabled"
                break
                ;;
            2)
                DISABLE_IPV6="yes"
                log_config "IPv6 will be disabled"
                break
                ;;
            *)
                log_error "Invalid option. Please select 1-2."
                ;;
        esac
    done
}

# ========================================
# Parameter Parsing
# ========================================
REGION=""
QDISC=""
DISABLE_IPV6=""

while getopts "r:q:d:h" opt; do
    case $opt in
        r)
            REGION="$OPTARG"
            ;;
        q)
            QDISC="$OPTARG"
            ;;
        d)
            DISABLE_IPV6="$OPTARG"
            ;;
        h)
            show_help
            ;;
        \?)
            log_error "Invalid option: -$OPTARG"
            show_help
            ;;
    esac
done

# ========================================
# Root Privilege Check
# ========================================
if [ "$(id -u)" != "0" ]; then
    echo
    log_error "Root privileges required"
    exit 1
fi

# ========================================
# Configuration Collection
# ========================================
echo
log_info "Collecting configuration parameters..."

# Validate and set region
if [ -n "$REGION" ]; then
    case "$REGION" in
        jp)
            RMEM_MAX=33554432
            WMEM_MAX=16777216
            log_config "Using JP configuration from parameter"
            ;;
        hk)
            RMEM_MAX=12582912
            WMEM_MAX=6291456
            log_config "Using HK configuration from parameter"
            ;;
        us)
            RMEM_MAX=67108864
            WMEM_MAX=33554432
            log_config "Using US configuration from parameter"
            ;;
        custom)
            log_error "Custom region requires interactive input"
            show_region_menu
            ;;
        *)
            log_warning "Invalid region '$REGION'. Valid options: jp, hk, us, custom"
            show_region_menu
            ;;
    esac
else
    show_region_menu
fi

# Validate and set qdisc
if [ -n "$QDISC" ]; then
    case "$QDISC" in
        fq|fq_pie|cake)
            log_config "Using qdisc from parameter: $QDISC"
            ;;
        *)
            log_warning "Invalid qdisc '$QDISC'. Valid options: fq, fq_pie, cake"
            show_qdisc_menu
            ;;
    esac
else
    show_qdisc_menu
fi

# Validate and set IPv6 disable option
if [ -n "$DISABLE_IPV6" ]; then
    case "$DISABLE_IPV6" in
        yes|no)
            if [ "$DISABLE_IPV6" = "yes" ]; then
                log_config "IPv6 will be disabled (from parameter)"
            else
                log_config "IPv6 will remain enabled (from parameter)"
            fi
            ;;
        *)
            log_warning "Invalid disable_ipv6 value '$DISABLE_IPV6'. Valid options: yes, no"
            show_ipv6_menu
            ;;
    esac
else
    show_ipv6_menu
fi

# ========================================
# Configuration Summary
# ========================================
echo
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}              ${WHITE}Configuration Summary${NC}                     ${GREEN}║${NC}"
echo -e "${GREEN}╠═══════════════════════════════════════════════════════╣${NC}"

# Display region
REGION_DISPLAY=$(echo "$REGION" | tr '[:lower:]' '[:upper:]')
echo -e "${GREEN}║${NC} ${CYAN}Region:${NC} ${WHITE}$REGION_DISPLAY${NC}"
echo -e "${GREEN}║${NC} ${CYAN}Rmem Max:${NC} ${WHITE}$RMEM_MAX${NC}"
echo -e "${GREEN}║${NC} ${CYAN}Wmem Max:${NC} ${WHITE}$WMEM_MAX${NC}"

# Display qdisc
echo -e "${GREEN}║${NC} ${CYAN}Queue Discipline:${NC} ${WHITE}$QDISC${NC}"

# Display IPv6 status
if [ "$DISABLE_IPV6" = "yes" ]; then
    echo -e "${GREEN}║${NC} ${CYAN}IPv6:${NC} ${WHITE}Disabled${NC}"
else
    echo -e "${GREEN}║${NC} ${CYAN}IPv6:${NC} ${WHITE}Enabled${NC}"
fi

echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"

# ========================================
# Start Optimization
# ========================================
echo
log_info "Starting Linux kernel optimization..."

# ========================================
# File Descriptor Limits Configuration
# ========================================
echo
log_info "Configuring file descriptor limits..."

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
log_success "TLS module enabled"

if [ -f /etc/pam.d/common-session ]; then
    echo "session required pam_limits.so" >> /etc/pam.d/common-session
fi

log_success "File descriptor limits configured"

# ========================================
# Kernel Network Parameters
# ========================================
log_info "Configuring kernel network parameters (Rmem: $RMEM_MAX, Wmem: $WMEM_MAX)"

cat > /etc/sysctl.conf << EOF
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
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.route.gc_timeout = 100
EOF

# Conditionally add IPv6 disable configuration
if [ "$DISABLE_IPV6" = "yes" ]; then
    cat >> /etc/sysctl.conf << 'EOF'

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
fi

# Add Virtual Memory parameters
cat >> /etc/sysctl.conf << 'EOF'

# Virtual Memory
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF

log_success "Kernel network parameters configured"

# ========================================
# BBR Congestion Control
# ========================================
log_info "Configuring BBR congestion control..."

if modprobe tcp_bbr 2>/dev/null; then
    if grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        echo "net.core.default_qdisc = $QDISC" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        log_success "BBR enabled successfully with qdisc: $QDISC"
    else
        log_warning "BBR not available"
    fi
else
    log_warning "BBR module not supported"
fi

# ========================================
# Apply Configuration
# ========================================
log_info "Applying configuration..."

if sysctl -p >/dev/null 2>&1; then
    log_success "sysctl.conf loaded successfully"
else
    log_warning "sysctl.conf loading failed"
fi

if sysctl --system >/dev/null 2>&1; then
    log_success "System sysctl configurations loaded"
else
    log_warning "System sysctl loading failed"
fi

# ========================================
# Verification
# ========================================
echo
echo -e "${BLUE}╔═══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}        ${WHITE}Verification Results${NC}           ${BLUE}║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════╝${NC}"

# Verify kernel parameters applied
rmem_actual=$(cat /proc/sys/net/core/rmem_max 2>/dev/null)
wmem_actual=$(cat /proc/sys/net/core/wmem_max 2>/dev/null)

if [ "$rmem_actual" = "$RMEM_MAX" ] && [ "$wmem_actual" = "$WMEM_MAX" ]; then
    log_success "Buffer sizes applied successfully"
else
    log_warning "Buffer sizes may not be applied correctly"
fi

# Verify BBR status
bbr_status=$(lsmod | grep bbr >/dev/null 2>&1 && echo 'loaded' || echo 'not loaded')
if [ "$bbr_status" = "loaded" ]; then
    qdisc_actual=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)
    congestion=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    if [ "$qdisc_actual" = "$QDISC" ] && [ "$congestion" = "bbr" ]; then
        log_success "BBR and $QDISC applied successfully"
    else
        log_warning "BBR configuration may not be applied correctly"
    fi
else
    log_warning "BBR module not loaded"
fi

# Verify IPv6 status
if [ "$DISABLE_IPV6" = "yes" ]; then
    ipv6_actual=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo '0')
    if [ "$ipv6_actual" = "1" ]; then
        log_success "IPv6 disabled successfully"
    else
        log_warning "IPv6 disable pending (reboot required)"
    fi
fi

# Verify file descriptors
fd_limit=$(ulimit -n)
if [ "$fd_limit" -ge "131072" ]; then
    log_success "File descriptor limits applied successfully"
else
    log_warning "File descriptor limits may require relogin or reboot"
fi

echo
log_success "Optimization completed. Reboot recommended for all changes to take effect."
