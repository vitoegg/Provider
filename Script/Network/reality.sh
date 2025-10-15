#!/bin/bash

# Reality Xray 管理脚本
# 支持安装、更新、卸载 Reality 和 ShadowSocks 代理服务

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置文件路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"

# 日志输出函数
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} $timestamp $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} $timestamp $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR] $timestamp $message${NC}"
            ;;
        "DEBUG")
            echo -e "${BLUE}[DEBUG]${NC} $timestamp $message"
            ;;
        "SUCCESS")
            echo -e "${CYAN}[SUCCESS]${NC} $timestamp $message"
            ;;
        *)
            echo -e "${PURPLE}[LOG]${NC} $timestamp $message"
            ;;
    esac
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "此脚本必须以 root 权限运行"
        log "ERROR" "请使用 sudo $0 或切换到 root 用户"
        exit 1
    fi
    log "INFO" "Root 权限检查通过"
}

# 检查并安装 curl
check_curl() {
    if ! command -v curl &> /dev/null; then
        log "WARN" "curl 未安装，正在安装..."
        
        # 检测系统类型并安装 curl
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y curl
        elif command -v yum &> /dev/null; then
            yum install -y curl
        elif command -v dnf &> /dev/null; then
            dnf install -y curl
        elif command -v pacman &> /dev/null; then
            pacman -S --noconfirm curl
        else
            log "ERROR" "无法自动安装 curl，请手动安装后重试"
            exit 1
        fi
        
        if command -v curl &> /dev/null; then
            log "SUCCESS" "curl 安装成功"
        else
            log "ERROR" "curl 安装失败"
            exit 1
        fi
    else
        log "INFO" "curl 已安装"
    fi
}

# 生成端口号（避免包含数字4）
generate_port() {
    local lower_bound=$1
    local upper_bound=$2
    while true; do
        local port
        port=$(shuf -i ${lower_bound}-${upper_bound} -n 1)
        if [[ ! "$port" =~ "4" ]]; then
            echo "$port"
            break
        fi
    done
}

# 生成 UUID
generate_uuid() {
    if [[ -x "$XRAY_BIN" ]]; then
        $XRAY_BIN uuid
    else
        log "ERROR" "无法生成 UUID，请确保 Xray 已正确安装"
        return 1
    fi
}

# 生成 X25519 密钥对
generate_x25519() {
    if [[ -x "$XRAY_BIN" ]]; then
        $XRAY_BIN x25519
    else
        log "ERROR" "无法生成 X25519 密钥对，请确保 Xray 已正确安装"
        return 1
    fi
}

# 解析 X25519 密钥对输出
# 输入格式示例：
# PrivateKey: kIuyOXiZKK7Df55LHWy9NPiDIJaV5tIC11A-ahu_yWI
# Password: fSAqw6z5z5u_xTSpYeh88vM6uE8er4uu-R8ZZyqUF0A
# Hash32: NZHORApg6jPiPoLLUVFINMW1OexvcpRZHXZaKHiNQk8
parse_x25519_keys() {
    local raw="$1"
    local private_key=""
    local public_key=""
    
    # 解析私钥
    private_key=$(echo "$raw" | grep -iE "(private|privatekey)" | awk -F ':' '{print $2}' | tr -d ' \r\n\t' || true)
    
    # 解析公钥，优先级：Password优先，然后Public
    public_key=$(echo "$raw" | grep -iE "password" | awk -F ':' '{print $2}' | tr -d ' \r\n\t' || true)
    
    # 如果没有Password字段，尝试Public字段
    if [[ -z "$public_key" ]]; then
        public_key=$(echo "$raw" | grep -iE "(public|publickey)" | awk -F ':' '{print $2}' | tr -d ' \r\n\t' || true)
    fi
    
    # 验证密钥是否有效（X25519密钥通常是44字符的Base64编码）
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        log "ERROR" "密钥解析失败"
        log "DEBUG" "原始输出: $raw"
        log "DEBUG" "解析到的私钥: '$private_key'"
        log "DEBUG" "解析到的公钥: '$public_key'"
        return 1
    fi
    
    # 输出解析结果（用特定分隔符分隔）
    echo "${private_key}|${public_key}"
    return 0
}

