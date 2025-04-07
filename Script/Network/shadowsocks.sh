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

################################################################################
# Log function with timestamp and category tag
################################################################################
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

################################################################################
# Usage function for script help
################################################################################
usage() {
    echo -e "Usage: $0 [-s password] [-p port] [-h]\n"
    echo "Options:"
    echo "  -s    Specify Shadowsocks password"
    echo "  -p    Specify Shadowsocks port"
    echo "  -h    Show this help message"
    exit 1
}

################################################################################
# Parse command line arguments
################################################################################
while getopts "s:p:h" opt; do
    case $opt in
        s) sspasswd="$OPTARG" ;;
        p) ssport="$OPTARG" ;;
        h) usage ;;
        \?) log error "Invalid option: -$OPTARG"; usage ;;
    esac
done

################################################################################
# Check for root privileges
################################################################################
if [[ $EUID -ne 0 ]]; then
    log error "This script must be run as root!"
    exit 1
fi

################################################################################
# Detect system architecture
################################################################################
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

################################################################################
# Helper function: Check if a command exists
################################################################################
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

################################################################################
# Function to install a dependency if it does not exist
################################################################################
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

################################################################################
# Install required packages if missing
################################################################################
install_packages() {
    log progress "Checking and installing required packages"
    install_dependency "wget" "wget"
    install_dependency "jq" "jq"
    # Ensure extraction tools
    if command_exists apt-get; then
        install_dependency "tar" "tar"
        install_dependency "xz" "xz-utils"
    elif command_exists yum; then
        install_dependency "tar" "tar"
        install_dependency "xz" "xz"
    else
        log warn "Unknown package manager, please ensure tar and xz are installed"
    fi
    install_dependency "openssl" "openssl"
    
    # Check mktemp availability
    if ! command_exists mktemp; then
        log warn "mktemp command is not available, this may affect temporary directory creation"
    fi
    log progress_end "Required packages are ready"
}

################################################################################
# Function to generate a random port (skip ports containing digit 4)
################################################################################
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

################################################################################
# Get current installed version of Shadowsocks
# This returns the version string exactly as output by ssserver -V.
################################################################################
get_current_version() {
    if [ ! -f "/usr/local/bin/ssserver" ]; then
        echo "not_installed"
        return
    fi

    # Return the complete output from ssserver -V without modification
    /usr/local/bin/ssserver -V 2>&1
}

################################################################################
# Get the latest version from GitHub
# This function returns the version string exactly as obtained from the API.
################################################################################
get_latest_version() {
    local latest_ver
    latest_ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases |
                 jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    echo "$latest_ver"
}

################################################################################
# Download Shadowsocks package for a given version and architecture.
# Outputs useful log messages regarding download status.
################################################################################
download_shadowsocks_package() {
    local version="$1"
    local archive_name="shadowsocks-${version}.${ss_arch}-unknown-linux-gnu.tar.xz"
    local download_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${version}/${archive_name}"
    
    log progress "Downloading Shadowsocks package ${archive_name}"
    log info "Download URL: ${download_url}"
    
    # Use temporary file to record download errors
    if wget -q --no-check-certificate -N "${download_url}" 2>/tmp/wget_error.log; then
        if [[ -f "${archive_name}" ]]; then
            local file_size=$(stat -c %s "${archive_name}" 2>/dev/null || stat -f %z "${archive_name}" 2>/dev/null)
            log success "Successfully downloaded ${archive_name} (Size: ${file_size} bytes)"
            return 0
        else
            log error "Download completed but file ${archive_name} not found!"
            return 1
        fi
    else
        log error "Failed to download Shadowsocks package ${archive_name}"
        log error "Download error: $(cat /tmp/wget_error.log)"
        rm -f /tmp/wget_error.log
        return 1
    fi
}

