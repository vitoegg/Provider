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
DEFAULT_SS_PORT_START=20000
DEFAULT_SS_PORT_END=40000

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
INSTALL_SS=false
TLS_PORT=""
TLS_PASSWORD=""
SS_PASSWORD=""
SS_PORT=""
SS_STANDALONE_PASSWORD=""
TLS_DOMAIN=""

################################################################################
# Command-line arguments parser
################################################################################
parse_args() {
    local has_shadowtls_params=false
    local has_ss_params=false
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
            --ss-port)
                SS_PORT="$2"
                has_ss_params=true
                shift 2
                ;;
            --ss-standalone-password)
                SS_STANDALONE_PASSWORD="$2"
                has_ss_params=true
                shift 2
                ;;
            --install-shadowtls)
                INSTALL_SHADOWTLS=true
                shift
                ;;
            --install-ss)
                INSTALL_SS=true
                shift
                ;;
            --install-both)
                INSTALL_SHADOWTLS=true
                INSTALL_SS=true
                shift
                ;;
            -u|--uninstall)
                uninstall_requested=true
                shift
                ;;
            --update)
                update_singbox
                exit $?
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
    if [[ "$INSTALL_SHADOWTLS" == false && "$INSTALL_SS" == false ]]; then
        log_info "Analyzing parameters for service detection..."
        log_info "ShadowTLS parameters detected: $has_shadowtls_params"
        log_info "Shadowsocks parameters detected: $has_ss_params"
        
        if [[ "$has_shadowtls_params" == true && "$has_ss_params" == true ]]; then
            # Both types of parameters provided
            INSTALL_SHADOWTLS=true
            INSTALL_SS=true
            log_info "Auto-detected both ShadowTLS and Shadowsocks installation from parameters"
        elif [[ "$has_shadowtls_params" == true ]]; then
            # Only ShadowTLS parameters provided
            INSTALL_SHADOWTLS=true
            log_info "Auto-detected ShadowTLS installation from parameters"
        elif [[ "$has_ss_params" == true ]]; then
            # Only Shadowsocks parameters provided
            INSTALL_SS=true
            log_info "Auto-detected Shadowsocks installation from parameters"
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
    echo "  --install-ss            Install Shadowsocks service only"
    echo "  --install-both          Install both ShadowTLS and Shadowsocks services"
    echo ""
    echo "Configuration Options:"
    echo "  --tls-port PORT         Specify TLS port (50000-60000)"
    echo "  --tls-password PASS     Specify TLS password"
    echo "  --tls-domain DOMAIN     Specify TLS domain"
    echo "  --ss-password PASS      Specify Shadowsocks password for ShadowTLS"
    echo "  --ss-port PORT          Specify Shadowsocks port (20000-40000)"
    echo "  --ss-standalone-password PASS  Specify standalone Shadowsocks password"
    echo ""
    echo "Other Options:"
    echo "  --uninstall             Uninstall sing-box service and remove configuration"
    echo "  --update                Update sing-box to the latest version"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Smart Detection:"
    echo "  The script can auto-detect which services to install based on parameters:"
    echo "  - ShadowTLS parameters: --tls-port, --tls-password, --tls-domain, --ss-password"
    echo "  - Shadowsocks parameters: --ss-port, --ss-standalone-password"
    echo ""
    echo "Examples:"
    echo "  # Explicit installation"
    echo "  $0 --install-shadowtls --tls-port 58568 --tls-password mypass"
    echo "  $0 --install-ss --ss-port 31606"
    echo "  $0 --install-both"
    echo ""
    echo "  # Auto-detection (recommended)"
    echo "  $0 --tls-port 58568 --tls-password mypass"
    echo "  $0 --ss-port 31606 --ss-standalone-password mypass"
    echo "  $0 --tls-port 58568 --ss-port 31606"
    echo ""
    echo "  # Update and Uninstall"
    echo "  $0 --update"
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
# Get current sing-box version
################################################################################
get_current_version() {
    if command -v sing-box >/dev/null 2>&1; then
        sing-box version 2>/dev/null | head -n1 | awk '{print $3}' | sed 's/^v//'
    else
        echo ""
    fi
}

