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
# Interactive selection
################################################################################
# Function: Tuning type selection (interactive; no logging prefix in the prompt)
tune_selection() {
    echo "Please select tuning type:"
    echo "1. Only BBR"
    echo "2. TCP+BBR"
    echo "3. TCP+BBR+File"
    read -p "Enter your choice (1-3): " tune_choice
    case $tune_choice in
        1)
            mode="only_bbr"
            ;;
        2)
            mode="tcp_bbr"
            ;;
        3)
            mode="tcp_bbr_file"
            ;;
        *)
            timestamped_echo "${Error} Invalid selection, defaulting to Only BBR"
            mode="only_bbr"
            ;;
    esac
}

# Function: Server selection for memory parameters (for TCP+BBR and TCP+BBR+File)
server_selection() {
    echo "Please select server type:"
    echo "1. HK Server"
    echo "2. JP Server"
    echo "3. US Server"
    echo "4. Customized"
    read -p "Enter your choice (1-4): " server_choice
    case $server_choice in
        1)
            Rmem=6875000
            Wmem=6875000
            ;;
        2)
            Rmem=7786000
            Wmem=7786000
            ;;
        3)
            Rmem=18750000
            Wmem=18750000
            ;;
        4)
            read -p "Enter Rmem value: " Rmem
            read -p "Enter Wmem value: " Wmem
            ;;
        *)
            timestamped_echo "${Error} Invalid selection, defaulting to HK Server configuration"
            Rmem=6875000
            Wmem=6875000
            ;;
    esac
    timestamped_echo "${Info} Selected Rmem: ${Rmem}, Wmem: ${Wmem}"
}

################################################################################
# Linux optimization main code
################################################################################
# Function: Simple BBR tuning (Only BBR mode)
simple_bbr_tune() {
    cat > /etc/sysctl.conf << EOF
# TCP congestion control
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
# Network buffer tuning
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 ${Rmem}
net.ipv4.tcp_wmem=4096 16384 ${Wmem}
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
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
}

# Function: Full TCP and BBR tuning (for TCP+BBR and TCP+BBR+File)
system_tune() {
    cat > /etc/sysctl.conf << EOF
# Maximum number of file descriptors
fs.file-max=6815744
# Use Swap when physical memory is below 20%
vm.swappiness=20
# TCP congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# TCP connection keepalive settings
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 30
# Disable Explicit Congestion Notification (ECN)
net.ipv4.tcp_ecn=0
# Disable TCP fast retransmission optimization
net.ipv4.tcp_frto=0
net.ipv4.tcp_rfc1337=0
# Disable Slow-Start Restart
net.ipv4.tcp_slow_start_after_idle = 0
# Disable MTU probing
net.ipv4.tcp_mtu_probing=0
# Disable connection metrics saving
net.ipv4.tcp_no_metrics_save=1
# Enable TCP Selective Acknowledgment
net.ipv4.tcp_sack=1
# Enable TCP Forward Acknowledgment
net.ipv4.tcp_fack=1
# TCP window scaling
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
# Network buffer tuning
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 ${Rmem}
net.ipv4.tcp_wmem=4096 16384 ${Wmem}
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
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
}

# Function: System resource (ulimit) tuning for TCP+BBR+File mode
ulimit_tune() {
    echo "1000000" > /proc/sys/fs/file-max
    sed -i '/fs.file-max/d' /etc/sysctl.conf
    cat >> /etc/sysctl.conf << EOF
fs.file-max=1000000
EOF

    ulimit -SHn 1000000 && ulimit -c unlimited
    cat > /etc/security/limits.conf << EOF
root     soft   nofile    1000000
root     hard   nofile    1000000
root     soft   nproc     1000000
root     hard   nproc     1000000
root     soft   core      unlimited
root     hard   core      unlimited
root     hard   memlock   unlimited
root     soft   memlock   unlimited

*     soft   nofile    1000000
*     hard   nofile    1000000
*     soft   nproc     1000000
*     hard   nproc     1000000
*     soft   core      unlimited
*     hard   core      unlimited
*     hard   memlock   unlimited
*     soft   memlock   unlimited
EOF

    if grep -q "ulimit" /etc/profile; then
        :
    else
        sed -i '/ulimit -SHn/d' /etc/profile
        echo "ulimit -SHn 1000000" >> /etc/profile
    fi

    if grep -q "pam_limits.so" /etc/pam.d/common-session; then
        :
    else
        sed -i '/required pam_limits.so/d' /etc/pam.d/common-session
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    fi

    sed -i '/DefaultTimeoutStartSec/d' /etc/systemd/system.conf
    sed -i '/DefaultTimeoutStopSec/d' /etc/systemd/system.conf
    sed -i '/DefaultRestartSec/d' /etc/systemd/system.conf
    sed -i '/DefaultLimitCORE/d' /etc/systemd/system.conf
    sed -i '/DefaultLimitNOFILE/d' /etc/systemd/system.conf
    sed -i '/DefaultLimitNPROC/d' /etc/systemd/system.conf

    cat >> /etc/systemd/system.conf << EOF
[Manager]
#DefaultTimeoutStartSec=90s
DefaultTimeoutStopSec=30s
#DefaultRestartSec=100ms
DefaultLimitCORE=infinity
DefaultLimitNOFILE=65535
DefaultLimitNPROC=65535
EOF

    systemctl daemon-reload
}

# Function: Finalize sysctl configuration application
finalize_sysctl() {
    sysctl -p && sysctl --system
    if [ $? -eq 0 ]; then
        timestamped_echo "${Info} TCP+BBR tuning applied successfully."
    else
        timestamped_echo "${Error} Failed to apply TCP+BBR tuning."
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

# Tuning type selection
tune_selection

if [ "$mode" = "only_bbr" ]; then
    server_selection
    timestamped_echo "${Info} Applying Only BBR tuning..."
    simple_bbr_tune
elif [ "$mode" = "tcp_bbr" ]; then
    # For TCP+BBR, prompt for server selection and then apply full TCP tuning
    server_selection
    timestamped_echo "${Info} Applying TCP+BBR tuning..."
    system_tune
elif [ "$mode" = "tcp_bbr_file" ]; then
    # For TCP+BBR+File, prompt for server selection, apply full TCP tuning and then ulimit tuning
    server_selection
    timestamped_echo "${Info} Applying TCP+BBR tuning..."
    system_tune
    timestamped_echo "${Info} Applying system resource (ulimit) tuning..."
    ulimit_tune
fi

# Finalize sysctl updates (applies to all modes)
finalize_sysctl

timestamped_echo "${Info} System tuning completed."
echo "================================"
timestamped_echo "${Info} Starting script cleanup..."
clean_file
timestamped_echo "${Info} Script cleanup completed."
timestamped_echo "${Tip} Some settings may require a system restart to take effect."
timestamped_echo "${Tip} IPv6 has been disabled; if you need IPv6, please manually modify the /etc/sysctl.conf file."
