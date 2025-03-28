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
    echo "4. Customized"
    read -p "Enter your choice (1-4): " server_choice
    case $server_choice in
        1)
            Rmem=9699328
            Wmem=9699328
            ;;
        2)
            Rmem=12722722
            Wmem=12722722
            ;;
        3)
            Rmem=35966156
            Wmem=35966156
            ;;
        4)
            read -p "Enter Rmem value: " Rmem
            read -p "Enter Wmem value: " Wmem
            ;;
        *)
            timestamped_echo "${Error} Invalid selection, defaulting to General Mode"
            Rmem=6735000
            Wmem=6735000
            ;;
    esac
    timestamped_echo "${Info} Selected Rmem: ${Rmem}, Wmem: ${Wmem}"
}

################################################################################
# Function: BBR tuning and TCP optimizing
################################################################################
bbr_tcp_tune() {
    cat > /etc/sysctl.conf << EOF
# Memory recovery and swap control
vm.swappiness = 10
vm.min_free_kbytes = 153600

# TCP congestion control
net.core.default_qdisc = cake
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
server_selection

timestamped_echo "${Info} Applying BBR+TCP tuning..."
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
