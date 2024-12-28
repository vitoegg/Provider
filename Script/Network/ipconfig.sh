#!/bin/bash

# Color output functions
red() {
    echo -e "\033[31m\033[01m$1\033[0m"
}
green() {
    echo -e "\033[32m\033[01m$1\033[0m"
}
yellow() {
    echo -e "\033[33m\033[01m$1\033[0m"
}

# Print banner
print_banner() {
    clear
    echo "╭───────────────────────────────────────────╮"
    echo "│         IP Priority Configuration         │"
    echo "│            Created by Vitoegg             │"
    echo "╰───────────────────────────────────────────╯"
    echo
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "╭───────────────── Error ─────────────────╮"
        red "│    This script must be run as root!     │"
        red "│    Please use sudo or root user.        │"
        echo "╰───────────────────────────────────────────╯"
        exit 1
    fi
}

# Check and install dependencies
check_dependencies() {
    local deps=("curl" "sed")
    local missing_deps=()
    
    echo "╭─────────────── System Check ───────────────╮"
    echo "│ Checking required dependencies...          │"
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        yellow "│ Installing missing packages: ${missing_deps[*]}"
        
        # Detect package manager and install
        if command -v apt &>/dev/null; then
            apt update -y >/dev/null 2>&1
            apt install -y "${missing_deps[@]}" >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y "${missing_deps[@]}" >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y "${missing_deps[@]}" >/dev/null 2>&1
        else
            red "│ Unsupported package manager!"
            red "│ Please install manually: ${missing_deps[*]}"
            echo "╰───────────────────────────────────────────╯"
            exit 1
        fi
        
        # Verify installation
        for dep in "${missing_deps[@]}"; do
            if ! command -v "$dep" &>/dev/null; then
                red "│ Failed to install: $dep"
                echo "╰───────────────────────────────────────────╯"
                exit 1
            fi
        done
    fi
    
    green "│ All dependencies are satisfied!           │"
    echo "╰───────────────────────────────────────────╯"
    echo
}

# Verify configuration
verify_configuration() {
    echo "╭────────────── Configuration ──────────────╮"
    
    # Print current configuration type
    local config_type
    if grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf; then
        config_type="IPv4 Priority"
    elif grep -q "label 2002::/16   2" /etc/gai.conf; then
        config_type="IPv6 Priority"
    else
        config_type="System Default"
    fi
    echo "│ Current Setting: $(green "$config_type")"
    
    # Test connection and get IP
    echo -n "│ Testing connection... "
    if current_ip=$(curl -s --max-time 10 ip.p3terx.com); then
        echo "$(green "Success!")"
        
        # Determine IP version and format output
        if [[ $current_ip =~ ":" ]]; then
            ip_version="IPv6"
        else
            ip_version="IPv4"
        fi
        
        echo "├──────────────── Results ────────────────┤"
        echo "│ IP Version : $(green "$ip_version")"
        echo "│ Address    : $(green "$current_ip")"
        
        # Verify if configuration matches actual connection
        if [[ "$config_type" == "IPv4 Priority" && "$ip_version" == "IPv6" ]] || \
           [[ "$config_type" == "IPv6 Priority" && "$ip_version" == "IPv4" ]]; then
            echo "├─────────────── Notice ────────────────┤"
            yellow "│ Connection type differs from setting    │"
            yellow "│ This may be due to network availability│"
        fi
    else
        echo "$(red "Failed!")"
        echo "├───────────────── Error ────────────────┤"
        red "│ Unable to verify network connection    │"
        red "│ Please check your internet connection  │"
        echo "╰───────────────────────────────────────────╯"
        return 1
    fi
    
    echo "╰───────────────────────────────────────────╯"
    echo
}

# Configure IP preference
configure_ip() {
    local mode=$1
    
    echo "╭─────────────── Processing ──────────────────╮"
    echo "│ Configuring IP priority...                 │"
    
    # Clean existing configuration
    if [[ -f "/etc/gai.conf" ]]; then
        sed -i '/^precedence \:\:ffff\:0\:0/d' /etc/gai.conf
        sed -i '/^label 2002\:\:\/16/d' /etc/gai.conf
    else
        touch /etc/gai.conf
    fi
    
    case "$mode" in
        "ipv4")
            echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
            green "│ Successfully set IPv4 priority            │"
            ;;
        "ipv6")
            echo "label 2002::/16   2" >> /etc/gai.conf
            green "│ Successfully set IPv6 priority            │"
            ;;
        "default")
            green "│ Restored default IP priority settings     │"
            ;;
        *)
            red "│ Invalid mode specified                    │"
            echo "╰───────────────────────────────────────────╯"
            exit 1
            ;;
    esac
    echo "╰───────────────────────────────────────────╯"
    echo
    
    # Verify the new configuration
    verify_configuration
}

# Show usage
usage() {
    echo "Usage: $0 [-v4|-v6|-u|-h]"
    echo
    echo "Options:"
    echo "  -v4    Set IPv4 priority"
    echo "  -v6    Set IPv6 priority"
    echo "  -u     Restore default settings"
    echo "  -h     Show this help message"
    echo
    echo "Example:"
    echo "  sudo $0 -v4    # Set IPv4 priority"
    exit 1
}

# Main script
main() {
    print_banner
    
    # Check root privileges first
    check_root
    
    # Check dependencies
    check_dependencies
    
    # Parse command line arguments
    while getopts "v4v6uh" opt; do
        case $opt in
            v4)
                configure_ip "ipv4"
                ;;
            v6)
                configure_ip "ipv6"
                ;;
            u)
                configure_ip "default"
                ;;
            h|*)
                usage
                ;;
        esac
    done
    
    # Show usage if no options provided
    if [[ $OPTIND -eq 1 ]]; then
        usage
    fi
}

# Run main function
main "$@"
