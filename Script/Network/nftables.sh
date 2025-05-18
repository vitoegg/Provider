#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log function with different levels
function log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

function log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# Check if system is Debian or Ubuntu
if ! grep -qiE 'debian|ubuntu' /etc/os-release; then
    log_error "This script only works on Debian or Ubuntu systems"
    exit 1
fi

# Check if nftables is installed, if not install it
if ! command -v nft &> /dev/null; then
    log_warn "nftables is not installed. Installing now..."
    apt update
    apt install -y nftables
    
    if [ $? -ne 0 ]; then
        log_error "Failed to install nftables. Please install it manually"
        exit 1
    else
        log_info "nftables installed successfully"
    fi
else
    log_info "nftables is already installed"
fi

# Enable and start nftables service
systemctl enable nftables
systemctl start nftables

# Configuration file path
CONFIG_FILE="/etc/nftables.conf"

# Function to initialize nftables if needed
function initialize_nftables() {
    log_info "Initializing nftables forwarding configuration"
    
    # Check if fowardaws table exists in the active ruleset
    if ! nft list tables | grep -q "fowardaws"; then
        # Create basic config if it doesn't exist
        cat > "$CONFIG_FILE" << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table ip fowardaws {
    chain prerouting {
        type nat hook prerouting priority -100;
        # TCP and UDP forwarding rules will be added here
    }

    chain postrouting {
        type nat hook postrouting priority 100;
        # Masquerade rules will be added here
    }
}
EOF
        # Load the configuration
        if nft -f "$CONFIG_FILE"; then
            log_info "Basic forwarding configuration created and loaded"
        else
            log_error "Failed to initialize nftables configuration"
            return 1
        fi
    else
        log_info "Forwarding table already exists"
    fi
    
    # Make sure IP forwarding is enabled in the kernel
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward
        
        # Check if net.ipv4.ip_forward = 1 already exists in /etc/sysctl.conf
        if grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
            log_info "IP forwarding is already enabled"
        else
            # Add configuration and comment to /etc/sysctl.conf
            echo "" >> /etc/sysctl.conf
            echo "# Enable IP forwarding for port forwarding" >> /etc/sysctl.conf
            echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
            
            # Apply configuration without logging output
            sysctl -p > /dev/null 2>&1
            
            log_info "IP forwarding enabled successfully"
        fi
    fi
    
    return 0
}

# Initialize nftables when script starts
initialize_nftables