################################################################################
# Compare two version strings
# Returns: 0 if equal, 1 if version1 > version2, 2 if version1 < version2
################################################################################
compare_versions() {
    local version1="$1"
    local version2="$2"
    
    # Remove 'v' prefix if present
    version1="${version1#v}"
    version2="${version2#v}"
    
    if [[ "$version1" == "$version2" ]]; then
        return 0
    fi
    
    # Split versions into arrays
    IFS='.' read -ra ver1_parts <<< "$version1"
    IFS='.' read -ra ver2_parts <<< "$version2"
    
    # Compare each part
    local max_parts=$((${#ver1_parts[@]} > ${#ver2_parts[@]} ? ${#ver1_parts[@]} : ${#ver2_parts[@]}))
    
    for ((i=0; i<max_parts; i++)); do
        local part1=${ver1_parts[i]:-0}
        local part2=${ver2_parts[i]:-0}
        
        # Extract numeric part (handle pre-release versions)
        part1=$(echo "$part1" | sed 's/[^0-9].*//')
        part2=$(echo "$part2" | sed 's/[^0-9].*//')
        
        if [[ $part1 -gt $part2 ]]; then
            return 1
        elif [[ $part1 -lt $part2 ]]; then
            return 2
        fi
    done
    
    return 0
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
# Update sing-box (Binary Replacement)
################################################################################
update_singbox() {
    print_header "Updating sing-box (Binary Replacement)"
    
    # Check if sing-box is installed
    if ! command -v sing-box >/dev/null 2>&1; then
        log_error "sing-box is not installed. Please install it first."
        return 1
    fi
    
    # Get current version
    local current_version
    current_version=$(get_current_version)
    if [[ -z "$current_version" ]]; then
        log_error "Failed to get current sing-box version"
        return 1
    fi
    log_info "Current version: $current_version"
    
    # Get latest version
    local latest_version
    latest_version=$(wget -qO- --timeout=10 --tries=3 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r .tag_name)
    if [[ -z "$latest_version" ]]; then
        log_error "Failed to retrieve latest sing-box version"
        return 1
    fi
    log_info "Latest version: $latest_version"
    
    # Compare versions
    compare_versions "$latest_version" "$current_version"
    local comparison_result=$?
    
    case $comparison_result in
        0)
            log_info "sing-box is already up to date (version $current_version)"
            return 0
            ;;
        2)
            log_warning "Current version ($current_version) is newer than latest release ($latest_version)"
            log_warning "Update cancelled to prevent downgrade"
            return 0
            ;;
        1)
            log_info "Update available: $current_version -> $latest_version"
            ;;
    esac
    
    # Stop sing-box service
    local service_was_running=false
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        service_was_running=true
        log_info "Stopping sing-box service for update..."
        if ! systemctl stop sing-box >/dev/null 2>&1; then
            log_error "Failed to stop sing-box service"
            return 1
        fi
        log_success "Service stopped"
    fi
    
    # Backup current binary
    local binary_backup="/tmp/sing-box-binary-backup"
    if [[ -f "/usr/bin/sing-box" ]]; then
        log_info "Backing up current binary..."
        cp "/usr/bin/sing-box" "$binary_backup"
        if [[ $? -eq 0 ]]; then
            log_success "Binary backed up to: $binary_backup"
        else
            log_error "Failed to backup binary"
            return 1
        fi
    fi
    
    # Download binary archive
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${latest_version#v}-linux-${ARCH}.tar.gz"
    local temp_archive="/tmp/sing-box-update.tar.gz"
    local temp_dir="/tmp/sing-box-update"
    
    log_info "Downloading sing-box binary $latest_version..."
    log_info "Download URL: $download_url"
    if ! wget --no-check-certificate -q -O "$temp_archive" "$download_url"; then
        log_error "Failed to download sing-box from: $download_url"
        # Restore service if it was running
        if [[ "$service_was_running" == true ]]; then
            systemctl start sing-box >/dev/null 2>&1
        fi
        return 1
    fi
    
    # Extract and replace binary
    log_info "Extracting and installing binary..."
    mkdir -p "$temp_dir" >/dev/null 2>&1
    if ! tar -xzf "$temp_archive" -C "$temp_dir" >/dev/null 2>&1; then
        log_error "Failed to extract sing-box archive"
        # Clean up and restore service
        rm -rf "$temp_archive" "$temp_dir"
        if [[ "$service_was_running" == true ]]; then
            systemctl start sing-box >/dev/null 2>&1
        fi
        return 1
    fi
    
    # Find and install the binary
    local binary_file
    binary_file=$(find "$temp_dir" -name "sing-box" -type f | head -n1)
    if [[ -z "$binary_file" ]]; then
        log_error "sing-box binary not found in archive"
        # Clean up and restore service
        rm -rf "$temp_archive" "$temp_dir"
        if [[ "$service_was_running" == true ]]; then
            systemctl start sing-box >/dev/null 2>&1
        fi
        return 1
    fi
    
    # Replace binary
    log_info "Replacing sing-box binary..."
    if ! cp "$binary_file" "/usr/bin/sing-box"; then
        log_error "Failed to replace sing-box binary"
        # Restore backup if available
        if [[ -f "$binary_backup" ]]; then
            cp "$binary_backup" "/usr/bin/sing-box"
            log_warning "Restored original binary from backup"
        fi
        # Clean up and restore service
        rm -rf "$temp_archive" "$temp_dir"
        if [[ "$service_was_running" == true ]]; then
            systemctl start sing-box >/dev/null 2>&1
        fi
        return 1
    fi
    
    # Set proper permissions
    chmod +x "/usr/bin/sing-box" >/dev/null 2>&1
    log_success "Binary replaced successfully"
    
    # Clean up temporary files
    rm -rf "$temp_archive" "$temp_dir" "$binary_backup"
    log_info "Cleaned up temporary files"
    
    # Restart service if it was running
    if [[ "$service_was_running" == true ]]; then
        log_info "Starting sing-box service..."
        if ! systemctl start sing-box >/dev/null 2>&1; then
            log_error "Failed to start sing-box service after update"
            log_error "Check logs with: journalctl -u sing-box"
            return 1
        fi
        
        # Wait a moment and check service status
        sleep 2
        if ! systemctl is-active --quiet sing-box; then
            log_error "sing-box service failed to start after update"
            log_error "Check logs with: journalctl -u sing-box"
            return 1
        fi
        log_success "Service restarted successfully"
    fi
    
    # Verify update
    local new_version
    new_version=$(get_current_version)
    if [[ "$new_version" == "${latest_version#v}" ]]; then
        log_success "sing-box successfully updated to version $new_version"
        log_info "Update method: Binary replacement (faster and more efficient)"
        return 0
    else
        log_error "Update verification failed. Expected: ${latest_version#v}, Got: $new_version"
        return 1
    fi
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
    
    # Generate Shadowsocks parameters if needed
    if [[ "$INSTALL_SS" == true ]]; then
        if [[ -z "$SS_PORT" ]]; then
            SS_PORT=$(generate_port "$DEFAULT_SS_PORT_START" "$DEFAULT_SS_PORT_END")
            log_info "Generated Shadowsocks port: $SS_PORT"
        else
            log_info "Using specified Shadowsocks port: $SS_PORT"
        fi
        
        if [[ -z "$SS_STANDALONE_PASSWORD" ]]; then
            SS_STANDALONE_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
            log_info "Generated Shadowsocks password"
        else
            log_info "Using specified Shadowsocks password"
        fi
    fi
    
    log_success "Configuration parameters ready"
}

################################################################################
# Create sing-box configuration
################################################################################
create_singbox_config() {
    print_header "Creating sing-box Configuration"
    
    # Clean existing configuration before creating new one
    clean_sing_box_config
    
    local config_file="/etc/sing-box/config.json"
    local inbounds="[]"
    
    # Build inbounds array
    if [[ "$INSTALL_SHADOWTLS" == true && "$INSTALL_SS" == true ]]; then
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
      "listen_port": '$SS_PORT',
      "method": "aes-128-gcm",
      "password": "'$SS_STANDALONE_PASSWORD'"
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
    elif [[ "$INSTALL_SS" == true ]]; then
        # Shadowsocks only
        inbounds='[
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": '$SS_PORT',
      "method": "aes-128-gcm",
      "password": "'$SS_STANDALONE_PASSWORD'"
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
    
    if [[ "$INSTALL_SS" == true ]]; then
        echo ""
        echo -e "${BOLD}Shadowsocks Configuration:${NC}"
        printf "%-25s %s\n" "SS Port:" "$SS_PORT"
        printf "%-25s %s\n" "SS Password:" "$SS_STANDALONE_PASSWORD"
        printf "%-25s %s\n" "SS Method:" "aes-128-gcm"
    fi
    
    echo "=================================="
    echo ""
}

################################################################################
# Clean sing-box configuration files and directories
################################################################################
clean_sing_box_config() {
    log_info "Cleaning existing sing-box configuration..."
    
    # Remove configuration directory and all its contents
    if [[ -d "/etc/sing-box" ]]; then
        rm -rf "/etc/sing-box" >/dev/null 2>&1
        log_info "Removed configuration directory: /etc/sing-box"
    fi
    
    # Remove any cached or temporary configuration files
    local temp_configs=(
        "/tmp/sing-box-config-backup.json"
        "/var/lib/sing-box"
        "/var/cache/sing-box"
        "/run/sing-box"
    )
    
    for config_path in "${temp_configs[@]}"; do
        if [[ -e "$config_path" ]]; then
            rm -rf "$config_path" >/dev/null 2>&1
            log_info "Cleaned: $config_path"
        fi
    done
    
    # Ensure configuration directory exists with proper permissions
    mkdir -p "/etc/sing-box" >/dev/null 2>&1
    chmod 755 "/etc/sing-box" >/dev/null 2>&1
    
    log_success "Configuration cleanup completed"
}

################################################################################
# Uninstall sing-box service
################################################################################
uninstall_service() {
    print_header "Uninstalling sing-box"
    
    # Stop and disable service
    log_info "Stopping and disabling sing-box service..."
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        if ! systemctl stop sing-box >/dev/null 2>&1; then
            log_warning "Failed to stop sing-box service gracefully, forcing stop..."
            systemctl kill sing-box >/dev/null 2>&1
        fi
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
    
    # Clean up systemd unit files and reload daemon
    log_info "Cleaning up systemd configuration..."
    local systemd_files=(
        "/etc/systemd/system/sing-box.service"
        "/lib/systemd/system/sing-box.service"
        "/usr/lib/systemd/system/sing-box.service"
    )
    
    local found_systemd_file=false
    for file in "${systemd_files[@]}"; do
        if [[ -f "$file" ]]; then
            rm -f "$file" >/dev/null 2>&1
            found_systemd_file=true
            log_info "Removed systemd unit file: $file"
        fi
    done
    
    if [[ "$found_systemd_file" == true ]]; then
        systemctl daemon-reload >/dev/null 2>&1
        log_success "Systemd daemon reloaded"
    fi
    
    # Remove sing-box package
    log_info "Removing sing-box package..."
    if dpkg -l | grep -q "^ii.*sing-box" 2>/dev/null; then
        # Try normal removal first, then force if needed
        DEBIAN_FRONTEND=noninteractive dpkg --remove sing-box >/dev/null 2>&1 || \
        DEBIAN_FRONTEND=noninteractive dpkg --remove --force-remove-reinstreq sing-box >/dev/null 2>&1
        log_success "Package removed"
    else
        log_info "Package is not installed"
    fi
    
    # Use the centralized configuration cleanup function
    clean_sing_box_config
    
    # Clean up additional paths that might not be covered by the function
    log_info "Removing additional configuration files and directories..."
    local additional_paths=(
        "/var/log/sing-box"
        "/etc/default/sing-box"
        "/etc/sing-box.conf"
        "/home/*/.sing-box"
        "/root/.sing-box"
    )
    
    for path in "${additional_paths[@]}"; do
        if [[ -e "$path" ]]; then
            rm -rf "$path" >/dev/null 2>&1
            log_info "Removed: $path"
        fi
    done
    
    # Clean up any sing-box binary if it still exists
    log_info "Removing sing-box binary..."
    local binary_paths=(
        "/usr/bin/sing-box"
        "/usr/local/bin/sing-box"
        "/opt/sing-box/sing-box"
    )
    
    for binary in "${binary_paths[@]}"; do
        if [[ -f "$binary" ]]; then
            rm -f "$binary" >/dev/null 2>&1
            log_info "Removed binary: $binary"
        fi
    done
    
    # Quick package manager cleanup (optional)
    log_info "Running basic package cleanup..."
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1 || true
    log_success "Basic cleanup completed"
    
    # Clean up temporary files from this script
    cleanup_temp_files
    
    log_success "Complete uninstallation finished successfully"
    log_info "All sing-box components have been removed from the system"
    log_info "The system is ready for normal package operations"
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
        echo "2. Install Shadowsocks only"
        echo "3. Install both ShadowTLS and Shadowsocks"
        echo "4. Update Singbox service"
        echo "5. Uninstall Singbox service"
        echo "6. Exit Script"
        echo -e "=====================================\n"
        read -p "Please select an option (1-6): " choice
        
        case $choice in
            1)
                INSTALL_SHADOWTLS=true
                INSTALL_SS=false
                run_installation
                exit 0
                ;;
            2)
                INSTALL_SHADOWTLS=false
                INSTALL_SS=true
                run_installation
                exit 0
                ;;
            3)
                INSTALL_SHADOWTLS=true
                INSTALL_SS=true
                run_installation
                exit 0
                ;;
            4)
                update_singbox
                exit 0
                ;;
            5)
                uninstall_service
                exit 0
                ;;
            6)
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
    if [[ "$INSTALL_SHADOWTLS" == true || "$INSTALL_SS" == true ]]; then
        run_installation
    else
        # Show interactive menu
        show_menu
    fi
}

main "$@"