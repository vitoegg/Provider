#!/bin/bash
################################################################################
# Unified Shadowsocks Installation Script
# This script installs and manages ShadowTLS and SS2022 services using sing-box.
# It supports selective installation and provides friendly output messages.
################################################################################

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'     # No Color
BOLD='\033[1m'

# Default port ranges
DEFAULT_TLS_PORT_START=50000
DEFAULT_TLS_PORT_END=60000
DEFAULT_SS2022_PORT_START=20000
DEFAULT_SS2022_PORT_END=40000

# Preset domains for ShadowTLS
PRESET_DOMAINS=(
    "publicassets.cdn-apple.com"
    "s0.awsstatic.com"
    "p11.douyinpic.com"
    "sns-video-hw.xhscdn.com"
)

################################################################################
# Logging functions with timestamp and category
################################################################################
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
# Cleanup function for temporary files
################################################################################
cleanup_temp_files() {
    local temp_file="/tmp/sing-box.deb"
    if [[ -f "$temp_file" ]]; then
        rm -f "$temp_file"
        log_info "Cleaned up temporary files on exit"
    fi
}

# Set trap to cleanup on script exit
trap cleanup_temp_files EXIT

################################################################################
# Global variables for configuration
################################################################################
INSTALL_SHADOWTLS=false
INSTALL_SS2022=false
TLS_PORT=""
TLS_PASSWORD=""
SS_PASSWORD=""
SS2022_PORT=""
SS2022_PASSWORD=""
TLS_DOMAIN=""

################################################################################
# Command-line arguments parser
################################################################################
parse_args() {
    local has_shadowtls_params=false
    local has_ss2022_params=false
    local uninstall_requested=false
    
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --tls-port)
                TLS_PORT="$2"
                has_shadowtls_params=true
                shift 2
                ;;
            --tls-password)
                TLS_PASSWORD="$2"
                has_shadowtls_params=true
                shift 2
                ;;
            --tls-domain)
                TLS_DOMAIN="$2"
                has_shadowtls_params=true
                shift 2
                ;;
            --ss-password)
                SS_PASSWORD="$2"
                has_shadowtls_params=true
                shift 2
                ;;
            --ss2022-port)
                SS2022_PORT="$2"
                has_ss2022_params=true
                shift 2
                ;;
            --ss2022-password)
                SS2022_PASSWORD="$2"
                has_ss2022_params=true
                shift 2
                ;;
            --install-shadowtls)
                INSTALL_SHADOWTLS=true
                shift
                ;;
            --install-ss2022)
                INSTALL_SS2022=true
                shift
                ;;
            --install-both)
                INSTALL_SHADOWTLS=true
                INSTALL_SS2022=true
                shift
                ;;
            -u|--uninstall)
                uninstall_requested=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Handle uninstall request
    if [[ "$uninstall_requested" == true ]]; then
        uninstall_service
        exit 0
    fi
    
    # Auto-detect services based on parameters (only if no explicit install flags are set)
    if [[ "$INSTALL_SHADOWTLS" == false && "$INSTALL_SS2022" == false ]]; then
        log_info "Analyzing parameters for service detection..."
        log_info "ShadowTLS parameters detected: $has_shadowtls_params"
        log_info "SS2022 parameters detected: $has_ss2022_params"
        
        if [[ "$has_shadowtls_params" == true && "$has_ss2022_params" == true ]]; then
            # Both types of parameters provided
            INSTALL_SHADOWTLS=true
            INSTALL_SS2022=true
            log_info "Auto-detected both ShadowTLS and SS2022 installation from parameters"
        elif [[ "$has_shadowtls_params" == true ]]; then
            # Only ShadowTLS parameters provided
            INSTALL_SHADOWTLS=true
            log_info "Auto-detected ShadowTLS installation from parameters"
        elif [[ "$has_ss2022_params" == true ]]; then
            # Only SS2022 parameters provided
            INSTALL_SS2022=true
            log_info "Auto-detected SS2022 installation from parameters"
        else
            log_info "No service parameters detected, will show interactive menu"
        fi
    else
        log_info "Explicit installation flags detected, skipping auto-detection"
    fi
}