# Function to display current rules
function display_rules() {
    log_info "Current port forwarding rules:"
    
    # First check if nftables ruleset exists
    if ! nft list ruleset &> /dev/null; then
        log_warn "No nftables ruleset found"
        return
    fi
    
    # Try to get rules directly from the running ruleset
    local ruleset_output=$(nft list ruleset)
    
    if ! echo "$ruleset_output" | grep -q "table ip fowardaws"; then
        log_warn "No forwarding table found in nftables"
        return
    fi
    
    # Extract TCP rules from prerouting
    local tcp_rules=$(echo "$ruleset_output" | grep -A20 "chain prerouting" | grep "tcp dport .* dnat to")
    # Extract UDP rules from prerouting
    local udp_rules=$(echo "$ruleset_output" | grep -A20 "chain prerouting" | grep "udp dport .* dnat to")
    
    # Extract local TCP rules from output chain
    local local_tcp_rules=$(echo "$ruleset_output" | grep -A20 "chain output" | grep "tcp dport .* dnat to")
    # Extract local UDP rules from output chain
    local local_udp_rules=$(echo "$ruleset_output" | grep -A20 "chain output" | grep "udp dport .* dnat to")
    
    if [[ -z "$tcp_rules" && -z "$udp_rules" && -z "$local_tcp_rules" && -z "$local_udp_rules" ]]; then
        log_warn "No forwarding rules found"
        return
    fi
    
    # Store unique port:destination pairs
    declare -A rule_protocols
    declare -A rule_map
    declare -A rule_type  # To identify if it's local or remote forwarding
    
    # Process TCP rules from prerouting (remote forwarding)
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        local key="${src_port}:${dest}"
        
        rule_map["$key"]="$dest"
        rule_type["$key"]="remote"
        if [[ -z "${rule_protocols[$key]}" ]]; then
            rule_protocols["$key"]="TCP"
        fi
    done <<< "$tcp_rules"
    
    # Process UDP rules from prerouting and merge with TCP (remote forwarding)
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        local key="${src_port}:${dest}"
        
        rule_map["$key"]="$dest"
        rule_type["$key"]="remote"
        if [[ -z "${rule_protocols[$key]}" ]]; then
            rule_protocols["$key"]="UDP"
        else
            rule_protocols["$key"]="TCP+UDP"
        fi
    done <<< "$udp_rules"
    
    # Process local TCP rules from output chain (local forwarding)
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        local key="${src_port}:${dest}:local"
        
        rule_map["$key"]="$dest"
        rule_type["$key"]="local"
        if [[ -z "${rule_protocols[$key]}" ]]; then
            rule_protocols["$key"]="TCP"
        fi
    done <<< "$local_tcp_rules"
    
    # Process local UDP rules from output chain and merge with TCP (local forwarding)
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        local key="${src_port}:${dest}:local"
        
        rule_map["$key"]="$dest"
        rule_type["$key"]="local"
        if [[ -z "${rule_protocols[$key]}" ]]; then
            rule_protocols["$key"]="UDP"
        else
            rule_protocols["$key"]="TCP+UDP"
        fi
    done <<< "$local_udp_rules"
    
    # Display the combined rules
    echo -e "${YELLOW}=== Port Forwarding Rules ===${NC}"
    local count=1
    
    for key in "${!rule_map[@]}"; do
        local src_port=$(echo "$key" | cut -d':' -f1)
        local dest="${rule_map[$key]}"
        local dest_ip=$(echo "$dest" | cut -d':' -f1)
        local dest_port=$(echo "$dest" | cut -d':' -f2)
        local protocol="${rule_protocols[$key]}"
        local type="${rule_type[$key]}"
        
        if [ "$type" = "local" ]; then
            echo -e "${GREEN}$count)${NC} ${BLUE}[LOCAL]${NC} Port: ${YELLOW}$src_port${NC} -> ${YELLOW}$dest_ip:$dest_port${NC} (${BLUE}$protocol${NC})"
        else
            echo -e "${GREEN}$count)${NC} Port: ${YELLOW}$src_port${NC} -> Destination: ${YELLOW}$dest_ip:$dest_port${NC} (${BLUE}$protocol${NC})"
        fi
        count=$((count+1))
    done
    
    # If no rules found
    if [ $count -eq 1 ]; then
        log_warn "No forwarding rules found"
    fi
}

