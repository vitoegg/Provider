#!/usr/bin/env bash

# Define color codes and message tags
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[INFO]${Font_color_suffix}"
Error="${Red_font_prefix}[ERROR]${Font_color_suffix}"
Tip="${Green_font_prefix}[TIP]${Font_color_suffix}"

################################################################################
# Function: Print output with a timestamp at the beginning
################################################################################
timestamped_echo() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

################################################################################
# Check root privileges
################################################################################
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root!"
    exit 1
fi

################################################################################
# Server selection for memory parameters
################################################################################
server_selection() {
    echo "Please select server type:"
    echo "1. HK Frenzy"
    echo "2. JP Frenzy"
    echo "3. US Frenzy"
    echo "4. JP Relay"
    echo "5. Customized"
    read -p "Enter your choice (1-5): " server_choice
    case $server_choice in
        1)
            Rmem=9699328
            Wmem=9699328
            server_type="HK Frenzy"
            ;;
        2)
            Rmem=12722722
            Wmem=12722722
            server_type="JP Frenzy"
            ;;
        3)
            Rmem=35966156
            Wmem=35966156
            server_type="US Frenzy"
            ;;
        4)
            Rmem=40737177
            Wmem=20368588
            server_type="JP Relay"
            ;;
        5)
            read -p "Enter Rmem value: " Rmem
            read -p "Enter Wmem value: " Wmem
            server_type="Custom"
            ;;
        *)
            timestamped_echo "${Error} Invalid selection, defaulting to General Mode"
            Rmem=6735000
            Wmem=6735000
            server_type="General"
            ;;
    esac
    timestamped_echo "${Info} Selected server type: ${server_type}"
    timestamped_echo "${Info} Selected Rmem: ${Rmem}, Wmem: ${Wmem}"
}

################################################################################
# Function: BBR tuning and TCP optimizing
################################################################################
bbr_tcp_tune() {
    if [[ "$server_type" == "JP Relay" ]]; then
        cat > /etc/sysctl.conf << EOF
# Kernel parameters
kernel.pid_max = 65535
kernel.panic = 1
kernel.sysrq = 1
kernel.core_pattern = core_%e
kernel.printk = 3 4 1 3
kernel.numa_balancing = 0
kernel.sched_autogroup_enabled = 0

# Memory management
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.panic_on_oom = 1
vm.overcommit_memory = 1
vm.min_free_kbytes = 153600

# Network core settings
net.core.default_qdisc = cake
net.core.netdev_max_backlog = 2800
net.core.rmem_max = 40737177
net.core.wmem_max = 20368588
net.core.rmem_default = 87380
net.core.wmem_default = 65536
net.core.somaxconn = 700
net.core.optmem_max = 65536

# TCP parameters
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 0

# TCP memory settings
net.ipv4.tcp_rmem = 8192 87380 40737177
net.ipv4.tcp_wmem = 8192 65536 20368588
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 4096
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 0

# TCP connection settings
net.ipv4.tcp_max_syn_backlog = 2867
net.ipv4.tcp_max_orphans = 65536
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_stdurg = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_syncookies = 1

# IP settings
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.route.gc_timeout = 100
net.ipv4.neigh.default.gc_stale_time = 120
net.ipv4.neigh.default.gc_thresh3 = 8192
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh1 = 1024

# Security settings
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1

# Enable packet forwarding
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    else
        cat > /etc/sysctl.conf << EOF
# Memory recovery and swap control
vm.swappiness = 10
vm.min_free_kbytes = 153600

# TCP congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Network buffer tuning
net.ipv4.tcp_rmem=4096 87380 ${Rmem}
net.ipv4.tcp_wmem=4096 16384 ${Wmem}

# Increase queue length
net.core.netdev_max_backlog = 4000
net.core.somaxconn = 1024

# Enable window expansion
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=2
net.ipv4.tcp_moderate_rcvbuf=1

# Enable packet forwarding
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    fi
}

# Function: Finalize sysctl configuration application
finalize_sysctl() {
    sysctl -p && sysctl --system
    if [ $? -eq 0 ]; then
        timestamped_echo "${Info} TCP tuning applied successfully for ${server_type} mode."
    else
        timestamped_echo "${Error} Failed to apply TCP tuning."
    fi
}

# Function: Clean up the script file itself
clean_file() {
    rm -f "$(readlink -f "$0")"
    timestamped_echo "${Info} Script file cleaned up."
}

################################################################################
# Main execution flow
################################################################################
echo "================================"
timestamped_echo "${Info} Starting system tuning..."
server_selection

timestamped_echo "${Info} Applying TCP tuning for ${server_type} mode..."
bbr_tcp_tune

# Finalize sysctl updates (applies to all modes)
finalize_sysctl

timestamped_echo "${Info} System tuning completed."
echo "================================"
timestamped_echo "${Info} Starting script cleanup..."
clean_file
timestamped_echo "${Info} Script cleanup completed."
timestamped_echo "${Tip} Some settings may require a system restart to take effect."
timestamped_echo "${Tip} IPv6 has been disabled; if you need IPv6, please manually modify the /etc/sysctl.conf file."
