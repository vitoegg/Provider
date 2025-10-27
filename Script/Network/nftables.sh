#!/bin/bash

# ============================================================================
# NFTables 端口转发管理工具
# 功能：管理 Linux nftables 端口转发规则，支持远程和本地端口转发
# ============================================================================

# ============================================================================
# 全局配置
# ============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置文件路径
CONFIG_FILE="/etc/nftables.conf"

# ============================================================================
# 日志函数组
# ============================================================================

log_info() {
    echo -e "${GREEN}[信息]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

log_error() {
    echo -e "${RED}[错误]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[调试]${NC} $1"
}

# ============================================================================
# 系统检查和初始化
# ============================================================================

# 检查是否以 root 权限运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "此脚本必须以 root 权限运行"
        exit 1
    fi
}

# 检查系统类型
check_system() {
    if ! grep -qiE 'debian|ubuntu' /etc/os-release; then
        log_error "此脚本仅支持 Debian 或 Ubuntu 系统"
        exit 1
    fi
}

# 安装并启动 nftables
install_nftables() {
    if ! command -v nft &> /dev/null; then
        log_warn "nftables 未安装，正在安装..."
        apt update || { log_error "更新软件包列表失败"; exit 1; }
        apt install -y nftables || { log_error "安装 nftables 失败，请手动安装"; exit 1; }
        log_info "nftables 安装成功"
    else
        log_info "nftables 已安装"
    fi
    
    systemctl enable nftables 2>/dev/null
    systemctl start nftables 2>/dev/null
}

# 启用 IP 转发
enable_ip_forwarding() {
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward
        
        if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
            echo "" >> /etc/sysctl.conf
            echo "# 启用 IP 转发（用于端口转发）" >> /etc/sysctl.conf
            echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
            sysctl -p > /dev/null 2>&1
            log_info "IP 转发已启用"
        fi
    fi
}

# 初始化 nftables 配置
initialize_nftables() {
    log_info "初始化 nftables 转发配置"
    
    if ! nft list tables | grep -q "fowardaws"; then
        cat > "$CONFIG_FILE" << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table ip fowardaws {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # TCP 和 UDP 转发规则将添加在此
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # Masquerade 规则将添加在此
    }
}
EOF
        nft -f "$CONFIG_FILE" || { log_error "初始化 nftables 配置失败"; return 1; }
        log_info "基础转发配置已创建并加载"
    else
        log_info "转发表已存在"
    fi
    
    enable_ip_forwarding
    return 0
}

# ============================================================================
# 核心工具函数
# ============================================================================

