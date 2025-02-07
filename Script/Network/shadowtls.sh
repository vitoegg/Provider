#!/bin/bash

# Text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Print formatted messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_header() {
    echo -e "\n${BOLD}=== $1 ===${NC}"
}

# Parse command-line arguments for custom parameters
# Options:
#   --ss-port      : Shadowsocks server port
#   --ss-pass      : Shadowsocks password
#   --tls-port     : TLS port for ShadowTLS
#   --tls-pass     : TLS password for ShadowTLS
#   --tls-domain   : TLS domain for ShadowTLS
parse_args() {
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --ss-port)
                ssport="$2"
                shift 2
                ;;
            --ss-pass)
                sspasswd="$2"
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
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root!"
    exit 1
fi

# Common variables
generate_port() {
    while true; do
        port=$(shuf -i $1-$2 -n 1)
        if [[ ! "$port" =~ "4" ]]; then
            echo "$port"
            break
        fi
    done
}

# If custom parameters were not provided, generate defaults
if [[ -z "$ssport" ]]; then
    ssport=$(generate_port 20000 40000)
fi

if [[ -z "$sspasswd" ]]; then
    sspasswd=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
fi

if [[ -z "$tls_password" ]]; then
    tls_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
fi

# Preset domains array
PRESET_DOMAINS=(
    "publicassets.cdn-apple.com"
    "s0.awsstatic.com"
    "p11.douyinpic.com"
    "cmsassets.rgpub.io"
)

# Install necessary packages
install_packages() {
    print_header "Installing Required Packages"
    
    if command -v apt-get >/dev/null 2>&1; then
        print_info "Using apt package manager..."
        apt-get update
        apt-get install -y wget xz-utils jq
    elif command -v yum >/dev/null 2>&1; then
        print_info "Using yum package manager..."
        yum update -y
        yum install -y epel-release
        yum install -y wget xz jq
    else
        print_error "Unsupported package manager"
        exit 1
    fi
    print_success "Packages installed successfully"
}

# Detect system architecture
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
            print_error "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac
    print_success "Detected architecture: $ss_arch"
}

# Install/Update Shadowsocks
install_shadowsocks() {
    print_header "Installing Shadowsocks-rust"
    local new_ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | 
                    jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    
    print_info "Installing version: $new_ver"
    local archive_name="shadowsocks-${new_ver}.${ss_arch}-unknown-linux-gnu.tar.xz"
    
    # Delete old files
    if [[ -f "/usr/local/bin/ssserver" ]]; then
        print_info "Removing old Shadowsocks binary..."
        rm -f /usr/local/bin/ssserver
        if [[ $? -ne 0 ]]; then
            print_error "Failed to remove old Shadowsocks binary!"
            exit 1
        fi
    fi
    
    if ! wget --no-check-certificate -N "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${new_ver}/${archive_name}"; then
        print_error "Failed to download Shadowsocks Rust!"
        exit 1
    fi
    
    print_info "Extracting files..."
    tar -xf "$archive_name"
    
    if [[ ! -f "ssserver" ]]; then
        print_error "Failed to extract Shadowsocks Rust!"
        exit 1
    fi
    
    chmod +x ssserver
    mv ssserver /usr/local/bin/
    if [[ $? -ne 0 ]]; then
        print_error "Failed to install Shadowsocks binary!"
        exit 1
    fi
    
    rm -f sslocal ssmanager ssservice ssurl "$archive_name"
    print_success "Shadowsocks-rust installation completed"
}

# Configure Shadowsocks
configure_shadowsocks() {
    print_header "Configuring Shadowsocks"
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
    print_info "Starting Shadowsocks service..."
    systemctl enable shadowsocks.service
    systemctl start shadowsocks.service
    
    if ! systemctl is-active --quiet shadowsocks.service; then
        print_error "Shadowsocks service failed to start!"
        exit 1
    fi
    print_success "Shadowsocks configured and started successfully"
}