# 生成 8 位 16 进制 shortId
generate_shortid() {
    openssl rand -hex 4
}

# 清理字符串，移除可能导致JSON解析错误的字符
clean_string() {
    echo "$1" | tr -d '\n\r\t' | sed 's/[[:space:]]*$//'
}

# 生成 ShadowSocks 密码
generate_ss_password() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

# 域名列表
get_domain_list() {
    echo "1) store.disney.co.jp (Akamai JP)"
    echo "2) www.westjr.co.jp (Akamai JP)"
    echo "3) www.jreast.co.jp (Akamai JP)"
    echo "4) www.knt.co.jp (Akamai JP)"
    echo "5) www.tokyodisneyresort.jp (Akamai JP)"
    echo "6) www.ehealth.gov.hk (Tencent HK)"
    echo "7) www.hkgourmet.com.hk (Imperva HK)"
    echo "8) www.visitcalifornia.com (Sucuri US)"
}

# 选择域名
select_domain() {
    local domain=""
    
    if [[ -n "$DOMAIN" ]]; then
        domain="$DOMAIN"
        log "INFO" "使用指定域名: $domain" >&2
    else
        echo "" >&2
        log "INFO" "请选择一个域名作为 Reality 的目标：" >&2
        get_domain_list >&2
        
        local choice
        read -p "请输入选择 (1-8): " choice >&2
        
        case $choice in
            1) domain="store.disney.co.jp" ;;
            2) domain="www.westjr.co.jp" ;;
            3) domain="www.jreast.co.jp" ;;
            4) domain="www.knt.co.jp" ;;
            5) domain="www.tokyodisneyresort.jp" ;;
            6) domain="www.ehealth.gov.hk" ;;
            7) domain="www.hkgourmet.com.hk" ;;
            8) domain="www.visitcalifornia.com" ;;
            *)
                log "ERROR" "无效选择，请输入 1-8" >&2
                return 1
                ;;
        esac
    fi
    
    # 确保域名不为空
    if [[ -z "$domain" ]]; then
        log "ERROR" "域名选择失败" >&2
        return 1
    fi
    
    # 只输出域名到标准输出
    echo "$domain"
}

# 生成 Reality 配置
generate_reality_config() {
    local uuid=$(clean_string "$1")
    local private_key=$(clean_string "$2")
    local public_key=$(clean_string "$3")
    local short_id=$(clean_string "$4")
    local port=$(clean_string "$5")
    local domain=$(clean_string "$6")
    
    cat << EOF
{
    "log": {
        "loglevel": "error"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$uuid",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "target": "$domain:443",
                    "serverNames": [
                        "$domain"
                    ],
                    "privateKey": "$private_key",
                    "shortIds": [
                        "$short_id"
                    ]
                }
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}
EOF
}

# 生成 Reality + ShadowSocks 配置
generate_reality_ss_config() {
    local reality_uuid=$(clean_string "$1")
    local private_key=$(clean_string "$2")
    local public_key=$(clean_string "$3")
    local short_id=$(clean_string "$4")
    local reality_port=$(clean_string "$5")
    local domain=$(clean_string "$6")
    local ss_password=$(clean_string "$7")
    local ss_port=$(clean_string "$8")
    
    cat << EOF
{
    "log": {
        "loglevel": "error"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": $reality_port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$reality_uuid",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "fingerprint": "ios",
                    "target": "$domain:443",
                    "serverNames": [
                        "$domain"
                    ],
                    "privateKey": "$private_key",
                    "shortIds": [
                        "$short_id"
                    ]
                }
            }
        },
        {
            "listen": "0.0.0.0",
            "port": $ss_port,
            "protocol": "shadowsocks",
            "settings": {
                "network": "tcp,udp",
                "method": "aes-128-gcm",
                "password": "$ss_password"
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}
EOF
}

