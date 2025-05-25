#!/usr/bin/env bash

################################################################################
# TCP Configuration Script
# Author: System Administrator
# Description: Modular TCP optimization script with custom configuration support
# Version: 2.0
################################################################################

# Define color codes and message tags
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[INFO]${Font_color_suffix}"
Error="${Red_font_prefix}[ERROR]${Font_color_suffix}"
Tip="${Green_font_prefix}[TIP]${Font_color_suffix}"

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Function: Print output with a timestamp at the beginning
timestamped_echo() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Check root privileges
check_root_privileges() {
    if [[ $EUID -ne 0 ]]; then
        timestamped_echo "${Error} This script must be run as root!"
        exit 1
    fi
}

################################################################################
# CONFIGURATION GENERATION FUNCTIONS
################################################################################

# Function: Configure basic IP forwarding rules
configure_ip_forwarding() {
    timestamped_echo "${Info} Configuring IP forwarding rules..."
    
    cat > /tmp/ip_forwarding.conf << EOF
# Focused sysctl configuration for nftables relay server
# Optimized specifically for Layer 3/4 packet forwarding

# ===== Essential: IP Forwarding =====
net.ipv4.ip_forward = 1

# ===== Memory for Network Stack =====
# Prevent swapping of network buffers
vm.swappiness = 5

# ===== Process Limits =====
# Higher PID limit for connection tracking threads
kernel.pid_max = 65536
EOF
    
    timestamped_echo "${Info} IP forwarding configuration prepared."
}

# Function: Configure IPv6 disable rules
configure_ipv6_disable() {
    timestamped_echo "${Info} Configuring IPv6 disable rules..."
    
    cat > /tmp/ipv6_disable.conf << EOF
# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    
    timestamped_echo "${Info} IPv6 disable configuration prepared."
}

# Function: Select buffer parameters for TCP optimization
select_buffer_parameters() {
    echo "================================"
    echo "TCP Buffer Parameter Selection"
    echo "================================"
    echo "Available configurations:"
    echo "1. HK (Rmem: 9699328, Wmem: 9699328)"
    echo "2. JP (Rmem: 33554432, Wmem: 16777216)"
    echo "3. Custom Values"
    echo "================================"
    
    read -p "Enter your choice (1-6): " buffer_choice
    case $buffer_choice in
        1)
            Rmem=9699328
            Wmem=9699328
            server_type="HK Frenzy"
            ;;
        2)
            Rmem=33554432
            Wmem=16777216
            server_type="JP Frenzy"
            ;;
        3)
            echo "Enter custom buffer values:"
            while true; do
                read -p "Enter Rmem value (recommended: 8MB-64MB, e.g., 33554432): " Rmem
                if [[ "$Rmem" =~ ^[0-9]+$ ]] && [ "$Rmem" -gt 0 ]; then
                    break
                else
                    timestamped_echo "${Error} Please enter a valid positive number for Rmem."
                fi
            done
            
            while true; do
                read -p "Enter Wmem value (recommended: 4MB-32MB, e.g., 16777216): " Wmem
                if [[ "$Wmem" =~ ^[0-9]+$ ]] && [ "$Wmem" -gt 0 ]; then
                    break
                else
                    timestamped_echo "${Error} Please enter a valid positive number for Wmem."
                fi
            done
            server_type="Custom"
            ;;
        *)
            timestamped_echo "${Error} Invalid selection, using General Mode defaults"
            Rmem=33554432
            Wmem=16777216
            server_type="General Mode (Default)"
            ;;
    esac
    
    timestamped_echo "${Info} Selected configuration: ${server_type}"
    timestamped_echo "${Info} Rmem (Read Buffer): ${Rmem} bytes ($(($Rmem / 1024 / 1024))MB)"
    timestamped_echo "${Info} Wmem (Write Buffer): ${Wmem} bytes ($(($Wmem / 1024 / 1024))MB)"
}