# Install/Update ShadowTLS
install_shadowtls() {
    print_header "Installing ShadowTLS"
    local latest_version=$(curl -s https://api.github.com/repos/ihciah/shadow-tls/releases/latest | jq -r .tag_name)
    
    print_info "Installing version: ${latest_version}"
    
    # Delete old files
    if [[ -f "/usr/local/bin/shadow-tls" ]]; then
        print_info "Removing old ShadowTLS binary..."
        rm -f /usr/local/bin/shadow-tls
        if [[ $? -ne 0 ]]; then
            print_error "Failed to remove old ShadowTLS binary!"
            exit 1
        fi
    fi
    
    # Download to temporary file
    local temp_file="/tmp/shadow-tls.tmp"
    if ! wget -q --show-progress "https://github.com/ihciah/shadow-tls/releases/download/${latest_version}/shadow-tls-${tls_arch_suffix}" -O "${temp_file}"; then
        print_error "Failed to download ShadowTLS!"
        rm -f "${temp_file}"
        exit 1
    fi
    
    # Move to the target position
    mv "${temp_file}" /usr/local/bin/shadow-tls
    if [[ $? -ne 0 ]]; then
        print_error "Failed to install ShadowTLS binary!"
        rm -f "${temp_file}"
        exit 1
    fi
    
    chmod +x /usr/local/bin/shadow-tls
    if [[ $? -ne 0 ]]; then
        print_error "Failed to set executable permission for ShadowTLS!"
        exit 1
    fi
    
    print_success "ShadowTLS binary installed successfully"
}

# Function to get user input for ShadowTLS listen port
get_user_port() {
    # Skip interactive prompt if tls port is already set via arguments
    if [[ -n "$listen_port" ]]; then
        print_info "Using specified TLS port: $listen_port"
        return 0
    fi
    
    print_header "ShadowTLS Port Configuration"
    echo "Please set the ShadowTLS listening port："
    echo "1. Random generation"
    echo "2. Manual input (Port range: 50000-60000)"
    echo -e "----------------------------------------\n"
    
    while true; do
        read -p "Please select (1/2): " choice
        case $choice in
            1)
                listen_port=$(generate_port 50000 60000)
                print_info "Randomly generated port: $listen_port"
                break
                ;;
            2)
                while true; do
                    read -p "Please enter the listening port (50000-60000): " port
                    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 50000 ] && [ "$port" -le 60000 ] && [[ ! "$port" =~ "4" ]]; then
                        listen_port=$port
                        print_info "Selected port: $listen_port"
                        break
                    else
                        print_error "Please enter a valid port number (50000-60000)"
                    fi
                done
                break
                ;;
            *)
                print_error "Invalid selection. Please enter 1 or 2."
                ;;
        esac
    done
}