# 安装 Xray
install_xray() {
    log "INFO" "开始安装 Xray..."
    
    if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --without-geodata; then
        log "SUCCESS" "Xray 安装成功"
        return 0
    else
        log "ERROR" "Xray 安装失败"
        return 1
    fi
}

# 配置服务
configure_service() {
    local config_type=$1
    
    # 生成或使用指定的配置参数
    local uuid
    if [[ -n "$CUSTOM_UUID" ]]; then
        uuid="$CUSTOM_UUID"
        log "INFO" "使用指定的UUID: $uuid"
    else
        uuid=$(generate_uuid)
        if [[ -z "$uuid" ]]; then
            log "ERROR" "UUID 生成失败"
            return 1
        fi
    fi
    
    local private_key
    local public_key
    if [[ -n "$CUSTOM_PRIVATE_KEY" && -n "$CUSTOM_PUBLIC_KEY" ]]; then
        private_key="$CUSTOM_PRIVATE_KEY"
        public_key="$CUSTOM_PUBLIC_KEY"
        log "INFO" "使用指定的密钥对"
    else
        # 生成 X25519 密钥对
        local keys=$(generate_x25519)
        if [[ -z "$keys" ]]; then
            log "ERROR" "X25519 密钥生成失败"
            return 1
        fi
        
        # 使用新的解析函数解析密钥对
        local parsed_keys
        parsed_keys=$(parse_x25519_keys "$keys")
        if [[ $? -ne 0 || -z "$parsed_keys" ]]; then
            log "ERROR" "X25519 密钥解析失败"
            return 1
        fi
        
        # 分解解析结果
        private_key=$(echo "$parsed_keys" | cut -d'|' -f1)
        public_key=$(echo "$parsed_keys" | cut -d'|' -f2)
        
        # 验证解析结果
        if [[ -z "$private_key" || -z "$public_key" ]]; then
            log "ERROR" "X25519 密钥解析结果无效"
            return 1
        fi
    fi
    
    local short_id
    if [[ -n "$CUSTOM_SHORT_ID" ]]; then
        short_id="$CUSTOM_SHORT_ID"
        log "INFO" "使用指定的短ID: $short_id"
    else
        short_id=$(generate_shortid)
    fi
    
    local domain
    domain=$(select_domain)
    if [[ $? -ne 0 || -z "$domain" ]]; then
        log "ERROR" "域名选择失败，无法继续配置"
        return 1
    fi
    
    local reality_port
    if [[ -n "$REALITY_PORT" ]]; then
        reality_port="$REALITY_PORT"
    else
        reality_port=$(generate_port 50000 60000)
    fi
    
    
    # 写入配置文件
    if [[ "$config_type" == "reality_only" ]]; then
        # 仅 Reality 配置
        generate_reality_config "$uuid" "$private_key" "$public_key" "$short_id" "$reality_port" "$domain" > "$CONFIG_FILE"
        log "SUCCESS" "Reality 配置已写入 $CONFIG_FILE"
        
        # 保存配置信息到全局变量，供后续输出使用
        REALITY_UUID="$uuid"
        REALITY_PRIVATE_KEY="$private_key"
        REALITY_PUBLIC_KEY="$public_key"
        REALITY_SHORT_ID="$short_id"
        REALITY_PORT="$reality_port"
        REALITY_DOMAIN="$domain"
        
    elif [[ "$config_type" == "reality_ss" ]]; then
        # Reality + ShadowSocks 配置
        local ss_password
        if [[ -n "$SS_PASSWORD" ]]; then
            ss_password="$SS_PASSWORD"
        else
            ss_password=$(generate_ss_password)
        fi
        
        local ss_port
        if [[ -n "$SS_PORT" ]]; then
            ss_port="$SS_PORT"
        else
            ss_port=$(generate_port 20000 30000)
        fi
        
        
        generate_reality_ss_config "$uuid" "$private_key" "$public_key" "$short_id" "$reality_port" "$domain" "$ss_password" "$ss_port" > "$CONFIG_FILE"
        log "SUCCESS" "Reality + ShadowSocks 配置已写入 $CONFIG_FILE"
        
        # 保存配置信息到全局变量，供后续输出使用
        REALITY_UUID="$uuid"
        REALITY_PRIVATE_KEY="$private_key"
        REALITY_PUBLIC_KEY="$public_key"
        REALITY_SHORT_ID="$short_id"
        REALITY_PORT="$reality_port"
        REALITY_DOMAIN="$domain"
        SS_PASSWORD_GENERATED="$ss_password"
        SS_PORT_GENERATED="$ss_port"
    fi
    
    return 0
}

