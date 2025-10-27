#!/bin/bash

# ============================================================================
# NFTables 端口转发管理工具
# 用途：管理 Linux 系统上的端口转发规则（本地转发和远程转发）
# ============================================================================

# 输出颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志输出函数
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

# 检查脚本是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    log_error "此脚本必须以 root 权限运行"
    exit 1
fi

# 检查系统是否为 Debian 或 Ubuntu
if ! grep -qiE 'debian|ubuntu' /etc/os-release; then
    log_error "此脚本仅支持 Debian 或 Ubuntu 系统"
    exit 1
fi

# 检查 nftables 是否已安装，若未安装则自动安装
if ! command -v nft &> /dev/null; then
    log_warn "nftables 未安装，正在自动安装..."
    apt update > /dev/null 2>&1
    apt install -y nftables > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        log_error "nftables 安装失败，请手动安装"
        exit 1
    else
        log_info "nftables 安装成功"
    fi
else
    log_info "nftables 已安装"
fi

# 启用并启动 nftables 服务
systemctl enable nftables > /dev/null 2>&1
systemctl start nftables > /dev/null 2>&1

# 配置文件路径
CONFIG_FILE="/etc/nftables.conf"

# 初始化 nftables 配置函数
function initialize_nftables() {
    log_info "正在初始化 nftables 端口转发配置"
    
    # 检查转发表是否已存在
    if ! nft list tables | grep -q "fowardaws"; then
        # 创建基础配置文件
        cat > "$CONFIG_FILE" << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table ip fowardaws {
    chain prerouting {
        type nat hook prerouting priority -100;
        # TCP 和 UDP 转发规则将在此处添加
    }

    chain postrouting {
        type nat hook postrouting priority 100;
        # Masquerade 规则将在此处添加
    }
}
EOF
        # 加载配置
        if nft -f "$CONFIG_FILE"; then
            log_info "基础转发配置已创建并加载"
        else
            log_error "初始化 nftables 配置失败"
            return 1
        fi
    else
        log_info "转发表已存在"
    fi
    
    # 确保内核 IP 转发已启用
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward
        
        # 检查 /etc/sysctl.conf 中是否已配置
        if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
            echo "" >> /etc/sysctl.conf
            echo "# 启用 IP 转发以支持端口转发" >> /etc/sysctl.conf
            echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
            sysctl -p > /dev/null 2>&1
        fi
        
        log_info "IP 转发已启用"
    fi
    
    return 0
}

# 启动时初始化 nftables
initialize_nftables

# ============================================================================
# 工具函数区 - 核心逻辑抽象
# ============================================================================

# IP 地址验证函数（增强版，检查每个八位字节范围）
function validate_ip_address() {
    local ip="$1"
    
    # 检查 IP 格式
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi
    
    # 检查每个八位字节是否在 0-255 范围内
    local IFS='.'
    read -ra octets <<< "$ip"
    
    for octet in "${octets[@]}"; do
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
    
    return 0
}

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
    elif ! validate_ip_address "$dest_ip"; then
        log_error "无效的目标IP地址: $dest_ip (支持格式: 有效的 IPv4 地址 或 local/localhost)"
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

