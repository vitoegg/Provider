#!/bin/bash
################################################################################
# This script installs and manages Shadowsocks and ShadowTLS services.
# It prints log messages with a timestamp and category (e.g., [INFO], [ERROR])
# for operational messages. Menu banners and configuration outputs are printed
# without logging decoration.
################################################################################

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'     # No Color
BOLD='\033[1m'

# Logging functions: these prepend a timestamp and category.
log_info() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*"
}

log_success() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $*"
}

log_error() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >&2
}

log_warning() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [WARNING] $*"
}

# Print header (for menus/configuration output).
print_header() {
    echo -e "\n${BOLD}=== $1 ===${NC}"
}

################################################################################
# Check root privileges
################################################################################
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root!"
    exit 1
fi

################################################################################
# Command-line arguments parser.
# Options:
#   --ss-port      : Shadowsocks server port
#   --ss-pass      : Shadowsocks password
#   --tls-port     : TLS port for ShadowTLS
#   --tls-pass     : TLS password for ShadowTLS
#   --tls-domain   : TLS domain for ShadowTLS
################################################################################
# Default encryption method
DEFAULT_METHOD="aes-128-gcm"

################################################################################
# Get the Shadowsocks encryption method
################################################################################
get_ss_encryption_method() {
    # Always use the default method
    echo "$DEFAULT_METHOD"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --ss-port)
                ssport="$2"
                shift 2
                ;;
            --ss-pass)
                sspass="$2"
                shift 2
                ;;
            --tls-port)
                listen_port="$2"
                shift 2
                ;;
            --tls-pass)
                tls_password="$2"
                shift 2
                ;;
            --tls-domain)
                domain="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

################################################################################
# Detect system architecture and set corresponding variables.
################################################################################
detect_arch() {
    print_header "Detecting System Architecture"
    case $(uname -m) in
        i686|i386)
            ss_arch="i686"
            ;;
        armv7*|armv6l)
            ss_arch="arm"
            ;;
        armv8*|aarch64)
            ss_arch="aarch64"
            tls_arch_suffix="aarch64-unknown-linux-musl"
            ;;
        x86_64)
            ss_arch="x86_64"
            tls_arch_suffix="x86_64-unknown-linux-musl"
            ;;
        *)
            log_error "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac
    log_success "Detected architecture: $ss_arch"
}

################################################################################
# Install required packages only if they are missing.
# Dependencies: wget, xz-utils, jq, and openssl.
################################################################################
install_packages() {
    print_header "Installing Required Packages"
    local packages_needed=(wget xz-utils jq openssl)
    if command -v apt-get >/dev/null 2>&1; then
        log_info "Using apt package manager..."
        apt-get update
        for pkg in "${packages_needed[@]}"; do
            if dpkg -s "$pkg" >/dev/null 2>&1; then
                log_info "Dependency exists: $pkg"
            else
                log_info "Installing dependency: $pkg"
                apt-get install -y "$pkg"
                if [[ $? -eq 0 ]]; then
                    log_success "Installed dependency: $pkg"
                else
                    log_error "Failed to install dependency: $pkg"
                    exit 1
                fi
            fi
        done
    elif command -v yum >/dev/null 2>&1; then
        log_info "Using yum package manager..."
        yum update -y
        if ! rpm -q epel-release >/dev/null 2>&1; then
            log_info "Installing dependency: epel-release"
            yum install -y epel-release
        else
            log_info "Dependency exists: epel-release"
        fi
        for pkg in "${packages_needed[@]}"; do
            if rpm -q "$pkg" >/dev/null 2>&1; then
                log_info "Dependency exists: $pkg"
            else
                log_info "Installing dependency: $pkg"
                yum install -y "$pkg"
                if [[ $? -eq 0 ]]; then
                    log_success "Installed dependency: $pkg"
                else
                    log_error "Failed to install dependency: $pkg"
                    exit 1
                fi
            fi
        done
    else
        log_error "Unsupported package manager!"
        exit 1
    fi
    log_success "Required packages installed successfully"
}

################################################################################
# Function to fetch remote content using wget.
################################################################################
fetch_content() {
    local url="$1"
    wget -qO- "$url"
    if [[ $? -ne 0 ]]; then
        log_error "Failed to fetch content from $url"
        exit 1
    fi
}