################################################################################
# Show usage information
################################################################################
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Installation Options:"
    echo "  --install-shadowtls     Install ShadowTLS service only"
    echo "  --install-ss2022        Install SS2022 service only"
    echo "  --install-both          Install both ShadowTLS and SS2022 services"
    echo ""
    echo "Configuration Options:"
    echo "  --tls-port PORT         Specify TLS port (50000-60000)"
    echo "  --tls-password PASS     Specify TLS password"
    echo "  --tls-domain DOMAIN     Specify TLS domain"
    echo "  --ss-password PASS      Specify Shadowsocks password for ShadowTLS"
    echo "  --ss2022-port PORT      Specify SS2022 port (20000-40000)"
    echo "  --ss2022-password PASS  Specify SS2022 password"
    echo ""
    echo "Other Options:"
    echo "  --uninstall             Uninstall sing-box service and remove configuration"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Smart Detection:"
    echo "  The script can auto-detect which services to install based on parameters:"
    echo "  - ShadowTLS parameters: --tls-port, --tls-password, --tls-domain, --ss-password"
    echo "  - SS2022 parameters: --ss2022-port, --ss2022-password"
    echo ""
    echo "Examples:"
    echo "  # Explicit installation"
    echo "  $0 --install-shadowtls --tls-port 58568 --tls-password mypass"
    echo "  $0 --install-ss2022 --ss2022-port 31606"
    echo "  $0 --install-both"
    echo ""
    echo "  # Auto-detection (recommended)"
    echo "  $0 --tls-port 58568 --tls-password mypass"
    echo "  $0 --ss2022-port 31606 --ss2022-password mypass"
    echo "  $0 --tls-port 58568 --ss2022-port 31606"
    echo ""
    echo "  # Uninstall"
    echo "  $0 --uninstall"
}

################################################################################
# Detect system architecture
################################################################################
detect_arch() {
    print_header "Detecting System Architecture"
    local ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64')
            ARCH='amd64'
            ;;
        'x86' | 'i686' | 'i386')
            ARCH='386'
            ;;
        'aarch64' | 'arm64')
            ARCH='arm64'
            ;;
        'armv7l')
            ARCH='armv7'
            ;;
        's390x')
            ARCH='s390x'
            ;;
        *)
            log_error "Unsupported architecture: ${ARCH_RAW}"
            exit 1
            ;;
    esac
    log_success "Detected architecture: $ARCH"
}

################################################################################
# Install required packages
################################################################################
install_packages() {
    print_header "Installing Required Packages"
    local packages_needed=(wget dpkg jq openssl)
    
    if command -v apt-get >/dev/null 2>&1; then
        log_info "Updating package list..."
        # Update package list silently
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
        
        for pkg in "${packages_needed[@]}"; do
            if dpkg -s "$pkg" >/dev/null 2>&1; then
                log_info "Dependency exists: $pkg"
            else
                log_info "Installing dependency: $pkg"
                # Install packages silently with automatic yes and no prompts
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" -qq >/dev/null 2>&1
                if [[ $? -eq 0 ]]; then
                    log_success "Installed dependency: $pkg"
                else
                    log_error "Failed to install dependency: $pkg"
                    exit 1
                fi
            fi
        done
    else
        log_error "This script requires Debian/Ubuntu system with apt package manager!"
        log_error "sing-box .deb packages are only available for Debian-based systems."
        exit 1
    fi
    log_success "Required packages installed successfully"
}

################################################################################
# Generate random port excluding digits "4"
################################################################################
generate_port() {
    local start="$1"
    local end="$2"
    while true; do
        local port
        port=$(shuf -i "$start"-"$end" -n 1)
        if [[ ! "$port" =~ "4" ]]; then
            echo "$port"
            break
        fi
    done
}