# Function: Configure TCP optimization with buffer parameters
configure_tcp_optimization() {
    timestamped_echo "${Info} Configuring TCP optimization..."
    
    # Buffer parameter selection
    select_buffer_parameters
    
    cat > /tmp/tcp_optimization.conf << EOF
# ==============================================================================
# Optimized for maintaining consistent high-speed video streaming
# Focuses on sustained throughput rather than burst performance
# ==============================================================================
# Maximum number of file descriptors
fs.file-max=6815744

# Use Swap when physical memory is below 5%
vm.swappiness=5

# TCP congestion control
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr

# TCP connection keepalive settings
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 30

# ------------------------------------------------------------------------------
# Core Buffer Settings - Balanced for Sustained Performance
# ------------------------------------------------------------------------------
# Larger maximum buffers to handle sustained high throughput
net.core.rmem_max = ${Rmem}
net.core.wmem_max = ${Wmem}

# Moderate default sizes to avoid initial over-allocation
net.core.rmem_default = 87380
net.core.wmem_default = 65536

# TCP memory auto-tuning with wider ranges for stability
net.ipv4.tcp_rmem = 4096 87380 ${Rmem}
net.ipv4.tcp_wmem = 4096 65536 ${Wmem}

# Enable automatic buffer tuning for sustained connections
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling= 1
net.ipv4.tcp_adv_win_scale= 1
# ------------------------------------------------------------------------------
# Stability & Sustained Performance
# ------------------------------------------------------------------------------
# Enable selective acknowledgment for efficient recovery
net.ipv4.tcp_sack = 1

# Disable Slow-Start Restart
net.ipv4.tcp_slow_start_after_idle = 0

# Precise RTT measurement for optimal pacing
net.ipv4.tcp_timestamps = 1

# Disable MTU probing
net.ipv4.tcp_mtu_probing = 0

# Reduce sensitivity to packet reordering (key for stability)
net.ipv4.tcp_reordering = 12

# Optimize for sustained throughput over latency
net.ipv4.tcp_thin_linear_timeouts = 0
EOF
    
    timestamped_echo "${Info} TCP optimization configuration prepared."
}

################################################################################
# DUPLICATE PARAMETER HANDLING FUNCTIONS
################################################################################

# Function: Remove duplicate parameters from configuration files
remove_duplicate_parameters() {
    local primary_file="$1"
    local secondary_file="$2"
    local temp_file="/tmp/temp_config.conf"
    
    # Extract parameter names from primary file (only lines with = and not comments)
    grep -E '^[^#]*=' "$primary_file" | cut -d'=' -f1 | sed 's/[[:space:]]*$//' > /tmp/primary_params.txt
    
    # Create secondary file without duplicate parameters
    > "$temp_file"
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ "$line" =~ ^[[:space:]]*$ ]]; then
            # Keep comments and empty lines
            echo "$line" >> "$temp_file"
        elif [[ "$line" =~ ^[[:space:]]*([^=]+)= ]]; then
            # Extract parameter name
            param_name=$(echo "$line" | cut -d'=' -f1 | sed 's/[[:space:]]*$//')
            # Check if this parameter exists in primary file
            if ! grep -Fxq "$param_name" /tmp/primary_params.txt; then
                echo "$line" >> "$temp_file"
            else
                echo "# REMOVED: $line (duplicate parameter, using value from TCP optimization)" >> "$temp_file"
            fi
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$secondary_file"
    
    # Replace secondary file with cleaned version
    mv "$temp_file" "$secondary_file"
    rm -f /tmp/primary_params.txt
}

################################################################################
# CONFIGURATION APPLICATION FUNCTIONS
################################################################################

# Function: Apply all configurations with full duplicate checking
apply_configurations() {
    timestamped_echo "${Info} Combining all configurations with TCP optimization priority..."
    timestamped_echo "${Info} Merge order: TCP Optimization → IP Forwarding → IPv6 Disable"
    
    # Remove duplicate parameters from IP forwarding and IPv6 configs
    timestamped_echo "${Info} Checking for duplicate parameters..."
    
    # Check and report duplicates before removal
    grep -E '^[^#]*=' /tmp/tcp_optimization.conf | cut -d'=' -f1 | sed 's/[[:space:]]*$//' > /tmp/tcp_params_list.txt
    
    # Check for duplicates in IP forwarding
    local ip_duplicates=""
    while IFS= read -r param; do
        if grep -Fxq "$param" /tmp/tcp_params_list.txt; then
            ip_duplicates="$ip_duplicates $param"
        fi
    done < <(grep -E '^[^#]*=' /tmp/ip_forwarding.conf | cut -d'=' -f1 | sed 's/[[:space:]]*$//')
    
    # Check for duplicates in IPv6 config
    local ipv6_duplicates=""
    while IFS= read -r param; do
        if grep -Fxq "$param" /tmp/tcp_params_list.txt; then
            ipv6_duplicates="$ipv6_duplicates $param"
        fi
    done < <(grep -E '^[^#]*=' /tmp/ipv6_disable.conf | cut -d'=' -f1 | sed 's/[[:space:]]*$//')
    
    if [[ -n "$ip_duplicates" ]]; then
        timestamped_echo "${Info} Found duplicate parameters in IP forwarding:$ip_duplicates"
        timestamped_echo "${Info} TCP optimization values will be used for these parameters"
    fi
    if [[ -n "$ipv6_duplicates" ]]; then
        timestamped_echo "${Info} Found duplicate parameters in IPv6 config:$ipv6_duplicates"
        timestamped_echo "${Info} TCP optimization values will be used for these parameters"
    fi
    
    rm -f /tmp/tcp_params_list.txt
    
    remove_duplicate_parameters "/tmp/tcp_optimization.conf" "/tmp/ip_forwarding.conf"
    remove_duplicate_parameters "/tmp/tcp_optimization.conf" "/tmp/ipv6_disable.conf"
    
    # Create the final sysctl.conf by combining all parts in specified order
    cat /tmp/tcp_optimization.conf > /etc/sysctl.conf
    echo "" >> /etc/sysctl.conf
    cat /tmp/ip_forwarding.conf >> /etc/sysctl.conf
    echo "" >> /etc/sysctl.conf
    cat /tmp/ipv6_disable.conf >> /etc/sysctl.conf
    
    # Clean up temporary files
    rm -f /tmp/ip_forwarding.conf /tmp/ipv6_disable.conf /tmp/tcp_optimization.conf
    
    timestamped_echo "${Info} Configuration files combined with duplicate parameters removed."
}