################################################################################
# Function to download a file from URL using wget.
# Arguments: URL, output file.
################################################################################
download_file() {
    local url="$1"
    local output="$2"
    wget --no-check-certificate -q -O "$output" "$url"
    if [[ $? -ne 0 ]]; then
        log_error "Failed to download file from $url"
        return 1
    fi
}

################################################################################
# Generate a random port between given lower and upper bounds excluding digits "4"
################################################################################
generate_port() {
    local lower_bound=$1
    local upper_bound=$2
    while true; do
        local port
        port=$(shuf -i ${lower_bound}-${upper_bound} -n 1)
        if [[ ! "$port" =~ "4" ]]; then
            echo "$port"
            break
        fi
    done
}

################################################################################
# Retrieve current public IPv4 address.
################################################################################
get_ipv4_address() {
    local ip
    ip=$(wget -qO- "https://api.ipify.org")
    if [[ -z "$ip" ]]; then
        echo "Unable to get IP address"
    else
        echo "$ip"
    fi
}

################################################################################
# Install or update Shadowsocks.
################################################################################
install_shadowsocks() {
    print_header "Installing Shadowsocks-rust"
    
    # Check if Shadowsocks service is already installed and running
    if systemctl is-active --quiet shadowsocks.service; then
        log_warning "Shadowsocks service is already installed and running."
        log_warning "If you want to reinstall, please uninstall first."
        exit 1
    fi
    
    local new_ver
    new_ver=$(fetch_content "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases" | \
              jq -r '[.[] | select(.prerelease == false and .draft == false) | .tag_name] | .[0]')
    if [[ -z "$new_ver" ]]; then
        log_error "Failed to retrieve Shadowsocks release version"
        exit 1
    fi
    
    log_info "Installing Shadowsocks version: $new_ver"
    local archive_name="shadowsocks-${new_ver}.${ss_arch}-unknown-linux-gnu.tar.xz"
    
    # Remove old binary if exists
    if [[ -f "/usr/local/bin/ssserver" ]]; then
        log_info "Removing old Shadowsocks binary..."
        rm -f /usr/local/bin/ssserver
        if [[ $? -ne 0 ]]; then
            log_error "Failed to remove old Shadowsocks binary!"
            exit 1
        fi
    fi

    if ! download_file "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${new_ver}/${archive_name}" "$archive_name"; then
        log_error "Failed to download Shadowsocks-rust archive!"
        exit 1
    fi

    log_info "Extracting archive..."
    tar -xf "$archive_name"
    
    if [[ ! -f "ssserver" ]]; then
        log_error "Extraction failed; ssserver binary not found!"
        exit 1
    fi

    chmod +x ssserver
    mv ssserver /usr/local/bin/
    if [[ $? -ne 0 ]]; then
        log_error "Failed to move and install Shadowsocks binary!"
        exit 1
    fi

    rm -f sslocal ssmanager ssservice ssurl "$archive_name"
    log_success "Shadowsocks-rust installation completed"
}

################################################################################
# Retrieve Shadowsocks configuration defaults.
# Use provided parameters or generate defaults.
################################################################################
get_shadowsocks_config() {
    if [[ -z "$ssport" ]]; then
        ssport=$(generate_port 20000 40000)
        log_info "No Shadowsocks port provided. Randomly generated port: $ssport"
    else
        log_info "Using specified Shadowsocks port: $ssport"
    fi

    if [[ -z "$sspass" ]]; then
        # Generate password using tr -dc for better randomness, same as TLS password generation
        sspass=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        log_info "No Shadowsocks password provided. Generated password: $sspass"
    else
        log_info "Using specified Shadowsocks password."
    fi
}

