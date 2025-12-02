#!/bin/bash
################################################################################
# AnyTLS Installation Script
# This script installs and manages AnyTLS service using Singbox.
# It provides friendly output messages and supports both CLI and interactive modes.
################################################################################

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'     # No Color
BOLD='\033[1m'

# Default port range
DEFAULT_PORT_START=50000
DEFAULT_PORT_END=60000

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
PORT=""
PASSWORD=""
DOMAIN=""
SINGBOX_VERSION=""
TOKEN=""

################################################################################
# Command-line arguments parser
################################################################################
parse_args() {
    local uninstall_requested=false
    
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --port)
                PORT="$2"
                shift 2
                ;;
            --password)
                PASSWORD="$2"
                shift 2
                ;;
            --domain)
                DOMAIN="$2"
                shift 2
                ;;
            --version)
                SINGBOX_VERSION="$2"
                shift 2
                ;;
            --token)
                TOKEN="$2"
                shift 2
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
}

################################################################################
# Show usage information
################################################################################
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Configuration Options:"
    echo "  --port PORT             Specify AnyTLS port (default: auto-generated 50000-60000)"
    echo "  --password PASS         Specify AnyTLS password (default: auto-generated)"
    echo "  --domain DOMAIN         Specify domain name (required if not provided interactively)"
    echo "  --token TOKEN           Specify Cloudflare API Token for DNS-01 certificate challenge"
    echo "  --version VERSION       Specify Singbox version to install (e.g., v1.8.0 or 1.8.0)"
    echo ""
    echo "Management Options:"
    echo "  --update                Update Singbox to the latest version"
    echo "  -u, --uninstall         Uninstall Singbox service and remove configuration"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Install with all parameters specified (including Cloudflare token)"
    echo "  $0 --port 52555 --password mypass123 --domain api.example.com --token YOUR_CF_TOKEN"
    echo ""
    echo "  # Install with partial parameters (others will be auto-generated or prompted)"
    echo "  $0 --domain api.example.com --token YOUR_CF_TOKEN"
    echo "  $0 --port 52555 --domain api.example.com"
    echo ""
    echo "  # Install with specific version"
    echo "  $0 --domain api.example.com --version v1.8.0"
    echo ""
    echo "  # Update or Uninstall"
    echo "  $0 --update"
    echo "  $0 --uninstall"
    echo ""
    echo "  # Interactive mode (no parameters)"
    echo "  $0"
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
    local packages_needed=(wget dpkg jq openssl tar)
    
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
# Download and install Singbox
################################################################################
install_singbox() {
    print_header "Installing Singbox"
    
    # Check if Singbox is already installed and running
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        log_warning "Singbox service is already installed and running."
        log_warning "If you want to reinstall, please uninstall first."
        return 0
    fi
    
    # Determine version to install
    local target_version
    if [[ -n "$SINGBOX_VERSION" ]]; then
        # Use specified version
        target_version="$SINGBOX_VERSION"
        # Ensure version starts with 'v' prefix for consistency
        if [[ ! "$target_version" =~ ^v ]]; then
            target_version="v$target_version"
        fi
        log_info "Using specified version: $target_version"
    else
        # Get latest version online
        log_info "Fetching latest version from GitHub..."
        target_version=$(wget -qO- --timeout=10 --tries=3 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r .tag_name)
        if [[ -z "$target_version" ]]; then
            log_error "Failed to retrieve Singbox release version"
            exit 1
        fi
        log_info "Latest available version: $target_version"
    fi
    
    log_info "Installing Singbox version: $target_version"
    
    # Download .deb package
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${target_version}/sing-box_${target_version#v}_linux_${ARCH}.deb"
    local temp_file="/tmp/sing-box.deb"
    
    log_info "Download URL: $download_url"
    log_info "Downloading Singbox package..."
    if ! wget --no-check-certificate -q -O "$temp_file" "$download_url"; then
        log_error "Failed to download Singbox from: $download_url"
        log_error "Please check if the URL is correct and accessible"
        exit 1
    fi
    
    # Install package
    log_info "Installing Singbox package..."
    if ! DEBIAN_FRONTEND=noninteractive dpkg -i "$temp_file" >/dev/null 2>&1; then
        log_error "Failed to install Singbox package!"
        # Clean up on failure
        rm -f "$temp_file"
        exit 1
    fi
    
    # Clean up temporary file
    rm -f "$temp_file"
    log_info "Cleaned up temporary files"
    
    log_success "Singbox installation completed"
}

################################################################################
# Update Singbox (Binary Replacement)
################################################################################
update_singbox() {
    print_header "Updating Singbox (Binary Replacement)"
    
    # Check if Singbox is installed
    if ! command -v sing-box >/dev/null 2>&1; then
        log_error "Singbox is not installed. Please install it first."
        return 1
    fi
    
    # Detect architecture
    detect_arch
    
    # Ensure required packages are installed
    install_packages
    
    # Get current version
    local current_version
    current_version=$(get_current_version)
    if [[ -z "$current_version" ]]; then
        log_error "Failed to get current Singbox version"
        return 1
    fi
    log_info "Current version: $current_version"
    
    # Get latest version
    local latest_version
    latest_version=$(wget -qO- --timeout=10 --tries=3 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r .tag_name)
    if [[ -z "$latest_version" ]]; then
        log_error "Failed to retrieve latest Singbox version"
        return 1
    fi
    log_info "Latest version: $latest_version"
    
    # Compare versions
    compare_versions "$latest_version" "$current_version"
    local comparison_result=$?
    
    case $comparison_result in
        0)
            log_info "Singbox is already up to date (version $current_version)"
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
    
    # Stop Singbox service
    local service_was_running=false
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        service_was_running=true
        log_info "Stopping Singbox service for update..."
        if ! systemctl stop sing-box >/dev/null 2>&1; then
            log_error "Failed to stop Singbox service"
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
    
    log_info "Downloading Singbox binary $latest_version..."
    log_info "Download URL: $download_url"
    if ! wget --no-check-certificate -q -O "$temp_archive" "$download_url"; then
        log_error "Failed to download Singbox from: $download_url"
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
        log_error "Failed to extract Singbox archive"
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
        log_error "Singbox binary not found in archive"
        # Clean up and restore service
        rm -rf "$temp_archive" "$temp_dir"
        if [[ "$service_was_running" == true ]]; then
            systemctl start sing-box >/dev/null 2>&1
        fi
        return 1
    fi
    
    # Replace binary
    log_info "Replacing Singbox binary..."
    if ! cp "$binary_file" "/usr/bin/sing-box"; then
        log_error "Failed to replace Singbox binary"
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
    
    # Verify binary version before starting service
    print_header "Verifying Update"
    local new_version
    new_version=$(get_current_version)
    if [[ -z "$new_version" ]]; then
        log_error "Failed to get new Singbox version"
        return 1
    fi
    
    if [[ "$new_version" != "${latest_version#v}" ]]; then
        log_error "Version mismatch. Expected: ${latest_version#v}, Got: $new_version"
        return 1
    fi
    log_success "Binary version verified: $new_version"
    
    # Ensure service is started (regardless of previous state)
    log_info "Starting Singbox service..."
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        log_info "Service is already running, restarting..."
        if ! systemctl restart sing-box >/dev/null 2>&1; then
            log_error "Failed to restart Singbox service"
            log_error "Check logs with: journalctl -u sing-box"
            return 1
        fi
    else
        if ! systemctl start sing-box >/dev/null 2>&1; then
            log_error "Failed to start Singbox service"
            log_error "Check logs with: journalctl -u sing-box"
            return 1
        fi
    fi
    
    # Wait for service to stabilize
    log_info "Waiting for service to stabilize..."
    sleep 3
    
    # Verify service status
    if ! systemctl is-active --quiet sing-box; then
        log_error "Singbox service is not running after update"
        log_error "Check logs with: journalctl -u sing-box"
        return 1
    fi
    log_success "Service is running"
    
    # Final verification: Check running service version
    log_info "Verifying running service version..."
    local running_version
    running_version=$(sing-box version 2>/dev/null | head -n1 | awk '{print $3}' | sed 's/^v//')
    
    if [[ -z "$running_version" ]]; then
        log_warning "Could not verify running version, but service is active"
    elif [[ "$running_version" == "${latest_version#v}" ]]; then
        log_success "Running version confirmed: $running_version"
    else
        log_warning "Running version ($running_version) differs from expected (${latest_version#v}), but service is active"
    fi
    
    # Display service status
    echo ""
    systemctl status sing-box --no-pager --lines=5
    echo ""
    
    log_success "Update completed successfully"
    log_success "Singbox updated from $current_version to $new_version"
    log_info "Update method: Binary replacement"
    return 0
}

