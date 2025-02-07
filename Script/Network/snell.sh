#!/usr/bin/env bash

# Set PATH
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

###################
# Constants
###################
CONF="/etc/snell/snell.conf"
SYSTEMD="/lib/systemd/system/snell.service"
DOWNLOAD_BASE="https://dl.nssurge.com/snell"
SERVER_BIN="/usr/local/bin/snell-server"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

###################
# Utility Functions
###################
print_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        "info")    echo -e "${timestamp} ${BLUE}[INFO] ${message}${NC}" ;;
        "success") echo -e "${timestamp} ${GREEN}[SUCCESS] ${message}${NC}" ;;
        "warning") echo -e "${timestamp} ${YELLOW}[WARNING] ${message}${NC}" ;;
        "error")   echo -e "${timestamp} ${RED}[ERROR] ${message}${NC}" ;;
    esac
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_message "error" "This script must be run as root. Please use sudo."
        exit 1
    fi
}

get_ipv4_address() {
    local ip=$(wget -qO- -t1 -T2 https://api.ipify.org)
    echo "${ip:-Unable to get IP address}"
}

###################
# Version Management
###################
validate_version_format() {
    local version=$1
    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_message "error" "Invalid version format. Please use format: X.Y.Z (e.g., 4.1.1)"
        return 1
    fi
    return 0
}

get_server_version() {
    if [[ -f "$SERVER_BIN" ]]; then
        # Try to get version from server binary
        local raw_version
        raw_version=$("$SERVER_BIN" -v 2>&1) || true
        if [[ $raw_version =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
            echo "${BASH_REMATCH[0]}"
            return 0
        fi
    fi
    echo "0.0.0"
}

prompt_version() {
    local current_version=$(get_server_version)
    print_message "info" "Current version: ${current_version}"
    
    local new_version
    while true; do
        read -p "Enter the version number (e.g., 4.1.1): " new_version
        if validate_version_format "$new_version"; then
            echo "$new_version"
            return 0
        fi
    done
}

version_gt() {
    test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" != "$1"
}

###################
# System Detection
###################
detect_architecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)   echo "amd64" ;;
        i386|i686) echo "i386" ;;
        aarch64)   echo "aarch64" ;;
        armv7l)    echo "armv7l" ;;
        *)
            print_message "error" "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

###################
# Dependencies
###################
setup_dependencies() {
    print_message "info" "Checking dependencies..."
    local deps=("unzip" "wget")
    local missing_deps=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_message "info" "Installing missing dependencies: ${missing_deps[*]}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y "${missing_deps[@]}"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing_deps[@]}"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${missing_deps[@]}"
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm "${missing_deps[@]}"
        else
            print_message "error" "No supported package manager found. Please install ${missing_deps[*]} manually."
            exit 1
        fi
        print_message "success" "Dependencies installed successfully"
    else
        print_message "success" "All dependencies are already installed"
    fi
}

###################
# Configuration
###################
get_valid_port() {
    while true; do
        read -p "Enter port number (10000-60000): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 10000 && "$PORT" -le 60000 ]]; then
            break
        else
            print_message "error" "Port must be between 10000 and 60000"
        fi
    done
    echo "$PORT"
}

generate_psk() {
    if [ -z "${PSK}" ]; then
        PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
        print_message "success" "Generated PSK: ${PSK}"
    else
        print_message "info" "Using predefined PSK: ${PSK}"
    fi
    echo "$PSK"
}

create_config() {
    local port=$1
    local psk=$2
    
    print_message "info" "Creating configuration directory..."
    mkdir -p /etc/snell
    
    print_message "info" "Creating configuration file..."
    cat > "${CONF}" << EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = false
EOF
    print_message "success" "Configuration file created"
}

create_service() {
    print_message "info" "Creating system service..."
    cat > "${SYSTEMD}" << EOF
[Unit]
Description=Snell Service
After=network.target
Before=network-online.target
StartLimitBurst=0
StartLimitIntervalSec=60

[Service]
Type=simple
LimitNOFILE=65536
ExecStart=/usr/local/bin/snell-server -c ${CONF}
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
    print_message "success" "System service created"
}

###################
# Core Operations
###################
download_and_install() {
    local version=$1
    local arch=$(detect_architecture)
    
    print_message "info" "Downloading Snell version ${version} for ${arch}..."
    cd ~/ || exit
    local download_url="${DOWNLOAD_BASE}/snell-server-v${version}-linux-${arch}.zip"
    if ! wget --no-check-certificate -O snell.zip "$download_url"; then
        print_message "error" "Failed to download Snell server"
        exit 1
    fi
    print_message "success" "Download completed"

    print_message "info" "Extracting files..."
    if ! unzip -o snell.zip; then
        print_message "error" "Failed to extract files"
        rm -f snell.zip
        exit 1
    fi
    rm -f snell.zip
    
    print_message "info" "Installing Snell server..."
    chmod +x snell-server
    mv -f snell-server "$SERVER_BIN"
    print_message "success" "Snell server installed"
}