# 输出客户端配置信息
output_config_info() {
    local config_type="$1"
    local server_ip
    
    # 获取服务器IP
    server_ip=$(curl -s ipinfo.io/ip)
    
    if [[ "$config_type" == "reality_only" ]]; then
        # 仅输出 Reality 配置信息
        echo ""
        echo "===== Reality 客户端配置信息 ====="
        echo "服务器IP: $server_ip"
        echo "端口: $REALITY_PORT"
        echo "协议: vless"
        echo "UUID: $REALITY_UUID"
        echo "目标域名: $REALITY_DOMAIN"
        echo "私钥: $REALITY_PRIVATE_KEY"
        echo "公钥: $REALITY_PUBLIC_KEY"
        echo "短ID: $REALITY_SHORT_ID"
        echo "================================="
        
    elif [[ "$config_type" == "reality_ss" ]]; then
        # 输出合并的配置信息（服务器IP只显示一次）
        echo ""
        echo "===== 客户端配置信息 ====="
        echo "服务器IP: $server_ip"
        echo ""
        echo "Reality 配置:"
        echo "  端口: $REALITY_PORT"
        echo "  协议: vless"
        echo "  UUID: $REALITY_UUID"
        echo "  目标域名: $REALITY_DOMAIN"
        echo "  私钥: $REALITY_PRIVATE_KEY"
        echo "  公钥: $REALITY_PUBLIC_KEY"
        echo "  短ID: $REALITY_SHORT_ID"
        echo ""
        echo "ShadowSocks 配置:"
        echo "  端口: $SS_PORT_GENERATED"
        echo "  协议: shadowsocks"
        echo "  加密方式: aes-128-gcm"
        echo "  密码: $SS_PASSWORD_GENERATED"
        echo "========================="
    fi
}

# 重启并检查服务状态
restart_service() {
    log "INFO" "重启 Xray 服务..."
    
    # 重启服务
    if systemctl restart xray; then
        log "SUCCESS" "Xray 服务重启成功"
    else
        log "ERROR" "Xray 服务重启失败"
        return 1
    fi
    
    # 检查服务状态
    sleep 2
    if systemctl is-active --quiet xray; then
        log "SUCCESS" "Xray 服务运行正常"
        log "INFO" "服务状态: $(systemctl is-active xray)"
        
        # 启用开机自启
        systemctl enable xray
        log "SUCCESS" "已启用 Xray 开机自启"
        
        return 0
    else
        log "ERROR" "Xray 服务启动失败"
        log "ERROR" "服务状态: $(systemctl is-active xray)"
        
        # 显示服务日志
        log "INFO" "服务日志："
        journalctl -u xray --no-pager -n 10
        
        return 1
    fi
}

# 安装功能
install_function() {
    local install_type="$1"
    
    if [[ -z "$install_type" ]]; then
        log "ERROR" "安装类型参数缺失"
        return 1
    fi
    
    log "INFO" "开始安装过程..."
    
    # 安装 Xray
    if ! install_xray; then
        return 1
    fi
    
    # 配置服务
    if ! configure_service "$install_type"; then
        return 1
    fi
    
    # 重启服务
    if ! restart_service; then
        return 1
    fi
    
    # 输出配置信息
    output_config_info "$install_type"
    
}