# Get user domain selection
get_user_domain() {
    # Skip interactive prompt if domain is already set via arguments
    if [[ -n "$domain" ]]; then
        print_info "Using specified TLS domain: $domain"
        return 0
    fi
    
    print_header "TLS Domain Configuration"
    echo "Please set the TLS domain: "
    echo "1. Randomly use preset domain"
    echo "2. Use the specified domain"
    echo "3. Manually enter the domain"
    echo -e "----------------------------------------\n"
    
    while true; do
        read -p "Please select (1/2/3): " domain_choice
        case $domain_choice in
            1)
                random_index=$((RANDOM % ${#PRESET_DOMAINS[@]}))
                domain="${PRESET_DOMAINS[$random_index]}"
                print_info "Used domain: $domain"
                break
                ;;
            2)
                echo -e "\nAvailable preset domains: "
                for i in "${!PRESET_DOMAINS[@]}"; do
                    echo "$((i+1)). ${PRESET_DOMAINS[$i]}"
                done
                while true; do
                    read -p "Please select the domain number (1-${#PRESET_DOMAINS[@]}): " domain_index
                    if [[ "$domain_index" =~ ^[0-9]+$ ]] && [ "$domain_index" -ge 1 ] && [ "$domain_index" -le "${#PRESET_DOMAINS[@]}" ]; then
                        domain="${PRESET_DOMAINS[$((domain_index-1))]}"
                        print_info "Selected domain: $domain"
                        break
                    else
                        print_error "Please enter a valid number (1-${#PRESET_DOMAINS[@]})"
                    fi
                done
                break
                ;;
            3)
                while true; do
                    read -p "Please enter the domain: " custom_domain
                    if [[ $custom_domain =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                        domain=$custom_domain
                        print_info "Used domain: $domain"
                        break
                    else
                        print_error "Please enter a valid domain format"
                    fi
                done
                break
                ;;
            *)
                print_error "Invalid selection. Please enter 1、2 or 3。"
                ;;
        esac
    done
}

# Configure ShadowTLS
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
    print_info "Starting ShadowTLS service..."
    systemctl enable shadowtls.service
    systemctl start shadowtls.service

    if ! systemctl is-active --quiet shadowtls.service; then
        print_error "ShadowTLS service failed to start!"
        print_warning "Please check the logs with: journalctl -u shadowtls.service"
        exit 1
    fi
    print_success "ShadowTLS configured and started successfully"
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

# Show configuration
show_configuration() {
    print_header "Installation Status"
    
    local server_ip=$(get_ipv4_address)
    
    echo -e "${BOLD}Service Status:${NC}"
    echo -e "\n${BOLD}Shadowsocks Service:${NC}"
    systemctl status shadowsocks.service --no-pager
    
    echo -e "\n${BOLD}ShadowTLS Service:${NC}"
    systemctl status shadowtls.service --no-pager
    
    print_header "Configuration Details"
    echo -e "${BOLD}Server IP:${NC} ${server_ip}"
    echo -e "${BOLD}Shadowsocks Port:${NC} ${ssport}"
    echo -e "${BOLD}Shadowsocks Password:${NC} ${sspasswd}"
    echo -e "${BOLD}ShadowTLS Port:${NC} ${listen_port}"
    echo -e "${BOLD}ShadowTLS Password:${NC} ${tls_password}"
    echo -e "${BOLD}ShadowTLS SNI:${NC} ${domain}"
}

# Update services
update_services() {
    print_header "Starting Version Check for Updates"

    # Check if Shadowsocks is installed
    if [[ ! -x "/usr/local/bin/ssserver" ]]; then
        print_error "Shadowsocks is not installed. Aborting update."
        exit 1
    fi

    # Get the local version
    local local_ss_ver_raw=$(/usr/local/bin/ssserver --version 2>&1 | awk '{print $2}')
    if [[ -z "$local_ss_ver_raw" ]]; then
        print_error "Unable to retrieve local Shadowsocks version."
        exit 1
    fi
    # Remove letters (only keep digits and dots)
    local local_ss_ver=$(echo "$local_ss_ver_raw" | sed 's/[A-Za-z]//g')
    print_info "Local Shadowsocks version: $local_ss_ver"

    # Get the latest version from GitHub
    local ss_latest_ver_raw=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | \
                                jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    if [[ -z "$ss_latest_ver_raw" ]]; then
        print_error "Failed to retrieve the latest Shadowsocks version."
        exit 1
    fi
    local ss_latest_ver=$(echo "$ss_latest_ver_raw" | sed 's/[A-Za-z]//g')
    print_info "Latest Shadowsocks version: $ss_latest_ver"

    # Compare versions using sort -V for natural version sorting
    if [[ "$local_ss_ver" == "$ss_latest_ver" ]]; then
        print_success "Shadowsocks is already at the latest version ($local_ss_ver)"
    elif [[ "$local_ss_ver" == "$(printf '%s\n' "$local_ss_ver" "$ss_latest_ver" | sort -V | head -n1)" ]]; then
        print_info "Shadowsocks needs to be updated from $local_ss_ver to $ss_latest_ver"
        systemctl stop shadowsocks.service 2>/dev/null
        install_shadowsocks
        systemctl start shadowsocks.service
    else
        print_error "Local Shadowsocks version ($local_ss_ver) is greater than the GitHub version ($ss_latest_ver). The installed version might not be official."
        exit 1
    fi

    # Check if ShadowTLS is installed
    if [[ ! -x "/usr/local/bin/shadow-tls" ]]; then
        print_error "ShadowTLS is not installed. Aborting update."
        exit 1
    fi

    # Get the local version
    local local_stls_ver_raw=$(/usr/local/bin/shadow-tls --version 2>&1 | awk '{print $2}')
    if [[ -z "$local_stls_ver_raw" ]]; then
        print_error "Unable to retrieve local ShadowTLS version."
        exit 1
    fi
    # Remove letters (only keep digits and dots)
    local local_stls_ver=$(echo "$local_stls_ver_raw" | sed 's/[A-Za-z]//g')
    print_info "Local ShadowTLS version: $local_stls_ver"

    # Get the latest version from GitHub
    local stls_latest_ver_raw=$(curl -s https://api.github.com/repos/ihciah/shadow-tls/releases/latest | jq -r .tag_name)
    if [[ -z "$stls_latest_ver_raw" ]]; then
        print_error "Failed to retrieve the latest ShadowTLS version."
        exit 1
    fi
    local stls_latest_ver=$(echo "$stls_latest_ver_raw" | sed 's/[A-Za-z]//g')
    print_info "Latest ShadowTLS version: $stls_latest_ver"

    # Compare versions
    if [[ "$local_stls_ver" == "$stls_latest_ver" ]]; then
        print_success "ShadowTLS is already at the latest version ($local_stls_ver)"
    elif [[ "$local_stls_ver" == "$(printf '%s\n' "$local_stls_ver" "$stls_latest_ver" | sort -V | head -n1)" ]]; then
        print_info "ShadowTLS needs to be updated from $local_stls_ver to $stls_latest_ver"
        systemctl stop shadowtls.service 2>/dev/null
        install_shadowtls
        systemctl start shadowtls.service
    else
        print_error "Local ShadowTLS version ($local_stls_ver) is greater than the GitHub version ($stls_latest_ver). The installed version might not be official."
        exit 1
    fi

    print_success "All services are already the latest version"
    exit 0
}

# Uninstall services
uninstall_service() {
    print_header "Uninstalling Services"
    
    print_info "Stopping and disabling Shadowsocks service..."
    systemctl stop shadowsocks.service 2>/dev/null
    systemctl disable shadowsocks.service 2>/dev/null
    print_success "Shadowsocks service stopped and disabled"
    
    print_info "Stopping and disabling ShadowTLS service..."
    systemctl stop shadowtls.service 2>/dev/null
    systemctl disable shadowtls.service 2>/dev/null
    print_success "ShadowTLS service stopped and disabled"
    
    print_info "Removing service files..."
    rm -f /lib/systemd/system/shadowsocks.service
    rm -f /lib/systemd/system/shadowtls.service
    print_success "Service files removed"
    
    print_info "Removing configuration files..."
    rm -rf /etc/shadowsocks
    rm -f /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
    print_success "Configuration files removed"
    
    print_info "Removing binary files..."
    rm -f /usr/local/bin/ssserver
    rm -f /usr/local/bin/shadow-tls
    print_success "Binary files removed"
    
    print_info "Reloading systemd daemon..."
    systemctl daemon-reload
    systemctl reset-failed
    print_success "Systemd daemon reloaded"
    
    print_success "Uninstallation completed successfully"
}

# Main menu
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
                install_packages
                detect_arch
                install_shadowsocks
                configure_shadowsocks
                install_shadowtls
                get_user_port
                get_user_domain
                configure_shadowtls
                show_configuration
                exit 0
                ;;
            2)
                install_packages
                detect_arch
                update_services
                # The update_services function already contains exit internally
                ;;
            3)
                uninstall_service
                exit 0
                ;;
            *)
                print_error "Invalid option. Please try again."
                ;;
        esac
    done
}

# Execute parameter parsing if arguments are provided
parse_args "$@"

# Start script execution
main_menu
