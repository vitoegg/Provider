#!/bin/bash
################################################################################
# Unified Shadowsocks Installation Script
# This script installs and manages Reality and SS2022 services using sing-box.
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
DEFAULT_REALITY_PORT_START=50000
DEFAULT_REALITY_PORT_END=60000
DEFAULT_SS_PORT_START=20000
DEFAULT_SS_PORT_END=40000

# Preset domains for Reality
PRESET_DOMAINS=(
    "www.1991991.xyz"
    "blog.hypai.org"
    "buylite.tv.apple.com"
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
INSTALL_REALITY=false
INSTALL_SS=false
REALITY_PORT=""
REALITY_UUID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
REALITY_DOMAIN=""
SS_PORT=""
SS_STANDALONE_PASSWORD=""

################################################################################
# Command-line arguments parser
################################################################################
parse_args() {
    local has_reality_params=false
    local has_ss_params=false
    local uninstall_requested=false
    
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --reality-port)
                REALITY_PORT="$2"
                has_reality_params=true
                shift 2
                ;;
            --reality-uuid)
                REALITY_UUID="$2"
                has_reality_params=true
                shift 2
                ;;
            --reality-private-key)
                REALITY_PRIVATE_KEY="$2"
                has_reality_params=true
                shift 2
                ;;
            --reality-public-key)
                REALITY_PUBLIC_KEY="$2"
                has_reality_params=true
                shift 2
                ;;
            --reality-short-id)
                REALITY_SHORT_ID="$2"
                has_reality_params=true
                shift 2
                ;;
            --reality-domain)
                REALITY_DOMAIN="$2"
                has_reality_params=true
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
            --install-reality)
                INSTALL_REALITY=true
                shift
                ;;
            --install-ss)
                INSTALL_SS=true
                shift
                ;;
            --install-both)
                INSTALL_REALITY=true
                INSTALL_SS=true
                shift
                ;;
            -u|--uninstall)
                uninstall_requested=true
                shift
                ;;
            --update)
                detect_arch
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
    if [[ "$INSTALL_REALITY" == false && "$INSTALL_SS" == false ]]; then
        log_info "Analyzing parameters for service detection..."
        log_info "Reality parameters detected: $has_reality_params"
        log_info "Shadowsocks parameters detected: $has_ss_params"
        
        if [[ "$has_reality_params" == true && "$has_ss_params" == true ]]; then
            # Both types of parameters provided
            INSTALL_REALITY=true
            INSTALL_SS=true
            log_info "Auto-detected both Reality and Shadowsocks installation from parameters"
        elif [[ "$has_reality_params" == true ]]; then
            # Only Reality parameters provided
            INSTALL_REALITY=true
            log_info "Auto-detected Reality installation from parameters"
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
    echo "  --install-reality       Install Reality service only"
    echo "  --install-ss            Install Shadowsocks service only"
    echo "  --install-both          Install both Reality and Shadowsocks services"
    echo ""
    echo "Configuration Options:"
    echo "  --reality-port PORT     Specify Reality port (50000-60000)"
    echo "  --reality-uuid UUID     Specify Reality UUID"
    echo "  --reality-private-key KEY  Specify Reality private key"
    echo "  --reality-public-key KEY   Specify Reality public key (optional)"
    echo "  --reality-short-id ID   Specify Reality short ID"
    echo "  --reality-domain DOMAIN Specify Reality domain"
    echo "  --ss-port PORT          Specify Shadowsocks port (20000-40000)"
    echo "  --ss-standalone-password PASS  Specify standalone Shadowsocks password"
    echo ""
    echo "Other Options:"
    echo "  --update                Update sing-box to latest version (preserves configuration)"
    echo "  --uninstall             Uninstall sing-box service and remove configuration"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Smart Detection:"
    echo "  The script can auto-detect which services to install based on parameters:"
    echo "  - Reality parameters: --reality-port, --reality-uuid, --reality-domain, etc."
    echo "  - Shadowsocks parameters: --ss-port, --ss-standalone-password"
    echo ""
    echo "Examples:"
    echo "  # Explicit installation"
    echo "  $0 --install-reality --reality-port 58568 --reality-domain www.microsoft.com"
    echo "  $0 --install-ss --ss-port 31606"
    echo "  $0 --install-both"
    echo ""
    echo "  # Auto-detection (recommended)"
    echo "  $0 --reality-port 58568 --reality-domain www.apple.com"
    echo "  $0 --ss-port 31606 --ss-standalone-password mypass"
    echo "  $0 --reality-port 58568 --ss-port 31606"
    echo ""
    echo "  # Update"
    echo "  $0 --update"
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
# Get current installed sing-box version
################################################################################
get_current_version() {
    if command -v sing-box >/dev/null 2>&1; then
        local version_output
        version_output=$(sing-box version 2>/dev/null | head -n1)
        if [[ -n "$version_output" ]]; then
            # Extract version number from output like "sing-box version 1.8.0"
            echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
        else
            echo ""
        fi
    else
        echo ""
    fi
}