# 规则验证函数（返回格式化字符串，不使用全局变量）
validate_rule() {
    local rule_string="$1"
    
    # 检查规则格式
    if [[ ! "$rule_string" =~ ^[^:]+:[^:]+:[^:]+$ ]]; then
        log_error "规则格式错误: $rule_string (正确格式: 端口:IP:端口)"
        return 1
    fi
    
    local local_port=$(echo "$rule_string" | cut -d':' -f1)
    local dest_ip=$(echo "$rule_string" | cut -d':' -f2)
    local dest_port=$(echo "$rule_string" | cut -d':' -f3)
    
    # 验证源端口
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        log_error "无效的源端口: $local_port (必须在 1-65535 之间)"
        return 1
    fi
    
    # 处理本地转发标识
    local is_local="false"
    if [[ "$dest_ip" == "local" || "$dest_ip" == "localhost" || "$dest_ip" == "127.0.0.1" ]]; then
        dest_ip="127.0.0.1"
        is_local="true"
    elif ! [[ "$dest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "无效的目标IP地址: $dest_ip (支持格式: IP地址 或 local/localhost)"
        return 1
    fi
    
    # 验证目标端口
    if ! [[ "$dest_port" =~ ^[0-9]+$ ]] || [ "$dest_port" -lt 1 ] || [ "$dest_port" -gt 65535 ]; then
        log_error "无效的目标端口: $dest_port (必须在 1-65535 之间)"
        return 1
    fi
    
    # 输出验证结果（使用 | 分隔）
    echo "${local_port}|${dest_ip}|${dest_port}|${is_local}"
    return 0
}

# 提取规则的通用函数（解决代码重复问题）
extract_rules_from_chain() {
    local chain_name="$1"
    local protocol="$2"
    local ruleset_output="$3"
    
    # 使用 awk 完整提取整个链的规则（不限制行数）
    echo "$ruleset_output" | awk -v chain="$chain_name" -v proto="$protocol" '
        $0 ~ "chain " chain {found=1; next}
        found && /^[[:space:]]*}/ {found=0}
        found && $0 ~ proto " dport .* dnat to" {print}
    '
}

# 公共规则解析函数（消除重复代码）
parse_forwarding_rules() {
    local ruleset_output="$1"
    
    if ! echo "$ruleset_output" | grep -q "table ip fowardaws"; then
        return 1
    fi
    
    # 提取各链的规则
    local tcp_rules=$(extract_rules_from_chain "prerouting" "tcp" "$ruleset_output")
    local udp_rules=$(extract_rules_from_chain "prerouting" "udp" "$ruleset_output")
    local local_tcp_rules=$(extract_rules_from_chain "output" "tcp" "$ruleset_output")
    local local_udp_rules=$(extract_rules_from_chain "output" "udp" "$ruleset_output")
    
    # 处理规则并输出统一格式（端口|目标|协议|类型）
    # 使用临时文件避免子 shell 中的关联数组问题
    local temp_file=$(mktemp)
    
    # 处理远程 TCP 规则
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local src_port=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dport") print $(i+1)}')
        local dest=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="to") print $(i+1)}')
        echo "${src_port}|${dest}|TCP|remote" >> "$temp_file"
    done <<< "$tcp_rules"
    
    # 处理远程 UDP 规则
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local src_port=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dport") print $(i+1)}')
        local dest=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="to") print $(i+1)}')
        # 检查是否已有 TCP 规则，如果有则标记为 TCP+UDP
        if grep -q "^${src_port}|${dest}|TCP|remote$" "$temp_file"; then
            # 使用临时文件避免 sed -i 的跨平台兼容性问题
            awk -v sp="$src_port" -v dst="$dest" '
                $0 == sp"|"dst"|TCP|remote" {print sp"|"dst"|TCP+UDP|remote"; next}
                {print}
            ' "$temp_file" > "${temp_file}.tmp" && mv "${temp_file}.tmp" "$temp_file"
        else
            echo "${src_port}|${dest}|UDP|remote" >> "$temp_file"
        fi
    done <<< "$udp_rules"
    
    # 处理本地 TCP 规则
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local src_port=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dport") print $(i+1)}')
        local dest=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="to") print $(i+1)}')
        echo "${src_port}|${dest}|TCP|local" >> "$temp_file"
    done <<< "$local_tcp_rules"
    
    # 处理本地 UDP 规则
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local src_port=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dport") print $(i+1)}')
        local dest=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="to") print $(i+1)}')
        # 检查是否已有 TCP 规则
        if grep -q "^${src_port}|${dest}|TCP|local$" "$temp_file"; then
            # 使用临时文件避免 sed -i 的跨平台兼容性问题
            awk -v sp="$src_port" -v dst="$dest" '
                $0 == sp"|"dst"|TCP|local" {print sp"|"dst"|TCP+UDP|local"; next}
                {print}
            ' "$temp_file" > "${temp_file}.tmp" && mv "${temp_file}.tmp" "$temp_file"
        else
            echo "${src_port}|${dest}|UDP|local" >> "$temp_file"
        fi
    done <<< "$local_udp_rules"
    
    # 输出结果并清理
    cat "$temp_file"
    rm -f "$temp_file"
    return 0
}

