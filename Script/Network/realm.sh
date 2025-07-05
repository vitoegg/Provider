#!/usr/bin/env bash

# Realm TCP/UDP Forwarding Management Script
# Version: 2.4
# Description: Install, configure and manage Realm forwarding service with multiple endpoints support
# Requirements: Root privileges only
# Improvements: Added placeholder endpoint structure to ensure service can start without active rules

# Check root privileges immediately
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m This script must be run as root user"
    echo "Please run: sudo $0"
    exit 1
fi

# Set secure PATH
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# Color definitions for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Configuration constants
readonly CONF_FILE="/etc/realm/config.toml"
readonly BINARY_PATH="/usr/local/bin/realm"
readonly LOG_FILE="/var/log/realm.log"

# Determine systemd service path based on system
if [ -d "/usr/lib/systemd/system" ]; then
    readonly SYSTEMD_PATH="/usr/lib/systemd/system/realm.service"
elif [ -d "/lib/systemd/system" ]; then
    readonly SYSTEMD_PATH="/lib/systemd/system/realm.service"
else
    echo -e "${RED}[ERROR]${NC} systemd directory not found"
    exit 1
fi

# Logging functions with different levels
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1" >&2
}

log_success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1" >&2
}

# Print formatted section headers
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}" >&2
}

# Print formatted divider
print_divider() {
    echo -e "${YELLOW}──────────────────────────────${NC}" >&2
}

# Unified download function, prioritize curl, fallback to wget
download_file() {
    local url="$1"
    local output="$2"
    
    # Try curl first
    if command -v curl >/dev/null 2>&1; then
        if curl -L -o "$output" "$url" 2>/dev/null; then
            return 0
        fi
    fi
    
    # If curl fails or doesn't exist, try wget
    if command -v wget >/dev/null 2>&1; then
        if wget --no-check-certificate -O "$output" "$url" 2>/dev/null; then
            return 0
        fi
    fi
    
    # If both fail, return error
    return 1
}

# Simplified tool installation function
install_required_tools() {
    log_info "Checking required tools..."
    
    # Check if download tool exists
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        log_warn "No download tool found, installing curl..."
        
        # Detect package manager and install curl
        if command -v apt >/dev/null 2>&1; then
            apt update -y && apt install -y curl
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl
        else
            log_error "Cannot identify package manager. Please install curl or wget manually"
            exit 1
        fi
        
        # Verify installation
        if ! command -v curl >/dev/null 2>&1; then
            log_error "Failed to install curl"
            exit 1
        fi
        
        log_success "curl installed successfully"
    fi
    
    # Check tar tool
    if ! command -v tar >/dev/null 2>&1; then
        log_warn "tar not found, installing..."
        
        if command -v apt >/dev/null 2>&1; then
            apt install -y tar
        elif command -v yum >/dev/null 2>&1; then
            yum install -y tar
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y tar
        else
            log_error "Cannot install tar. Please install it manually"
            exit 1
        fi
        
        if ! command -v tar >/dev/null 2>&1; then
            log_error "Failed to install tar"
            exit 1
        fi
        
        log_success "tar installed successfully"
    fi
    
    log_success "All required tools are available"
}

# Check if Realm is installed
is_realm_installed() {
    [[ -f "$BINARY_PATH" && -f "$CONF_FILE" ]]
}

# Detect system architecture
detect_system_architecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "x86_64"
            ;;
        aarch64)
            echo "aarch64"
            ;;
        *)
            log_error "Unsupported system architecture: $arch"
            exit 1
            ;;
    esac
}

