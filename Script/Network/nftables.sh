#!/bin/bash

# ============================================================================
# NFTables 端口转发与保护管理工具
# 用途：管理 Linux 系统上的端口转发规则和防火墙保护
# 功能：
#   - 端口转发：本地转发和远程转发
#   - 端口保护：防火墙过滤，仅允许指定端口访问
#   - 联动机制：添加转发规则时自动开启保护
# ============================================================================

# ============================================================================
# 常量定义
# ============================================================================

# NFTables 表和链名称（IPv4/IPv6 共用同名表）
readonly TABLE_NAME="fowardaws"
readonly CHAIN_PREROUTING="prerouting"
readonly CHAIN_POSTROUTING="postrouting"
readonly CHAIN_OUTPUT="output"
readonly CHAIN_INPUT="input"

# 配置文件路径
readonly CONFIG_FILE="/etc/nftables.conf"

# 默认开放端口（保护模式下允许访问的端口）
readonly DEFAULT_OPEN_PORTS="5168,51080,52080"

# 输出颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ============================================================================
# 日志函数
# ============================================================================

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug()   { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# ============================================================================
# 工具函数
# ============================================================================

# 验证端口号是否有效 (1-65535)
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# 验证 IP 地址格式和范围
validate_ip_address() {
    local ip="$1"
    
    # 检查基本格式
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    
    # 检查每个八位字节范围
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
    return 0
}

# 规范化端口列表格式（去除空格，去重，排序）
normalize_ports() {
    local ports="$1"
    echo "$ports" | tr -d ' ' | tr ',' '\n' | sort -un | tr '\n' ',' | sed 's/,$//'
}

# ============================================================================
# 核心函数
# ============================================================================

# 通用表存在性检查
ensure_table_family() {
    local family="$1"
    nft list tables "$family" 2>/dev/null | grep -q "$TABLE_NAME" || nft add table "$family" "$TABLE_NAME"
}

# 确保 IPv4 NAT 表与基础链存在
ensure_nat_table_v4() {
    ensure_table_family ip
    nft list chains ip "$TABLE_NAME" 2>/dev/null | grep -q "chain $CHAIN_PREROUTING" || \
        nft add chain ip "$TABLE_NAME" "$CHAIN_PREROUTING" '{ type nat hook prerouting priority -100; }'
    nft list chains ip "$TABLE_NAME" 2>/dev/null | grep -q "chain $CHAIN_POSTROUTING" || \
        nft add chain ip "$TABLE_NAME" "$CHAIN_POSTROUTING" '{ type nat hook postrouting priority 100; }'
}

# 确保 output 链存在（用于本地转发）
ensure_output_chain() {
    ensure_nat_table_v4
    if ! nft list chains ip "$TABLE_NAME" 2>/dev/null | grep -q "chain $CHAIN_OUTPUT"; then
        nft add chain ip "$TABLE_NAME" "$CHAIN_OUTPUT" '{ type nat hook output priority -100; }'
    fi
}

# 保存当前规则集到配置文件
save_rules() {
    nft list ruleset > "$CONFIG_FILE"
}

# 检测保护模式是否已开启
is_protection_enabled() {
    nft list chain ip "$TABLE_NAME" "$CHAIN_INPUT" 2>/dev/null | grep -q "policy drop" || \
    nft list chain ip6 "$TABLE_NAME" "$CHAIN_INPUT" 2>/dev/null | grep -q "policy drop"
}

# 从转发规则中提取所有源端口
get_forwarding_ports() {
    local prerouting_ports=$(nft list chain ip "$TABLE_NAME" "$CHAIN_PREROUTING" 2>/dev/null | \
        grep -oP 'dport \K[0-9]+(?= dnat)' | sort -u)
    local output_ports=$(nft list chain ip "$TABLE_NAME" "$CHAIN_OUTPUT" 2>/dev/null | \
        grep -oP 'dport \K[0-9]+(?= dnat)' | sort -u)
    
    # 合并并格式化
    echo -e "${prerouting_ports}\n${output_ports}" | grep -v '^$' | sort -un | tr '\n' ',' | sed 's/,$//'
}

# ============================================================================
# 规则管理函数
# ============================================================================

# 验证并解析转发规则，返回格式: local_port:dest_ip:dest_port:is_local
validate_rule() {
    local rule_string="$1"
    
    # 检查规则格式是否为 端口:IP:端口
    if [[ ! "$rule_string" =~ ^[^:]+:[^:]+:[^:]+$ ]]; then
        log_error "规则格式错误: $rule_string (正确格式: 端口:IP:端口)"
        return 1
    fi
    
    local local_port=$(echo "$rule_string" | cut -d':' -f1)
    local dest_ip=$(echo "$rule_string" | cut -d':' -f2)
    local dest_port=$(echo "$rule_string" | cut -d':' -f3)
    local is_local="false"
    
    # 验证源端口
    if ! validate_port "$local_port"; then
        log_error "无效的源端口: $local_port (必须在 1-65535 之间)"
        return 1
    fi
    
    # 处理本地转发标识
    if [[ "$dest_ip" == "local" || "$dest_ip" == "localhost" || "$dest_ip" == "127.0.0.1" ]]; then
        dest_ip="127.0.0.1"
        is_local="true"
    elif ! validate_ip_address "$dest_ip"; then
        log_error "无效的目标IP地址: $dest_ip"
        return 1
    fi
    
    # 验证目标端口
    if ! validate_port "$dest_port"; then
        log_error "无效的目标端口: $dest_port (必须在 1-65535 之间)"
        return 1
    fi
    
    # 返回解析结果
    echo "${local_port}:${dest_ip}:${dest_port}:${is_local}"
    return 0
}

# 检查规则冲突
check_rule_conflict() {
    local local_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_local="$4"
    
    # 表不存在则无冲突
    nft list tables 2>/dev/null | grep -q "$TABLE_NAME" || return 0
    
    local prerouting_rules=$(nft list chain ip "$TABLE_NAME" "$CHAIN_PREROUTING" 2>/dev/null)
    local output_rules=$(nft list chain ip "$TABLE_NAME" "$CHAIN_OUTPUT" 2>/dev/null)
    
    # 精确匹配端口：使用 dport X dnat 格式，X 后有空格确保精确
    if [ "$is_local" = "true" ]; then
        # 本地转发：检查是否与远程转发冲突
        if echo "$prerouting_rules" | grep -qE "dport ${local_port} dnat to"; then
            log_error "端口冲突: 端口 ${local_port} 已被用于远程转发"
            return 1
        fi
        
        # 检查本地转发规则
        local existing=$(echo "$output_rules" | grep -E "dport ${local_port} dnat to")
        if [ -n "$existing" ]; then
            if echo "$existing" | grep -q "dnat to ${dest_ip}:${dest_port}"; then
                log_warn "本地转发规则已存在: 端口 ${local_port} -> ${dest_ip}:${dest_port}"
            else
                log_error "端口冲突: 本地端口 ${local_port} 已被用于其他转发"
            fi
            return 1
        fi
    else
        # 远程转发：检查是否与本地转发冲突
        if echo "$output_rules" | grep -qE "dport ${local_port} dnat to"; then
            log_error "端口冲突: 端口 ${local_port} 已被用于本地转发"
            return 1
        fi
        
        # 检查远程转发规则
        local existing=$(echo "$prerouting_rules" | grep -E "dport ${local_port} dnat to")
        if [ -n "$existing" ]; then
            if echo "$existing" | grep -q "dnat to ${dest_ip}:${dest_port}"; then
                log_warn "转发规则已存在: 端口 ${local_port} -> ${dest_ip}:${dest_port}"
            else
                log_error "端口冲突: 端口 ${local_port} 已被用于其他转发"
            fi
            return 1
        fi
    fi
    
    return 0
}

# 应用单条转发规则
apply_single_forwarding_rule() {
    local local_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_local="$4"
    
    if [ "$is_local" = "true" ]; then
        ensure_output_chain
        nft add rule ip "$TABLE_NAME" "$CHAIN_OUTPUT" tcp dport "$local_port" dnat to "${dest_ip}:${dest_port}"
        nft add rule ip "$TABLE_NAME" "$CHAIN_OUTPUT" udp dport "$local_port" dnat to "${dest_ip}:${dest_port}"
    else
        ensure_nat_table_v4
        nft add rule ip "$TABLE_NAME" "$CHAIN_PREROUTING" tcp dport "$local_port" dnat to "${dest_ip}:${dest_port}"
        nft add rule ip "$TABLE_NAME" "$CHAIN_PREROUTING" udp dport "$local_port" dnat to "${dest_ip}:${dest_port}"
        
        # 添加 masquerade 规则（如果不存在）
        if ! nft list chain ip "$TABLE_NAME" "$CHAIN_POSTROUTING" 2>/dev/null | grep -q "ip daddr $dest_ip masquerade"; then
            nft add rule ip "$TABLE_NAME" "$CHAIN_POSTROUTING" ip daddr "$dest_ip" masquerade
        fi
    fi
    
    save_rules
    return 0
}

# 清除所有转发规则
clear_all_rules() {
    log_info "正在清除所有转发规则..."
    
    local has_ip_table=false
    local has_ip6_table=false
    nft list tables ip 2>/dev/null | grep -q "$TABLE_NAME" && has_ip_table=true
    nft list tables ip6 2>/dev/null | grep -q "$TABLE_NAME" && has_ip6_table=true
    
    if [ "$has_ip_table" = false ] && [ "$has_ip6_table" = false ]; then
        log_warn "转发表不存在，无需清除"
        return 0
    fi
    
    local protection_was_enabled=false
    is_protection_enabled && protection_was_enabled=true
    
    # 清空转发链
    if [ "$has_ip_table" = true ]; then
        nft flush chain ip "$TABLE_NAME" "$CHAIN_PREROUTING" 2>/dev/null
        nft flush chain ip "$TABLE_NAME" "$CHAIN_POSTROUTING" 2>/dev/null
        nft flush chain ip "$TABLE_NAME" "$CHAIN_OUTPUT" 2>/dev/null
    fi
    
    # 如果之前开启了保护，重建为仅默认端口
    if [ "$protection_was_enabled" = true ]; then
        log_info "重建保护规则（仅保留默认端口）..."
        nft delete chain ip "$TABLE_NAME" "$CHAIN_INPUT" 2>/dev/null
        nft delete chain ip6 "$TABLE_NAME" "$CHAIN_INPUT" 2>/dev/null
        build_protection_rules "$DEFAULT_OPEN_PORTS"
    fi
    
    save_rules
    log_info "已清除所有转发规则"
}

# 解析规则集到关联数组
parse_ruleset_to_map() {
    declare -gA RULE_MAP RULE_PROTOCOLS RULE_TYPE
    RULE_MAP=() RULE_PROTOCOLS=() RULE_TYPE=()
    
    nft list tables 2>/dev/null | grep -q "$TABLE_NAME" || return 1
    
    # 处理远程转发规则
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local proto=$(echo "$line" | grep -oP '^(tcp|udp)')
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        [ -z "$src_port" ] || [ -z "$dest" ] && continue
        
        local key="${src_port}:${dest}"
        RULE_MAP["$key"]="$dest"
        RULE_TYPE["$key"]="remote"
        
        if [ -z "${RULE_PROTOCOLS[$key]}" ]; then
            RULE_PROTOCOLS["$key"]="${proto^^}"
        elif [[ "${RULE_PROTOCOLS[$key]}" != *"${proto^^}"* ]]; then
            RULE_PROTOCOLS["$key"]="TCP+UDP"
        fi
    done < <(nft list chain ip "$TABLE_NAME" "$CHAIN_PREROUTING" 2>/dev/null | grep "dnat to")
    
    # 处理本地转发规则
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local proto=$(echo "$line" | grep -oP '^(tcp|udp)')
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        [ -z "$src_port" ] || [ -z "$dest" ] && continue
        
        local key="${src_port}:${dest}:local"
        RULE_MAP["$key"]="$dest"
        RULE_TYPE["$key"]="local"
        
        if [ -z "${RULE_PROTOCOLS[$key]}" ]; then
            RULE_PROTOCOLS["$key"]="${proto^^}"
        elif [[ "${RULE_PROTOCOLS[$key]}" != *"${proto^^}"* ]]; then
            RULE_PROTOCOLS["$key"]="TCP+UDP"
        fi
    done < <(nft list chain ip "$TABLE_NAME" "$CHAIN_OUTPUT" 2>/dev/null | grep "dnat to")
    
    [ ${#RULE_MAP[@]} -gt 0 ]
}

# ============================================================================
# 保护模式函数
# ============================================================================

# 创建保护链（支持 IPv4/IPv6）
create_input_chain() {
    local family="$1"
    local ports="$2"
    
    ensure_table_family "$family"
    nft delete chain "$family" "$TABLE_NAME" "$CHAIN_INPUT" 2>/dev/null
    nft add chain "$family" "$TABLE_NAME" "$CHAIN_INPUT" '{ type filter hook input priority 0; policy drop; }'
    nft add rule "$family" "$TABLE_NAME" "$CHAIN_INPUT" iifname "lo" accept
    nft add rule "$family" "$TABLE_NAME" "$CHAIN_INPUT" ct state established,related accept
    
    if [ "$family" = "ip" ]; then
        nft add rule ip "$TABLE_NAME" "$CHAIN_INPUT" ip protocol icmp accept
        nft add rule ip "$TABLE_NAME" "$CHAIN_INPUT" tcp dport "{ $ports }" accept
        nft add rule ip "$TABLE_NAME" "$CHAIN_INPUT" udp dport "{ $ports }" accept
    else
        nft add rule ip6 "$TABLE_NAME" "$CHAIN_INPUT" ip6 nexthdr icmpv6 accept
        nft add rule ip6 "$TABLE_NAME" "$CHAIN_INPUT" tcp dport "{ $ports }" accept
        nft add rule ip6 "$TABLE_NAME" "$CHAIN_INPUT" udp dport "{ $ports }" accept
    fi
}

# 构建保护规则（核心函数，被其他保护函数调用）
build_protection_rules() {
    local ports="$1"
    create_input_chain "ip" "$ports"
    create_input_chain "ip6" "$ports"
    save_rules
}

# 获取当前保护链开放端口（优先 IPv4，回退 IPv6）
get_current_protection_ports() {
    local ports=$(nft list chain ip "$TABLE_NAME" "$CHAIN_INPUT" 2>/dev/null | \
        grep "tcp dport" | grep -oP '\{ \K[^}]+' | head -1 | tr -d ' ')
    [ -n "$ports" ] && { echo "$ports"; return 0; }
    nft list chain ip6 "$TABLE_NAME" "$CHAIN_INPUT" 2>/dev/null | \
        grep "tcp dport" | grep -oP '\{ \K[^}]+' | head -1 | tr -d ' '
}

# 开启保护模式（可选包含转发端口）
enable_protection() {
    local include_forward="${1:-false}"
    
    log_info "正在开启端口保护模式..."
    
    local all_ports="$DEFAULT_OPEN_PORTS"
    
    if [ "$include_forward" = "true" ]; then
        local forward_ports=$(get_forwarding_ports)
        if [ -n "$forward_ports" ]; then
            all_ports=$(normalize_ports "${DEFAULT_OPEN_PORTS},${forward_ports}")
        fi
    fi
    
    build_protection_rules "$all_ports"
    log_info "端口保护已开启，开放端口: $all_ports"
}

# 关闭保护模式
disable_protection() {
    log_info "正在关闭端口保护模式..."
    
    local removed=false
    nft delete chain ip "$TABLE_NAME" "$CHAIN_INPUT" 2>/dev/null && removed=true
    nft delete chain ip6 "$TABLE_NAME" "$CHAIN_INPUT" 2>/dev/null && removed=true
    if [ "$removed" = true ]; then
        save_rules
        log_info "端口保护已关闭"
    else
        log_warn "保护模式未开启"
    fi
}

# 追加开放端口到保护规则
add_open_port() {
    local new_port="$1"
    
    is_protection_enabled || return 0
    
    # 获取当前开放的端口（处理 nft 输出格式）
    local current_ports=$(get_current_protection_ports)
    
    [ -z "$current_ports" ] && return 1
    
    # 检查端口是否已存在
    if echo ",$current_ports," | grep -q ",${new_port},"; then
        log_debug "端口 $new_port 已在开放列表中"
        return 0
    fi
    
    # 重建保护规则
    local all_ports=$(normalize_ports "${current_ports},${new_port}")
    build_protection_rules "$all_ports"
    log_debug "已追加开放端口: $new_port"
}

# 显示保护状态
show_protection_status() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}           端口保护状态${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    if is_protection_enabled; then
        echo -e "保护状态: ${GREEN}已开启${NC}"
        
        local current_ports=$(get_current_protection_ports)
        [ -n "$current_ports" ] && echo -e "开放端口: ${YELLOW}$current_ports${NC}"
        echo -e "默认端口: ${BLUE}$DEFAULT_OPEN_PORTS${NC}"
        
        local forward_ports=$(get_forwarding_ports)
        [ -n "$forward_ports" ] && echo -e "转发端口: ${YELLOW}$forward_ports${NC}"
    else
        echo -e "保护状态: ${RED}未开启${NC}"
        echo -e "说明: 所有端口均可访问"
    fi
    
    echo -e "${BLUE}========================================${NC}"
}

# ============================================================================
# 业务函数
# ============================================================================

# 批量添加规则
add_rule_batch() {
    local rules=("$@")
    
    [ ${#rules[@]} -eq 0 ] && { log_error "未提供任何规则"; return 1; }
    
    log_info "准备批量添加 ${#rules[@]} 条转发规则..."
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null
    
    local -a success_rules success_ports failed_rules skipped_rules
    
    for rule in "${rules[@]}"; do
        log_info "处理规则: $rule"
        
        # 验证并解析规则
        local parsed=$(validate_rule "$rule")
        if [ $? -ne 0 ]; then
            failed_rules+=("$rule (格式验证失败)")
            continue
        fi
        
        # 解析返回值
        local local_port=$(echo "$parsed" | cut -d':' -f1)
        local dest_ip=$(echo "$parsed" | cut -d':' -f2)
        local dest_port=$(echo "$parsed" | cut -d':' -f3)
        local is_local=$(echo "$parsed" | cut -d':' -f4)
        
        # 检查冲突
        if ! check_rule_conflict "$local_port" "$dest_ip" "$dest_port" "$is_local"; then
            skipped_rules+=("$rule (冲突或已存在)")
            continue
        fi
        
        # 应用规则
        if apply_single_forwarding_rule "$local_port" "$dest_ip" "$dest_port" "$is_local"; then
            success_rules+=("$rule")
            success_ports+=("$local_port")
            log_debug "规则已添加: $rule"
        else
            failed_rules+=("$rule (应用失败)")
        fi
    done
    
    # 处理结果
    if [ ${#success_rules[@]} -gt 0 ]; then
        rm -f "${CONFIG_FILE}.bak"
        
        # 更新保护模式
        if is_protection_enabled; then
            for port in "${success_ports[@]}"; do
                add_open_port "$port"
            done
        else
            enable_protection "true"
        fi
    else
        [ -f "${CONFIG_FILE}.bak" ] && mv "${CONFIG_FILE}.bak" "$CONFIG_FILE" && nft -f "$CONFIG_FILE" 2>/dev/null
    fi
    
    # 输出摘要
    print_batch_summary success_rules skipped_rules failed_rules
    [ ${#success_rules[@]} -gt 0 ] && show_protection_status
}

# 打印批量操作摘要
print_batch_summary() {
    local -n _success=$1 _skipped=$2 _failed=$3
    
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}           批量添加结果摘要${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    echo -e "${GREEN}成功添加: ${#_success[@]} 条${NC}"
    for rule in "${_success[@]}"; do echo -e "  ${GREEN}✓${NC} $rule"; done
    
    if [ ${#_skipped[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}跳过规则: ${#_skipped[@]} 条${NC}"
        for rule in "${_skipped[@]}"; do echo -e "  ${YELLOW}○${NC} $rule"; done
    fi
    
    if [ ${#_failed[@]} -gt 0 ]; then
        echo -e "\n${RED}失败规则: ${#_failed[@]} 条${NC}"
        for rule in "${_failed[@]}"; do echo -e "  ${RED}✗${NC} $rule"; done
    fi
    
    echo -e "${BLUE}========================================${NC}"
}

# 显示当前规则
display_rules() {
    log_info "当前端口转发规则:"
    
    if ! parse_ruleset_to_map; then
        log_warn "未找到转发规则"
        return
    fi
    
    echo -e "${YELLOW}=== 端口转发规则 ===${NC}"
    local count=1
    
    for key in "${!RULE_MAP[@]}"; do
        local src_port=$(echo "$key" | cut -d':' -f1)
        local dest="${RULE_MAP[$key]}"
        local protocol="${RULE_PROTOCOLS[$key]}"
        local type="${RULE_TYPE[$key]}"
        
        if [ "$type" = "local" ]; then
            echo -e "${GREEN}$count)${NC} ${BLUE}[本地]${NC} 端口: ${YELLOW}$src_port${NC} -> ${YELLOW}$dest${NC} (${BLUE}$protocol${NC})"
        else
            echo -e "${GREEN}$count)${NC} 端口: ${YELLOW}$src_port${NC} -> 目标: ${YELLOW}$dest${NC} (${BLUE}$protocol${NC})"
        fi
        ((count++))
    done
}

# 显示帮助信息
show_help() {
    cat << EOF
${BLUE}NFTables 端口转发与保护管理工具${NC}

${GREEN}用法:${NC}
  $0 --help                       ${YELLOW}# 显示此帮助${NC}
  $0 --list                       ${YELLOW}# 列出当前转发规则${NC}
  $0 --add 规则1 [规则2 ...]      ${YELLOW}# 批量添加转发规则（自动开启保护）${NC}
  $0 --replace 规则1 [规则2 ...]  ${YELLOW}# 清除现有规则后添加新规则${NC}
  $0 --protect on                 ${YELLOW}# 开启端口保护（仅开放默认端口，IPv4+IPv6）${NC}
  $0 --protect off                ${YELLOW}# 关闭端口保护${NC}
  $0 --protect status             ${YELLOW}# 查看保护状态${NC}

${GREEN}规则格式:${NC} 源端口:目标IP:目标端口
  ${BLUE}远程转发:${NC} 8080:192.168.1.10:80
  ${BLUE}本地转发:${NC} 9000:local:3000 (或 localhost/127.0.0.1)

${GREEN}端口保护:${NC}
  默认开放端口: ${YELLOW}$DEFAULT_OPEN_PORTS${NC}
  - 保护模式开启后，仅允许访问开放的端口（IPv4+IPv6 同步）
  - 端口转发仅支持 IPv4，IPv6 仅用于保护
  - 添加转发规则时会自动开启保护并开放转发端口
  - 已建立的连接和 ICMP 流量始终允许通过

${GREEN}示例:${NC}
  ${BLUE}# 场景1：只开启保护（不转发）${NC}
  $0 --protect on

  ${BLUE}# 场景2：添加转发规则（自动开启保护）${NC}
  $0 --add 8080:192.168.1.10:80
  ${YELLOW}# 结果：开放 $DEFAULT_OPEN_PORTS + 8080${NC}

  ${BLUE}# 场景3：已保护后追加转发${NC}
  $0 --protect on
  $0 --add 9000:192.168.1.20:443
  ${YELLOW}# 结果：开放 $DEFAULT_OPEN_PORTS + 9000${NC}

  ${BLUE}# 场景4：关闭保护${NC}
  $0 --protect off

${GREEN}说明:${NC}
  - 每条规则会同时创建 TCP 和 UDP 转发
  - 本地转发用于在本机内部重定向端口
  - 远程转发用于将流量转发到其他主机
  - --add 会自动检测并阻止端口冲突和重复规则
  - --replace 会先清除所有现有规则，再添加新规则
  - 使用转发功能时会自动开启保护模式

EOF
}

# ============================================================================
# 初始化函数
# ============================================================================

initialize_nftables() {
    log_info "正在初始化 nftables 端口转发配置"
    
    if ! nft list tables 2>/dev/null | grep -q "$TABLE_NAME"; then
        cat > "$CONFIG_FILE" << 'EOF'
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
        if nft -f "$CONFIG_FILE"; then
            log_info "基础转发配置已创建并加载"
        else
            log_error "初始化 nftables 配置失败"
            return 1
        fi
    else
        log_info "转发表已存在"
    fi
    
    # 确保 IPv4 NAT 链存在（幂等）
    ensure_nat_table_v4
    
    # 启用 IP 转发
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward
        
        if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
            echo -e "\n# 启用 IP 转发以支持端口转发\nnet.ipv4.ip_forward = 1" >> /etc/sysctl.conf
            sysctl -p > /dev/null 2>&1
        fi
        log_info "IP 转发已启用"
    fi
}

# ============================================================================
# 主流程
# ============================================================================

# 检查 root 权限
[ "$EUID" -ne 0 ] && { log_error "此脚本必须以 root 权限运行"; exit 1; }

# 检查系统类型
grep -qiE 'debian|ubuntu' /etc/os-release 2>/dev/null || { log_error "此脚本仅支持 Debian 或 Ubuntu 系统"; exit 1; }

# 检查并安装 nftables
if ! command -v nft &> /dev/null; then
    log_warn "nftables 未安装，正在自动安装..."
    apt update > /dev/null 2>&1 && apt install -y nftables > /dev/null 2>&1 || { log_error "nftables 安装失败"; exit 1; }
    log_info "nftables 安装成功"
else
    log_info "nftables 已安装"
fi

# 启用服务
systemctl enable nftables > /dev/null 2>&1
systemctl start nftables > /dev/null 2>&1

# 初始化
initialize_nftables

# 命令行参数处理
[ $# -eq 0 ] && { show_help; exit 0; }

case "$1" in
    --help|-h)
        show_help
        ;;
    --list|-l)
        display_rules
        ;;
    --add|-a)
        shift
        [ $# -eq 0 ] && { log_error "未提供任何规则。用法: $0 --add 规则1 [规则2 ...]"; show_help; exit 1; }
        add_rule_batch "$@"
        ;;
    --replace|-r)
        shift
        [ $# -eq 0 ] && { log_error "未提供任何规则。用法: $0 --replace 规则1 [规则2 ...]"; show_help; exit 1; }
        clear_all_rules
        add_rule_batch "$@"
        ;;
    --protect|-p)
        shift
        [ $# -eq 0 ] && { log_error "未提供保护模式参数。用法: $0 --protect [on|off|status]"; show_help; exit 1; }
        case "$1" in
            on)     enable_protection "false"; show_protection_status ;;
            off)    disable_protection; show_protection_status ;;
            status) show_protection_status ;;
            *)      log_error "未知的保护模式参数: $1"; exit 1 ;;
        esac
        ;;
    *)
        log_error "未知参数: $1"
        show_help
        exit 1
        ;;
esac

exit 0
