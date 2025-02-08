#!/bin/bash

# Default port range settings
DEFAULT_PORT_RANGE_START=20000
DEFAULT_PORT_RANGE_END=40000

# Logging colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log function with timestamp and category tag (timestamp is at the beginning)
log() {
    local type="$1"
    local message="$2"
    local ts
    ts=$(date "+%Y-%m-%d %H:%M:%S")
    case "$type" in
        info)
            echo -e "[${ts}] ${BLUE}[Info]:${NC} $message"
            ;;
        error)
            echo -e "[${ts}] ${RED}[Error]:${NC} $message" 1>&2
            ;;
        warn)
            echo -e "[${ts}] ${YELLOW}[Warning]:${NC} $message"
            ;;
        success)
            echo -e "[${ts}] ${GREEN}[Success]:${NC} $message"
            ;;
        progress)
            echo -e "[${ts}] ${BLUE}[Info]:${NC} $message..."
            ;;
        progress_end)
            echo -e "[${ts}] ${GREEN}[Success]:${NC} $message"
            ;;
        *)
            echo -e "[${ts}]: $message"
            ;;
    esac
}

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    log error "This script must be run as root!"
    exit 1
fi

# Usage function for script help
usage() {
    echo -e "Usage: $0 [-s password] [-p port] [-h]\n"
    echo "Options:"
    echo "  -s    Specify Shadowsocks password"
    echo "  -p    Specify Shadowsocks port"
    echo "  -h    Show this help message"
    exit 1
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install a dependency if it does not exist
install_dependency() {
    local cmd="$1"
    local package="$2"
    if ! command_exists "$cmd"; then
        log info "Installing dependency: $package"
        if command_exists apt-get; then
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y "$package" -qq >/dev/null 2>&1
        elif command_exists yum; then
            yum install -y "$package" -q >/dev/null 2>&1
        else
            log error "Unsupported package manager, please install $package manually"
            exit 1
        fi
    else
        log info "Dependency $cmd already exists"
    fi
}

# Function to install required packages if missing
install_packages() {
    log progress "Checking and installing required packages"
    install_dependency "wget" "wget"
    install_dependency "jq" "jq"
    # For systems with apt-get, use xz-utils; otherwise, use xz
    if command_exists apt-get; then
        install_dependency "tar" "xz-utils"
    else
        install_dependency "tar" "xz"
    fi
    log progress_end "Required packages are ready"
}

# Function to generate a random port (skip ports containing digit 4)
generate_port() {
    local start="$1"
    local end="$2"
    while true; do
        port=$(shuf -i "$start"-"$end" -n 1)
        if [[ "$port" != *"4"* ]]; then
            echo "$port"
            break
        fi
    done
}

# Parse command line arguments
while getopts "s:p:h" opt; do
    case $opt in
        s) sspasswd="$OPTARG" ;;
        p) ssport="$OPTARG" ;;
        h) usage ;;
        \?) log error "Invalid option: -$OPTARG"; usage ;;
    esac
done

# Set or generate port and password
if [ -z "$ssport" ]; then
    ssport=$(generate_port "$DEFAULT_PORT_RANGE_START" "$DEFAULT_PORT_RANGE_END")
    log info "Generated random port: $ssport"
else
    log info "Using specified port: $ssport"
fi

if [ -z "$sspasswd" ]; then
    sspasswd=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    log info "Generated random password"
else
    log info "Using specified password"
fi

# Detect system architecture
detect_arch() {
    log progress "Detecting system architecture"
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
            log error "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac
    log progress_end "Architecture detected: $ss_arch"
}

# Uninstall Shadowsocks
uninstall_service() {
    echo -e "\n=== Uninstalling Shadowsocks ===\n"
    log progress "Stopping and disabling Shadowsocks service"
    systemctl stop shadowsocks.service 2>/dev/null
    systemctl disable shadowsocks.service 2>/dev/null
    log progress_end "Service stopped and disabled"

    log progress "Removing service files"
    rm -f /lib/systemd/system/shadowsocks.service
    log progress_end "Service files removed"

    log progress "Removing configuration files"
    rm -rf /etc/shadowsocks
    rm -f /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
    log progress_end "Configuration files removed"

    log progress "Removing binary files"
    rm -f /usr/local/bin/ssserver
    log progress_end "Binary files removed"

    log progress "Reloading systemd daemon"
    systemctl daemon-reload
    systemctl reset-failed
    log progress_end "Systemd daemon reloaded"

    echo -e "\n=== Uninstallation completed successfully ===\n"
}