# Get latest Realm version from GitHub
get_latest_realm_version() {
    log_info "Checking latest Realm version..."
    
    # Use unified download function to get version info
    local temp_file=$(mktemp)
    
    if ! download_file "https://api.github.com/repos/zhboner/realm/releases/latest" "$temp_file"; then
        log_error "Failed to fetch version information"
        rm -f "$temp_file"
        exit 1
    fi
    
    local version=$(grep tag_name "$temp_file" | cut -d ":" -f2 | sed 's/\"//g;s/\,//g;s/\ //g;s/v//')
    rm -f "$temp_file"
    
    if [[ -z "$version" ]]; then
        log_error "Failed to parse version information"
        exit 1
    fi
    
    echo "$version"
}

# Download and install Realm binary
download_and_install_realm() {
    local arch="$1"
    local version="$2"
    
    print_header "Downloading Realm"
    
    # Construct download URL
    local download_url="https://github.com/zhboner/realm/releases/download/v${version}/realm-${arch}-unknown-linux-gnu.tar.gz"
    local temp_file="realm.tar.gz"
    
    log_info "Downloading Realm v${version} for ${arch}..."
    
    # Use unified download function
    if ! download_file "$download_url" "$temp_file"; then
        log_error "Download failed"
        exit 1
    fi
    
    # Extract and install binary
    log_info "Installing Realm binary..."
    local temp_dir=$(mktemp -d)
    
    if ! tar -xzf "$temp_file" -C "$temp_dir"; then
        log_error "Failed to extract archive"
        rm -rf "$temp_dir" "$temp_file"
        exit 1
    fi
    
    # Install binary with proper permissions
    chmod 755 "$temp_dir/realm"
    if ! mv "$temp_dir/realm" "$BINARY_PATH"; then
        log_error "Failed to install binary"
        rm -rf "$temp_dir" "$temp_file"
        exit 1
    fi
    
    # Cleanup
    rm -rf "$temp_dir" "$temp_file"
    
    # Verify installation
    if [[ ! -x "$BINARY_PATH" ]]; then
        log_error "Installation verification failed"
        exit 1
    fi
    
    log_success "Realm binary installed successfully"
}

# Check if Realm service is running
is_realm_running() {
    systemctl is-active --quiet realm 2>/dev/null
}

# Create systemd service
create_systemd_service() {
    log_info "Creating systemd service..."
    
    # Create service directory if needed
    mkdir -p "$(dirname "$SYSTEMD_PATH")"
    
    # Generate service file
    cat > "$SYSTEMD_PATH" << EOF
[Unit]
Description=Realm TCP/UDP Forwarding Service
After=network.target
Before=network-online.target
StartLimitBurst=0
StartLimitIntervalSec=60

[Service]
Type=simple
LimitNOFILE=65536
ExecStart=$BINARY_PATH -c $CONF_FILE
Restart=always
RestartSec=2
TimeoutStopSec=15
WorkingDirectory=$(dirname "$CONF_FILE")

[Install]
WantedBy=multi-user.target
EOF
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create systemd service"
        exit 1
    fi
    
    log_success "Systemd service created"
}

# Start and enable service
start_realm_service() {
    log_info "Starting Realm service..."
    
    # Reload systemd configuration
    systemctl daemon-reload
    
    # Enable service for auto-start
    if ! systemctl enable realm; then
        log_error "Failed to enable Realm service"
        exit 1
    fi
    
    # Start service
    if ! systemctl start realm; then
        log_error "Failed to start Realm service"
        exit 1
    fi
    
    # Verify service status
    sleep 2
    if systemctl is-active --quiet realm; then
        log_success "Realm service started successfully"
    else
        log_error "Realm service failed to start properly"
        log_info "Check logs with: journalctl -u realm -f"
        exit 1
    fi
}