update_server() {
    local version=$1
    print_message "info" "Updating Snell server to version ${version}..."
    
    # Stop service before update
    print_message "info" "Stopping Snell service..."
    systemctl stop snell
    
    # Update only the server binary
    download_and_install "$version"
    
    # Start service
    print_message "info" "Starting Snell service..."
    systemctl start snell
    
    if systemctl is-active snell &> /dev/null; then
        print_message "success" "Snell service updated and started successfully"
        return 0
    else
        print_message "error" "Failed to start Snell service after update. Checking logs:"
        systemctl status snell --no-pager
        return 1
    fi
}

start_service() {
    print_message "info" "Configuring system service..."
    systemctl daemon-reload
    
    print_message "info" "Enabling Snell service..."
    systemctl enable snell
    
    print_message "info" "Starting Snell service..."
    systemctl start snell

    if systemctl is-active snell &> /dev/null; then
        print_message "success" "Snell service started successfully!"
        return 0
    else
        print_message "error" "Snell service failed to start. Checking logs:"
        systemctl status snell --no-pager
        return 1
    fi
}

show_configuration() {
    local port=$1
    local psk=$2
    local version=$3
    local server_ip=$(get_ipv4_address)
    
    echo -e "\n${BLUE}=== Snell Configuration ===${NC}"
    echo -e "Server IP:      ${GREEN}${server_ip}${NC}"
    echo -e "Port:           ${GREEN}${port}${NC}"
    echo -e "PSK:            ${GREEN}${psk}${NC}"
    echo -e "Version:        ${GREEN}${version}${NC}"
    echo -e "${BLUE}================================${NC}\n"
}

###################
# Main Operations
###################
do_install() {
    local version=$1
    
    # Handle version input
    if [ -z "$version" ]; then
        version=$(prompt_version)
    else
        if ! validate_version_format "$version"; then
            exit 1
        fi
    fi
    
    print_message "info" "Starting installation process..."
    setup_dependencies
    local port=$(get_valid_port)
    local psk=$(generate_psk)
    
    download_and_install "$version"
    create_config "$port" "$psk"
    create_service
    
    if start_service; then
        show_configuration "$port" "$psk" "$version"
    fi
}

do_update() {
    local current_version=$(get_server_version)
    local new_version=$1
    
    # Handle version input
    if [ -z "$new_version" ]; then
        new_version=$(prompt_version)
    else
        if ! validate_version_format "$new_version"; then
            exit 1
        fi
    fi
    
    if version_gt "$new_version" "$current_version"; then
        print_message "info" "Update available: ${current_version} -> ${new_version}"
        if update_server "$new_version"; then
            show_configuration \
                "$(grep -oP 'listen = 0.0.0.0:\K[0-9]+' "$CONF")" \
                "$(grep -oP 'psk = \K[A-Za-z0-9]+' "$CONF")" \
                "$new_version"
        fi
    else
        print_message "warning" "No update needed. Current version ${current_version} is up to date."
    fi
}

do_uninstall() {
    print_message "info" "Starting uninstallation process..."
    
    print_message "info" "Stopping Snell service..."
    systemctl stop snell
    
    print_message "info" "Disabling Snell service..."
    systemctl disable snell
    
    print_message "info" "Removing files..."
    rm -f "${SYSTEMD}"
    rm -f "${CONF}"
    rm -f "$SERVER_BIN"
    
    print_message "info" "Reloading systemd..."
    systemctl daemon-reload
    
    print_message "success" "Snell service has been successfully uninstalled."
}

show_menu() {
    echo -e "${BLUE}=== Snell Server Management ===${NC}"
    echo "1. Install Snell Server"
    echo "2. Update Snell Server"
    echo "3. Uninstall Snell Server"
    echo "4. Exit"
    echo -e "${BLUE}=============================${NC}"
}

###################
# Main Program
###################
main() {
    check_root
    
    # Handle command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--install)
                shift
                if [ -z "$1" ] || [[ "$1" == -* ]]; then
                    do_install
                else
                    do_install "$1"
                    shift
                fi
                exit 0
                ;;
            -u|--update)
                shift
                if [ -z "$1" ] || [[ "$1" == -* ]]; then
                    do_update
                else
                    do_update "$1"
                    shift
                fi
                exit 0
                ;;
            --uninstall)
                do_uninstall
                exit 0
                ;;
            -h|--help)
                echo "Usage: $0 [-i|--install [VERSION]] [-u|--update [VERSION]] [--uninstall] [-h|--help]"
                echo "VERSION format: X.Y.Z (e.g., 4.1.1)"
                exit 0
                ;;
            *)
                print_message "error" "Unknown parameter: $1"
                exit 1
                ;;
        esac
    done
    
    # Interactive menu
    while true; do
        show_menu
        read -p "Please select an option (1-4): " choice
        case $choice in
            1) do_install ;;
            2) do_update ;;
            3) do_uninstall ;;
            4) exit 0 ;;
            *) print_message "error" "Invalid option. Please try again." ;;
        esac
    done
}

# Execute main program
main "$@"