################################################################################
# Configure Shadowsocks service.
################################################################################
configure_shadowsocks() {
    print_header "Configuring Shadowsocks"
    mkdir -p /etc/shadowsocks

    # Get the encryption method based on command line arguments
    ss_method=$(get_ss_encryption_method)
    
    # Create the Shadowsocks configuration file
    cat > /etc/shadowsocks/config.json << EOF
{
    "server": "0.0.0.0",
    "server_port": $ssport,
    "password": "$sspass",
    "timeout": 600,
    "mode": "tcp_and_udp",
    "method": "$ss_method"
}
EOF
    log_info "Using $ss_method encryption method"

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
    log_info "Starting Shadowsocks service..."
    systemctl enable shadowsocks.service
    systemctl start shadowsocks.service
    
    if ! systemctl is-active --quiet shadowsocks.service; then
        log_error "Shadowsocks service failed to start!"
        exit 1
    fi
    log_success "Shadowsocks configured and started successfully"
}

################################################################################
# Install or update ShadowTLS.
################################################################################
install_shadowtls() {
    print_header "Installing ShadowTLS"
    
    # Check if ShadowTLS service is already installed and running
    if systemctl is-active --quiet shadowtls.service; then
        log_warning "ShadowTLS service is already installed and running."
        log_warning "If you want to reinstall, please uninstall first."
        exit 1
    fi
    
    local latest_version
    latest_version=$(fetch_content "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" | jq -r .tag_name)
    if [[ -z "$latest_version" ]]; then
        log_error "Failed to retrieve ShadowTLS release version"
        exit 1
    fi

    log_info "Installing ShadowTLS version: ${latest_version}"
    if [[ -f "/usr/local/bin/shadow-tls" ]]; then
        log_info "Removing old ShadowTLS binary..."
        rm -f /usr/local/bin/shadow-tls
        if [[ $? -ne 0 ]]; then
            log_error "Failed to remove old ShadowTLS binary!"
            exit 1
        fi
    fi

    local temp_file="/tmp/shadow-tls.tmp"
    if ! download_file "https://github.com/ihciah/shadow-tls/releases/download/${latest_version}/shadow-tls-${tls_arch_suffix}" "${temp_file}"; then
        log_error "Failed to download ShadowTLS binary!"
        rm -f "${temp_file}"
        exit 1
    fi

    mv "${temp_file}" /usr/local/bin/shadow-tls
    if [[ $? -ne 0 ]]; then
        log_error "Failed to install ShadowTLS binary!"
        rm -f "${temp_file}"
        exit 1
    fi

    chmod +x /usr/local/bin/shadow-tls
    if [[ $? -ne 0 ]]; then
        log_error "Failed to set execute permission for ShadowTLS!"
        exit 1
    fi
    log_success "ShadowTLS binary installed successfully"
}

