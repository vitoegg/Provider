#!/usr/bin/env bash

# Realm TCP/UDP Forwarding Management Script
# Version: 3.0
# Description: Command-line tool to manage Realm forwarding service with batch operations support
# Requirements: Root privileges only
# Changes: Refactored to CLI-based operation, removed interactive menu, improved stability

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

# Display usage information
usage() {
    cat << EOF
Realm TCP/UDP Forwarding Management Tool

Usage:
    $(basename $0) --add RULE [--add RULE...]      添加转发规则（未安装时自动安装）
    $(basename $0) --remove PORT [--remove PORT...] 删除指定端口的规则
    $(basename $0) --remove-all                     删除所有规则
    $(basename $0) --list                           列出当前所有规则
    $(basename $0) --status                         查看服务运行状态
    $(basename $0) --uninstall                      卸载服务
    $(basename $0) --help, -h                       显示此帮助信息

规则格式: "监听端口:目标地址:目标端口"

示例:
    $(basename $0) --add "8080:example.com:80"
    $(basename $0) --add "8080:example.com:80" --add "3306:db.example.com:3306"
    $(basename $0) --remove "8080" --remove "3306"
    $(basename $0) --list
    $(basename $0) --status

选项说明:
    --add RULE          添加转发规则（可多次使用以批量添加）
    --remove PORT       删除指定端口的规则（可多次使用）
    --remove-all        删除所有规则
    --list              列出当前所有规则
    --status            查看服务运行状态
    --uninstall         卸载 Realm 服务
    --help, -h          显示此帮助信息

注意:
    - 所有操作需要 root 权限
    - 端口范围: 1024-65535（排除 65534 保留端口）
    - 添加规则时会自动检查端口冲突和规则重复
    - 首次添加规则时会自动安装 Realm 服务

EOF
}

# Validate port number
validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    if [ "$port" -eq 65534 ]; then
        return 1
    fi
    return 0
}

# Validate address (IP or domain)
validate_address() {
    local addr="$1"
    if [[ -z "$addr" ]]; then
        return 1
    fi
    # Basic validation: alphanumeric, dots, hyphens, colons (for IPv6)
    if [[ ! "$addr" =~ ^[a-zA-Z0-9][a-zA-Z0-9\.\-:]*$ ]]; then
        return 1
    fi
    return 0
}

# Validate rule format
validate_rule_format() {
    local rule="$1"
    
    # Check if rule contains exactly 2 colons
    local colon_count=$(echo "$rule" | grep -o ":" | wc -l)
    if [ "$colon_count" -ne 2 ]; then
        log_error "Invalid rule format: '$rule' (expected format: port:address:port)"
        return 1
    fi
    
    local IFS=':'
    read -r listen_port remote_addr remote_port <<< "$rule"
    
    if ! validate_port "$listen_port"; then
        log_error "Invalid listen port: $listen_port (must be 1024-65535, excluding reserved port 65534)"
        return 1
    fi
    
    if ! validate_address "$remote_addr"; then
        log_error "Invalid remote address: $remote_addr"
        return 1
    fi
    
    if ! validate_port "$remote_port"; then
        log_error "Invalid remote port: $remote_port (must be 1024-65535, excluding reserved port 65534)"
        return 1
    fi
    
    return 0
}

# Check if port is listening on the system (conflict detection)
check_port_conflict() {
    local port="$1"
    
    # Try ss first (modern tool)
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":${port} "; then
            return 0
        fi
    # Fallback to netstat
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln | grep -q ":${port} "; then
            return 0
        fi
    fi
    
    return 1
}