# Function to add new forwarding rule
function add_rule() {
    log_info "Adding new port forwarding rule"
    
    # Get input from user
    read -p "Enter local port number: " local_port
    read -p "Enter destination IP address (or 'local' for localhost): " dest_ip
    read -p "Enter destination port number: " dest_port
    
    # Validate input
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        log_error "Invalid local port. Port must be between 1-65535"
        return
    fi
    
    # Check if local port forwarding is requested
    local is_local=false
    if [[ "$dest_ip" == "local" || "$dest_ip" == "localhost" || "$dest_ip" == "127.0.0.1" ]]; then
        dest_ip="127.0.0.1"
        is_local=true
    elif ! [[ "$dest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid IP address format"
        return
    fi
    
    if ! [[ "$dest_port" =~ ^[0-9]+$ ]] || [ "$dest_port" -lt 1 ] || [ "$dest_port" -gt 65535 ]; then
        log_error "Invalid destination port. Port must be between 1-65535"
        return
    fi
    
    # Backup current config
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    
    # Read the current config
    local current_config=$(cat "$CONFIG_FILE")
    
    # Check if the table and chains exist
    if ! grep -q "table ip fowardaws" "$CONFIG_FILE"; then
        # Create new config with the table and chains
        cat > "$CONFIG_FILE" << EOF
#!/usr/sbin/nft -f

flush ruleset

table ip fowardaws {
    chain prerouting {
        type nat hook prerouting priority -100;
        # TCP and UDP forwarding rules
        tcp dport $local_port dnat to $dest_ip:$dest_port
        udp dport $local_port dnat to $dest_ip:$dest_port
    }

    chain postrouting {
        type nat hook postrouting priority 100;
        # Masquerade rules
        ip daddr $dest_ip masquerade
    }
}
EOF

        # Add local forwarding rule for redirect if needed
        if [ "$is_local" = true ]; then
            # For local redirection, we need to use the output chain
            sed -i "/table ip fowardaws {/a\\    chain output {\n        type nat hook output priority -100;\n        # Local port forwarding rules\n        tcp dport $local_port dnat to $dest_ip:$dest_port\n        udp dport $local_port dnat to $dest_ip:$dest_port\n    }" "$CONFIG_FILE"
        fi
    else
        # Add rules to existing config
        # Check if chains exist
        if ! grep -q "chain prerouting" "$CONFIG_FILE"; then
            # Add prerouting chain
            sed -i "/table ip fowardaws {/a\\    chain prerouting {\n        type nat hook prerouting priority -100;\n        # TCP and UDP forwarding rules\n        tcp dport $local_port dnat to $dest_ip:$dest_port\n        udp dport $local_port dnat to $dest_ip:$dest_port\n    }" "$CONFIG_FILE"
        else
            # Add forwarding rules to prerouting chain
            sed -i "/chain prerouting {/,/}/{s/}/        tcp dport $local_port dnat to $dest_ip:$dest_port\n        udp dport $local_port dnat to $dest_ip:$dest_port\n    }/}" "$CONFIG_FILE"
        fi
        
        # For local redirection, add or modify output chain
        if [ "$is_local" = true ]; then
            if ! grep -q "chain output" "$CONFIG_FILE"; then
                # Add output chain for local forwarding
                sed -i "/table ip fowardaws {/a\\    chain output {\n        type nat hook output priority -100;\n        # Local port forwarding rules\n        tcp dport $local_port dnat to $dest_ip:$dest_port\n        udp dport $local_port dnat to $dest_ip:$dest_port\n    }" "$CONFIG_FILE"
            else
                # Add local forwarding rules to output chain
                sed -i "/chain output {/,/}/{s/}/        tcp dport $local_port dnat to $dest_ip:$dest_port\n        udp dport $local_port dnat to $dest_ip:$dest_port\n    }/}" "$CONFIG_FILE"
            fi
        fi
        
        if ! grep -q "chain postrouting" "$CONFIG_FILE"; then
            # Add postrouting chain
            sed -i "/table ip fowardaws {/a\\    chain postrouting {\n        type nat hook postrouting priority 100;\n        # Masquerade rules\n        ip daddr $dest_ip masquerade\n    }" "$CONFIG_FILE"
        else
            # Add masquerade rule to postrouting chain if not local
            if ! grep -q "ip daddr $dest_ip masquerade" "$CONFIG_FILE" && [ "$is_local" = false ]; then
                sed -i "/chain postrouting {/,/}/{s/}/        ip daddr $dest_ip masquerade\n    }/}" "$CONFIG_FILE"
            fi
        fi
    fi
    
    # Reload nftables configuration
    if nft -f "$CONFIG_FILE"; then
        if [ "$is_local" = true ]; then
            log_info "Local port forwarding rule added successfully (TCP+UDP) from port $local_port to $dest_ip:$dest_port"
        else
            log_info "Port forwarding rule added successfully (TCP+UDP)"
        fi
        # Display the current ruleset to verify
        log_debug "Current nftables ruleset:"
        nft list ruleset
    else
        log_error "Failed to apply the new rules, restoring backup"
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
    fi
}

# Function to delete a forwarding rule
function delete_rule() {
    # Display current rules first (rules will be displayed combined)
    display_rules
    
    # Get the current ruleset
    local ruleset_output=$(nft list ruleset)
    
    if ! echo "$ruleset_output" | grep -q "table ip fowardaws"; then
        log_warn "No forwarding table found to delete"
        return
    fi
    
    # Extract all rules
    local tcp_rules=$(echo "$ruleset_output" | grep -A20 "chain prerouting" | grep "tcp dport .* dnat to")
    local udp_rules=$(echo "$ruleset_output" | grep -A20 "chain prerouting" | grep "udp dport .* dnat to")
    local local_tcp_rules=$(echo "$ruleset_output" | grep -A20 "chain output" | grep "tcp dport .* dnat to")
    local local_udp_rules=$(echo "$ruleset_output" | grep -A20 "chain output" | grep "udp dport .* dnat to")
    local masq_rules=$(echo "$ruleset_output" | grep -A20 "chain postrouting" | grep "ip daddr .* masquerade")
    
    # Build a map of combined rules for display
    declare -A rule_protocols
    declare -A rule_map
    declare -A rule_type  # To identify if it's local or remote forwarding
    local combined_ports=()
    local combined_dests=()
    local combined_protocols=()
    local combined_types=()
    
    # Process TCP rules from prerouting (remote forwarding)
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        local key="${src_port}:${dest}"
        
        rule_map["$key"]="$dest"
        rule_type["$key"]="remote"
        if [[ -z "${rule_protocols[$key]}" ]]; then
            rule_protocols["$key"]="TCP"
        fi
    done <<< "$tcp_rules"
    
    # Process UDP rules from prerouting and merge with TCP (remote forwarding)
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        local key="${src_port}:${dest}"
        
        rule_map["$key"]="$dest"
        rule_type["$key"]="remote"
        if [[ -z "${rule_protocols[$key]}" ]]; then
            rule_protocols["$key"]="UDP"
        else
            rule_protocols["$key"]="TCP+UDP"
        fi
    done <<< "$udp_rules"
    
    # Process local TCP rules from output chain (local forwarding)
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        local key="${src_port}:${dest}:local"
        
        rule_map["$key"]="$dest"
        rule_type["$key"]="local"
        if [[ -z "${rule_protocols[$key]}" ]]; then
            rule_protocols["$key"]="TCP"
        fi
    done <<< "$local_tcp_rules"
    
    # Process local UDP rules from output chain and merge with TCP (local forwarding)
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        local key="${src_port}:${dest}:local"
        
        rule_map["$key"]="$dest"
        rule_type["$key"]="local"
        if [[ -z "${rule_protocols[$key]}" ]]; then
            rule_protocols["$key"]="UDP"
        else
            rule_protocols["$key"]="TCP+UDP"
        fi
    done <<< "$local_udp_rules"
    
    # Convert associative arrays to indexed arrays for easier selection
    for key in "${!rule_map[@]}"; do
        local src_port=$(echo "$key" | cut -d':' -f1)
        local dest="${rule_map[$key]}"
        local protocol="${rule_protocols[$key]}"
        local type="${rule_type[$key]}"
        
        combined_ports+=("$src_port")
        combined_dests+=("$dest")
        combined_protocols+=("$protocol")
        combined_types+=("$type")
    done
    
    # Process masquerade rules (hidden from user but used for cleanup)
    local masq_ips=()
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local dest_ip=$(echo "$line" | grep -oP 'daddr \K[0-9.]+')
        masq_ips+=("$dest_ip")
    done <<< "$masq_rules"
    
    # If no rules found
    if [ ${#combined_ports[@]} -eq 0 ]; then
        log_warn "No forwarding rules found to delete"
        return
    fi
    
    # Display rules for deletion
    echo -e "\n${YELLOW}Select a port forwarding rule to delete:${NC}"
    for i in "${!combined_ports[@]}"; do
        local src_port="${combined_ports[$i]}"
        local dest="${combined_dests[$i]}"
        local protocol="${combined_protocols[$i]}"
        local type="${combined_types[$i]}"
        local dest_ip=$(echo "$dest" | cut -d':' -f1)
        local dest_port=$(echo "$dest" | cut -d':' -f2)
        
        if [ "$type" = "local" ]; then
            echo "$((i+1))) [LOCAL] Port ${src_port} -> ${dest_ip}:${dest_port} (${protocol})"
        else
            echo "$((i+1))) Port ${src_port} -> ${dest_ip}:${dest_port} (${protocol})"
        fi
    done
    
    echo "$((${#combined_ports[@]}+1))) Cancel"
    
    read -p "Enter number (1-$((${#combined_ports[@]}+1))): " choice
    
    # Cancel option
    if [ "$choice" -eq "$((${#combined_ports[@]}+1))" ]; then
        log_info "Deletion cancelled"
        return
    fi
    
    # Validate input
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#combined_ports[@]}" ]; then
        log_error "Invalid selection"
        return
    fi
    
    # Get the selected port and destination
    local index=$((choice-1))
    local selected_port="${combined_ports[$index]}"
    local selected_dest="${combined_dests[$index]}"
    local selected_protocol="${combined_protocols[$index]}"
    local selected_type="${combined_types[$index]}"
    local selected_ip=$(echo "$selected_dest" | cut -d':' -f1)
    
    log_info "Deleting ${selected_protocol} forwarding rule for port ${selected_port}..."
    
    # Get handle numbers for the rules we want to delete
    local tcp_handle=""
    local udp_handle=""
    local local_tcp_handle=""
    local local_udp_handle=""
    local masq_handle=""
    
    # Handle remote or local rules differently
    if [ "$selected_type" = "remote" ]; then
        # Get TCP rule handle if needed for remote forwarding
        if [[ "$selected_protocol" == *"TCP"* ]]; then
            tcp_handle=$(nft -a list table ip fowardaws | grep "tcp dport ${selected_port} dnat to ${selected_dest}" | grep -v "chain output" | grep -oP 'handle \K[0-9]+')
            if [ -n "$tcp_handle" ]; then
                nft delete rule ip fowardaws prerouting handle "$tcp_handle"
                log_debug "Deleted TCP forwarding rule for port $selected_port (handle $tcp_handle)"
            fi
        fi
        
        # Get UDP rule handle if needed for remote forwarding
        if [[ "$selected_protocol" == *"UDP"* ]]; then
            udp_handle=$(nft -a list table ip fowardaws | grep "udp dport ${selected_port} dnat to ${selected_dest}" | grep -v "chain output" | grep -oP 'handle \K[0-9]+')
            if [ -n "$udp_handle" ]; then
                nft delete rule ip fowardaws prerouting handle "$udp_handle"
                log_debug "Deleted UDP forwarding rule for port $selected_port (handle $udp_handle)"
            fi
        fi
    else
        # Get TCP rule handle if needed for local forwarding
        if [[ "$selected_protocol" == *"TCP"* ]]; then
            local_tcp_handle=$(nft -a list table ip fowardaws | grep "chain output" -A20 | grep "tcp dport ${selected_port} dnat to ${selected_dest}" | grep -oP 'handle \K[0-9]+')
            if [ -n "$local_tcp_handle" ]; then
                nft delete rule ip fowardaws output handle "$local_tcp_handle"
                log_debug "Deleted local TCP forwarding rule for port $selected_port (handle $local_tcp_handle)"
            fi
        fi
        
        # Get UDP rule handle if needed for local forwarding
        if [[ "$selected_protocol" == *"UDP"* ]]; then
            local_udp_handle=$(nft -a list table ip fowardaws | grep "chain output" -A20 | grep "udp dport ${selected_port} dnat to ${selected_dest}" | grep -oP 'handle \K[0-9]+')
            if [ -n "$local_udp_handle" ]; then
                nft delete rule ip fowardaws output handle "$local_udp_handle"
                log_debug "Deleted local UDP forwarding rule for port $selected_port (handle $local_udp_handle)"
            fi
        fi
    fi
    
    # Check if any other rules use this destination IP (except localhost)
    if [ "$selected_ip" != "127.0.0.1" ]; then
        local ip_still_in_use=false
        for i in "${!combined_dests[@]}"; do
            if [ $i -ne $index ]; then  # Skip the one we just deleted
                local other_dest="${combined_dests[$i]}"
                local other_ip=$(echo "$other_dest" | cut -d':' -f1)
                
                if [ "$other_ip" == "$selected_ip" ]; then
                    ip_still_in_use=true
                    break
                fi
            fi
        done
        
        # If IP is no longer used, delete the masquerade rule
        if [ "$ip_still_in_use" = false ]; then
            masq_handle=$(nft -a list table ip fowardaws | grep "ip daddr ${selected_ip} masquerade" | grep -oP 'handle \K[0-9]+')
            if [ -n "$masq_handle" ]; then
                nft delete rule ip fowardaws postrouting handle "$masq_handle"
                log_debug "Deleted associated masquerade rule for $selected_ip (handle $masq_handle)"
            fi
        fi
    fi
    
    # Save the changes to the config file
    nft list ruleset > "$CONFIG_FILE"
    log_info "Port forwarding rule deleted successfully"
    
    # Verify deletion by listing current rules
    log_debug "Verifying deletion..."
    nft list table ip fowardaws
}

# Main menu
while true; do
    echo -e "\n${BLUE}=== NFTables Port Forwarding Management ===${NC}"
    echo "1) View current forwarding rules"
    echo "2) Add new forwarding rule"
    echo "3) Delete forwarding rule"
    echo "4) Exit"
    read -p "Select an option (1-4): " choice
    
    case $choice in
        1)
            display_rules
            ;;
        2)
            add_rule
            ;;
        3)
            delete_rule
            ;;
        4)
            log_info "Exiting..."
            exit 0
            ;;
        *)
            log_error "Invalid option. Please select 1-4"
            ;;
    esac
done 