################################################################################
# Get server's IPv4 address
################################################################################
get_ipv4_address() {
    local ip
    ip=$(wget -qO- --timeout=5 --tries=2 https://api.ipify.org 2>/dev/null)
    if [[ -z "$ip" ]]; then
        echo "Unable to get IP address"
    else
        echo "$ip"
    fi
}



################################################################################
# Download and install sing-box
################################################################################
install_singbox() {
    print_header "Installing sing-box"
    
    # Check if sing-box is already installed and running
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        log_warning "sing-box service is already installed and running."
        log_warning "If you want to reinstall, please uninstall first."
        return 0
    fi
    
    # Get latest version
    local latest_version
    latest_version=$(wget -qO- --timeout=10 --tries=3 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r .tag_name)
    if [[ -z "$latest_version" ]]; then
        log_error "Failed to retrieve sing-box release version"
        exit 1
    fi
    
    log_info "Installing sing-box version: $latest_version"
    
    # Download .deb package
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box_${latest_version#v}_linux_${ARCH}.deb"
    local temp_file="/tmp/sing-box.deb"
    
    log_info "Download URL: $download_url"
    log_info "Downloading sing-box package..."
    if ! wget --no-check-certificate -q -O "$temp_file" "$download_url"; then
        log_error "Failed to download sing-box from: $download_url"
        log_error "Please check if the URL is correct and accessible"
        exit 1
    fi
    
    # Install package
    log_info "Installing sing-box package..."
    if ! DEBIAN_FRONTEND=noninteractive dpkg -i "$temp_file" >/dev/null 2>&1; then
        log_error "Failed to install sing-box package!"
        # Clean up on failure
        rm -f "$temp_file"
        exit 1
    fi
    
    # Clean up temporary file
    rm -f "$temp_file"
    log_info "Cleaned up temporary files"
    
    log_success "sing-box installation completed"
}

################################################################################
# Generate configuration parameters
################################################################################
generate_config_params() {
    print_header "Generating Configuration Parameters"
    
    # Generate ShadowTLS parameters if needed
    if [[ "$INSTALL_SHADOWTLS" == true ]]; then
        if [[ -z "$TLS_PORT" ]]; then
            TLS_PORT=$(generate_port "$DEFAULT_TLS_PORT_START" "$DEFAULT_TLS_PORT_END")
            log_info "Generated TLS port: $TLS_PORT"
        else
            log_info "Using specified TLS port: $TLS_PORT"
        fi
        
        if [[ -z "$TLS_PASSWORD" ]]; then
            TLS_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
            log_info "Generated TLS password"
        else
            log_info "Using specified TLS password"
        fi
        
        if [[ -z "$TLS_DOMAIN" ]]; then
            local random_index=$((RANDOM % ${#PRESET_DOMAINS[@]}))
            TLS_DOMAIN="${PRESET_DOMAINS[$random_index]}"
            log_info "Selected TLS domain: $TLS_DOMAIN"
        else
            log_info "Using specified TLS domain: $TLS_DOMAIN"
        fi
        
        if [[ -z "$SS_PASSWORD" ]]; then
            SS_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
            log_info "Generated Shadowsocks password for ShadowTLS"
        else
            log_info "Using specified Shadowsocks password for ShadowTLS"
        fi
    fi
    
    # Generate SS2022 parameters if needed
    if [[ "$INSTALL_SS2022" == true ]]; then
        if [[ -z "$SS2022_PORT" ]]; then
            SS2022_PORT=$(generate_port "$DEFAULT_SS2022_PORT_START" "$DEFAULT_SS2022_PORT_END")
            log_info "Generated SS2022 port: $SS2022_PORT"
        else
            log_info "Using specified SS2022 port: $SS2022_PORT"
        fi
        
        if [[ -z "$SS2022_PASSWORD" ]]; then
            SS2022_PASSWORD=$(openssl rand -base64 16)
            log_info "Generated SS2022 password using openssl"
        else
            log_info "Using specified SS2022 password"
        fi
    fi
    
    log_success "Configuration parameters ready"
}

################################################################################
# Create sing-box configuration
################################################################################
create_singbox_config() {
    print_header "Creating sing-box Configuration"
    
    local config_file="/etc/sing-box/config.json"
    local inbounds="[]"
    
    # Build inbounds array
    if [[ "$INSTALL_SHADOWTLS" == true && "$INSTALL_SS2022" == true ]]; then
        # Both services
        inbounds='[
    {
      "type": "shadowtls",
      "listen": "::",
      "listen_port": '$TLS_PORT',
      "version": 3,
      "users": [
        {
          "name": "Cloud",
          "password": "'$TLS_PASSWORD'"
        }
      ],
      "handshake": {
        "server": "'$TLS_DOMAIN'",
        "server_port": 443
      },
      "detour": "shadowsocks-in"
    },
    {
      "type": "shadowsocks",
      "tag": "shadowsocks-in",
      "listen": "127.0.0.1",
      "method": "aes-128-gcm",
      "password": "'$SS_PASSWORD'"
    },
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": '$SS2022_PORT',
      "method": "2022-blake3-aes-128-gcm",
      "password": "'$SS2022_PASSWORD'"
    }
  ]'
    elif [[ "$INSTALL_SHADOWTLS" == true ]]; then
        # ShadowTLS only
        inbounds='[
    {
      "type": "shadowtls",
      "listen": "::",
      "listen_port": '$TLS_PORT',
      "version": 3,
      "users": [
        {
          "name": "Cloud",
          "password": "'$TLS_PASSWORD'"
        }
      ],
      "handshake": {
        "server": "'$TLS_DOMAIN'",
        "server_port": 443
      },
      "detour": "shadowsocks-in"
    },
    {
      "type": "shadowsocks",
      "tag": "shadowsocks-in",
      "listen": "127.0.0.1",
      "method": "aes-128-gcm",
      "password": "'$SS_PASSWORD'"
    }
  ]'
    elif [[ "$INSTALL_SS2022" == true ]]; then
        # SS2022 only
        inbounds='[
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": '$SS2022_PORT',
      "method": "2022-blake3-aes-128-gcm",
      "password": "'$SS2022_PASSWORD'"
    }
  ]'
    fi
    
    # Create configuration file
    cat > "$config_file" << EOF
{
  "log": {
    "disabled": true
  },
  "inbounds": $inbounds
}
EOF
    
    log_success "Configuration file created: $config_file"
}

