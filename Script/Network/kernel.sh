#!/bin/bash
# Linux Kernel Optimization Script
# Optimized for clean environment installation

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Logging functions
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

# Default qdisc value
DEFAULT_QDISC="fq"

# Parse command line arguments
while getopts "q:" opt; do
    case $opt in
        q)
            QDISC="$OPTARG"
            ;;
        \?)
            log_error "Invalid option: -$OPTARG"
            echo "Usage: $0 [-q qdisc]"
            echo "  -q: Specify qdisc algorithm (fq, fq_pie, or cake). Default: fq"
            exit 1
            ;;
    esac
done

# Validate and set qdisc
if [ -n "$QDISC" ]; then
    case "$QDISC" in
        fq|fq_pie|cake)
            log_config "Using specified qdisc: $QDISC"
            ;;
        *)
            log_warning "Invalid qdisc '$QDISC'. Valid options: fq, fq_pie, cake. Using default: $DEFAULT_QDISC"
            QDISC="$DEFAULT_QDISC"
            ;;
    esac
else
    QDISC="$DEFAULT_QDISC"
    log_config "Using default qdisc: $QDISC"
fi

# Check root privileges
if [ "$(id -u)" != "0" ]; then
    log_error "Root privileges required"
    exit 1
fi

# ========================================
# Configuration Menu
# ========================================
show_menu() {
    echo
    echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${WHITE}Linux Kernel Optimization Script${NC}         ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}1.${NC} ${WHITE}Default Configuration${NC}                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}2.${NC} ${WHITE}Custom Configuration${NC}                   ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
    echo -e -n "${YELLOW}Please select an option (1-2): ${NC}"
}

show_custom_menu() {
    echo
    echo -e "${PURPLE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC}            ${WHITE}Custom Configuration Options${NC}                   ${PURPLE}║${NC}"
    echo -e "${PURPLE}╠═══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${PURPLE}║${NC} ${GREEN}1.${NC} ${WHITE}HK Config${NC} ${CYAN}(Rmem: 12582912, Wmem: 6291456)${NC}              ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC} ${GREEN}2.${NC} ${WHITE}US Config${NC} ${CYAN}(Rmem: 67108864, Wmem: 33554432)${NC}             ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC} ${GREEN}3.${NC} ${WHITE}Custom Values${NC}                                          ${PURPLE}║${NC}"
    echo -e "${PURPLE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo -e -n "${YELLOW}Please select an option (1-3): ${NC}"
}

# Get user input for configuration
get_configuration() {
    while true; do
        show_menu
        read choice
        case $choice in
            1)
                log_config "Default Configuration selected"
                RMEM_MAX=33554432
                WMEM_MAX=16777216
                break
                ;;
            2)
                while true; do
                    show_custom_menu
                    read custom_choice
                    case $custom_choice in
                        1)
                            log_config "HK Configuration selected"
                            RMEM_MAX=12582912
                            WMEM_MAX=6291456
                            break 2
                            ;;
                        2)
                            log_config "US Configuration selected"
                            RMEM_MAX=67108864
                            WMEM_MAX=33554432
                            break 2
                            ;;
                        3)
                            log_config "Custom Values selected"
                            echo -e -n "${CYAN}Enter Rmem value: ${NC}"
                            read RMEM_MAX
                            echo -e -n "${CYAN}Enter Wmem value: ${NC}"
                            read WMEM_MAX
                            
                            # Validate input
                            if ! [[ "$RMEM_MAX" =~ ^[0-9]+$ ]] || ! [[ "$WMEM_MAX" =~ ^[0-9]+$ ]]; then
                                log_error "Please enter valid numeric values"
                                continue
                            fi
                            
                            log_success "Custom values set - Rmem: $RMEM_MAX, Wmem: $WMEM_MAX"
                            break 2
                            ;;
                        *)
                            log_error "Invalid option. Please select 1-3."
                            ;;
                    esac
                done
                ;;
            *)
                log_error "Invalid option. Please select 1-2."
                ;;
        esac
    done
}

echo
log_info "Starting Linux kernel optimization..."

# Get user configuration choice
get_configuration

# ========================================
# File Descriptor Limits Configuration
# ========================================
echo
log_info "Configuring file descriptor limits..."

# Configure limits.conf
cat > /etc/security/limits.conf << 'EOF'
# File descriptor and process limits
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

# Enable PAM limits module
if [ -f /etc/pam.d/common-session ]; then
    echo "session required pam_limits.so" >> /etc/pam.d/common-session
fi

log_success "File descriptor limits configured"

# ========================================
# Kernel Network Parameters
# ========================================
log_info "Configuring kernel network parameters (Rmem: $RMEM_MAX, Wmem: $WMEM_MAX)"

cat > /etc/sysctl.conf << EOF
# File System Parameters
fs.file-max = 131072
fs.inotify.max_user_instances = 4096

# Network Core Parameters
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 8192
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX

# UDP Buffer Parameters
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 65536 131072 229376

# TCP Buffer Parameters
net.ipv4.tcp_rmem = 4096 262144 $RMEM_MAX
net.ipv4.tcp_wmem = 4096 262144 $WMEM_MAX
net.ipv4.tcp_mem = 65536 131072 229376

# TCP Connection Parameters
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

# TCP Performance Parameters
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

# TCP Security Parameters
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

# Virtual Memory Parameters
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

# Load /etc/sysctl.conf
if sysctl -p >/dev/null 2>&1; then
    log_success "sysctl.conf loaded successfully"
else
    log_warning "sysctl.conf loading failed"
fi

# Load all system sysctl configurations
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
echo -e "${BLUE}║${NC}        ${WHITE}Configuration Status${NC}           ${BLUE}║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════╝${NC}"

log_status "File descriptors: $(ulimit -n)"
log_status "Rmem max: $(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 'unavailable')"
log_status "Wmem max: $(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo 'unavailable')"
log_status "Congestion control: $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo 'unavailable')"
bbr_status=$(lsmod | grep bbr >/dev/null 2>&1 && echo 'loaded' || echo 'not loaded')
if [ "$bbr_status" = "loaded" ]; then
    qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo 'unknown')
    log_status "BBR status: loaded (qdisc: $qdisc)"
else
    log_status "BBR status: not loaded"
fi

echo
log_success "Optimization completed. Reboot recommended."