################################################################################
# Generate configuration parameters
################################################################################
generate_config_params() {
    print_header "Generating Configuration Parameters"
    
    # Generate port if not specified
    if [[ -z "$PORT" ]]; then
        PORT=$(generate_port "$DEFAULT_PORT_START" "$DEFAULT_PORT_END")
        log_info "Generated port: $PORT"
    else
        log_info "Using specified port: $PORT"
    fi
    
    # Generate password if not specified
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        log_info "Generated password"
    else
        log_info "Using specified password"
    fi
    
    # Prompt for domain if not specified
    if [[ -z "$DOMAIN" ]]; then
        echo ""
        read -p "Please enter your domain name: " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            log_error "Domain name is required!"
            exit 1
        fi
        log_info "Using domain: $DOMAIN"
    else
        log_info "Using specified domain: $DOMAIN"
    fi
    
    # Prompt for Cloudflare API Token if not specified
    if [[ -z "$TOKEN" ]]; then
        echo ""
        log_info "DNS-01 certificate challenge requires Cloudflare API Token"
        read -p "Please enter your Cloudflare API Token: " TOKEN
        if [[ -z "$TOKEN" ]]; then
            log_error "Cloudflare API Token is required for DNS-01 certificate challenge!"
            exit 1
        fi
        log_info "Cloudflare API Token configured"
    else
        log_info "Using specified Cloudflare API Token"
    fi
    
    log_success "Configuration parameters ready"
}