################################################################################
# Start and enable sing-box service
################################################################################
start_singbox_service() {
    print_header "Starting sing-box Service"
    
    log_info "Enabling sing-box service..."
    if ! systemctl enable sing-box >/dev/null 2>&1; then
        log_error "Failed to enable sing-box service"
        exit 1
    fi
    
    log_info "Starting sing-box service..."
    if ! systemctl start sing-box >/dev/null 2>&1; then
        log_error "Failed to start sing-box service"
        exit 1
    fi
    
    # Wait a moment for service to start
    sleep 2
    
    # Check service status
    if ! systemctl is-active --quiet sing-box; then
        log_error "sing-box service failed to start!"
        log_error "Check logs with: journalctl -u sing-box"
        exit 1
    fi
    
    log_success "sing-box service started successfully"
}

################################################################################
# Display configuration information
################################################################################
show_configuration() {
    print_header "Installation Status"
    echo "------------------------------------"
    echo -e "${BOLD}sing-box Service Status:${NC}"
    systemctl status sing-box --no-pager
    echo "------------------------------------"

    print_header "Configuration Details"
    local server_ip
    server_ip=$(get_ipv4_address)
    
    printf "%-25s %s\n" "Server IP:" "$server_ip"
    
    if [[ "$INSTALL_SHADOWTLS" == true ]]; then
        echo ""
        echo -e "${BOLD}ShadowTLS Configuration:${NC}"
        printf "%-25s %s\n" "TLS Port:" "$TLS_PORT"
        printf "%-25s %s\n" "TLS Password:" "$TLS_PASSWORD"
        printf "%-25s %s\n" "TLS Domain:" "$TLS_DOMAIN"
        printf "%-25s %s\n" "SS Password:" "$SS_PASSWORD"
        printf "%-25s %s\n" "SS Method:" "aes-128-gcm"
    fi
    
    if [[ "$INSTALL_SS2022" == true ]]; then
        echo ""
        echo -e "${BOLD}SS2022 Configuration:${NC}"
        printf "%-25s %s\n" "SS2022 Port:" "$SS2022_PORT"
        printf "%-25s %s\n" "SS2022 Password:" "$SS2022_PASSWORD"
        printf "%-25s %s\n" "SS2022 Method:" "2022-blake3-aes-128-gcm"
    fi
    
    echo "=================================="
    echo ""
}