# 更新功能
update_function() {
    log "INFO" "正在检查 Xray 版本..."
    
    # 执行版本检查，捕获输出
    local check_output
    check_output=$(bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ check 2>&1)
    local check_status=$?
    
    # 提取当前版本和最新版本（只匹配关键词，避免匹配到 pre-release 版本）
    local current_version=$(echo "$check_output" | grep "current version" | grep -oP "v[0-9]+\.[0-9]+\.[0-9]+")
    local latest_version=$(echo "$check_output" | grep "latest release version" | grep -oP "v[0-9]+\.[0-9]+\.[0-9]+")
    
    # 检查是否成功获取版本信息
    if [[ -z "$current_version" || -z "$latest_version" ]]; then
        log "ERROR" "无法获取版本信息"
        log "DEBUG" "检查输出: $check_output"
        return 1
    fi
    
    # 比较版本
    if [[ "$current_version" == "$latest_version" ]]; then
        log "SUCCESS" "当前已经是最新版本: $current_version"
    else
        log "INFO" "发现新版本: $current_version -> $latest_version"
        log "INFO" "开始更新 Xray..."
        
        # 执行更新
        if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --without-geodata; then
            log "SUCCESS" "Xray 已成功从 $current_version 更新到 $latest_version"
            
            # 重启服务
            log "INFO" "重启 Xray 服务..."
            if systemctl restart xray; then
                log "SUCCESS" "Xray 服务重启成功"
            else
                log "WARN" "Xray 服务重启失败，请手动重启"
            fi
        else
            log "ERROR" "Xray 更新失败"
            return 1
        fi
    fi
}

# 卸载功能
uninstall_function() {
    log "INFO" "开始卸载 Xray..."
    
    # 停止服务
    log "INFO" "停止 Xray 服务..."
    systemctl stop xray 2>/dev/null
    systemctl disable xray 2>/dev/null
    
    # 卸载 Xray
    log "INFO" "正在卸载 Xray..."
    if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge; then
        log "SUCCESS" "Xray 卸载成功"
    else
        log "ERROR" "Xray 卸载失败"
    fi
}

# 显示主菜单
show_menu() {
    echo ""
    echo "=============================================="
    echo "           Reality Xray 管理脚本"
    echo "=============================================="
    echo "1) 安装 Reality + ShadowSocks"
    echo "2) 仅安装 Reality"
    echo "3) 更新内核"
    echo "4) 卸载服务"
    echo "=============================================="
}

# 显示帮助信息
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help              显示帮助信息"
    echo "  --install               直接执行安装"
    echo "  --update                直接执行更新"
    echo "  --uninstall             直接执行卸载"
    echo "  --install-type TYPE     安装类型 (reality_only|reality_ss)"
    echo "  --domain DOMAIN         指定域名"
    echo "  --reality-port PORT     指定 Reality 端口"
    echo "  --uuid UUID             指定 UUID"
    echo "  --private-key KEY       指定 Reality 私钥"
    echo "  --public-key KEY        指定 Reality 公钥"
    echo "  --short-id ID           指定 Reality 短ID"
    echo "  --ss-port PORT          指定 ShadowSocks 端口"
    echo "  --ss-password PASS      指定 ShadowSocks 密码"
    echo ""
    echo "Examples:"
    echo "  # 传统方式（手动指定操作）"
    echo "  $0 --install --install-type reality_only --domain www.google.com"
    echo "  $0 --install --install-type reality_ss --reality-port 55555 --ss-port 25555"
    echo ""
    echo "  # 自动识别方式（推荐）"
    echo "  $0 --domain www.google.com --reality-port 55555"
    echo "  $0 --domain www.google.com --ss-port 25555 --ss-password mypass123"
    echo "  $0 --uuid 12345678-1234-1234-1234-123456789abc --domain www.google.com"
    echo ""
    echo "  # 其他操作"
    echo "  $0 --update"
    echo "  $0 --uninstall"
}