# 冲突检测函数（使用优化的规则提取）
check_rule_conflict() {
    local local_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_local="$4"
    
    local ruleset_output=$(nft list ruleset 2>/dev/null)
    [ -z "$ruleset_output" ] && return 0
    
    local chain_type="prerouting"
    [ "$is_local" = "true" ] && chain_type="output"
    
    # 使用优化的提取方法（完整提取，不限制行数）
    local existing_tcp=$(extract_rules_from_chain "$chain_type" "tcp" "$ruleset_output")
    local existing_udp=$(extract_rules_from_chain "$chain_type" "udp" "$ruleset_output")
    
    if [[ -n "$existing_tcp" || -n "$existing_udp" ]]; then
        # 检查是否存在相同端口的规则
        if echo "$existing_tcp" | grep -q "dport ${local_port} " || \
           echo "$existing_udp" | grep -q "dport ${local_port} "; then
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

# 配置文件重建函数（带去重）
rebuild_config_file() {
    log_debug "从当前规则集重建配置文件..."
    
    local current_rules=$(nft list table ip fowardaws 2>/dev/null)
    
    if [ -z "$current_rules" ]; then
        log_warn "未找到 fowardaws 表，创建新配置"
        initialize_nftables
        return 0
    fi
    
    cat > "$CONFIG_FILE" << 'HEADER'
#!/usr/sbin/nft -f

flush ruleset

HEADER
    
    # 去重并追加规则集
    echo "$current_rules" | awk '!seen[$0]++' >> "$CONFIG_FILE"
    log_debug "配置文件重建成功（已去除重复规则）"
    return 0
}

# 规则应用函数
apply_single_forwarding_rule() {
    local local_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_local="$4"
    
    # 确保表和链存在
    if ! nft list table ip fowardaws &>/dev/null; then
        log_error "转发表不存在，正在初始化..."
        initialize_nftables || return 1
    fi
    
    # 为本地转发创建 output 链（如果需要）
    if [ "$is_local" = "true" ] && ! nft list chain ip fowardaws output &>/dev/null; then
        nft add chain ip fowardaws output '{ type nat hook output priority dstnat; policy accept; }' || {
            log_error "创建 output 链失败"
            return 1
        }
        log_debug "已创建 output 链用于本地转发"
    fi
    
    # 添加转发规则
    if [ "$is_local" = "true" ]; then
        nft add rule ip fowardaws output tcp dport "$local_port" dnat to "${dest_ip}:${dest_port}" || return 1
        nft add rule ip fowardaws output udp dport "$local_port" dnat to "${dest_ip}:${dest_port}" || return 1
        log_debug "已添加本地转发规则到运行时"
    else
        nft add rule ip fowardaws prerouting tcp dport "$local_port" dnat to "${dest_ip}:${dest_port}" || return 1
        nft add rule ip fowardaws prerouting udp dport "$local_port" dnat to "${dest_ip}:${dest_port}" || return 1
        log_debug "已添加远程转发规则到运行时"
        
        # 添加 masquerade 规则（如果不存在）
        if ! nft list table ip fowardaws | grep -q "ip daddr ${dest_ip} masquerade"; then
            nft add rule ip fowardaws postrouting ip daddr "$dest_ip" masquerade || {
                log_warn "添加 masquerade 规则失败"
            }
            log_debug "已为 ${dest_ip} 添加 masquerade 规则"
        fi
    fi
    
    return 0
}

# ============================================================================
# 规则操作函数
# ============================================================================

# 显示当前规则
display_rules() {
    log_info "当前端口转发规则："
    
    local ruleset_output=$(nft list ruleset 2>/dev/null)
    if [ -z "$ruleset_output" ]; then
        log_warn "未找到 nftables 规则集"
        return
    fi
    
    # 使用公共解析函数
    local rules=$(parse_forwarding_rules "$ruleset_output")
    if [ -z "$rules" ]; then
        log_warn "未找到转发规则"
        return
    fi
    
    echo -e "${YELLOW}=== 端口转发规则 ===${NC}"
    local count=1
    
    while IFS='|' read -r src_port dest protocol type; do
        local dest_ip=$(echo "$dest" | cut -d':' -f1)
        local dest_port=$(echo "$dest" | cut -d':' -f2)
        
        if [ "$type" = "local" ]; then
            echo -e "${GREEN}$count)${NC} ${BLUE}[本地]${NC} 端口: ${YELLOW}$src_port${NC} -> ${YELLOW}$dest_ip:$dest_port${NC} (${BLUE}$protocol${NC})"
        else
            echo -e "${GREEN}$count)${NC} 端口: ${YELLOW}$src_port${NC} -> 目标: ${YELLOW}$dest_ip:$dest_port${NC} (${BLUE}$protocol${NC})"
        fi
        count=$((count+1))
    done <<< "$rules"
}

# 添加新的转发规则（交互模式）
add_rule() {
    log_info "添加新的端口转发规则"
    
    read -p "输入源端口号: " local_port
    read -p "输入目标IP地址 (或输入 'local' 表示本地转发): " dest_ip
    read -p "输入目标端口号: " dest_port
    
    local rule_string="${local_port}:${dest_ip}:${dest_port}"
    
    # 验证规则（使用返回值，不使用全局变量）
    local validated=$(validate_rule "$rule_string")
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # 解析验证结果
    local validated_port=$(echo "$validated" | cut -d'|' -f1)
    local validated_ip=$(echo "$validated" | cut -d'|' -f2)
    local validated_dest_port=$(echo "$validated" | cut -d'|' -f3)
    local validated_is_local=$(echo "$validated" | cut -d'|' -f4)
    
    # 检查冲突
    if ! check_rule_conflict "$validated_port" "$validated_ip" "$validated_dest_port" "$validated_is_local"; then
        log_error "无法添加规则，请检查上述冲突信息"
        return 1
    fi
    
    # 备份配置文件
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null
    
    # 应用规则
    if ! apply_single_forwarding_rule "$validated_port" "$validated_ip" "$validated_dest_port" "$validated_is_local"; then
        log_error "应用规则失败"
        [ -f "${CONFIG_FILE}.bak" ] && mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        return 1
    fi
    
    # 重建配置文件
    rebuild_config_file
    
    if [ "$validated_is_local" = "true" ]; then
        log_info "本地端口转发规则添加成功 (TCP+UDP): 端口 $validated_port -> $validated_ip:$validated_dest_port"
    else
        log_info "端口转发规则添加成功 (TCP+UDP): 端口 $validated_port -> $validated_ip:$validated_dest_port"
    fi
    
    return 0
}

# 删除转发规则
delete_rule() {
    local ruleset_output=$(nft list ruleset 2>/dev/null)
    if ! echo "$ruleset_output" | grep -q "table ip fowardaws"; then
        log_warn "未找到可删除的转发表"
        return
    fi
    
    # 使用公共解析函数
    local rules=$(parse_forwarding_rules "$ruleset_output")
    if [ -z "$rules" ]; then
        log_warn "未找到可删除的转发规则"
        return
    fi
    
    # 将规则存入数组
    local -a rule_array
    while IFS= read -r line; do
        rule_array+=("$line")
    done <<< "$rules"
    
    # 显示删除选项
    echo -e "\n${YELLOW}选择要删除的端口转发规则:${NC}"
    local count=1
    for rule in "${rule_array[@]}"; do
        IFS='|' read -r src_port dest protocol type <<< "$rule"
        local dest_ip=$(echo "$dest" | cut -d':' -f1)
        local dest_port=$(echo "$dest" | cut -d':' -f2)
        
        if [ "$type" = "local" ]; then
            echo "$count) [本地] 端口 ${src_port} -> ${dest_ip}:${dest_port} (${protocol})"
        else
            echo "$count) 端口 ${src_port} -> ${dest_ip}:${dest_port} (${protocol})"
        fi
        count=$((count+1))
    done
    
    echo "$count) 取消"
    read -p "请输入编号 (1-$count): " choice
    
    # 取消操作
    if [ "$choice" -eq "$count" ]; then
        log_info "已取消删除操作"
        return
    fi
    
    # 验证输入
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$count" ]; then
        log_error "无效的选择"
        return
    fi
    
    # 获取选中的规则
    local index=$((choice-1))
    local selected_rule="${rule_array[$index]}"
    IFS='|' read -r selected_port selected_dest selected_protocol selected_type <<< "$selected_rule"
    local selected_ip=$(echo "$selected_dest" | cut -d':' -f1)
    
    log_info "正在删除 ${selected_protocol} 转发规则 (端口 ${selected_port})..."
    
    # 根据规则类型删除
    local chain_name="prerouting"
    [ "$selected_type" = "local" ] && chain_name="output"
    
    # 删除 TCP 规则
    if [[ "$selected_protocol" == *"TCP"* ]]; then
        local tcp_handles=$(nft -a list table ip fowardaws | awk -v chain="$chain_name" -v port="$selected_port" -v dest="$selected_dest" '
            $0 ~ "chain " chain {found=1; next}
            found && /^[[:space:]]*}/ {found=0}
            found && $0 ~ "tcp dport " port " dnat to " dest {
                for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)
            }
        ')
        
        while IFS= read -r handle; do
            [ -n "$handle" ] && nft delete rule ip fowardaws "$chain_name" handle "$handle" 2>/dev/null
        done <<< "$tcp_handles"
    fi
    
    # 删除 UDP 规则
    if [[ "$selected_protocol" == *"UDP"* ]]; then
        local udp_handles=$(nft -a list table ip fowardaws | awk -v chain="$chain_name" -v port="$selected_port" -v dest="$selected_dest" '
            $0 ~ "chain " chain {found=1; next}
            found && /^[[:space:]]*}/ {found=0}
            found && $0 ~ "udp dport " port " dnat to " dest {
                for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)
            }
        ')
        
        while IFS= read -r handle; do
            [ -n "$handle" ] && nft delete rule ip fowardaws "$chain_name" handle "$handle" 2>/dev/null
        done <<< "$udp_handles"
    fi
    
    # 检查是否需要删除 masquerade 规则
    if [ "$selected_ip" != "127.0.0.1" ]; then
        local ip_still_in_use=false
        for rule in "${rule_array[@]}"; do
            IFS='|' read -r _ dest _ _ <<< "$rule"
            local other_ip=$(echo "$dest" | cut -d':' -f1)
            
            if [ "$other_ip" = "$selected_ip" ] && [ "$rule" != "$selected_rule" ]; then
                ip_still_in_use=true
                break
            fi
        done
        
        # 如果 IP 不再使用，删除 masquerade 规则
        if [ "$ip_still_in_use" = false ]; then
            local masq_handle=$(nft -a list table ip fowardaws | awk -v ip="$selected_ip" '
                /chain postrouting/,/^[[:space:]]*}/ {
                    if ($0 ~ "ip daddr " ip " masquerade") {
                        for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)
                    }
                }
            ')
            
            if [ -n "$masq_handle" ]; then
                nft delete rule ip fowardaws postrouting handle "$masq_handle" 2>/dev/null
                log_debug "已删除 $selected_ip 的 masquerade 规则"
            fi
        fi
    fi
    
    # 重建配置文件
    rebuild_config_file
    log_info "端口转发规则删除成功"
}