# Function: Apply custom configurations with TCP priority
apply_custom_configurations() {
    local apply_ip_forwarding=$1
    local apply_ipv6_disable=$2
    local apply_tcp_optimization=$3
    
    timestamped_echo "${Info} Applying custom configuration with TCP optimization priority..."
    
    # Start with TCP optimization (highest priority)
    cat /tmp/tcp_optimization.conf > /etc/sysctl.conf
    
    # Add other configurations if selected
    if [[ "$apply_ip_forwarding" == true ]]; then
        timestamped_echo "${Info} Checking for duplicate parameters with IP forwarding..."
        remove_duplicate_parameters "/tmp/tcp_optimization.conf" "/tmp/ip_forwarding.conf"
        echo "" >> /etc/sysctl.conf
        cat /tmp/ip_forwarding.conf >> /etc/sysctl.conf
    fi
    
    if [[ "$apply_ipv6_disable" == true ]]; then
        timestamped_echo "${Info} Checking for duplicate parameters with IPv6 disable..."
        remove_duplicate_parameters "/tmp/tcp_optimization.conf" "/tmp/ipv6_disable.conf"
        echo "" >> /etc/sysctl.conf
        cat /tmp/ipv6_disable.conf >> /etc/sysctl.conf
    fi
    
    # Clean up temporary files
    rm -f /tmp/ip_forwarding.conf /tmp/ipv6_disable.conf /tmp/tcp_optimization.conf
    
    timestamped_echo "${Info} Custom configuration applied with TCP optimization priority."
}

# Function: Apply simple configurations without TCP optimization
apply_simple_configurations() {
    local apply_ip_forwarding=$1
    local apply_ipv6_disable=$2
    local apply_tcp_optimization=$3
    
    timestamped_echo "${Info} Applying simple configuration merge..."
    
    local first_file=true
    
    # Apply in order: IP forwarding, IPv6 disable
    if [[ "$apply_ip_forwarding" == true ]]; then
        if [[ "$first_file" == true ]]; then
            cat /tmp/ip_forwarding.conf > /etc/sysctl.conf
            first_file=false
        else
            echo "" >> /etc/sysctl.conf
            cat /tmp/ip_forwarding.conf >> /etc/sysctl.conf
        fi
    fi
    
    if [[ "$apply_ipv6_disable" == true ]]; then
        if [[ "$first_file" == true ]]; then
            cat /tmp/ipv6_disable.conf > /etc/sysctl.conf
            first_file=false
        else
            echo "" >> /etc/sysctl.conf
            cat /tmp/ipv6_disable.conf >> /etc/sysctl.conf
        fi
    fi
    
    # Clean up temporary files
    rm -f /tmp/ip_forwarding.conf /tmp/ipv6_disable.conf /tmp/tcp_optimization.conf
    
    timestamped_echo "${Info} Simple configuration applied."
}

# Function: Finalize sysctl configuration application
finalize_sysctl() {
    timestamped_echo "${Info} Applying sysctl configurations..."
    
    sysctl -p && sysctl --system
    if [ $? -eq 0 ]; then
        timestamped_echo "${Info} All configurations applied successfully."
    else
        timestamped_echo "${Error} Failed to apply configurations."
        return 1
    fi
}