################################################################################
# Get TLS configuration; use random generation if not provided via parameters.
################################################################################
get_tls_config() {
    # TLS Port: if not defined, generate randomly (range: 50000-60000)
    if [[ -z "$listen_port" ]]; then
        listen_port=$(generate_port 50000 60000)
        log_info "No TLS port provided. Randomly generated port: $listen_port"
    else
        log_info "Using specified TLS port: $listen_port"
    fi

    # TLS domain: if not defined, randomly pick from preset list.
    PRESET_DOMAINS=(
        "publicassets.cdn-apple.com"
        "s0.awsstatic.com"
        "p11.douyinpic.com"
        "sns-video-hw.xhscdn.com"
    )
    if [[ -z "$domain" ]]; then
        local random_index=$((RANDOM % ${#PRESET_DOMAINS[@]}))
        domain="${PRESET_DOMAINS[$random_index]}"
        log_info "No TLS domain provided. Randomly selected domain: $domain"
    else
        log_info "Using specified TLS domain: $domain"
    fi

    # TLS password: if not defined, generate a random 16-character string.
    if [[ -z "$tls_password" ]]; then
        tls_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        log_info "No TLS password provided. Generated password: $tls_password"
    fi
}

################################################################################
# Configure ShadowTLS service.
################################################################################
configure_shadowtls() {
    print_header "Configuring ShadowTLS"
    cat > /lib/systemd/system/shadowtls.service << EOF
[Unit]
Description=ShadowTLS Service
After=network.target
Before=network-online.target
StartLimitBurst=0
StartLimitIntervalSec=60

[Service]
LimitNOFILE=65536
ExecStart=/usr/local/bin/shadow-tls --fastopen --v3 --strict server --listen ::0:${listen_port} --server 127.0.0.1:${ssport} --tls ${domain} --password ${tls_password}
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_info "Starting ShadowTLS service..."
    systemctl enable shadowtls.service
    systemctl start shadowtls.service

    if ! systemctl is-active --quiet shadowtls.service; then
        log_error "ShadowTLS service failed to start!"
        log_warning "Please check the logs with: journalctl -u shadowtls.service"
        exit 1
    fi
    log_success "ShadowTLS configured and started successfully"
}

################################################################################
# Display final configuration and service status with aligned output.
################################################################################
show_configuration() {
    print_header "Installation Status"
    echo "------------------------------------"
    echo -e "${BOLD}Shadowsocks Service Status:${NC}"
    systemctl status shadowsocks.service --no-pager
    echo "------------------------------------"
    echo -e "${BOLD}ShadowTLS Service Status:${NC}"
    systemctl status shadowtls.service --no-pager
    echo "------------------------------------"

    print_header "Configuration Details"
    local server_ip
    server_ip=$(get_ipv4_address)
    printf "%-25s %s\n" "Server IP:" "$server_ip"
    printf "%-25s %s\n" "Shadowsocks Port:" "$ssport"
    printf "%-25s %s\n" "Shadowsocks Password:" "$sspass"
    printf "%-25s %s\n" "Shadowsocks Encryption:" "$ss_method"
    printf "%-25s %s\n" "ShadowTLS Port:" "$listen_port"
    printf "%-25s %s\n" "ShadowTLS Password:" "$tls_password"
    printf "%-25s %s\n" "ShadowTLS SNI:" "$domain"
    echo "=================================="
    echo ""
}

################################################################################
# Update services; version check and update if needed.
################################################################################
update_services() {
    print_header "Starting Version Check for Updates"

    # Check and update Shadowsocks
    if [[ ! -x "/usr/local/bin/ssserver" ]]; then
        log_error "Shadowsocks is not installed. Aborting update."
        exit 1
    fi

    local local_ss_ver_raw
    local_ss_ver_raw=$(/usr/local/bin/ssserver --version 2>&1 | awk '{print $2}')
    if [[ -z "$local_ss_ver_raw" ]]; then
        log_error "Unable to retrieve local Shadowsocks version."
        exit 1
    fi
    local local_ss_ver
    local_ss_ver=$(echo "$local_ss_ver_raw" | sed 's/[A-Za-z]//g')
    log_info "Local Shadowsocks version: $local_ss_ver"

    local ss_latest_ver_raw
    ss_latest_ver_raw=$(fetch_content "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases" | \
                        jq -r '[.[] | select(.prerelease == false and .draft == false) | .tag_name] | .[0]')
    if [[ -z "$ss_latest_ver_raw" ]]; then
        log_error "Failed to retrieve the latest Shadowsocks version."
        exit 1
    fi
    local ss_latest_ver
    ss_latest_ver=$(echo "$ss_latest_ver_raw" | sed 's/[A-Za-z]//g')
    log_info "Latest Shadowsocks version: $ss_latest_ver"

    if [[ "$local_ss_ver" == "$ss_latest_ver" ]]; then
        log_success "Shadowsocks is already at the latest version ($local_ss_ver)"
    elif [[ "$local_ss_ver" == "$(printf '%s\n' "$local_ss_ver" "$ss_latest_ver" | sort -V | head -n1)" ]]; then
        log_info "Updating Shadowsocks from version $local_ss_ver to $ss_latest_ver"
        systemctl stop shadowsocks.service 2>/dev/null
        install_shadowsocks
        systemctl start shadowsocks.service
    else
        log_error "Local Shadowsocks version ($local_ss_ver) is greater than GitHub version ($ss_latest_ver)."
        exit 1
    fi

    # Check and update ShadowTLS
    if [[ ! -x "/usr/local/bin/shadow-tls" ]]; then
        log_error "ShadowTLS is not installed. Aborting update."
        exit 1
    fi

    local local_stls_ver_raw
    local_stls_ver_raw=$(/usr/local/bin/shadow-tls --version 2>&1 | awk '{print $2}')
    if [[ -z "$local_stls_ver_raw" ]]; then
        log_error "Unable to retrieve local ShadowTLS version."
        exit 1
    fi
    local local_stls_ver
    local_stls_ver=$(echo "$local_stls_ver_raw" | sed 's/[A-Za-z]//g')
    log_info "Local ShadowTLS version: $local_stls_ver"

    local stls_latest_ver_raw
    stls_latest_ver_raw=$(fetch_content "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" | jq -r .tag_name)
    if [[ -z "$stls_latest_ver_raw" ]]; then
        log_error "Failed to retrieve the latest ShadowTLS version."
        exit 1
    fi
    local stls_latest_ver
    stls_latest_ver=$(echo "$stls_latest_ver_raw" | sed 's/[A-Za-z]//g')
    log_info "Latest ShadowTLS version: $stls_latest_ver"

    if [[ "$local_stls_ver" == "$stls_latest_ver" ]]; then
        log_success "ShadowTLS is already at the latest version ($local_stls_ver)"
    elif [[ "$local_stls_ver" == "$(printf '%s\n' "$local_stls_ver" "$stls_latest_ver" | sort -V | head -n1)" ]]; then
        log_info "Updating ShadowTLS from version $local_stls_ver to $stls_latest_ver"
        systemctl stop shadowtls.service 2>/dev/null
        install_shadowtls
        systemctl start shadowtls.service
    else
        log_error "Local ShadowTLS version ($local_stls_ver) is greater than GitHub version ($stls_latest_ver)."
        exit 1
    fi

    log_success "All services are up-to-date"
    exit 0
}

################################################################################
# Uninstall services and remove configuration files and binaries.
################################################################################
uninstall_service() {
    print_header "Uninstalling Services"

    log_info "Stopping and disabling Shadowsocks service..."
    systemctl stop shadowsocks.service 2>/dev/null
    systemctl disable shadowsocks.service 2>/dev/null
    log_success "Shadowsocks service stopped and disabled"

    log_info "Stopping and disabling ShadowTLS service..."
    systemctl stop shadowtls.service 2>/dev/null
    systemctl disable shadowtls.service 2>/dev/null
    log_success "ShadowTLS service stopped and disabled"

    log_info "Removing service files..."
    rm -f /lib/systemd/system/shadowsocks.service
    rm -f /lib/systemd/system/shadowtls.service
    log_success "Service files removed"

    log_info "Removing configuration files..."
    rm -rf /etc/shadowsocks
    rm -f /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
    log_success "Configuration files removed"

    log_info "Removing binary files..."
    rm -f /usr/local/bin/ssserver
    rm -f /usr/local/bin/shadow-tls
    log_success "Binary files removed"

    log_info "Reloading systemd daemon..."
    systemctl daemon-reload
    systemctl reset-failed
    log_success "Systemd daemon reloaded"

    log_success "Uninstallation completed successfully"
}

################################################################################
# Main installation function: perform all installation steps.
################################################################################
run_installation() {
    detect_arch
    install_packages
    install_shadowsocks
    get_shadowsocks_config
    configure_shadowsocks
    install_shadowtls
    get_tls_config
    configure_shadowtls
    show_configuration
}

################################################################################
# Main Menu (only launched if no parameters are provided)
################################################################################
main_menu() {
    while true; do
        clear
        print_header "ShadowTLS Management Script"
        echo "1. Install Shadowsocks and ShadowTLS"
        echo "2. Update Services"
        echo "3. Uninstall Services"
        echo -e "=====================================\n"
        read -p "Please select an option (1-3): " choice
        case $choice in
            1)
                run_installation
                exit 0
                ;;
            2) 
                detect_arch
                install_packages
                update_services
                ;;
            3)
                uninstall_service
                exit 0
                ;;
            *)
                log_error "Invalid option. Please try again."
                ;;
        esac
        read -p "Press Enter to continue..."
    done
}

################################################################################
# Script execution starts here.
################################################################################
parse_args "$@"

# If parameters are provided, skip the interactive menu and run installation directly.
if [[ -n "$ssport" || -n "$sspass" || -n "$listen_port" || -n "$tls_password" || -n "$domain" ]]; then
    run_installation
else
    main_menu
fi