# 冲突检测函数（增强版，修复 grep 行数限制问题，添加跨链冲突检测）
function check_rule_conflict() {
    local local_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_local="$4"
    
    # 检查 fowardaws 表是否存在
    if ! nft list tables 2>/dev/null | grep -q "fowardaws"; then
        # 表不存在，没有冲突
        return 0
    fi
    
    # 获取指定链的规则（不使用行数限制）
    local prerouting_rules=$(nft list chain ip fowardaws prerouting 2>/dev/null)
    local output_rules=$(nft list chain ip fowardaws output 2>/dev/null)
    
    # 检查跨链冲突（同一端口不应同时用于本地和远程转发）
    if [ "$is_local" = true ]; then
        # 检查是否在 prerouting 链中已使用该端口
        if echo "$prerouting_rules" | grep -q "dport ${local_port} dnat to"; then
            log_error "端口冲突: 端口 ${local_port} 已被用于远程转发，不能同时用于本地转发"
            return 1
        fi
        
        # 检查 output 链中的规则
        local existing_tcp=$(echo "$output_rules" | grep "tcp dport ${local_port} dnat to")
        local existing_udp=$(echo "$output_rules" | grep "udp dport ${local_port} dnat to")
        
        if [[ -n "$existing_tcp" && -n "$existing_udp" ]]; then
            # 检查是否是完全相同的规则
            if echo "$existing_tcp" | grep -q "dnat to ${dest_ip}:${dest_port}" && \
               echo "$existing_udp" | grep -q "dnat to ${dest_ip}:${dest_port}"; then
                log_warn "本地转发规则已存在: 端口 ${local_port} -> ${dest_ip}:${dest_port}"
                return 1
            else
                log_error "端口冲突: 本地端口 ${local_port} 已被用于其他转发规则"
                return 1
            fi
        elif [[ -n "$existing_tcp" || -n "$existing_udp" ]]; then
            log_error "端口冲突: 本地端口 ${local_port} 已被部分使用"
            return 1
        fi
    else
        # 检查是否在 output 链中已使用该端口
        if echo "$output_rules" | grep -q "dport ${local_port} dnat to"; then
            log_error "端口冲突: 端口 ${local_port} 已被用于本地转发，不能同时用于远程转发"
            return 1
        fi
        
        # 检查 prerouting 链中的规则
        local existing_tcp=$(echo "$prerouting_rules" | grep "tcp dport ${local_port} dnat to")
        local existing_udp=$(echo "$prerouting_rules" | grep "udp dport ${local_port} dnat to")
        
        if [[ -n "$existing_tcp" && -n "$existing_udp" ]]; then
            # 检查是否是完全相同的规则
            if echo "$existing_tcp" | grep -q "dnat to ${dest_ip}:${dest_port}" && \
               echo "$existing_udp" | grep -q "dnat to ${dest_ip}:${dest_port}"; then
                log_warn "转发规则已存在: 端口 ${local_port} -> ${dest_ip}:${dest_port}"
                return 1
            else
                log_error "端口冲突: 端口 ${local_port} 已被用于其他转发规则"
                return 1
            fi
        elif [[ -n "$existing_tcp" || -n "$existing_udp" ]]; then
            log_error "端口冲突: 端口 ${local_port} 已被部分使用"
            return 1
        fi
    fi
    
    return 0
}

# 规则应用函数（优化版，使用 nft 命令直接操作而非 sed）
function apply_single_forwarding_rule() {
    local local_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_local="$4"
    
    # 确保表存在
    if ! nft list tables | grep -q "fowardaws"; then
        nft add table ip fowardaws
        nft add chain ip fowardaws prerouting '{ type nat hook prerouting priority -100; }'
        nft add chain ip fowardaws postrouting '{ type nat hook postrouting priority 100; }'
    fi
    
    # 为本地转发创建 output 链（如果需要且不存在）
    if [ "$is_local" = true ]; then
        if ! nft list chains ip fowardaws 2>/dev/null | grep -q "output"; then
            nft add chain ip fowardaws output '{ type nat hook output priority -100; }'
        fi
        
        # 添加本地转发规则
        nft add rule ip fowardaws output tcp dport $local_port dnat to $dest_ip:$dest_port
        nft add rule ip fowardaws output udp dport $local_port dnat to $dest_ip:$dest_port
    else
        # 添加远程转发规则
        nft add rule ip fowardaws prerouting tcp dport $local_port dnat to $dest_ip:$dest_port
        nft add rule ip fowardaws prerouting udp dport $local_port dnat to $dest_ip:$dest_port
        
        # 检查是否需要添加 masquerade 规则
        if ! nft list chain ip fowardaws postrouting 2>/dev/null | grep -q "ip daddr $dest_ip masquerade"; then
            nft add rule ip fowardaws postrouting ip daddr $dest_ip masquerade
        fi
    fi
    
    # 保存规则集到配置文件
    nft list ruleset > "$CONFIG_FILE"
    
    return 0
}

# ============================================================================
# 规则提取和解析公共函数 - 消除代码重复
# ============================================================================