# Parse existing rules from configuration file
parse_existing_rules() {
    if [[ ! -f "$CONF_FILE" ]]; then
        return 0
    fi
    
    local rules=()
    while IFS= read -r line; do
        if [[ "$line" =~ listen\ =\ \"0\.0\.0\.0:([0-9]+)\" ]]; then
            local listen_port="${BASH_REMATCH[1]}"
            read -r next_line
            if [[ "$next_line" =~ remote\ =\ \"(.+)\" ]]; then
                local remote="${BASH_REMATCH[1]}"
                rules+=("$listen_port|$remote")
            fi
        fi
    done < <(grep -A1 "listen = " "$CONF_FILE")
    
    printf '%s\n' "${rules[@]}"
}

# Backup configuration file
backup_config() {
    if [[ -f "$CONF_FILE" ]]; then
        local backup_file="${CONF_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        if cp "$CONF_FILE" "$backup_file"; then
            log_debug "Configuration backed up to: $backup_file"
            echo "$backup_file"
            return 0
        else
            log_warn "Failed to backup configuration"
            return 1
        fi
    fi
    return 0
}

# Restore configuration from backup
restore_config() {
    local backup_file="$1"
    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        if cp "$backup_file" "$CONF_FILE"; then
            log_info "Configuration restored from backup"
            rm -f "$backup_file"
            return 0
        fi
    fi
    return 1
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

# Check and install only essential tools
install_required_tools() {
    log_info "Checking required tools..."
    
    local tools_needed=()
    
    # Check if download tool exists (curl or wget)
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        tools_needed+=("curl")
    fi
    
    # Check tar tool (required for extraction)
    if ! command -v tar >/dev/null 2>&1; then
        tools_needed+=("tar")
    fi
    
    # If no tools needed, exit early
    if [ ${#tools_needed[@]} -eq 0 ]; then
        log_success "All required tools are available"
        return 0
    fi
    
    # Install missing tools
    log_info "Installing missing tools: ${tools_needed[*]}"
    
    # Detect package manager and install
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq "${tools_needed[@]}" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "${tools_needed[@]}" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "${tools_needed[@]}" >/dev/null 2>&1
    else
        log_error "Cannot identify package manager"
        log_error "Please manually install: ${tools_needed[*]}"
        exit 1
    fi
    
    # Verify installation
    local failed_tools=()
    for tool in "${tools_needed[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            failed_tools+=("$tool")
        fi
    done
    
    if [ ${#failed_tools[@]} -gt 0 ]; then
        log_error "Failed to install: ${failed_tools[*]}"
        exit 1
    fi
    
    log_success "Required tools installed successfully"
}

# Check if Realm is installed
is_realm_installed() {
    [[ -f "$BINARY_PATH" && -f "$SYSTEMD_PATH" ]]
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

# Check service health
check_service_health() {
    if ! systemctl is-active --quiet realm; then
        return 1
    fi
    
    # Wait a moment for service to stabilize
    sleep 1
    
    # Check if service is still active after brief wait
    if ! systemctl is-active --quiet realm; then
        return 1
    fi
    
    # Verify that configured ports are listening
    local rules=$(parse_existing_rules)
    if [[ -n "$rules" ]]; then
        while IFS='|' read -r port remote; do
            # Give service time to bind ports
            sleep 0.5
            if command -v ss >/dev/null 2>&1; then
                if ! ss -tuln | grep -q ":${port} "; then
                    log_warn "Port $port is not listening yet"
                fi
            fi
        done <<< "$rules"
    fi
    
    return 0
}

# Unified service restart with health check and rollback
restart_service_with_validation() {
    local backup_file="$1"
    
    log_info "Restarting Realm service..."
    
    # Reload systemd configuration
    systemctl daemon-reload
    
    # Restart service
    if ! systemctl restart realm; then
        log_error "Failed to restart Realm service"
        if [[ -n "$backup_file" ]]; then
            log_info "Attempting to restore previous configuration..."
            restore_config "$backup_file"
            systemctl restart realm
        fi
        return 1
    fi
    
    # Check service health
    sleep 2
    if ! check_service_health; then
        log_error "Service health check failed"
        log_info "Check logs with: journalctl -u realm -n 50"
        if [[ -n "$backup_file" ]]; then
            log_info "Attempting to restore previous configuration..."
            restore_config "$backup_file"
            systemctl restart realm
        fi
        return 1
    fi
    
    log_success "Realm service restarted successfully"
    
    # Remove backup if successful
    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        rm -f "$backup_file"
    fi
    
    return 0
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
        log_info "Check logs with: journalctl -u realm -n 50"
        exit 1
    fi
    
    # Check service health
    sleep 2
    if ! check_service_health; then
        log_error "Service health check failed"
        log_info "Check logs with: journalctl -u realm -n 50"
        exit 1
    fi
    
    log_success "Realm service started successfully"
}

# Check if rule already exists in configuration
check_rule_exists() {
    local listen_port="$1"
    local remote_address="$2"
    local remote_port="$3"
    
    if [[ ! -f "$CONF_FILE" ]]; then
        return 1
    fi
    
    # Check if exact rule exists
    local rules=$(parse_existing_rules)
    while IFS='|' read -r port remote; do
        if [[ "$port" == "$listen_port" && "$remote" == "${remote_address}:${remote_port}" ]]; then
            return 0
        fi
    done <<< "$rules"
    
    return 1
}

# Check if port is already in use in configuration file
check_port_in_config() {
    local port="$1"
    if [[ -f "$CONF_FILE" ]]; then
        # Check if port is already configured
        grep -q "listen = \"0.0.0.0:$port\"" "$CONF_FILE"
    else
        return 1
    fi
}

# Generate initial configuration file (without rules)
generate_base_configuration() {
    log_info "Creating configuration file..."
    
    # Create configuration directory
    mkdir -p "$(dirname "$CONF_FILE")"
    
    # Generate base configuration without endpoints
    cat > "$CONF_FILE" << EOF
[log]
level = "warn"
output = "$LOG_FILE"

[network]
no_tcp = false
use_udp = true

EOF
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create configuration file"
        exit 1
    fi
    
    log_success "Configuration file created at $CONF_FILE"
}

# Add forwarding rule to configuration file
add_endpoint_to_config() {
    local listen_port="$1"
    local remote_address="$2"
    local remote_port="$3"
    
    log_debug "Adding endpoint: $listen_port -> $remote_address:$remote_port"
    
    # If configuration file doesn't exist, create base configuration
    if [[ ! -f "$CONF_FILE" ]]; then
        generate_base_configuration
    fi
    
    # Add endpoint to configuration
    cat >> "$CONF_FILE" << EOF
[[endpoints]]
listen = "0.0.0.0:${listen_port}"
remote = "${remote_address}:${remote_port}"

EOF
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to add endpoint to configuration file"
        return 1
    fi
    
    return 0
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
    
    # Create systemd service
    create_systemd_service
    
    log_success "Realm installed successfully"
    log_info "Service will start when first rule is added"
}

# Add multiple forwarding rules (batch operation)
add_rules() {
    local rules=("$@")
    
    if [ ${#rules[@]} -eq 0 ]; then
        log_error "No rules provided"
        echo "Usage: $(basename $0) --add \"port:address:port\" [--add \"port:address:port\" ...]"
        return 1
    fi
    
    print_header "Adding Forwarding Rules"
    
    # Check if Realm is installed, if not, install it first
    if ! is_realm_installed; then
        log_info "Realm is not installed. Installing now..."
        install_realm
        
        # Check if installation was successful
        if ! is_realm_installed; then
            log_error "Realm installation failed. Cannot proceed with adding forwarding rules"
            return 1
        fi
    fi
    
    # Validate all rules first
    log_info "Validating ${#rules[@]} rule(s)..."
    local valid_rules=()
    local has_errors=false
    
    for rule in "${rules[@]}"; do
        if ! validate_rule_format "$rule"; then
            has_errors=true
            continue
        fi
        
        local IFS=':'
        read -r listen_port remote_addr remote_port <<< "$rule"
        
        # Check for port conflict with system services
        if check_port_conflict "$listen_port"; then
            log_error "Port $listen_port is already in use by another service"
            has_errors=true
            continue
        fi
        
        # Check for duplicate rule in configuration
        if check_rule_exists "$listen_port" "$remote_addr" "$remote_port"; then
            log_warn "Rule already exists: $listen_port -> $remote_addr:$remote_port (skipping)"
            continue
        fi
        
        # Check for port conflict in configuration
        if check_port_in_config "$listen_port"; then
            log_error "Port $listen_port is already configured with a different destination"
            has_errors=true
            continue
        fi
        
        valid_rules+=("$rule")
    done
    
    if [ ${#valid_rules[@]} -eq 0 ]; then
        if [ "$has_errors" = true ]; then
            log_error "No valid rules to add due to validation errors"
            return 1
        else
            log_info "No new rules to add (all rules already exist)"
            return 0
        fi
    fi
    
    log_success "Validated ${#valid_rules[@]} rule(s)"
    
    # Backup configuration
    local backup_file=$(backup_config)
    
    # Add all valid rules
    log_info "Adding ${#valid_rules[@]} rule(s) to configuration..."
    for rule in "${valid_rules[@]}"; do
        local IFS=':'
        read -r listen_port remote_addr remote_port <<< "$rule"
        
        echo -e "${CYAN}  Adding: ${YELLOW}$listen_port${NC} -> ${YELLOW}$remote_addr:$remote_port${NC}"
        add_endpoint_to_config "$listen_port" "$remote_addr" "$remote_port"
    done
    
    log_success "Rules added to configuration"
    
    # Restart service to apply changes
    if is_realm_running; then
        if ! restart_service_with_validation "$backup_file"; then
            log_error "Failed to apply new rules"
            return 1
        fi
    else
        log_info "Starting Realm service..."
        if ! systemctl enable realm; then
            log_error "Failed to enable Realm service"
            restore_config "$backup_file"
            return 1
        fi
        
        if ! systemctl start realm; then
            log_error "Failed to start Realm service"
            log_info "Check logs with: journalctl -u realm -n 50"
            restore_config "$backup_file"
            return 1
        fi
        
        sleep 2
        if ! check_service_health; then
            log_error "Service health check failed"
            log_info "Check logs with: journalctl -u realm -n 50"
            restore_config "$backup_file"
            return 1
        fi
        
        log_success "Realm service started successfully"
        
        # Remove backup if successful
        if [[ -n "$backup_file" && -f "$backup_file" ]]; then
            rm -f "$backup_file"
        fi
    fi
    
    log_success "Successfully added ${#valid_rules[@]} forwarding rule(s)"
    
    # Display added rules
    echo ""
    echo -e "${GREEN}Added rules:${NC}"
    for rule in "${valid_rules[@]}"; do
        local IFS=':'
        read -r listen_port remote_addr remote_port <<< "$rule"
        echo -e "  ${GREEN}✓${NC} Port ${YELLOW}$listen_port${NC} -> ${YELLOW}$remote_addr:$remote_port${NC}"
    done
    
    return 0
}

# Remove forwarding rules by port (batch operation)
remove_rules() {
    local ports=("$@")
    
    if [ ${#ports[@]} -eq 0 ]; then
        log_error "No ports provided"
        echo "Usage: $(basename $0) --remove PORT [--remove PORT ...]"
        return 1
    fi
    
    print_header "Removing Forwarding Rules"
    
    # Check if configuration file exists
    if [[ ! -f "$CONF_FILE" ]]; then
        log_error "Configuration file not found. No rules to remove"
        return 1
    fi
    
    # Parse existing rules
    local existing_rules=$(parse_existing_rules)
    if [[ -z "$existing_rules" ]]; then
        log_warn "No forwarding rules found in configuration"
        return 1
    fi
    
    # Validate ports and find matching rules
    log_info "Validating ${#ports[@]} port(s)..."
    local valid_ports=()
    local has_errors=false
    
    for port in "${ports[@]}"; do
        if ! validate_port "$port"; then
            log_error "Invalid port: $port"
            has_errors=true
            continue
        fi
        
        # Check if port exists in configuration
        if ! check_port_in_config "$port"; then
            log_warn "Port $port not found in configuration (skipping)"
            continue
        fi
        
        valid_ports+=("$port")
    done
    
    if [ ${#valid_ports[@]} -eq 0 ]; then
        if [ "$has_errors" = true ]; then
            log_error "No valid ports to remove due to validation errors"
            return 1
        else
            log_info "No matching rules found to remove"
            return 0
        fi
    fi
    
    log_success "Found ${#valid_ports[@]} rule(s) to remove"
    
    # Backup configuration
    local backup_file=$(backup_config)
    
    # Remove rules by port
    log_info "Removing ${#valid_ports[@]} rule(s) from configuration..."
    for port in "${valid_ports[@]}"; do
        # Find the rule details for display
        local rule_dest=""
        while IFS='|' read -r rule_port rule_remote; do
            if [[ "$rule_port" == "$port" ]]; then
                rule_dest="$rule_remote"
                break
            fi
        done <<< "$existing_rules"
        
        echo -e "${CYAN}  Removing: ${YELLOW}$port${NC} -> ${YELLOW}$rule_dest${NC}"
        
        # Remove the rule by filtering out the endpoint
        remove_rule_by_port "$port"
    done
    
    # Check if all rules were removed
    local remaining_rules=$(grep -c "listen = \"0.0.0.0:" "$CONF_FILE" 2>/dev/null || echo "0")
    
    log_success "Rules removed from configuration"
    
    # If all rules removed, stop the service
    if [[ $remaining_rules -eq 0 ]]; then
        log_info "All forwarding rules removed"
        if is_realm_running; then
            log_info "Stopping Realm service (no rules configured)..."
            systemctl stop realm 2>/dev/null && log_success "Service stopped" || log_warn "Failed to stop service"
        fi
        # Remove backup if successful
        if [[ -n "$backup_file" && -f "$backup_file" ]]; then
            rm -f "$backup_file"
        fi
    else
        # Restart service to apply changes
        if is_realm_running; then
            if ! restart_service_with_validation "$backup_file"; then
                log_error "Failed to apply changes"
                return 1
            fi
        else
            # Remove backup if successful
            if [[ -n "$backup_file" && -f "$backup_file" ]]; then
                rm -f "$backup_file"
            fi
        fi
    fi
    
    log_success "Successfully removed ${#valid_ports[@]} forwarding rule(s)"
    
    return 0
}

# Remove all forwarding rules
remove_all_rules() {
    print_header "Removing All Forwarding Rules"
    
    # Check if configuration file exists
    if [[ ! -f "$CONF_FILE" ]]; then
        log_error "Configuration file not found. No rules to remove"
        return 1
    fi
    
    # Parse existing rules
    local existing_rules=$(parse_existing_rules)
    if [[ -z "$existing_rules" ]]; then
        log_warn "No forwarding rules found in configuration"
        return 0
    fi
    
    # Count rules
    local rule_count=$(echo "$existing_rules" | wc -l)
    log_info "Found $rule_count forwarding rule(s)"
    
    # Backup configuration
    local backup_file=$(backup_config)
    
    # Regenerate base configuration (without endpoints)
    log_info "Removing all forwarding rules..."
    generate_base_configuration
    
    log_success "All rules removed from configuration"
    
    # Stop service since no rules configured
    if is_realm_running; then
        log_info "Stopping Realm service (no rules configured)..."
        systemctl stop realm 2>/dev/null && log_success "Service stopped" || log_warn "Failed to stop service"
    fi
    
    # Remove backup if successful
    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        rm -f "$backup_file"
    fi
    
    log_success "Successfully removed all $rule_count forwarding rule(s)"
    
    return 0
}

# Remove rule by port (helper function)
remove_rule_by_port() {
    local target_port="$1"
    
    if [[ ! -f "$CONF_FILE" ]]; then
        return 1
    fi
    
    local temp_file=$(mktemp)
    local in_target_endpoint=false
    local skip_line=false
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[\[endpoints\]\]$ ]]; then
            in_target_endpoint=false
            skip_line=false
        elif [[ "$line" =~ ^listen\ =\ \"0\.0\.0\.0:([0-9]+)\" ]]; then
            if [[ "${BASH_REMATCH[1]}" == "$target_port" ]]; then
                in_target_endpoint=true
                skip_line=true
                continue
            fi
        fi
        
        if [[ "$in_target_endpoint" == true ]]; then
            if [[ "$line" =~ ^remote\ = || "$line" =~ ^$ ]]; then
                if [[ "$line" =~ ^$ && "$skip_line" == true ]]; then
                    in_target_endpoint=false
                    skip_line=false
                fi
                continue
            fi
        fi
        
        if [[ "$skip_line" == false ]]; then
            echo "$line" >> "$temp_file"
        fi
    done < "$CONF_FILE"
    
    mv "$temp_file" "$CONF_FILE"
    return 0
}

# List forwarding rules
list_rules() {
    print_header "Current Forwarding Rules"
    
    if [[ ! -f "$CONF_FILE" ]]; then
        log_warn "Configuration file not found. No rules configured"
        return 1
    fi
    
    # Parse existing rules
    local rules=$(parse_existing_rules)
    
    if [[ -z "$rules" ]]; then
        log_warn "No forwarding rules configured"
        return 0
    fi
    
    # Count and display rules
    local count=0
    echo ""
    while IFS='|' read -r port remote; do
        count=$((count + 1))
        echo -e "  ${GREEN}$count${NC}. Port ${YELLOW}$port${NC} -> ${YELLOW}$remote${NC}"
    done <<< "$rules"
    
    echo ""
    echo -e "${CYAN}Total: $count rule(s)${NC}"
    
    # Display service status
    if is_realm_running; then
        echo -e "${GREEN}✓ Realm service is running${NC}"
    else
        echo -e "${RED}✗ Realm service is not running${NC}"
    fi
    
    return 0
}

# Show service status
show_status() {
    print_header "Realm Service Status"
    
    if ! is_realm_installed; then
        log_warn "Realm is not installed"
        return 1
    fi
    
    echo ""
    echo -e "${CYAN}Service Status:${NC}"
    
    if is_realm_running; then
        echo -e "  ${GREEN}✓ Running${NC}"
    else
        echo -e "  ${RED}✗ Stopped${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}Systemd Status:${NC}"
    systemctl status realm --no-pager -l 2>&1 | head -20
    
    echo ""
    echo -e "${CYAN}Configuration:${NC}"
    echo -e "  Binary: ${YELLOW}$BINARY_PATH${NC}"
    echo -e "  Config: ${YELLOW}$CONF_FILE${NC}"
    echo -e "  Log: ${YELLOW}$LOG_FILE${NC}"
    
    # Show forwarding rules count
    if [[ -f "$CONF_FILE" ]]; then
        local rules=$(parse_existing_rules)
        if [[ -n "$rules" ]]; then
            local rule_count=$(echo "$rules" | wc -l)
            echo ""
            echo -e "${CYAN}Forwarding Rules: ${YELLOW}$rule_count${NC}"
        fi
    fi
    
    return 0
}

# Uninstall Realm service
uninstall_realm() {
    print_header "Realm Uninstallation"
    
    # Check if Realm is installed
    if ! is_realm_installed; then
        log_warn "Realm is not installed on this system"
        return 0
    fi
    
    log_info "Starting Realm uninstallation process..."
    
    # Step 1: Stop and disable service
    log_info "Stopping Realm service..."
    if systemctl is-active --quiet realm.service 2>/dev/null; then
        systemctl stop realm.service 2>/dev/null && log_success "Service stopped" || log_warn "Failed to stop service"
    fi
    
    if systemctl is-enabled --quiet realm.service 2>/dev/null; then
        systemctl disable realm.service 2>/dev/null && log_success "Service disabled" || log_warn "Failed to disable service"
    fi
    
    # Step 2: Remove service file
    log_info "Removing systemd service file..."
    if [[ -f "$SYSTEMD_PATH" ]]; then
        rm -f "$SYSTEMD_PATH" && log_success "Service file removed" || log_error "Failed to remove service file"
    fi
    
    # Step 3: Remove configuration directory
    log_info "Removing configuration directory..."
    local config_dir="$(dirname "$CONF_FILE")"
    if [[ -d "$config_dir" ]]; then
        rm -rf "$config_dir" && log_success "Configuration removed" || log_error "Failed to remove configuration"
    fi
    
    # Step 4: Remove binary file
    log_info "Removing binary file..."
    if [[ -f "$BINARY_PATH" ]]; then
        rm -f "$BINARY_PATH" && log_success "Binary removed" || log_error "Failed to remove binary"
    fi
    
    # Step 5: Remove log file
    log_info "Removing log file..."
    if [[ -f "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE" && log_success "Log file removed" || log_warn "Failed to remove log file"
    fi
    
    # Step 6: Reload systemd configuration
    log_info "Reloading systemd configuration..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null
        systemctl reset-failed 2>/dev/null
        log_success "Systemd configuration reloaded"
    fi
    
    log_success "Realm uninstallation completed successfully"
    
    return 0
}

# Main program entry point - Parse command-line arguments
main() {
    # Check if any arguments provided
    if [ $# -eq 0 ]; then
        usage
        exit 1
    fi
    
    # Arrays to collect multiple operations
    local rules_to_add=()
    local ports_to_remove=()
    local operation=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --add)
                if [[ -z "$2" || "$2" == --* ]]; then
                    log_error "Option --add requires an argument"
                    echo "Format: --add \"port:address:port\""
                    exit 1
                fi
                rules_to_add+=("$2")
                operation="add"
                shift 2
                ;;
            --remove)
                if [[ -z "$2" || "$2" == --* ]]; then
                    log_error "Option --remove requires an argument"
                    echo "Format: --remove PORT"
                    exit 1
                fi
                ports_to_remove+=("$2")
                operation="remove"
                shift 2
                ;;
            --remove-all)
                operation="remove-all"
                shift
                ;;
            --list)
                operation="list"
                shift
                ;;
            --status)
                operation="status"
                shift
                ;;
            --uninstall)
                operation="uninstall"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo ""
                usage
                exit 1
                ;;
        esac
    done
    
    # Execute operations based on collected arguments
    case "$operation" in
        add)
            if [ ${#rules_to_add[@]} -eq 0 ]; then
                log_error "No rules provided for --add operation"
                exit 1
            fi
            add_rules "${rules_to_add[@]}"
            exit $?
            ;;
        remove)
            if [ ${#ports_to_remove[@]} -eq 0 ]; then
                log_error "No ports provided for --remove operation"
                exit 1
            fi
            remove_rules "${ports_to_remove[@]}"
            exit $?
            ;;
        remove-all)
            remove_all_rules
            exit $?
            ;;
        list)
            list_rules
            exit $?
            ;;
        status)
            show_status
            exit $?
            ;;
        uninstall)
            uninstall_realm
            exit $?
            ;;
        *)
            log_error "No valid operation specified"
            usage
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"