################################################################################
# USER INTERFACE FUNCTIONS
################################################################################

# Function: Display unified configuration menu
show_menu() {
    echo "================================"
    echo "TCP Configuration Script"
    echo "================================"
    echo "Available configurations:"
    echo "1. IP Forwarding"
    echo "2. IPv6 Disable"
    echo "3. TCP Optimization"
    echo "================================"
    echo "Selection options:"
    echo "• Single: Enter one number (e.g., 1, 2, 3)"
    echo "• Multiple: Enter numbers with + or spaces (e.g., 1+2, 1 3, 2+3, 1+2+3)"
    echo "• Exit: Enter 'q' or 'exit'"
    echo "================================"
}

# Function: Handle configuration selection
handle_configuration_selection() {
    read -p "Your choice: " user_input
    
    # Handle exit commands
    if [[ "$user_input" =~ ^[Qq]$ ]] || [[ "$user_input" =~ ^[Ee][Xx][Ii][Tt]$ ]]; then
        timestamped_echo "${Info} Exiting script."
        exit 0
    fi
    
    # Parse user input - handle both + and space separators
    user_input=$(echo "$user_input" | sed 's/+/ /g' | sed 's/,/ /g')
    
    # Initialize flags
    local apply_ip_forwarding=false
    local apply_ipv6_disable=false
    local apply_tcp_optimization=false
    
    # Parse selections
    for choice in $user_input; do
        case $choice in
            1)
                apply_ip_forwarding=true
                ;;
            2)
                apply_ipv6_disable=true
                ;;
            3)
                apply_tcp_optimization=true
                ;;
            *)
                timestamped_echo "${Error} Invalid choice: $choice. Skipping..."
                ;;
        esac
    done
    
    # Validate at least one selection
    if [[ "$apply_ip_forwarding" == false && "$apply_ipv6_disable" == false && "$apply_tcp_optimization" == false ]]; then
        timestamped_echo "${Error} No valid configurations selected!"
        return 1
    fi
    
    # Show selected configurations
    local selected_configs=""
    if [[ "$apply_ip_forwarding" == true ]]; then
        selected_configs="$selected_configs IP-Forwarding"
    fi
    if [[ "$apply_ipv6_disable" == true ]]; then
        selected_configs="$selected_configs IPv6-Disable"
    fi
    if [[ "$apply_tcp_optimization" == true ]]; then
        selected_configs="$selected_configs TCP-Optimization"
    fi
    
    timestamped_echo "${Info} Selected configurations:$selected_configs"
    
    # Generate configuration files
    if [[ "$apply_ip_forwarding" == true ]]; then
        configure_ip_forwarding
    fi
    if [[ "$apply_ipv6_disable" == true ]]; then
        configure_ipv6_disable
    fi
    if [[ "$apply_tcp_optimization" == true ]]; then
        configure_tcp_optimization
    fi
    
    # Apply configurations based on selection
    if [[ "$apply_ip_forwarding" == true && "$apply_ipv6_disable" == true && "$apply_tcp_optimization" == true ]]; then
        # All three selected - use the full merge logic
        apply_configurations
    elif [[ "$apply_tcp_optimization" == true ]]; then
        # TCP optimization is selected - use priority merge logic
        apply_custom_configurations "$apply_ip_forwarding" "$apply_ipv6_disable" "$apply_tcp_optimization"
    else
        # No TCP optimization - simple merge
        apply_simple_configurations "$apply_ip_forwarding" "$apply_ipv6_disable" "$apply_tcp_optimization"
    fi
    
    return 0
}



# Function: Clean up the script file itself
clean_file() {
    read -p "Do you want to delete this script file? (y/N): " delete_choice
    if [[ "$delete_choice" =~ ^[Yy]$ ]]; then
        rm -f "$(readlink -f "$0")"
        timestamped_echo "${Info} Script file cleaned up."
    else
        timestamped_echo "${Info} Script file preserved."
    fi
}

################################################################################
# MAIN EXECUTION FLOW
################################################################################

# Initialize script
timestamped_echo "${Info} Starting TCP configuration script..."

# Check prerequisites
check_root_privileges

# Main execution loop
while true; do
    show_menu
    if handle_configuration_selection; then
        finalize_sysctl
        break
    fi
done

# Script completion
timestamped_echo "${Info} Configuration completed successfully."
timestamped_echo "${Tip} Some settings may require a system restart to take effect."
timestamped_echo "${Tip} IPv6 has been disabled; if you need IPv6, please manually modify the /etc/sysctl.conf file."

echo "================================"
clean_file
timestamped_echo "${Info} Script execution completed."