################################################################################
# Uninstall sing-box service
################################################################################
uninstall_service() {
    print_header "Uninstalling sing-box"
    
    log_info "Stopping and disabling sing-box service..."
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        systemctl stop sing-box >/dev/null 2>&1
        log_success "Service stopped"
    else
        log_info "Service is not running"
    fi
    
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
        systemctl disable sing-box >/dev/null 2>&1
        log_success "Service disabled"
    else
        log_info "Service is not enabled"
    fi
    
    log_info "Uninstalling sing-box package..."
    if dpkg -l | grep -q sing-box 2>/dev/null; then
        DEBIAN_FRONTEND=noninteractive dpkg -r sing-box >/dev/null 2>&1
        log_success "Package uninstalled"
    else
        log_info "Package is not installed"
    fi
    
    log_info "Removing configuration files..."
    if [ -d "/etc/sing-box" ]; then
        rm -rf /etc/sing-box
        log_success "Configuration files removed"
    else
        log_info "Configuration directory does not exist"
    fi
    
    log_success "Uninstallation completed successfully"
}

################################################################################
# Main installation function
################################################################################
run_installation() {
    detect_arch
    install_packages
    install_singbox
    generate_config_params
    create_singbox_config
    start_singbox_service
    show_configuration
}

################################################################################
# Interactive menu
################################################################################
show_menu() {
    while true; do
        clear
        print_header "Shadowsocks Unified Installation Script"
        echo "1. Install ShadowTLS only"
        echo "2. Install SS2022 only"
        echo "3. Install both ShadowTLS and SS2022"
        echo "4. Uninstall services"
        echo "5. Exit"
        echo -e "=====================================\n"
        read -p "Please select an option (1-5): " choice
        
        case $choice in
            1)
                INSTALL_SHADOWTLS=true
                INSTALL_SS2022=false
                run_installation
                exit 0
                ;;
            2)
                INSTALL_SHADOWTLS=false
                INSTALL_SS2022=true
                run_installation
                exit 0
                ;;
            3)
                INSTALL_SHADOWTLS=true
                INSTALL_SS2022=true
                run_installation
                exit 0
                ;;
            4)
                uninstall_service
                exit 0
                ;;
            5)
                log_info "Exiting..."
                exit 0
                ;;
            *)
                log_error "Invalid option. Please try again."
                read -p "Press Enter to continue..."
                ;;
        esac
    done
}

################################################################################
# Main execution
################################################################################
main() {
    log_info "Shadowsocks Unified Installation Script v1.0"
    log_info "Operating System: $(uname -s) $(uname -r)"
    log_info "Architecture: $(uname -m)"
    
    # Parse command line arguments
    parse_args "$@"
    
    # If installation flags are set via command line, run installation
    if [[ "$INSTALL_SHADOWTLS" == true || "$INSTALL_SS2022" == true ]]; then
        run_installation
    else
        # Show interactive menu
        show_menu
    fi
}

main "$@" 