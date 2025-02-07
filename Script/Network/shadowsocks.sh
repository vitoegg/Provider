#!/bin/bash

# Set default values
DEFAULT_PORT_RANGE_START=20000
DEFAULT_PORT_RANGE_END=40000

# Text colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display script usage
usage() {
    echo -e "${BLUE}Usage:${NC} $0 [-s password] [-p port] [-h]"
    echo -e "${BLUE}Options:${NC}"
    echo "  -s    Specify shadowsocks password"
    echo "  -p    Specify shadowsocks port"
    echo "  -h    Show this help message"
    exit 1
}

# Function to display error messages
error() {
    echo -e "${RED}Error:${NC} $1" 1>&2
    exit 1
}

# Function to display success messages
success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Function to display info messages
info() {
    echo -e "${BLUE}>>>${NC} $1"
}

# Function to display warning messages
warning() {
    echo -e "${YELLOW}Warning:${NC} $1"
}

# Function to print progress with spinner
print_progress() {
    local message="$1"
    echo -ne "${BLUE}>>>${NC} $message... "
}

# Function to end progress with success
end_progress() {
    echo -e "\r${GREEN}✓${NC} $1"
}

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root!"
fi

# Parse command line arguments
while getopts "s:p:h" opt; do
    case $opt in
        s) sspasswd="$OPTARG" ;;
        p) ssport="$OPTARG" ;;
        h) usage ;;
        \?) error "Invalid option: -$OPTARG" ;;
    esac
done

# Generate random port avoiding digit 4
generate_port() {
    while true; do
        port=$(shuf -i $1-$2 -n 1)
        if [[ ! "$port" =~ "4" ]]; then
            echo "$port"
            break
        fi
    done
}

# Set or generate port
if [ -z "$ssport" ]; then
    ssport=$(generate_port $DEFAULT_PORT_RANGE_START $DEFAULT_PORT_RANGE_END)
    info "Generated random port: $ssport"
else
    info "Using specified port: $ssport"
fi

# Set or generate password
if [ -z "$sspasswd" ]; then
    sspasswd=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
    info "Generated random password"
else
    info "Using specified password"
fi

# Install necessary packages
install_packages() {
    print_progress "Installing required packages"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1
        apt-get install -y wget jq xz-utils >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum update -y >/dev/null 2>&1
        yum install -y epel-release >/dev/null 2>&1
        yum install -y wget jq xz >/dev/null 2>&1
    else
        error "Unsupported package manager"
    fi
    end_progress "Packages installed successfully"
}

# Detect system architecture
detect_arch() {
    print_progress "Detecting system architecture"
    case $(uname -m) in
        i686|i386)
            ss_arch="i686"
            ;;
        armv7*|armv6l)
            ss_arch="arm"
            ;;
        armv8*|aarch64)
            ss_arch="aarch64"
            ;;
        x86_64)
            ss_arch="x86_64"
            ;;
        *)
            error "Unsupported architecture: $(uname -m)"
            ;;
    esac
    end_progress "Detected architecture: $ss_arch"
}

# Uninstall Shadowsocks
uninstall_service() {
    echo -e "\n${BLUE}=== Uninstalling Shadowsocks ===${NC}"
    
    print_progress "Stopping and disabling Shadowsocks service"
    systemctl stop shadowsocks.service 2>/dev/null
    systemctl disable shadowsocks.service 2>/dev/null
    end_progress "Shadowsocks service stopped and disabled"
    
    print_progress "Removing service files"
    rm -f /lib/systemd/system/shadowsocks.service
    end_progress "Service files removed"
    
    print_progress "Removing configuration files"
    rm -rf /etc/shadowsocks
    rm -f /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
    end_progress "Configuration files removed"
    
    print_progress "Removing binary files"
    rm -f /usr/local/bin/ssserver
    end_progress "Binary files removed"
    
    print_progress "Reloading systemd daemon"
    systemctl daemon-reload
    systemctl reset-failed
    end_progress "Systemd daemon reloaded"
    
    echo -e "\n${GREEN}Uninstallation completed successfully${NC}\n"
}

# Install Shadowsocks
install_shadowsocks() {
    print_progress "Installing Shadowsocks-rust"
    local new_ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | \
                    jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    
    info "Downloading version: $new_ver"
    local archive_name="shadowsocks-${new_ver}.${ss_arch}-unknown-linux-gnu.tar.xz"
    
    # Delete old files
    if [[ -f "/usr/local/bin/ssserver" ]]; then
        print_progress "Removing old Shadowsocks binary..."
        rm -f /usr/local/bin/ssserver
        if [[ $? -ne 0 ]]; then
            error "Failed to remove old Shadowsocks binary!"
            exit 1
        fi
    fi
    
    if ! wget --no-check-certificate -N "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${new_ver}/${archive_name}"; then
        error "Failed to download Shadowsocks Rust!"
        exit 1
    fi
    
    print_progress "Extracting files"
    tar -xf "$archive_name" >/dev/null 2>&1
    if [[ ! -f "ssserver" ]]; then
        error "Failed to extract Shadowsocks Rust!"
    fi
    
    chmod +x ssserver
    mv -f ssserver /usr/local/bin/
    rm -f sslocal ssmanager ssservice ssurl "$archive_name"
    
    end_progress "Shadowsocks-rust installation completed"
}

