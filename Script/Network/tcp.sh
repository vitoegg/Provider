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
            Rmem=7375000
            Wmem=7375000
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
# Function: BBR tuning and TCP optimizing
################################################################################
bbr_tcp_tune() {
    cat > /etc/sysctl.conf << EOF
# TCP congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# Network buffer tuning
net.ipv4.tcp_rmem=4096 87380 ${Rmem}
net.ipv4.tcp_wmem=4096 16384 ${Wmem}
# Increase queue length
net.core.somaxconn = 4096
# Enable window expansion
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
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