# 从规则集中提取规则的公共函数
function extract_rules_from_ruleset() {
    local ruleset_output="$1"
    
    # 提取各类规则
    EXTRACTED_TCP_RULES=$(echo "$ruleset_output" | nft list chain ip fowardaws prerouting 2>/dev/null | grep "tcp dport .* dnat to")
    EXTRACTED_UDP_RULES=$(echo "$ruleset_output" | nft list chain ip fowardaws prerouting 2>/dev/null | grep "udp dport .* dnat to")
    EXTRACTED_LOCAL_TCP_RULES=$(echo "$ruleset_output" | nft list chain ip fowardaws output 2>/dev/null | grep "tcp dport .* dnat to")
    EXTRACTED_LOCAL_UDP_RULES=$(echo "$ruleset_output" | nft list chain ip fowardaws output 2>/dev/null | grep "udp dport .* dnat to")
    EXTRACTED_MASQ_RULES=$(echo "$ruleset_output" | nft list chain ip fowardaws postrouting 2>/dev/null | grep "ip daddr .* masquerade")
}

# 解析规则到映射数组的公共函数
function parse_ruleset_to_map() {
    # 清空全局关联数组
    unset RULE_PROTOCOLS
    unset RULE_MAP
    unset RULE_TYPE
    declare -gA RULE_PROTOCOLS
    declare -gA RULE_MAP
    declare -gA RULE_TYPE
    
    # 获取规则集
    local ruleset_output=$(nft list ruleset 2>/dev/null)
    
    if [ -z "$ruleset_output" ] || ! echo "$ruleset_output" | grep -q "table ip fowardaws"; then
        return 1
    fi
    
    # 提取规则
    local tcp_rules=$(nft list chain ip fowardaws prerouting 2>/dev/null | grep "tcp dport .* dnat to")
    local udp_rules=$(nft list chain ip fowardaws prerouting 2>/dev/null | grep "udp dport .* dnat to")
    local local_tcp_rules=$(nft list chain ip fowardaws output 2>/dev/null | grep "tcp dport .* dnat to")
    local local_udp_rules=$(nft list chain ip fowardaws output 2>/dev/null | grep "udp dport .* dnat to")
    
    # 处理远程 TCP 规则
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        local key="${src_port}:${dest}"
        
        RULE_MAP["$key"]="$dest"
        RULE_TYPE["$key"]="remote"
        if [[ -z "${RULE_PROTOCOLS[$key]}" ]]; then
            RULE_PROTOCOLS["$key"]="TCP"
        fi
    done <<< "$tcp_rules"
    
    # 处理远程 UDP 规则并合并
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        local key="${src_port}:${dest}"
        
        RULE_MAP["$key"]="$dest"
        RULE_TYPE["$key"]="remote"
        if [[ -z "${RULE_PROTOCOLS[$key]}" ]]; then
            RULE_PROTOCOLS["$key"]="UDP"
        else
            RULE_PROTOCOLS["$key"]="TCP+UDP"
        fi
    done <<< "$udp_rules"
    
    # 处理本地 TCP 规则
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        local key="${src_port}:${dest}:local"
        
        RULE_MAP["$key"]="$dest"
        RULE_TYPE["$key"]="local"
        if [[ -z "${RULE_PROTOCOLS[$key]}" ]]; then
            RULE_PROTOCOLS["$key"]="TCP"
        fi
    done <<< "$local_tcp_rules"
    
    # 处理本地 UDP 规则并合并
    while read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local src_port=$(echo "$line" | grep -oP 'dport \K[0-9]+')
        local dest=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+:[0-9]+')
        local key="${src_port}:${dest}:local"
        
        RULE_MAP["$key"]="$dest"
        RULE_TYPE["$key"]="local"
        if [[ -z "${RULE_PROTOCOLS[$key]}" ]]; then
            RULE_PROTOCOLS["$key"]="UDP"
        else
            RULE_PROTOCOLS["$key"]="TCP+UDP"
        fi
    done <<< "$local_udp_rules"
    
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
    
    # 验证规则应用结果
    if [ ${#success_rules[@]} -gt 0 ]; then
        log_info "规则已成功应用到运行时配置"
        # 清理备份文件
        rm -f "${CONFIG_FILE}.bak"
    else
        log_warn "没有成功添加任何规则"
        # 恢复备份并重新加载
        if [ -f "${CONFIG_FILE}.bak" ]; then
            mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
            nft -f "$CONFIG_FILE" > /dev/null 2>&1
        fi
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

# 显示当前规则函数（优化版，使用公共函数消除重复代码）
function display_rules() {
    log_info "当前端口转发规则:"
    
    # 检查 nftables 规则集是否存在
    if ! nft list ruleset &> /dev/null; then
        log_warn "未找到 nftables 规则集"
        return
    fi
    
    # 使用公共函数解析规则
    if ! parse_ruleset_to_map; then
        log_warn "未找到转发表或规则"
        return
    fi
    
    # 检查是否有规则
    if [ ${#RULE_MAP[@]} -eq 0 ]; then
        log_warn "未找到转发规则"
        return
    fi
    
    # 显示规则
    echo -e "${YELLOW}=== 端口转发规则 ===${NC}"
    local count=1
    
    for key in "${!RULE_MAP[@]}"; do
        local src_port=$(echo "$key" | cut -d':' -f1)
        local dest="${RULE_MAP[$key]}"
        local dest_ip=$(echo "$dest" | cut -d':' -f1)
        local dest_port=$(echo "$dest" | cut -d':' -f2)
        local protocol="${RULE_PROTOCOLS[$key]}"
        local type="${RULE_TYPE[$key]}"
        
        if [ "$type" = "local" ]; then
            echo -e "${GREEN}$count)${NC} ${BLUE}[本地]${NC} 端口: ${YELLOW}$src_port${NC} -> ${YELLOW}$dest_ip:$dest_port${NC} (${BLUE}$protocol${NC})"
        else
            echo -e "${GREEN}$count)${NC} 端口: ${YELLOW}$src_port${NC} -> 目标: ${YELLOW}$dest_ip:$dest_port${NC} (${BLUE}$protocol${NC})"
        fi
        count=$((count+1))
    done
}

# 添加新转发规则函数（交互模式）
function add_rule() {
    log_info "添加新的端口转发规则"
    
    # 从用户获取输入
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
    
    # 备份当前配置
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    fi
    
    # 应用规则
    if ! apply_single_forwarding_rule "$validated_port" "$validated_ip" "$validated_dest_port" "$validated_is_local"; then
        log_error "应用规则失败"
        if [ -f "${CONFIG_FILE}.bak" ]; then
            mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
            nft -f "$CONFIG_FILE" > /dev/null 2>&1
        fi
        return 1
    fi
    
    # 显示成功信息
    if [ "$validated_is_local" = true ]; then
        log_info "本地端口转发规则添加成功 (TCP+UDP): 端口 $validated_port -> $validated_ip:$validated_dest_port"
    else
        log_info "端口转发规则添加成功 (TCP+UDP): 端口 $validated_port -> $validated_ip:$validated_dest_port"
    fi
    
    # 清理备份文件
    rm -f "${CONFIG_FILE}.bak"
    
    return 0
}

# 删除转发规则函数（优化版，使用公共函数）
function delete_rule() {
    # 首先显示当前规则
    display_rules
    
    # 使用公共函数解析规则
    if ! parse_ruleset_to_map; then
        log_warn "未找到可删除的转发表"
        return
    fi
    
    # 转换为索引数组便于选择
    local combined_ports=()
    local combined_dests=()
    local combined_protocols=()
    local combined_types=()
    
    for key in "${!RULE_MAP[@]}"; do
        local src_port=$(echo "$key" | cut -d':' -f1)
        local dest="${RULE_MAP[$key]}"
        local protocol="${RULE_PROTOCOLS[$key]}"
        local type="${RULE_TYPE[$key]}"
        
        combined_ports+=("$src_port")
        combined_dests+=("$dest")
        combined_protocols+=("$protocol")
        combined_types+=("$type")
    done
    
    # 检查是否有规则
    if [ ${#combined_ports[@]} -eq 0 ]; then
        log_warn "未找到可删除的转发规则"
        return
    fi
    
    # 显示删除选项
    echo -e "\n${YELLOW}请选择要删除的端口转发规则:${NC}"
    for i in "${!combined_ports[@]}"; do
        local src_port="${combined_ports[$i]}"
        local dest="${combined_dests[$i]}"
        local protocol="${combined_protocols[$i]}"
        local type="${combined_types[$i]}"
        local dest_ip=$(echo "$dest" | cut -d':' -f1)
        local dest_port=$(echo "$dest" | cut -d':' -f2)
        
        if [ "$type" = "local" ]; then
            echo "$((i+1))) [本地] 端口 ${src_port} -> ${dest_ip}:${dest_port} (${protocol})"
        else
            echo "$((i+1))) 端口 ${src_port} -> ${dest_ip}:${dest_port} (${protocol})"
        fi
    done
    
    echo "$((${#combined_ports[@]}+1))) 取消"
    
    read -p "输入编号 (1-$((${#combined_ports[@]}+1))): " choice
    
    # 取消选项
    if [ "$choice" -eq "$((${#combined_ports[@]}+1))" ]; then
        log_info "已取消删除操作"
        return
    fi
    
    # 验证输入
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#combined_ports[@]}" ]; then
        log_error "无效的选择"
        return
    fi
    
    # 获取选中的规则信息
    local index=$((choice-1))
    local selected_port="${combined_ports[$index]}"
    local selected_dest="${combined_dests[$index]}"
    local selected_protocol="${combined_protocols[$index]}"
    local selected_type="${combined_types[$index]}"
    local selected_ip=$(echo "$selected_dest" | cut -d':' -f1)
    
    log_info "正在删除端口 ${selected_port} 的 ${selected_protocol} 转发规则..."
    
    # 根据规则类型删除相应的规则
    if [ "$selected_type" = "remote" ]; then
        # 删除远程转发规则
        if [[ "$selected_protocol" == *"TCP"* ]]; then
            local tcp_handle=$(nft -a list chain ip fowardaws prerouting 2>/dev/null | grep "tcp dport ${selected_port} dnat to ${selected_dest}" | grep -oP 'handle \K[0-9]+')
            if [ -n "$tcp_handle" ]; then
                nft delete rule ip fowardaws prerouting handle "$tcp_handle"
                log_debug "已删除 TCP 转发规则 (handle $tcp_handle)"
            fi
        fi
        
        if [[ "$selected_protocol" == *"UDP"* ]]; then
            local udp_handle=$(nft -a list chain ip fowardaws prerouting 2>/dev/null | grep "udp dport ${selected_port} dnat to ${selected_dest}" | grep -oP 'handle \K[0-9]+')
            if [ -n "$udp_handle" ]; then
                nft delete rule ip fowardaws prerouting handle "$udp_handle"
                log_debug "已删除 UDP 转发规则 (handle $udp_handle)"
            fi
        fi
    else
        # 删除本地转发规则
        if [[ "$selected_protocol" == *"TCP"* ]]; then
            local tcp_handle=$(nft -a list chain ip fowardaws output 2>/dev/null | grep "tcp dport ${selected_port} dnat to ${selected_dest}" | grep -oP 'handle \K[0-9]+')
            if [ -n "$tcp_handle" ]; then
                nft delete rule ip fowardaws output handle "$tcp_handle"
                log_debug "已删除本地 TCP 转发规则 (handle $tcp_handle)"
            fi
        fi
        
        if [[ "$selected_protocol" == *"UDP"* ]]; then
            local udp_handle=$(nft -a list chain ip fowardaws output 2>/dev/null | grep "udp dport ${selected_port} dnat to ${selected_dest}" | grep -oP 'handle \K[0-9]+')
            if [ -n "$udp_handle" ]; then
                nft delete rule ip fowardaws output handle "$udp_handle"
                log_debug "已删除本地 UDP 转发规则 (handle $udp_handle)"
            fi
        fi
    fi
    
    # 检查是否还有其他规则使用该目标 IP（本地地址除外）
    if [ "$selected_ip" != "127.0.0.1" ]; then
        local ip_still_in_use=false
        for i in "${!combined_dests[@]}"; do
            if [ $i -ne $index ]; then
                local other_dest="${combined_dests[$i]}"
                local other_ip=$(echo "$other_dest" | cut -d':' -f1)
                
                if [ "$other_ip" == "$selected_ip" ]; then
                    ip_still_in_use=true
                    break
                fi
            fi
        done
        
        # 如果 IP 不再被使用，删除对应的 masquerade 规则
        if [ "$ip_still_in_use" = false ]; then
            local masq_handle=$(nft -a list chain ip fowardaws postrouting 2>/dev/null | grep "ip daddr ${selected_ip} masquerade" | grep -oP 'handle \K[0-9]+')
            if [ -n "$masq_handle" ]; then
                nft delete rule ip fowardaws postrouting handle "$masq_handle"
                log_debug "已删除关联的 masquerade 规则 (handle $masq_handle)"
            fi
        fi
    fi
    
    # 保存更改到配置文件
    nft list ruleset > "$CONFIG_FILE"
    log_info "端口转发规则删除成功"
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
        echo "4) 退出程序"
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
                log_info "正在退出程序..."
                exit 0
                ;;
            *)
                log_error "无效选项，请选择 1-4"
                ;;
        esac
    done
fi