# ============================================================================
# 帮助和批量操作
# ============================================================================

# 显示帮助信息
show_help() {
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

# 批量添加规则
add_rule_batch() {
    local rules=("$@")
    
    if [ ${#rules[@]} -eq 0 ]; then
        log_error "未提供任何规则"
        return 1
    fi
    
    log_info "准备批量添加 ${#rules[@]} 条转发规则..."
    
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null
    
    local -a success_rules
    local -a failed_rules
    local -a skipped_rules
    
    for rule in "${rules[@]}"; do
        log_info "处理规则: $rule"
        
        # 验证规则（使用返回值）
        local validated=$(validate_rule "$rule")
        if [ $? -ne 0 ]; then
            failed_rules+=("$rule (格式验证失败)")
            continue
        fi
        
        local local_port=$(echo "$validated" | cut -d'|' -f1)
        local dest_ip=$(echo "$validated" | cut -d'|' -f2)
        local dest_port=$(echo "$validated" | cut -d'|' -f3)
        local is_local=$(echo "$validated" | cut -d'|' -f4)
        
        # 检查冲突
        if ! check_rule_conflict "$local_port" "$dest_ip" "$dest_port" "$is_local"; then
            skipped_rules+=("$rule (冲突或已存在)")
            continue
        fi
        
        # 应用规则
        if apply_single_forwarding_rule "$local_port" "$dest_ip" "$dest_port" "$is_local"; then
            success_rules+=("$rule")
            log_debug "规则已添加: $rule"
        else
            failed_rules+=("$rule (应用失败)")
        fi
    done
    
    # 重建配置文件
    if [ ${#success_rules[@]} -gt 0 ]; then
        log_info "正在重建配置文件..."
        rebuild_config_file
        log_info "配置文件重建成功"
    else
        log_warn "没有成功添加任何规则"
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

# ============================================================================
# 主流程
# ============================================================================

# 系统检查
check_root
check_system
install_nftables

# 初始化 nftables
initialize_nftables

# 配置文件检查和修复（仅在必要时重载）
if [ -f "$CONFIG_FILE" ]; then
    if ! grep -q "^flush ruleset" "$CONFIG_FILE"; then
        log_warn "检测到配置文件格式问题，正在修复..."
        if nft list table ip fowardaws &>/dev/null; then
            rebuild_config_file
            log_info "配置文件修复成功"
        fi
    fi
else
    log_warn "配置文件不存在，将在首次添加规则时创建"
fi

# 命令行参数解析
if [ $# -gt 0 ]; then
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
            shift
            if [ $# -eq 0 ]; then
                log_error "未提供任何规则。用法: $0 --add 规则1 [规则2 ...]"
                echo ""
                show_help
                exit 1
            fi
            add_rule_batch "$@"
            exit $?
            ;;
        *)
            log_error "未知参数: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
else
    # 交互式菜单
    while true; do
        echo -e "\n${BLUE}=== NFTables 端口转发管理 ===${NC}"
        echo "1) 查看当前转发规则"
        echo "2) 添加新的转发规则"
        echo "3) 删除转发规则"
        echo "4) 退出"
        read -p "请选择操作 (1-4): " choice
        
        case $choice in
            1) display_rules ;;
            2) add_rule ;;
            3) delete_rule ;;
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