################################################################################
# Compare two version strings (only numeric parts)
# Returns: 0 if equal, 1 if first > second, 2 if first < second
################################################################################
compare_versions() {
    local version1="$1"
    local version2="$2"
    
    # Remove any non-numeric prefixes (like 'v')
    version1=$(echo "$version1" | sed 's/^v//')
    version2=$(echo "$version2" | sed 's/^v//')
    
    # Extract only numeric version parts (x.y.z format)
    local v1_clean
    local v2_clean
    v1_clean=$(echo "$version1" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    v2_clean=$(echo "$version2" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    
    # If either version is empty, handle it
    if [[ -z "$v1_clean" || -z "$v2_clean" ]]; then
        return 0
    fi
    
    # Split versions into arrays
    IFS='.' read -ra V1 <<< "$v1_clean"
    IFS='.' read -ra V2 <<< "$v2_clean"
    
    # Compare each part
    for i in {0..2}; do
        local num1=${V1[i]:-0}
        local num2=${V2[i]:-0}
        
        if (( num1 > num2 )); then
            return 1  # version1 > version2
        elif (( num1 < num2 )); then
            return 2  # version1 < version2
        fi
    done
    
    return 0  # versions are equal
}

################################################################################
# Update sing-box to the latest version while preserving configuration
################################################################################
update_singbox() {
    print_header "Updating sing-box"
    
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
    
    # Backup current configuration
    local config_backup="/tmp/sing-box-config-backup.json"
    if [[ -f "/etc/sing-box/config.json" ]]; then
        log_info "Backing up current configuration..."
        cp "/etc/sing-box/config.json" "$config_backup"
        if [[ $? -eq 0 ]]; then
            log_success "Configuration backed up to: $config_backup"
        else
            log_error "Failed to backup configuration"
            return 1
        fi
    else
        log_warning "No existing configuration found to backup"
    fi
    
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
    
    # Download and install new version
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box_${latest_version#v}_linux_${ARCH}.deb"
    local temp_file="/tmp/sing-box-update.deb"
    
    log_info "Downloading sing-box $latest_version..."
    log_info "Download URL: $download_url"
    if ! wget --no-check-certificate -q -O "$temp_file" "$download_url"; then
        log_error "Failed to download sing-box from: $download_url"
        # Restore service if it was running
        if [[ "$service_was_running" == true ]]; then
            systemctl start sing-box >/dev/null 2>&1
        fi
        return 1
    fi
    
    log_info "Installing updated sing-box package..."
    if ! DEBIAN_FRONTEND=noninteractive dpkg -i "$temp_file" >/dev/null 2>&1; then
        log_error "Failed to install updated sing-box package"
        # Clean up and restore service
        rm -f "$temp_file"
        if [[ "$service_was_running" == true ]]; then
            systemctl start sing-box >/dev/null 2>&1
        fi
        return 1
    fi
    
    # Clean up download file
    rm -f "$temp_file"
    
    # Restore configuration
    if [[ -f "$config_backup" ]]; then
        log_info "Restoring configuration..."
        cp "$config_backup" "/etc/sing-box/config.json"
        if [[ $? -eq 0 ]]; then
            log_success "Configuration restored"
            rm -f "$config_backup"
        else
            log_error "Failed to restore configuration from backup"
            log_warning "Backup file preserved at: $config_backup"
        fi
    fi
    
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
        return 0
    else
        log_error "Update verification failed. Expected: ${latest_version#v}, Got: $new_version"
        return 1
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
# Generate 8-character hex string for short_id
################################################################################
generate_short_id() {
    printf "%08x" $((RANDOM * RANDOM))
}

################################################################################
# Interactive domain selection
################################################################################
select_domain() {
    echo "Available domains for Reality:"
    for i in "${!PRESET_DOMAINS[@]}"; do
        echo "  $((i+1)). ${PRESET_DOMAINS[$i]}"
    done
    
    while true; do
        read -p "Please select a domain (1-${#PRESET_DOMAINS[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#PRESET_DOMAINS[@]} ]]; then
            echo "${PRESET_DOMAINS[$((choice-1))]}"
            break
        else
            echo "Invalid choice. Please enter a number between 1 and ${#PRESET_DOMAINS[@]}."
        fi
    done
}

################################################################################
# Generate configuration parameters
################################################################################
generate_config_params() {
    print_header "Generating Configuration Parameters"
    
    # Generate Reality parameters if needed
    if [[ "$INSTALL_REALITY" == true ]]; then
        if [[ -z "$REALITY_PORT" ]]; then
            REALITY_PORT=$(generate_port "$DEFAULT_REALITY_PORT_START" "$DEFAULT_REALITY_PORT_END")
            log_info "Generated Reality port: $REALITY_PORT"
        else
            log_info "Using specified Reality port: $REALITY_PORT"
        fi
        
        if [[ -z "$REALITY_UUID" ]]; then
            REALITY_UUID=$(sing-box generate uuid)
            log_info "Generated Reality UUID"
        else
            log_info "Using specified Reality UUID"
        fi
        
        if [[ -z "$REALITY_PRIVATE_KEY" ]]; then
            local keypair_output
            keypair_output=$(sing-box generate reality-keypair)
            REALITY_PRIVATE_KEY=$(echo "$keypair_output" | grep "PrivateKey:" | awk '{print $2}')
            if [[ -z "$REALITY_PUBLIC_KEY" ]]; then
                REALITY_PUBLIC_KEY=$(echo "$keypair_output" | grep "PublicKey:" | awk '{print $2}')
            fi
            log_info "Generated Reality key pair"
        else
            log_info "Using specified Reality private key"
        fi
        
        if [[ -z "$REALITY_SHORT_ID" ]]; then
            REALITY_SHORT_ID=$(generate_short_id)
            log_info "Generated Reality short ID: $REALITY_SHORT_ID"
        else
            log_info "Using specified Reality short ID: $REALITY_SHORT_ID"
        fi
        
        if [[ -z "$REALITY_DOMAIN" ]]; then
            if [[ "$INSTALL_REALITY" == true && "$INSTALL_SS" == false ]]; then
                # Interactive mode for Reality-only installation
                REALITY_DOMAIN=$(select_domain)
            else
                # Auto-select for batch installation
                local random_index=$((RANDOM % ${#PRESET_DOMAINS[@]}))
                REALITY_DOMAIN="${PRESET_DOMAINS[$random_index]}"
            fi
            log_info "Selected Reality domain: $REALITY_DOMAIN"
        else
            log_info "Using specified Reality domain: $REALITY_DOMAIN"
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
    
    local config_file="/etc/sing-box/config.json"
    local inbounds="[]"
    
    # Build inbounds array
    if [[ "$INSTALL_REALITY" == true && "$INSTALL_SS" == true ]]; then
        # Both services
        inbounds='[
    {
      "type": "vless",
      "listen": "::",
      "listen_port": '$REALITY_PORT',
      "users": [
        {
          "uuid": "'$REALITY_UUID'",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "'$REALITY_DOMAIN'",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "'$REALITY_DOMAIN'",
            "server_port": 443
          },
          "private_key": "'$REALITY_PRIVATE_KEY'",
          "short_id": [
            "'$REALITY_SHORT_ID'"
          ]
        }
      }
    },
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": '$SS_PORT',
      "method": "aes-128-gcm",
      "password": "'$SS_STANDALONE_PASSWORD'"
    }
  ]'
    elif [[ "$INSTALL_REALITY" == true ]]; then
        # Reality only
        inbounds='[
    {
      "type": "vless",
      "listen": "::",
      "listen_port": '$REALITY_PORT',
      "users": [
        {
          "uuid": "'$REALITY_UUID'",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "'$REALITY_DOMAIN'",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "'$REALITY_DOMAIN'",
            "server_port": 443
          },
          "private_key": "'$REALITY_PRIVATE_KEY'",
          "short_id": [
            "'$REALITY_SHORT_ID'"
          ]
        }
      }
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
    
    if [[ "$INSTALL_REALITY" == true ]]; then
        echo ""
        echo -e "${BOLD}Reality Configuration:${NC}"
        printf "%-25s %s\n" "Reality Port:" "$REALITY_PORT"
        printf "%-25s %s\n" "UUID:" "$REALITY_UUID"
        if [[ -n "$REALITY_PUBLIC_KEY" ]]; then
            printf "%-25s %s\n" "PublicKey:" "$REALITY_PUBLIC_KEY"
        fi
        printf "%-25s %s\n" "Short ID:" "$REALITY_SHORT_ID"
        printf "%-25s %s\n" "Domain:" "$REALITY_DOMAIN"
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
# Verify system package manager health
################################################################################
verify_package_manager_health() {
    log_info "Verifying package manager health..."
    
    # Check if dpkg is locked
    if [[ -f "/var/lib/dpkg/lock-frontend" ]] || [[ -f "/var/lib/dpkg/lock" ]]; then
        local lock_count=0
        while [[ -f "/var/lib/dpkg/lock-frontend" ]] || [[ -f "/var/lib/dpkg/lock" ]]; do
            if [[ $lock_count -ge 30 ]]; then
                log_error "Package manager is locked. Please wait for other package operations to complete."
                return 1
            fi
            log_info "Waiting for package manager to be available... ($((lock_count + 1))/30)"
            sleep 2
            ((lock_count++))
        done
    fi
    
    # Check dpkg status
    if ! dpkg --audit >/dev/null 2>&1; then
        log_warning "Found dpkg issues, attempting to fix..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            log_error "Failed to fix dpkg issues. Please run: sudo dpkg --configure -a"
            return 1
        fi
    fi
    
    # Test basic package operations
    if ! dpkg -l >/dev/null 2>&1; then
        log_error "Package manager is not functioning properly"
        return 1
    fi
    
    log_success "Package manager is healthy"
    return 0
}

################################################################################
# Uninstall sing-box service
################################################################################
uninstall_service() {
    print_header "Uninstalling sing-box"
    
    # Verify package manager health before proceeding
    if ! verify_package_manager_health; then
        log_error "Cannot proceed with uninstallation due to package manager issues"
        exit 1
    fi
    
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
    
    # Completely remove sing-box package with all configuration files
    log_info "Completely removing sing-box package..."
    if dpkg -l | grep -q "^ii.*sing-box" 2>/dev/null; then
        # First try normal purge
        if ! DEBIAN_FRONTEND=noninteractive dpkg --purge sing-box >/dev/null 2>&1; then
            log_warning "Normal purge failed, forcing removal..."
            # Force removal if normal purge fails
            DEBIAN_FRONTEND=noninteractive dpkg --remove --force-remove-reinstreq sing-box >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive dpkg --purge --force-remove-reinstreq sing-box >/dev/null 2>&1
        fi
        log_success "Package completely removed"
    else
        log_info "Package is not installed"
    fi
    
    # Clean up any remaining configuration files
    log_info "Removing configuration files and directories..."
    local config_paths=(
        "/etc/sing-box"
        "/var/lib/sing-box"
        "/var/log/sing-box"
        "/run/sing-box"
    )
    
    for path in "${config_paths[@]}"; do
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
    
    # Fix potential apt/dpkg database issues
    log_info "Fixing package manager database..."
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -f install -y >/dev/null 2>&1
        log_success "Package manager database fixed"
    fi
    
    # Clean up temporary files from this script
    cleanup_temp_files
    
    # Final verification of package manager health
    log_info "Performing final system health check..."
    if ! verify_package_manager_health; then
        log_warning "Package manager health check failed after uninstallation"
        log_warning "You may need to run: sudo dpkg --configure -a && sudo apt-get -f install"
    else
        log_success "System package manager is functioning normally"
    fi
    
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
        echo "1. Install Reality only"
        echo "2. Install Shadowsocks only"
        echo "3. Install both Reality and Shadowsocks"
        echo "4. Update sing-box to latest version"
        echo "5. Uninstall services"
        echo "6. Exit"
        echo -e "=====================================\n"
        read -p "Please select an option (1-6): " choice
        
        case $choice in
            1)
                INSTALL_REALITY=true
                INSTALL_SS=false
                run_installation
                exit 0
                ;;
            2)
                INSTALL_REALITY=false
                INSTALL_SS=true
                run_installation
                exit 0
                ;;
            3)
                INSTALL_REALITY=true
                INSTALL_SS=true
                run_installation
                exit 0
                ;;
            4)
                detect_arch
                update_singbox
                read -p "Press Enter to continue..."
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
    if [[ "$INSTALL_REALITY" == true || "$INSTALL_SS" == true ]]; then
        run_installation
    else
        # Show interactive menu
        show_menu
    fi
}

main "$@" 