################################################################################
# Get server's IPv4 address
################################################################################
get_ipv4_address() {
    local ip
    ip=$(wget -qO- -t1 -T2 https://api.ipify.org)
    if [[ -z "$ip" ]]; then
        echo "Unable to get IP address"
    else
        echo "$ip"
    fi
}

################################################################################
# Install Shadowsocks-rust
#
# Retrieves the latest version using get_latest_version, downloads the package via 
# download_shadowsocks_package, and extracts the binary.
################################################################################
install_shadowsocks() {
    log progress "Installing Shadowsocks-rust"
    local latest_ver
    latest_ver=$(get_latest_version)
    if [ -z "$latest_ver" ]; then
        log error "Could not determine the latest version."
        exit 1
    fi

    log info "Preparing to download version: $latest_ver"
    if ! download_shadowsocks_package "$latest_ver"; then
        exit 1
    fi

    # Remove old binary if it exists
    if [[ -f "/usr/local/bin/ssserver" ]]; then
        log progress "Removing old Shadowsocks binary"
        rm -f /usr/local/bin/ssserver
        if [[ $? -ne 0 ]]; then
            log error "Failed to remove old Shadowsocks binary!"
            exit 1
        fi
    fi

    log progress "Extracting package"
    local archive_name="shadowsocks-${latest_ver}.${ss_arch}-unknown-linux-gnu.tar.xz"
    local current_dir="$(pwd)"
    
    # Check if the downloaded file exists
    if [[ ! -f "$current_dir/$archive_name" ]]; then
        log error "Downloaded file $archive_name not found in $current_dir!"
        exit 1
    fi
    
    # Create temporary directory for extraction
    local temp_dir=$(mktemp -d)
    log info "Created temporary directory for extraction: $temp_dir"
    
    # Use detailed error checking for extraction
    if ! tar -xf "$current_dir/$archive_name" -C "$temp_dir" 2>/tmp/tar_error.log; then
        log error "Failed to extract Shadowsocks package! Error code: $?"
        log error "Tar error log: $(cat /tmp/tar_error.log)"
        log error "Please check if xz-utils is properly installed"
        rm -rf "$temp_dir" /tmp/tar_error.log
        exit 1
    fi
    
    # Check if the extracted file exists
    if [[ ! -f "$temp_dir/ssserver" ]]; then
        log error "Extraction completed but ssserver binary not found in extracted files!"
        log info "Listing extracted files: $(ls -la $temp_dir)"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # Set permissions and move file
    chmod +x "$temp_dir/ssserver"
    mv -f "$temp_dir/ssserver" /usr/local/bin/
    
    # Clean up other files
    rm -f "$temp_dir/sslocal" "$temp_dir/ssmanager" "$temp_dir/ssservice" "$temp_dir/ssurl" 2>/dev/null
    rm -rf "$temp_dir"
    rm -f "$current_dir/$archive_name"
    log progress_end "Shadowsocks-rust installation completed"
}

################################################################################
# Prepare for Configuration
################################################################################
prepare_configuration() {
    # Set encryption method to 2022-blake3-aes-128-gcm
    ss_method="2022-blake3-aes-128-gcm"
    log info "Using encryption method: $ss_method"

    # Set or generate port
    if [ -z "$ssport" ]; then
        ssport=$(generate_port "$DEFAULT_PORT_RANGE_START" "$DEFAULT_PORT_RANGE_END")
        log info "Generated random port: $ssport"
    else
        log info "Using specified port: $ssport"
    fi

    # Set or generate password using openssl
    if [ -z "$sspasswd" ]; then
        sspasswd=$(openssl rand -base64 16)
        log info "Generated random password using openssl"
    else
        log info "Using specified password"
    fi
}

################################################################################
# Configure Shadowsocks
################################################################################
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
    "method": "$ss_method"
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
        echo "Service status:"
        systemctl status shadowsocks.service --no-pager
        exit 1
    fi
    log progress_end "Shadowsocks configured and started successfully"
}

################################################################################
# Display final configuration
################################################################################
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
    echo "Encryption:     $ss_method"
    echo "=================================="
    echo ""
}

################################################################################
# Update Shadowsocks
################################################################################
update_shadowsocks() {
    log progress "Checking current version"
    local current_ver
    current_ver=$(get_current_version)

    if [ "$current_ver" = "not_installed" ]; then
        log progress_end "Shadowsocks is not installed"
        log error "Please install Shadowsocks first"
        exit 1
    fi

    log info "Current version as reported: $current_ver"
    log progress "Checking latest version"
    local latest_ver
    latest_ver=$(get_latest_version)
    if [ -z "$latest_ver" ]; then
        log error "Failed to get latest version information"
        exit 1
    fi
    log progress_end "Latest version: $latest_ver"

    # For comparing versions, remove non-digits and dots from both strings.
    local compare_current compare_latest
    compare_current=$(echo "$current_ver" | tr -dc '0-9.')
    compare_latest=$(echo "$latest_ver" | tr -dc '0-9.')
    log info "Comparing versions (numeric): current = $compare_current, latest = $compare_latest"

    if [ "$compare_current" = "$compare_latest" ]; then
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
        echo "Service status:"
        systemctl status shadowsocks.service --no-pager
        exit 1
    fi
    log progress_end "Service started"

    echo -e "\nSuccessfully updated Shadowsocks to version $latest_ver\n"
    echo "=== Service Status ==="
    systemctl status shadowsocks.service --no-pager
}

################################################################################
# Uninstall Shadowsocks
################################################################################
uninstall_service() {
    echo -e "\n=== Uninstalling Shadowsocks ===\n"
    
    # Check if service exists before attempting to uninstall
    if ! check_service_exists; then
        log error "Shadowsocks service is not installed. Nothing to uninstall."
        exit 1
    fi
    
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

################################################################################
# Check if Shadowsocks service exists
################################################################################
check_service_exists() {
    # Check if service file exists
    if [[ -f "/lib/systemd/system/shadowsocks.service" ]]; then
        # Also verify the service is known to systemd
        if systemctl list-unit-files | grep -q shadowsocks.service; then
            return 0  # Service exists
        fi
    fi
    return 1  # Service does not exist
}

################################################################################
# Unified Installation Function
#
# This function encapsulates all steps needed for a successful installation.
################################################################################
run_installation() {
    # Check if service already exists
    if check_service_exists; then
        log error "Shadowsocks service is already installed. Please uninstall it first."
        echo -e "\nTo uninstall, run: $0 uninstall\n"
        exit 1
    fi
    
    install_packages
    detect_arch
    prepare_configuration
    install_shadowsocks
    configure_shadowsocks
    show_configuration
}

################################################################################
# Main execution:
# 1. If additional parameters are provided, skip interactive menu.
# 2. Otherwise, show the interactive menu.
################################################################################
main() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log error "This script must be run as root! Please use sudo."
        exit 1
    fi
    
    # Display script version and execution environment information
    log info "Shadowsocks installation script v1.1"
    log info "Operating System: $(uname -s) $(uname -r)"
    log info "Architecture: $(uname -m)"
    
    # If parameters are provided (beyond script name) then execute non-interactive mode.
    if [ "$#" -gt 0 ]; then
        run_installation
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
            run_installation
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