# 自动检测安装模式
auto_detect_install() {
    # 检查是否指定了安装相关的参数
    local install_params=()
    
    [[ -n "$DOMAIN" ]] && install_params+=("--domain")
    [[ -n "$REALITY_PORT" ]] && install_params+=("--reality-port")
    [[ -n "$CUSTOM_UUID" ]] && install_params+=("--uuid")
    [[ -n "$CUSTOM_PRIVATE_KEY" ]] && install_params+=("--private-key")
    [[ -n "$CUSTOM_PUBLIC_KEY" ]] && install_params+=("--public-key")
    [[ -n "$CUSTOM_SHORT_ID" ]] && install_params+=("--short-id")
    [[ -n "$SS_PORT" ]] && install_params+=("--ss-port")
    [[ -n "$SS_PASSWORD" ]] && install_params+=("--ss-password")
    
    # 如果指定了任意一个安装参数，则自动设置为安装模式
    if [[ ${#install_params[@]} -gt 0 ]]; then
        log "INFO" "检测到安装参数: ${install_params[*]}"
        ACTION="install"
        
        # 自动检测安装类型
        if [[ -n "$SS_PORT" || -n "$SS_PASSWORD" ]]; then
            INSTALL_TYPE="reality_ss"
            log "INFO" "自动检测安装类型: Reality + ShadowSocks"
        else
            INSTALL_TYPE="reality_only"
            log "INFO" "自动检测安装类型: 仅 Reality"
        fi
        
        return 0
    fi
    
    return 1
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            --install)
                ACTION="install"
                shift
                ;;
            --update)
                ACTION="update"
                shift
                ;;
            --uninstall)
                ACTION="uninstall"
                shift
                ;;
            --install-type)
                INSTALL_TYPE="$2"
                shift 2
                ;;
            --domain)
                DOMAIN="$2"
                shift 2
                ;;
            --reality-port)
                REALITY_PORT="$2"
                shift 2
                ;;
            --ss-port)
                SS_PORT="$2"
                shift 2
                ;;
            --uuid)
                CUSTOM_UUID="$2"
                shift 2
                ;;
            --private-key)
                CUSTOM_PRIVATE_KEY="$2"
                shift 2
                ;;
            --public-key)
                CUSTOM_PUBLIC_KEY="$2"
                shift 2
                ;;
            --short-id)
                CUSTOM_SHORT_ID="$2"
                shift 2
                ;;
            --ss-password)
                SS_PASSWORD="$2"
                shift 2
                ;;
            *)
                log "ERROR" "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 主函数
main() {
    # 检查 root 权限
    check_root
    
    # 检查 curl 依赖
    check_curl
    
    # 解析命令行参数
    parse_args "$@"
    
    # 如果没有指定操作，尝试自动检测
    if [[ -z "$ACTION" ]]; then
        auto_detect_install
    fi
    
    # 如果指定了操作，直接执行
    if [[ -n "$ACTION" ]]; then
        case "$ACTION" in
            "install")
                install_function "$INSTALL_TYPE"
                ;;
            "update")
                update_function
                ;;
            "uninstall")
                uninstall_function
                ;;
        esac
        exit 0
    fi
    
    # 显示菜单
    show_menu
    read -p "请选择操作 (1-4): " choice
    
    case $choice in
        1)
            log "INFO" "开始安装 Reality + ShadowSocks..."
            install_function "reality_ss"
            ;;
        2)
            log "INFO" "开始安装 Reality..."
            install_function "reality_only"
            ;;
        3)
            log "INFO" "开始更新内核..."
            update_function
            ;;
        4)
            log "INFO" "开始卸载服务..."
            uninstall_function
            ;;
        *)
            log "ERROR" "无效选择，请输入 1-4"
            exit 1
            ;;
    esac
    
    # 操作完成后直接退出
    exit 0
}

# 执行主函数
main "$@"