# Get user input for forwarding rule configuration
get_forwarding_rule() {
    local port=""
    local remote_address=""
    
    # Get port (will be used for both listening and remote)
    while true; do
        read -p "Enter port (1024-65535) or 'cancel' to abort: " port
        
        # Check if user wants to cancel
        if [[ "$port" == "cancel" ]]; then
            return 1
        fi
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
            # Check if port is already in use
            if check_port_in_use "$port"; then
                log_error "Port $port is already in use in configuration"
                continue
            fi
            break
        else
            log_error "Invalid port. Please enter a number between 1024-65535"
        fi
    done

    # Get remote server address
    while true; do
        read -p "Enter remote server address (IP or domain) or 'cancel' to abort: " remote_address
        
        # Check if user wants to cancel
        if [[ "$remote_address" == "cancel" ]]; then
            return 1
        fi
        if [[ -n "$remote_address" ]]; then
            break
        else
            log_error "Remote address cannot be empty"
        fi
    done

    # Return configuration info (port is used for both listening and remote)
    echo "$port|$remote_address|$port"
}

# Check if port is already in use in configuration file
check_port_in_use() {
    local port="$1"
    if [[ -f "$CONF_FILE" ]]; then
        # Check for real endpoints (0.0.0.0), not placeholder (127.0.0.1)
        grep -q "listen = \"0.0.0.0:$port\"" "$CONF_FILE"
    else
        return 1
    fi
}

# Generate base configuration file (with placeholder endpoint structure)
generate_base_configuration() {
    log_info "Generating base configuration file..."
    
    # Create configuration directory
    mkdir -p "$(dirname "$CONF_FILE")"
    
    # Generate base configuration with placeholder endpoint structure
    cat > "$CONF_FILE" << EOF
[log]
level = "warn"
output = "$LOG_FILE"

[network]
no_tcp = false
use_udp = true

# Placeholder endpoint - will be replaced when adding first rule
# This ensures the service can start even without active forwarding rules
[[endpoints]]
listen = "127.0.0.1:65534"
remote = "127.0.0.1:65535"

EOF
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create configuration file"
        exit 1
    fi
    
    log_success "Base configuration file created at $CONF_FILE"
}

# Add forwarding rule to configuration file
add_endpoint_to_config() {
    local listen_port="$1"
    local remote_address="$2"
    local remote_port="$3"
    
    log_info "Adding forwarding rule: $listen_port -> $remote_address:$remote_port"
    
    # If configuration file doesn't exist, create base configuration
    if [[ ! -f "$CONF_FILE" ]]; then
        generate_base_configuration
    fi
    
    # Check if this is the first real rule (replacing placeholder)
    local has_placeholder=false
    if grep -q "listen = \"127.0.0.1:65534\"" "$CONF_FILE" 2>/dev/null; then
        has_placeholder=true
    fi
    
    if [[ "$has_placeholder" == true ]]; then
        # Replace placeholder with first real rule
        log_info "Replacing placeholder configuration with first real rule"
        
        # Create temporary file with new configuration
        local temp_file=$(mktemp)
        
        # Copy everything except the placeholder endpoint
        awk '
        /^\[\[endpoints\]\]$/ { 
            in_placeholder = 1
            next
        }
        /^listen = "127\.0\.0\.1:65534"$/ && in_placeholder { 
            next
        }
        /^remote = "127\.0\.0\.1:65535"$/ && in_placeholder { 
            in_placeholder = 0
            next
        }
        /^$/ && in_placeholder {
            in_placeholder = 0
            next
        }
        { 
            if (!in_placeholder) print
        }
        ' "$CONF_FILE" > "$temp_file"
        
        # Add the new real endpoint
        cat >> "$temp_file" << EOF
[[endpoints]]
listen = "0.0.0.0:${listen_port}"
remote = "${remote_address}:${remote_port}"

EOF
        
        # Replace original file
        if mv "$temp_file" "$CONF_FILE"; then
            log_success "Placeholder configuration replaced with real forwarding rule"
        else
            rm -f "$temp_file"
            log_error "Failed to replace placeholder configuration"
            exit 1
        fi
    else
        # Add new endpoint to existing configuration
        cat >> "$CONF_FILE" << EOF
[[endpoints]]
listen = "0.0.0.0:${listen_port}"
remote = "${remote_address}:${remote_port}"

EOF
        
        if [[ $? -ne 0 ]]; then
            log_error "Failed to add endpoint to configuration file"
            exit 1
        fi
        
        log_success "Forwarding rule added successfully"
    fi
}

