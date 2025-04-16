#!/bin/bash

# Logging functions with color-coded types
log_info() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "[${timestamp}] [\033[32mINFO\033[0m] $1"
}

log_error() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "[${timestamp}] [\033[31mERROR\033[0m] $1"
}

log_warn() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "[${timestamp}] [\033[33mWARNING\033[0m] $1"
}


################################################################################
# Check root privileges
################################################################################
if [ "$EUID" -ne 0 ]; then
  log_error "Please run this script as root."
  exit 1
fi

################################################################################
# Check system type and install dependencies
################################################################################
check_system_and_install() {
    # Check system type
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
            log_error "This script only supports Debian and Ubuntu systems."
            return 1
        fi
    else
        log_error "Unable to determine system type. Exiting script."
        return 1
    fi

    local missing_packages=()

    # Check for iptables
    if ! command -v iptables >/dev/null 2>&1; then
        missing_packages+=(iptables)
    else
        log_info "Dependency already installed: iptables"
    fi

    # Check for iptables-persistent by verifying existence of netfilter-persistent
    if [ ! -x /usr/sbin/netfilter-persistent ]; then
        missing_packages+=(iptables-persistent)
    else
        log_info "Dependency already installed: iptables-persistent"
    fi

    # Check for wget
    if ! command -v wget >/dev/null 2>&1; then
        missing_packages+=(wget)
    else
        log_info "Dependency already installed: wget"
    fi

    if [ ${#missing_packages[@]} -gt 0 ]; then
        log_info "Installing missing dependencies: ${missing_packages[*]}"
        
        # Pre-configure iptables-persistent to avoid interactive prompts
        if [[ " ${missing_packages[*]} " == *" iptables-persistent "* ]]; then
            log_info "Pre-configuring iptables-persistent to avoid interrupt..."
            echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections >/dev/null 2>&1
            echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections >/dev/null 2>&1
        fi
        
        # Redirect all output to /dev/null to suppress installation logs
        log_info "Starting installation, please wait..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -qq -y "${missing_packages[@]}" >/dev/null 2>&1
        
        # Check installation success/failure for each package individually
        for pkg in "${missing_packages[@]}"; do
            if dpkg -l "$pkg" | grep -q ^ii; then
                log_info "Successfully installed dependency: ${pkg}"
            else
                log_error "Failed to install dependency: ${pkg}"
                return 1
            fi
        done
    fi

    return 0
}

################################################################################
# Common Function
################################################################################
# Function: Display current forwarding rules
show_forwarding_rules() {
    echo -e "\n-----------------------------"
    echo "Current forwarding rules:"
    log_info "PREROUTING rules:"
    iptables -t nat -L PREROUTING -n --line-numbers
    echo ""
    log_info "POSTROUTING rules:"
    iptables -t nat -L POSTROUTING -n --line-numbers
}

# Function: Add a forwarding rule for both TCP and UDP
add_forward_rule() {
    local local_port="$1"
    local target_ip="$2"
    local target_port="$3"

    iptables -t nat -A PREROUTING -p tcp --dport "$local_port" -j DNAT --to-destination "$target_ip:$target_port"
    iptables -t nat -A PREROUTING -p udp --dport "$local_port" -j DNAT --to-destination "$target_ip:$target_port"
    iptables -t nat -A POSTROUTING -p tcp -d "$target_ip" --dport "$target_port" -j SNAT --to-source "$LOCAL_IP"
    iptables -t nat -A POSTROUTING -p udp -d "$target_ip" --dport "$target_port" -j SNAT --to-source "$LOCAL_IP"

    log_info "Added forwarding rule: local port $local_port -> $target_ip:$target_port"
}

# Function: Save and reload iptables rules
save_and_reload_rules() {
    netfilter-persistent save >/dev/null 2>&1
    netfilter-persistent reload >/dev/null 2>&1
    log_info "Rules saved and reloaded successfully"
}

# Function: Clear all forwarding rules and exit the script
clean_rules() {
    log_info "Clearing all forwarding rules..."
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    save_and_reload_rules
    log_info "All forwarding rules have been cleared. Exiting."
    exit 0
}

################################################################################
# Core Process
################################################################################
# Function: Process adding new forwarding rules
process_forward_rules() {
    # Check system and install dependencies first
    if ! check_system_and_install; then
        log_error "Failed to set up dependencies. Please check the error messages above."
        return 1
    fi

    # Get internal IP using ip command
    log_info "Detecting internal IP address..."
    INTERNAL_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [ -z "$INTERNAL_IP" ]; then
        log_warn "Unable to detect internal IP."
    else
        log_info "Detected internal IP: $INTERNAL_IP"
    fi

    # Get public IP using wget
    log_info "Detecting public IP address..."
    PUBLIC_IP=$(wget -qO- https://api.ipify.org 2>/dev/null)
    if [ -z "$PUBLIC_IP" ]; then
        log_warn "Unable to detect public IP."
    else
        log_info "Detected public IP: $PUBLIC_IP"
    fi

    # Determine which IP to use
    if [ -z "$INTERNAL_IP" ] && [ -z "$PUBLIC_IP" ]; then
        # Both detection methods failed, ask user to input manually
        log_warn "Failed to detect any IP address. Please enter manually."
        read -p "Please input local IP for SNAT: " LOCAL_IP
        if [ -z "$LOCAL_IP" ]; then
            log_error "No IP address provided. Exiting."
            return 1
        fi
    elif [ -z "$INTERNAL_IP" ]; then
        # Only public IP available
        LOCAL_IP=$PUBLIC_IP
        log_info "Using public IP: $LOCAL_IP"
    elif [ -z "$PUBLIC_IP" ]; then
        # Only internal IP available
        LOCAL_IP=$INTERNAL_IP
        log_info "Using internal IP: $LOCAL_IP"
    elif [ "$INTERNAL_IP" = "$PUBLIC_IP" ]; then
        # Both IPs are the same
        LOCAL_IP=$PUBLIC_IP
        log_info "Internal and public IPs are identical. Using: $LOCAL_IP"
    else
        # IPs are different, ask user which one to use
        echo "Detected different IP addresses:"
        echo "1. Internal IP: $INTERNAL_IP"
        echo "2. Public IP: $PUBLIC_IP"
        read -p "Which IP do you want to use for SNAT? [1/2]: " ip_choice

        case $ip_choice in
            1)
                LOCAL_IP=$INTERNAL_IP
                log_info "Using internal IP: $LOCAL_IP"
                ;;
            2)
                LOCAL_IP=$PUBLIC_IP
                log_info "Using public IP: $LOCAL_IP"
                ;;
            *)
                log_warn "Invalid choice. Using internal IP by default."
                LOCAL_IP=$INTERNAL_IP
                log_info "Using internal IP: $LOCAL_IP"
                ;;
        esac
    fi

    while true; do
        show_forwarding_rules
        echo -e "-----------------------------"
        echo "Enter a new forwarding rule (or press Ctrl+C to exit):"
        read -p "Enter local port: " LOCAL_PORT
        read -p "Enter target IP: " TARGET_IP
        read -p "Enter target port: " TARGET_PORT

        if [[ ! "$LOCAL_PORT" =~ ^[0-9]+$ ]] || \
           [[ ! "$TARGET_PORT" =~ ^[0-9]+$ ]] || \
           [[ ! "$TARGET_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_error "Input format error, please re-enter!"
            continue
        fi

        add_forward_rule "$LOCAL_PORT" "$TARGET_IP" "$TARGET_PORT"

        read -p "Do you want to continue adding forwarding rules? [Y/n]: " continue_add
        if [[ "$continue_add" =~ ^[Nn]$ ]]; then
            log_info "Saving all rules and exiting..."
            save_and_reload_rules
            show_forwarding_rules
            exit 0
        fi
    done
}

################################################################################
# Main menu loop
################################################################################
while true; do
    echo -e "\n====== IPTABLES SCRIPT ======"
    echo "Please select an operation:"
    echo "1. Add a new forwarding rule"
    echo "2. View current forwarding rules"
    echo "3. Clear all forwarding rules"
    echo "4. Exit"
    echo "-----------------------------"
    read -p "Enter option [1-4]: " choice

    case $choice in
        1)
            process_forward_rules
            ;;
        2)
            show_forwarding_rules
            ;;
        3)
            clean_rules
            ;;
        4)
            log_info "Exiting the program..."
            exit 0
            ;;
        *)
            log_error "Invalid option, please try again."
            ;;
    esac
done