# Install Shadowsocks-rust
install_shadowsocks() {
    log progress "Installing Shadowsocks-rust"
    local new_ver
    new_ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases |
              jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    log info "Downloading version: ${new_ver}"
    local archive_name="shadowsocks-${new_ver}.${ss_arch}-unknown-linux-gnu.tar.xz"

    # Remove old binary if exists
    if [[ -f "/usr/local/bin/ssserver" ]]; then
        log progress "Removing old Shadowsocks binary"
        rm -f /usr/local/bin/ssserver
        if [[ $? -ne 0 ]]; then
            log error "Failed to remove old Shadowsocks binary!"
            exit 1
        fi
    fi

    if ! wget --no-check-certificate -N "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${new_ver}/${archive_name}"; then
        log error "Failed to download Shadowsocks Rust!"
        exit 1
    fi

    log progress "Extracting package"
    tar -xf "$archive_name" >/dev/null 2>&1
    if [[ ! -f "ssserver" ]]; then
        log error "Failed to extract Shadowsocks Rust!"
        exit 1
    fi

    chmod +x ssserver
    mv -f ssserver /usr/local/bin/
    rm -f sslocal ssmanager ssservice ssurl "$archive_name"
    log progress_end "Shadowsocks-rust installation completed"
}

# Configure Shadowsocks
configure_shadowsocks() {
    log progress "Configuring Shadowsocks"
    mkdir -p /etc/shadowsocks

    cat > /etc/shadowsocks/config.json << EOF
{
    "server": "0.0.0.0",
    "server_port": $ssport,
    "password": "$sspasswd",
    "timeout": 600,
    "mode": "tcp_and_udp",
    "method": "aes-128-gcm"
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
    echo "Starting Shadowsocks service..."
    systemctl enable shadowsocks.service >/dev/null 2>&1
    systemctl start shadowsocks.service

    if ! systemctl is-active --quiet shadowsocks.service; then
        log error "Shadowsocks service failed to start!"
        exit 1
    fi
    log progress_end "Shadowsocks configured and started successfully"
}

# Get server's IPv4 address
get_ipv4_address() {
    local ip
    ip=$(wget -qO- -t1 -T2 https://api.ipify.org)
    if [[ -z "$ip" ]]; then
        echo "Unable to get IP address"
    else
        echo "$ip"
    fi
}

# Display final configuration:
# 1. First output service status.
# 2. Then a separator.
# 3. Then the configuration details.
show_configuration() {
    echo -e "\nService status:"
    systemctl status shadowsocks.service --no-pager
    echo -e "---------------------------------------------\n"

    local server_ip
    server_ip=$(get_ipv4_address)

    echo "=== Shadowsocks Configuration ==="
    echo "Server IP:      $server_ip"
    echo "Port:           $ssport"
    echo "Password:       $sspasswd"
    echo "Encryption:     aes-128-gcm"
    echo "=================================="
    echo ""
}

# Get current installed version
get_current_version() {
    if [ ! -f "/usr/local/bin/ssserver" ]; then
        echo "not_installed"
        return
    fi

    local version
    version=$(/usr/local/bin/ssserver -V 2>&1)
    if [[ $version =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "unknown"
    fi
}

# Get the latest version from GitHub
get_latest_version() {
    local latest_ver
    latest_ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases |
                 jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    echo "${latest_ver#v}"  # Remove "v" prefix if exists
}

# Update Shadowsocks
update_shadowsocks() {
    log progress "Checking current version"
    local current_ver
    current_ver=$(get_current_version)

    if [ "$current_ver" = "not_installed" ]; then
        log progress_end "Shadowsocks is not installed"
        log error "Please install Shadowsocks first"
        exit 1
    fi

    if [ "$current_ver" = "unknown" ]; then
        log warn "Unable to determine current version"
        log info "Proceeding with update anyway..."
    else
        log info "Current version: $current_ver"
    fi

    log progress "Checking latest version"
    local latest_ver
    latest_ver=$(get_latest_version)
    if [ -z "$latest_ver" ]; then
        log error "Failed to get latest version information"
        exit 1
    fi
    log progress_end "Latest version: $latest_ver"

    if [ "$current_ver" = "$latest_ver" ]; then
        echo -e "\nYou are already running the latest version ($current_ver)\n"
        return
    fi

    log info "New version available, updating..."
    log progress "Stopping Shadowsocks service"
    systemctl stop shadowsocks.service
    log progress_end "Service stopped"

    install_shadowsocks

    log progress "Starting Shadowsocks service"
    systemctl start shadowsocks.service
    if ! systemctl is-active --quiet shadowsocks.service; then
        log error "Failed to start Shadowsocks service after update!"
        exit 1
    fi
    log progress_end "Service started"

    echo -e "\nSuccessfully updated Shadowsocks to version $latest_ver\n"
    echo "=== Service Status ==="
    systemctl status shadowsocks.service --no-pager
}

# Main execution:
# 1. If parameters were provided, directly run installation mode.
# 2. Otherwise, show interactive menu.
main() {
    # If additional parameters are passed (not counting the script name), skip interactive menu
    if [ "$#" -gt 0 ]; then
        install_packages
        detect_arch
        install_shadowsocks
        configure_shadowsocks
        show_configuration
        exit 0
    fi

    clear
    echo "=== Shadowsocks Installation Script ==="
    echo "1. Install Shadowsocks"
    echo "2. Update Shadowsocks"
    echo "3. Uninstall Shadowsocks"
    echo "======================================="
    echo

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
            log error "Invalid option selected"
            exit 1
            ;;
    esac
}

main "$@"
