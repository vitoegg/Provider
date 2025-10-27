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

# ============================================================================
# 工具函数区 - 核心逻辑抽象
# ============================================================================

# 规则验证函数
function validate_rule() {
    local rule_string="$1"
    
    # 检查规则格式是否为 端口:IP:端口
    if [[ ! "$rule_string" =~ ^[^:]+:[^:]+:[^:]+$ ]]; then
        log_error "规则格式错误: $rule_string (正确格式: 端口:IP:端口)"
        return 1
    fi
    
    # 解析规则
    local local_port=$(echo "$rule_string" | cut -d':' -f1)
    local dest_ip=$(echo "$rule_string" | cut -d':' -f2)
    local dest_port=$(echo "$rule_string" | cut -d':' -f3)
    
    # 验证源端口
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        log_error "无效的源端口: $local_port (必须在 1-65535 之间)"
        return 1
    fi
    
    # 检查是否为本地转发
    local is_local=false
    if [[ "$dest_ip" == "local" || "$dest_ip" == "localhost" || "$dest_ip" == "127.0.0.1" ]]; then
        dest_ip="127.0.0.1"
        is_local=true
    elif ! [[ "$dest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "无效的目标IP地址: $dest_ip (支持格式: IP地址 或 local/localhost)"
        return 1
    fi
    
    # 验证目标端口
    if ! [[ "$dest_port" =~ ^[0-9]+$ ]] || [ "$dest_port" -lt 1 ] || [ "$dest_port" -gt 65535 ]; then
        log_error "无效的目标端口: $dest_port (必须在 1-65535 之间)"
        return 1
    fi
    
    # 输出验证后的值到全局变量
    VALIDATED_LOCAL_PORT="$local_port"
    VALIDATED_DEST_IP="$dest_ip"
    VALIDATED_DEST_PORT="$dest_port"
    VALIDATED_IS_LOCAL="$is_local"
    
    return 0
}

# 冲突检测函数
function check_rule_conflict() {
    local local_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_local="$4"
    
    # 获取当前规则集
    local ruleset_output=$(nft list ruleset 2>/dev/null)
    
    if [ -z "$ruleset_output" ]; then
        # 没有规则集，没有冲突
        return 0
    fi
    
    # 根据是否本地转发检查不同的链
    if [ "$is_local" = true ]; then
        # 检查本地转发规则(output链)
        local existing_tcp=$(echo "$ruleset_output" | grep "chain output" -A20 | grep "tcp dport ${local_port} dnat to")
        local existing_udp=$(echo "$ruleset_output" | grep "chain output" -A20 | grep "udp dport ${local_port} dnat to")
        
        if [[ -n "$existing_tcp" || -n "$existing_udp" ]]; then
            # 检查是否是完全相同的规则
            if echo "$existing_tcp" | grep -q "dnat to ${dest_ip}:${dest_port}" && \
               echo "$existing_udp" | grep -q "dnat to ${dest_ip}:${dest_port}"; then
                log_warn "本地转发规则已存在: 端口 ${local_port} -> ${dest_ip}:${dest_port}"
                return 1
            else
                log_error "端口冲突: 本地端口 ${local_port} 已被用于其他转发规则"
                return 1
            fi
        fi
    else
        # 检查远程转发规则(prerouting链)
        local existing_tcp=$(echo "$ruleset_output" | grep "chain prerouting" -A20 | grep "tcp dport ${local_port} dnat to")
        local existing_udp=$(echo "$ruleset_output" | grep "chain prerouting" -A20 | grep "udp dport ${local_port} dnat to")
        
        if [[ -n "$existing_tcp" || -n "$existing_udp" ]]; then
            # 检查是否是完全相同的规则
            if echo "$existing_tcp" | grep -q "dnat to ${dest_ip}:${dest_port}" && \
               echo "$existing_udp" | grep -q "dnat to ${dest_ip}:${dest_port}"; then
                log_warn "转发规则已存在: 端口 ${local_port} -> ${dest_ip}:${dest_port}"
                return 1
            else
                log_error "端口冲突: 端口 ${local_port} 已被用于其他转发规则"
                return 1
            fi
        fi
    fi
    
    return 0
}

# 规则应用函数
function apply_single_forwarding_rule() {
    local local_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_local="$4"
    
    # 检查表和链是否存在
    if ! grep -q "table ip fowardaws" "$CONFIG_FILE"; then
        # 创建基础配置
        cat > "$CONFIG_FILE" << EOF
#!/usr/sbin/nft -f

flush ruleset

table ip fowardaws {
    chain prerouting {
        type nat hook prerouting priority -100;
    }

    chain postrouting {
        type nat hook postrouting priority 100;
    }
}
EOF
    fi
    
    # 为本地转发添加output链(如果需要且不存在)
    if [ "$is_local" = true ] && ! grep -q "chain output" "$CONFIG_FILE"; then
        sed -i "/table ip fowardaws {/a\\    chain output {\n        type nat hook output priority -100;\n    }" "$CONFIG_FILE"
    fi
    
    # 添加转发规则
    if [ "$is_local" = true ]; then
        # 本地转发：添加到output链
        sed -i "/chain output {/,/}/{s/}/        tcp dport $local_port dnat to $dest_ip:$dest_port\n        udp dport $local_port dnat to $dest_ip:$dest_port\n    }/}" "$CONFIG_FILE"
    else
        # 远程转发：添加到prerouting链
        sed -i "/chain prerouting {/,/}/{s/}/        tcp dport $local_port dnat to $dest_ip:$dest_port\n        udp dport $local_port dnat to $dest_ip:$dest_port\n    }/}" "$CONFIG_FILE"
        
        # 添加masquerade规则(如果还不存在)
        if ! grep -q "ip daddr $dest_ip masquerade" "$CONFIG_FILE"; then
            sed -i "/chain postrouting {/,/}/{s/}/        ip daddr $dest_ip masquerade\n    }/}" "$CONFIG_FILE"
        fi
    fi
    
    return 0
}

# 帮助信息函数
function show_help() {
    cat << EOF
${BLUE}NFTables 端口转发管理工具${NC}

${GREEN}用法:${NC}
  $0                          ${YELLOW}# 进入交互式菜单${NC}
  $0 --add 规则1 [规则2 ...]  ${YELLOW}# 批量添加转发规则${NC}
  $0 --list                   ${YELLOW}# 列出当前规则${NC}
  $0 --help                   ${YELLOW}# 显示此帮助${NC}

${GREEN}规则格式:${NC} 源端口:目标IP:目标端口
  ${BLUE}远程转发:${NC} 8080:192.168.1.10:80
  ${BLUE}本地转发:${NC} 9000:local:3000 (或 localhost/127.0.0.1)

${GREEN}示例:${NC}
  $0 --add 8080:192.168.1.10:80 8443:192.168.1.10:443
  $0 --add 9000:local:3000
  $0 --add 3306:192.168.1.100:3306 6379:local:6379

${GREEN}说明:${NC}
  - 每条规则会同时创建 TCP 和 UDP 转发
  - 本地转发用于在本机内部重定向端口
  - 远程转发用于将流量转发到其他主机
  - 系统会自动检测并阻止端口冲突和重复规则

EOF
}

# 批量添加规则函数
function add_rule_batch() {
    local rules=("$@")
    
    if [ ${#rules[@]} -eq 0 ]; then
        log_error "未提供任何规则"
        return 1
    fi
    
    log_info "准备批量添加 ${#rules[@]} 条转发规则..."
    
    # 备份配置文件
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    
    # 结果统计
    local -a success_rules
    local -a failed_rules
    local -a skipped_rules
    
    # 处理每条规则
    for rule in "${rules[@]}"; do
        log_info "处理规则: $rule"
        
        # 验证规则
        if ! validate_rule "$rule"; then
            failed_rules+=("$rule (格式验证失败)")
            continue
        fi
        
        local local_port="$VALIDATED_LOCAL_PORT"
        local dest_ip="$VALIDATED_DEST_IP"
        local dest_port="$VALIDATED_DEST_PORT"
        local is_local="$VALIDATED_IS_LOCAL"
        
        # 检查冲突
        if ! check_rule_conflict "$local_port" "$dest_ip" "$dest_port" "$is_local"; then
            skipped_rules+=("$rule (冲突或已存在)")
            continue
        fi
        
        # 应用规则
        if apply_single_forwarding_rule "$local_port" "$dest_ip" "$dest_port" "$is_local"; then
            success_rules+=("$rule")
            log_debug "规则已添加到配置: $rule"
        else
            failed_rules+=("$rule (应用失败)")
        fi
    done
    
    # 重载nftables配置
    if [ ${#success_rules[@]} -gt 0 ]; then
        log_info "正在重载 nftables 配置..."
        if nft -f "$CONFIG_FILE"; then
            log_info "配置重载成功"
        else
            log_error "配置重载失败，正在恢复备份..."
            mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
            log_error "所有更改已回滚"
            return 1
        fi
    else
        log_warn "没有成功添加任何规则，跳过重载"
        # 恢复备份
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
    fi
    
    # 输出摘要
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}           批量添加结果摘要${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}成功添加: ${#success_rules[@]} 条${NC}"
    for rule in "${success_rules[@]}"; do
        echo -e "  ${GREEN}✓${NC} $rule"
    done
    
    if [ ${#skipped_rules[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}跳过规则: ${#skipped_rules[@]} 条${NC}"
        for rule in "${skipped_rules[@]}"; do
            echo -e "  ${YELLOW}○${NC} $rule"
        done
    fi
    
    if [ ${#failed_rules[@]} -gt 0 ]; then
        echo -e "\n${RED}失败规则: ${#failed_rules[@]} 条${NC}"
        for rule in "${failed_rules[@]}"; do
            echo -e "  ${RED}✗${NC} $rule"
        done
    fi
    
    echo -e "${BLUE}========================================${NC}"
    
    return 0
}

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

# Function to add new forwarding rule (interactive mode)
function add_rule() {
    log_info "添加新的端口转发规则"
    
    # Get input from user
    read -p "输入源端口号: " local_port
    read -p "输入目标IP地址 (或输入 'local' 表示本地转发): " dest_ip
    read -p "输入目标端口号: " dest_port
    
    # 构建规则字符串并验证
    local rule_string="${local_port}:${dest_ip}:${dest_port}"
    
    if ! validate_rule "$rule_string"; then
        return 1
    fi
    
    local validated_port="$VALIDATED_LOCAL_PORT"
    local validated_ip="$VALIDATED_DEST_IP"
    local validated_dest_port="$VALIDATED_DEST_PORT"
    local validated_is_local="$VALIDATED_IS_LOCAL"
    
    # 检查冲突
    if ! check_rule_conflict "$validated_port" "$validated_ip" "$validated_dest_port" "$validated_is_local"; then
        log_error "无法添加规则，请检查上述冲突信息"
        return 1
    fi
    
    # 备份配置文件
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    
    # 应用规则
    if ! apply_single_forwarding_rule "$validated_port" "$validated_ip" "$validated_dest_port" "$validated_is_local"; then
        log_error "应用规则失败"
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        return 1
    fi
    
    # 重载nftables配置
    if nft -f "$CONFIG_FILE"; then
        if [ "$validated_is_local" = true ]; then
            log_info "本地端口转发规则添加成功 (TCP+UDP): 端口 $validated_port -> $validated_ip:$validated_dest_port"
        else
            log_info "端口转发规则添加成功 (TCP+UDP): 端口 $validated_port -> $validated_ip:$validated_dest_port"
        fi
        log_debug "当前 nftables 规则集:"
        nft list ruleset
    else
        log_error "应用新规则失败，正在恢复备份"
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        return 1
    fi
    
    return 0
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
    
    # Save the changes to the config file by removing the specific rules
    # Instead of overwriting with nft list ruleset, we delete the specific lines from config file
    if [ "$selected_type" = "remote" ]; then
        # Delete TCP rule from config if it was deleted
        if [[ "$selected_protocol" == *"TCP"* ]] && [ -n "$tcp_handle" ]; then
            sed -i "/tcp dport ${selected_port} dnat to ${selected_dest}/d" "$CONFIG_FILE"
            log_debug "Removed TCP rule from config file"
        fi
        
        # Delete UDP rule from config if it was deleted
        if [[ "$selected_protocol" == *"UDP"* ]] && [ -n "$udp_handle" ]; then
            sed -i "/udp dport ${selected_port} dnat to ${selected_dest}/d" "$CONFIG_FILE"
            log_debug "Removed UDP rule from config file"
        fi
    else
        # Delete local TCP rule from config if it was deleted
        if [[ "$selected_protocol" == *"TCP"* ]] && [ -n "$local_tcp_handle" ]; then
            sed -i "/tcp dport ${selected_port} dnat to ${selected_dest}/d" "$CONFIG_FILE"
            log_debug "Removed local TCP rule from config file"
        fi
        
        # Delete local UDP rule from config if it was deleted
        if [[ "$selected_protocol" == *"UDP"* ]] && [ -n "$local_udp_handle" ]; then
            sed -i "/udp dport ${selected_port} dnat to ${selected_dest}/d" "$CONFIG_FILE"
            log_debug "Removed local UDP rule from config file"
        fi
    fi
    
    # Delete masquerade rule from config if it was deleted
    if [ -n "$masq_handle" ]; then
        sed -i "/ip daddr ${selected_ip} masquerade/d" "$CONFIG_FILE"
        log_debug "Removed masquerade rule from config file"
    fi
    
    log_info "Port forwarding rule deleted successfully"
    
    # Verify deletion by listing current rules
    log_debug "Verifying deletion..."
    nft list table ip fowardaws
}

# ============================================================================
# 主流程 - 命令行参数解析和交互式菜单
# ============================================================================

# 检查是否有命令行参数
if [ $# -gt 0 ]; then
    # 命令行模式
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --list|-l)
            display_rules
            exit 0
            ;;
        --add|-a)
            # 获取所有规则参数（从第二个参数开始）
            shift
            if [ $# -eq 0 ]; then
                log_error "未提供任何规则。用法: $0 --add 规则1 [规则2 ...]"
                echo ""
                show_help
                exit 1
            fi
            # 调用批量添加函数
            add_rule_batch "$@"
            exit $?
            ;;
        --delete|-d)
            log_error "命令行删除功能尚未实现，请使用交互式菜单"
            exit 1
            ;;
        *)
            log_error "未知参数: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
else
    # 交互式菜单模式
    while true; do
        echo -e "\n${BLUE}=== NFTables 端口转发管理 ===${NC}"
        echo "1) 查看当前转发规则"
        echo "2) 添加新的转发规则"
        echo "3) 删除转发规则"
        echo "4) 退出"
        read -p "请选择操作 (1-4): " choice
        
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
                log_info "退出程序..."
                exit 0
                ;;
            *)
                log_error "无效选项，请选择 1-4"
                ;;
        esac
    done
fi 