################################################################################
# Create Singbox configuration
################################################################################
create_singbox_config() {
    print_header "Creating Singbox Configuration"
    
    # Clean existing configuration before creating new one
    clean_sing_box_config
    
    local config_file="/etc/sing-box/config.json"
    
    # Create AnyTLS configuration file
    cat > "$config_file" << EOF
{
  "log": {
    "disabled": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "name": "AnyCloud",
          "password": "$PASSWORD"
        }
      ],
      "padding_scheme": [
        "stop=8",
        "0=30-30",
        "1=100-300",
        "2=300-600,c,800-1200,c,1000-1500",
        "3=200-500,c,800-1200",
        "4=50-100,c,500-1000",
        "5=50-100,c,500-1000",
        "6=50-100,c,500-1000",
        "7=50-100,c,500-1000"
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h2",
          "http/1.1"
        ],
        "server_name": "$DOMAIN",
        "acme": {
          "domain": [
            "$DOMAIN"
          ],
          "email": "admin@xinsight.eu.org",
          "provider": "letsencrypt",
          "dns01_challenge": {
            "provider": "cloudflare",
            "api_token": "$TOKEN"
          }
        }
      }
    }
  ]
}
EOF
    
    log_success "Configuration file created: $config_file"
}

################################################################################
# Start and enable Singbox service
################################################################################
start_singbox_service() {
    print_header "Starting Singbox Service"
    
    log_info "Enabling Singbox service..."
    if ! systemctl enable sing-box >/dev/null 2>&1; then
        log_error "Failed to enable Singbox service"
        exit 1
    fi
    
    log_info "Starting Singbox service..."
    if ! systemctl start sing-box >/dev/null 2>&1; then
        log_error "Failed to start Singbox service"
        exit 1
    fi
    
    # Wait a moment for service to start
    sleep 2
    
    # Check service status
    if ! systemctl is-active --quiet sing-box; then
        log_error "Singbox service failed to start!"
        log_error "Check logs with: journalctl -u sing-box"
        exit 1
    fi
    
    log_success "Singbox service started successfully"
}

################################################################################
# Display configuration information
################################################################################
show_configuration() {
    print_header "Installation Status"
    echo "------------------------------------"
    echo -e "${BOLD}Singbox Service Status:${NC}"
    systemctl status sing-box --no-pager
    echo "------------------------------------"

    print_header "Configuration Details"
    local server_ip
    server_ip=$(get_ipv4_address)
    
    echo ""
    echo -e "${BOLD}AnyTLS Configuration:${NC}"
    printf "%-25s %s\n" "Server IP:" "$server_ip"
    printf "%-25s %s\n" "Port:" "$PORT"
    printf "%-25s %s\n" "Password:" "$PASSWORD"
    printf "%-25s %s\n" "Domain:" "$DOMAIN"
    
    echo "=================================="
    echo ""
}

################################################################################
# Clean Singbox configuration files and directories
################################################################################
clean_sing_box_config() {
    log_info "Cleaning existing Singbox configuration..."
    
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
# Uninstall Singbox service
################################################################################
uninstall_service() {
    print_header "Uninstalling Singbox"
    
    # Stop and disable service
    log_info "Stopping and disabling Singbox service..."
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        if ! systemctl stop sing-box >/dev/null 2>&1; then
            log_warning "Failed to stop Singbox service gracefully, forcing stop..."
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
    
    # Remove Singbox package
    log_info "Removing Singbox package..."
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
    
    # Clean up any Singbox binary if it still exists
    log_info "Removing Singbox binary..."
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
    log_info "All Singbox components have been removed from the system"
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
        print_header "AnyTLS Installation Script"
        echo "1. Install AnyTLS service"
        echo "2. Update Singbox"
        echo "3. Uninstall Singbox service"
        echo "4. Exit Script"
        echo -e "=====================================\n"
        read -p "Please select an option (1-4): " choice
        
        case $choice in
            1)
                run_installation
                exit 0
                ;;
            2)
                update_singbox
                exit 0
                ;;
            3)
                uninstall_service
                exit 0
                ;;
            4)
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
    log_info "AnyTLS Installation Script v1.0"
    log_info "Operating System: $(uname -s) $(uname -r)"
    log_info "Architecture: $(uname -m)"
    
    # Parse command line arguments
    parse_args "$@"
    
    # If any configuration parameters are provided, run installation
    if [[ -n "$PORT" || -n "$PASSWORD" || -n "$DOMAIN" || -n "$TOKEN" ]]; then
        run_installation
    else
        # Show interactive menu
        show_menu
    fi
}

main "$@"