# Display current forwarding rules
show_current_rules() {
    print_header "Current Forwarding Rules"
    
    if [[ ! -f "$CONF_FILE" ]]; then
        log_warn "Configuration file not found. No rules configured."
        return
    fi
    
    # Extract all endpoints
    local rules=()
    local count=0
    
    # Use awk to parse endpoints in TOML file, excluding placeholder
    while IFS= read -r line; do
        if [[ "$line" =~ listen\ =\ \"0\.0\.0\.0:([0-9]+)\" ]]; then
            local listen_port="${BASH_REMATCH[1]}"
            # Read next line to get remote
            read -r next_line
            if [[ "$next_line" =~ remote\ =\ \"(.+)\" ]]; then
                local remote="${BASH_REMATCH[1]}"
                count=$((count + 1))
                rules+=("$count. Port: $listen_port -> Destination: $remote")
            fi
        fi
    done < <(grep -A1 "listen = " "$CONF_FILE" | grep -v "127.0.0.1:65534")
    
    if [[ ${#rules[@]} -eq 0 ]]; then
        log_warn "No forwarding rules found in configuration"
        return
    fi
    
    echo -e "${CYAN}Found ${#rules[@]} forwarding rule(s):${NC}"
    echo ""
    for rule in "${rules[@]}"; do
        echo -e "  ${GREEN}$rule${NC}"
    done
    echo ""
    
    # Display service status
    if is_realm_running; then
        echo -e "${GREEN}✓ Realm service is running${NC}"
    else
        echo -e "${RED}✗ Realm service is not running${NC}"
    fi
}

# Get list of forwarding rules for removal
get_rule_list() {
    if [[ ! -f "$CONF_FILE" ]]; then
        return 1
    fi
    
    local rules=()
    local count=0
    
    # Use awk to parse endpoints in TOML file, excluding placeholder
    while IFS= read -r line; do
        if [[ "$line" =~ listen\ =\ \"0\.0\.0\.0:([0-9]+)\" ]]; then
            local listen_port="${BASH_REMATCH[1]}"
            # Read next line to get remote
            read -r next_line
            if [[ "$next_line" =~ remote\ =\ \"(.+)\" ]]; then
                local remote="${BASH_REMATCH[1]}"
                count=$((count + 1))
                rules+=("$listen_port|$remote")
            fi
        fi
    done < <(grep -A1 "listen = " "$CONF_FILE" | grep -v "127.0.0.1:65534")
    
    if [[ ${#rules[@]} -eq 0 ]]; then
        return 1
    fi
    
    # Print rules for selection
    echo -e "${CYAN}Current forwarding rules:${NC}"
    echo ""
    for i in "${!rules[@]}"; do
        IFS='|' read -r port remote <<< "${rules[$i]}"
        echo -e "  ${GREEN}$((i+1))${NC}. Port: ${YELLOW}$port${NC} -> Destination: ${YELLOW}$remote${NC}"
    done
    echo ""
    
    echo "${#rules[@]}"
}

# Remove forwarding rule by index
remove_rule_by_index() {
    local rule_index="$1"
    
    if [[ ! -f "$CONF_FILE" ]]; then
        log_error "Configuration file not found"
        return 1
    fi
    
    # Create temporary file
    local temp_file=$(mktemp)
    local current_index=0
    local in_target_endpoint=false
    local skip_next=false
    local rule_found=false
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[\[endpoints\]\]$ ]]; then
            current_index=$((current_index + 1))
            if [[ $current_index -eq $rule_index ]]; then
                in_target_endpoint=true
                skip_next=true
                rule_found=true
                continue
            fi
            in_target_endpoint=false
        elif [[ "$line" =~ ^listen\ = ]]; then
            if [[ $in_target_endpoint == true ]]; then
                skip_next=true
                continue
            fi
        elif [[ "$line" =~ ^remote\ = ]]; then
            if [[ $in_target_endpoint == true ]]; then
                in_target_endpoint=false
                skip_next=false
                continue
            fi
        elif [[ "$line" =~ ^$ ]]; then
            # Empty line
            if [[ $skip_next == true ]]; then
                skip_next=false
                continue
            fi
        fi
        
        echo "$line" >> "$temp_file"
    done < "$CONF_FILE"
    
    # Check if rule was found and removed
    if [[ "$rule_found" == false ]]; then
        rm -f "$temp_file"
        return 1
    fi
    
    # Replace original file
    if mv "$temp_file" "$CONF_FILE"; then
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Complete installation process
install_realm() {
    print_header "Realm Installation"
    
    # Install required tools
    install_required_tools
    
    # Detect system architecture
    local arch=$(detect_system_architecture)
    log_info "Detected architecture: $arch"
    
    # Get latest version
    local version=$(get_latest_realm_version)
    log_info "Latest version: v$version"
    
    # Download and install
    download_and_install_realm "$arch" "$version"
    
    # Create base configuration file
    generate_base_configuration
    
    # Create systemd service
    create_systemd_service
    
    # Start and enable service for auto-start
    start_realm_service
    
    log_success "Realm installed successfully"
}

# Add forwarding rule (with installation check)
add_forwarding_rule() {
    print_header "Add Forwarding Rule"
    
    # Check if Realm is installed, if not, install it first
    if ! is_realm_installed; then
        log_info "Realm is not installed. Installing now..."
        
        # Ask user for confirmation before installing
        read -p "Do you want to install Realm now? (y/n): " install_confirm
        if [[ "$install_confirm" != "y" && "$install_confirm" != "Y" ]]; then
            log_info "Installation cancelled by user"
            return
        fi
        
        install_realm
        
        # Check if installation was successful
        if ! is_realm_installed; then
            log_error "Realm installation failed. Cannot proceed with adding forwarding rule."
            return
        fi
    fi
    
    # Get user input
    local rule_config=$(get_forwarding_rule)
    
    # Check if user cancelled the operation
    if [[ $? -ne 0 ]]; then
        log_info "Operation cancelled by user"
        return
    fi
    
    IFS='|' read -r port remote_address remote_port <<< "$rule_config"
    
    # Display configuration summary
    print_divider
    echo -e "${CYAN}Rule Configuration:${NC}"
    echo -e "  Listen Port: ${YELLOW}$port${NC}"
    echo -e "  Remote Server: ${YELLOW}$remote_address${NC}"
    echo -e "  Remote Port: ${YELLOW}$remote_port${NC}"
    print_divider
    
    # Add rule to configuration file
    add_endpoint_to_config "$port" "$remote_address" "$remote_port"
    
    # Restart service to apply new configuration
    if is_realm_running; then
        log_info "Restarting Realm service to apply changes..."
        if systemctl restart realm; then
            log_success "Realm service restarted successfully"
        else
            log_error "Failed to restart Realm service"
            log_info "Check logs with: journalctl -u realm -f"
        fi
    else
        log_info "Starting and enabling Realm service..."
        
        # Ensure service is enabled for auto-start
        if ! systemctl is-enabled --quiet realm; then
            if systemctl enable realm; then
                log_success "Realm service enabled for auto-start"
            else
                log_error "Failed to enable Realm service"
                log_info "Check logs with: journalctl -u realm -f"
                return
            fi
        fi
        
        # Start the service
        if systemctl start realm; then
            log_success "Realm service started successfully"
        else
            log_error "Failed to start Realm service"
            log_info "Check logs with: journalctl -u realm -f"
        fi
    fi
    
    log_success "Forwarding rule added and service updated"
}

# Remove forwarding rule
remove_forwarding_rule() {
    print_header "Remove Forwarding Rule"
    
    # Check if configuration file exists
    if [[ ! -f "$CONF_FILE" ]]; then
        log_error "Configuration file not found. No rules to remove."
        return
    fi
    
    # Get all rules and build arrays
    local rules=()
    local ports=()
    local remotes=()
    local count=0
    
    # Parse configuration file to get all rules, excluding placeholder
    while IFS= read -r line; do
        if [[ "$line" =~ listen\ =\ \"0\.0\.0\.0:([0-9]+)\" ]]; then
            local listen_port="${BASH_REMATCH[1]}"
            # Read next line to get remote
            read -r next_line
            if [[ "$next_line" =~ remote\ =\ \"(.+)\" ]]; then
                local remote="${BASH_REMATCH[1]}"
                count=$((count + 1))
                ports+=("$listen_port")
                remotes+=("$remote")
                rules+=("$count. Port: $listen_port -> Destination: $remote")
            fi
        fi
    done < <(grep -A1 "listen = " "$CONF_FILE" | grep -v "127.0.0.1:65534")
    
    # Check if any rules found
    if [[ ${#rules[@]} -eq 0 ]]; then
        log_warn "No forwarding rules found to remove"
        return
    fi
    
    # Display all rules with numbers
    echo -e "${CYAN}Current forwarding rules:${NC}"
    echo ""
    for rule in "${rules[@]}"; do
        echo -e "  ${GREEN}$rule${NC}"
    done
    echo -e "  ${YELLOW}0. Return to main menu${NC}"
    echo ""
    
    # Get user selection
    while true; do
        read -p "Enter rule number(s) to remove (1-$count), use comma/space/plus to separate multiple: " selection
        
        # Check if user wants to return to main menu
        if [[ "$selection" == "0" ]]; then
            log_info "Returning to main menu"
            return
        fi
        
        # Parse selection (support comma, space, plus as separators)
        local selected_indices=()
        local invalid_selection=false
        
        # Replace separators with spaces and split
        local normalized_selection=$(echo "$selection" | sed 's/[,+]/ /g')
        
        # Convert to array
        for num in $normalized_selection; do
            # Validate each number
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$count" ]; then
                selected_indices+=("$num")
            else
                log_error "Invalid selection: $num. Please enter numbers between 1-$count"
                invalid_selection=true
                break
            fi
        done
        
        # If invalid selection, continue loop
        if [[ "$invalid_selection" == true ]]; then
            continue
        fi
        
        # Remove duplicates and sort
        selected_indices=($(printf '%s\n' "${selected_indices[@]}" | sort -n | uniq))
        
        # If no valid selections, continue loop
        if [[ ${#selected_indices[@]} -eq 0 ]]; then
            log_error "No valid selections provided"
            continue
        fi
        
        # Display selected rules for confirmation
        echo ""
        echo -e "${YELLOW}Selected rules to remove:${NC}"
        for index in "${selected_indices[@]}"; do
            echo -e "  ${RED}${rules[$((index-1))]}${NC}"
        done
        echo ""
        
        # Remove selected rules (process in reverse order to maintain indices)
        local rules_removed=0
        for ((i=${#selected_indices[@]}-1; i>=0; i--)); do
            local rule_index="${selected_indices[$i]}"
            
            # Remove the rule
            if remove_rule_by_index "$rule_index"; then
                rules_removed=$((rules_removed + 1))
                log_success "Removed rule #$rule_index"
            else
                log_error "Failed to remove rule #$rule_index"
            fi
        done
        
        # Restart service if any rules were removed
        if [[ $rules_removed -gt 0 ]]; then
            # Check if all real rules were removed, if so, add placeholder back
            local remaining_rules=$(grep -c "listen = \"0.0.0.0:" "$CONF_FILE" 2>/dev/null || echo "0")
            if [[ $remaining_rules -eq 0 ]]; then
                log_info "All forwarding rules removed, adding placeholder configuration..."
                cat >> "$CONF_FILE" << EOF

# Placeholder endpoint - ensures service can start without active rules
[[endpoints]]
listen = "127.0.0.1:65534"
remote = "127.0.0.1:65535"

EOF
                log_success "Placeholder configuration added"
            fi
            
            if is_realm_running; then
                log_info "Restarting Realm service to apply changes..."
                if systemctl restart realm; then
                    log_success "Realm service restarted successfully"
                else
                    log_error "Failed to restart Realm service"
                    log_info "Check logs with: journalctl -u realm -f"
                fi
            fi
            
            log_success "$rules_removed forwarding rule(s) removed and service updated"
        fi
        
        break
    done
}

# Uninstall Realm service
uninstall_realm() {
    print_header "Realm Uninstallation"
    
    # Display current status before uninstallation
    log_info "Checking current Realm installation status..."
    
    # Check if Realm is installed
    if ! is_realm_installed; then
        log_warn "Realm is not installed on this system"
        echo -e "${YELLOW}Nothing to uninstall.${NC}"
        echo ""
        read -p "Press Enter to exit..."
        exit 0
    fi
    
    # Display what will be removed
    echo -e "${CYAN}The following components will be removed:${NC}"
    echo -e "  ${YELLOW}• Realm service${NC}"
    echo -e "  ${YELLOW}• Configuration file: $CONF_FILE${NC}"
    echo -e "  ${YELLOW}• Binary file: $BINARY_PATH${NC}"
    echo -e "  ${YELLOW}• Service file: $SYSTEMD_PATH${NC}"
    echo -e "  ${YELLOW}• Log file: $LOG_FILE${NC}"
    echo ""
    
    # Check service status
    if is_realm_running; then
        echo -e "${GREEN}✓ Realm service is currently running${NC}"
    else
        echo -e "${RED}✗ Realm service is not running${NC}"
    fi
    
    # Show current forwarding rules
    if [[ -f "$CONF_FILE" ]]; then
        local rule_count=$(grep -c "listen = " "$CONF_FILE" 2>/dev/null || echo "0")
        echo -e "${CYAN}Current forwarding rules: $rule_count${NC}"
    fi
    
    echo ""
    print_divider
    
    # Confirm uninstallation
    read -p "Are you sure you want to uninstall Realm? This will remove all configurations. (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Operation cancelled by user"
        return
    fi
    
    echo ""
    log_info "Starting Realm uninstallation process..."
    print_divider
    
    # Step 1: Stop and disable service
    log_info "Step 1/6: Stopping Realm service..."
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet realm.service; then
            if systemctl stop realm.service; then
                log_success "Realm service stopped successfully"
            else
                log_warn "Failed to stop Realm service (may already be stopped)"
            fi
        else
            log_info "Realm service is not running"
        fi
        
        log_info "Disabling Realm service..."
        if systemctl is-enabled --quiet realm.service; then
            if systemctl disable realm.service; then
                log_success "Realm service disabled successfully"
            else
                log_warn "Failed to disable Realm service"
            fi
        else
            log_info "Realm service is not enabled"
        fi
    else
        log_info "Using legacy service management..."
        service realm stop 2>/dev/null && log_success "Service stopped" || log_info "Service was not running"
    fi
    
    # Step 2: Remove service file
    log_info "Step 2/6: Removing systemd service file..."
    if [[ -f "$SYSTEMD_PATH" ]]; then
        if rm -f "$SYSTEMD_PATH"; then
            log_success "Service file removed: $SYSTEMD_PATH"
        else
            log_error "Failed to remove service file: $SYSTEMD_PATH"
        fi
    else
        log_info "Service file not found: $SYSTEMD_PATH"
    fi
    
    # Step 3: Remove configuration directory
    log_info "Step 3/6: Removing configuration directory..."
    local config_dir="$(dirname "$CONF_FILE")"
    if [[ -d "$config_dir" ]]; then
        if rm -rf "$config_dir"; then
            log_success "Configuration directory removed: $config_dir"
        else
            log_error "Failed to remove configuration directory: $config_dir"
        fi
    else
        log_info "Configuration directory not found: $config_dir"
    fi
    
    # Step 4: Remove binary file
    log_info "Step 4/6: Removing binary file..."
    if [[ -f "$BINARY_PATH" ]]; then
        if rm -f "$BINARY_PATH"; then
            log_success "Binary file removed: $BINARY_PATH"
        else
            log_error "Failed to remove binary file: $BINARY_PATH"
        fi
    else
        log_info "Binary file not found: $BINARY_PATH"
    fi
    
    # Step 5: Remove log file
    log_info "Step 5/6: Removing log file..."
    if [[ -f "$LOG_FILE" ]]; then
        if rm -f "$LOG_FILE"; then
            log_success "Log file removed: $LOG_FILE"
        else
            log_error "Failed to remove log file: $LOG_FILE"
        fi
    else
        log_info "Log file not found: $LOG_FILE"
    fi
    
    # Step 6: Reload systemd configuration
    log_info "Step 6/6: Reloading systemd configuration..."
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl daemon-reload; then
            log_success "Systemd configuration reloaded"
        else
            log_warn "Failed to reload systemd configuration"
        fi
        
        if systemctl reset-failed; then
            log_success "Systemd failed units reset"
        else
            log_warn "Failed to reset systemd failed units"
        fi
    else
        log_info "Systemd not available, skipping reload"
    fi
    
    print_divider
    log_success "Realm uninstallation completed successfully!"
    echo ""
    echo -e "${GREEN}All Realm components have been removed from your system.${NC}"
    echo -e "${CYAN}Thank you for using Realm Management Script!${NC}"
    echo ""
    
    # Exit the script completely
    exit 0
}

# Display main menu
show_main_menu() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        Realm Management Script       ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║                                      ║${NC}"
    echo -e "${BLUE}║  ${GREEN}1${NC}) Add forwarding rule              ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${RED}2${NC}) Remove forwarding rule           ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${CYAN}3${NC}) View forwarding rules            ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${YELLOW}4${NC}) Uninstall forwarding service     ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${YELLOW}5${NC}) Exit                             ${BLUE}║${NC}"
    echo -e "${BLUE}║                                      ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""
}

# Main program entry point
main() {
    # Root permission check is already done at the beginning of the script
    
    # Display welcome message
    echo -e "${CYAN}Welcome to Realm Management Script!${NC}"
    echo -e "${YELLOW}This script helps you manage TCP/UDP forwarding rules using Realm.${NC}"
    
    # Display initial main menu
    show_main_menu
    
    # Main menu loop
    while true; do
        read -p "Select an option [1-5]: " choice
        echo ""  # Add a blank line after the selection
        
        case "$choice" in
            1)
                add_forwarding_rule
                echo ""  # Add a divider after the operation
                print_divider
                echo -e "${CYAN}Operation completed. Returning to main menu...${NC}"
                show_main_menu
                ;;
            2)
                remove_forwarding_rule
                echo ""  # Add a divider after the operation
                print_divider
                echo -e "${CYAN}Operation completed. Returning to main menu...${NC}"
                show_main_menu
                ;;
            3)
                show_current_rules
                echo ""  # Add a divider after the operation
                print_divider
                echo -e "${CYAN}Operation completed. Returning to main menu...${NC}"
                show_main_menu
                ;;
            4)
                uninstall_realm
                # This line should never be reached as uninstall_realm exits
                ;;
            5)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                log_error "Invalid selection. Please choose 1-5"
                echo ""
                show_main_menu
                ;;
        esac
    done
}

# Execute main function
main "$@"