# Configure Shadowsocks
configure_shadowsocks() {
    print_progress "Configuring Shadowsocks"
    mkdir -p /etc/shadowsocks
    
    cat > /etc/shadowsocks/config.json << EOF
{
    "server":"0.0.0.0",
    "server_port":$ssport,
    "password":"$sspasswd",
    "timeout":600,
    "mode":"tcp_and_udp",
    "method":"aes-128-gcm"
}
EOF

    cat > /lib/systemd/system/shadowsocks.service << EOF
[Unit]
Description=Shadowsocks Server
After=network.target
Before=network-online.target
StartLimitBurst=0
StartLimitIntervalSec=60

[Service]
Type=simple
LimitNOFILE=65536
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    info "Starting Shadowsocks service..."
    systemctl enable shadowsocks.service >/dev/null 2>&1
    systemctl start shadowsocks.service
    
    if ! systemctl is-active --quiet shadowsocks.service; then
        error "Shadowsocks service failed to start!"
    fi
    end_progress "Shadowsocks configured and started successfully"
}

# Get IPv4 address
get_ipv4_address() {
    local ip=$(wget -qO- -t1 -T2 https://api.ipify.org)
    if [[ -z "$ip" ]]; then
        echo "Unable to get IP address"
    else
        echo "$ip"
    fi
}

# Show final configuration
show_configuration() {
    local server_ip=$(get_ipv4_address)
    
    echo -e "\n${GREEN}Installation completed successfully!${NC}"
    echo -e "\n${BLUE}=== Shadowsocks Configuration ===${NC}"
    echo -e "Server IP:      ${GREEN}${server_ip}${NC}"
    echo -e "Port:           ${GREEN}${ssport}${NC}"
    echo -e "Password:       ${GREEN}${sspasswd}${NC}"
    echo -e "Encryption:     ${GREEN}aes-128-gcm${NC}"
    echo -e "${BLUE}================================${NC}\n"
    
    info "Service status:"
    systemctl status shadowsocks.service --no-pager
}

# Check current version
get_current_version() {
    if [ ! -f "/usr/local/bin/ssserver" ]; then
        echo "not_installed"
        return
    fi
    
    local version=$(/usr/local/bin/ssserver -V 2>&1)
    if [[ $version =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "unknown"
    fi
}

# Get latest version from GitHub
get_latest_version() {
    local latest_ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | \
                       jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    echo "${latest_ver#v}"  # Remove 'v' prefix if present
}

# Update Shadowsocks
update_shadowsocks() {
    print_progress "Checking current version"
    local current_ver=$(get_current_version)
    
    if [ "$current_ver" = "not_installed" ]; then
        end_progress "Shadowsocks is not installed"
        error "Please install Shadowsocks first"
    fi
    
    if [ "$current_ver" = "unknown" ]; then
        warning "Unable to determine current version"
        info "Proceeding with update anyway..."
    else
        info "Current version: $current_ver"
    fi
    
    print_progress "Checking latest version"
    local latest_ver=$(get_latest_version)
    if [ -z "$latest_ver" ]; then
        error "Failed to get latest version information"
    fi
    end_progress "Latest version: $latest_ver"
    
    if [ "$current_ver" = "$latest_ver" ]; then
        echo -e "\n${GREEN}You are already running the latest version ($current_ver)${NC}\n"
        return
    fi
    
    info "New version available, updating..."
    
    # Stop the running service before updating
    print_progress "Stopping Shadowsocks service"
    systemctl stop shadowsocks.service
    end_progress "Service stopped"
    
    # For update, directly call install_shadowsocks() to update the binary
    install_shadowsocks
    
    # Starting the service
    print_progress "Starting Shadowsocks service"
    systemctl start shadowsocks.service
    if ! systemctl is-active --quiet shadowsocks.service; then
        error "Failed to start Shadowsocks service after update!"
    fi
    end_progress "Service started"
    
    echo -e "\n${GREEN}Successfully updated Shadowsocks to version $latest_ver${NC}"
    echo -e "\n${BLUE}=== Service Status ===${NC}"
    systemctl status shadowsocks.service --no-pager
}

# Main execution
main() {
    clear
    echo -e "${BLUE}=== Shadowsocks Installation Script ===${NC}"
    echo "1. Install Shadowsocks"
    echo "2. Update Shadowsocks"
    echo "3. Uninstall Shadowsocks"
    echo -e "${BLUE}=====================================${NC}\n"
    
    read -p "Please select an option (1/2/3): " choice
    
    case $choice in
        1)
            install_packages
            detect_arch
            install_shadowsocks
            configure_shadowsocks
            show_configuration
            ;;
        2)
            install_packages
            detect_arch
            update_shadowsocks
            ;;
        3)
            uninstall_service
            ;;
        *)
            error "Invalid option selected"
            ;;
    esac
}

main
