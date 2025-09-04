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

# 生成 8 位 16 进制 shortId
generate_shortid() {
    openssl rand -hex 4
}

# 生成 ShadowSocks 密码
generate_ss_password() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

# 域名列表
get_domain_list() {
    echo "1) www.1991991.xyz"
    echo "2) www.lovelive-anime.jp"
    echo "3) blog.hypai.org"
    echo "4) www.japan.travel"
}

# 选择域名
select_domain() {
    local domain=""
    
    if [[ -n "$DOMAIN" ]]; then
        domain="$DOMAIN"
        log "INFO" "使用指定域名: $domain"
    else
        echo ""
        log "INFO" "请选择一个域名作为 Reality 的目标："
        get_domain_list
        
        read -p "请输入选择 (1-4): " choice
        
        case $choice in
            1) domain="www.1991991.xyz" ;;
            2) domain="www.lovelive-anime.jp" ;;
            3) domain="blog.hypai.org" ;;
            4) domain="www.japan.travel" ;;
            *)
                log "ERROR" "无效选择，请输入 1-4"
                return 1
                ;;
        esac
    fi
    
    echo "$domain"
}

# 生成 Reality 配置
generate_reality_config() {
    local uuid=$1
    local private_key=$2
    local public_key=$3
    local short_id=$4
    local port=$5
    local domain=$6
    
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
    local reality_uuid=$1
    local private_key=$2
    local public_key=$3
    local short_id=$4
    local reality_port=$5
    local domain=$6
    local ss_password=$7
    local ss_port=$8
    
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
        local keys=$(generate_x25519)
        if [[ -z "$keys" ]]; then
            log "ERROR" "X25519 密钥生成失败"
            return 1
        fi
        private_key=$(echo "$keys" | grep "Private key:" | awk '{print $3}')
        public_key=$(echo "$keys" | grep "Public key:" | awk '{print $3}')
    fi
    
    local short_id
    if [[ -n "$CUSTOM_SHORT_ID" ]]; then
        short_id="$CUSTOM_SHORT_ID"
        log "INFO" "使用指定的短ID: $short_id"
    else
        short_id=$(generate_shortid)
    fi
    
    local domain=$(select_domain)
    if [[ -z "$domain" ]]; then
        return 1
    fi
    
    local reality_port
    if [[ -n "$REALITY_PORT" ]]; then
        reality_port="$REALITY_PORT"
    else
        reality_port=$(generate_port 50000 60000)
    fi
    
    log "INFO" "生成的配置信息："
    log "INFO" "UUID: $uuid"
    log "INFO" "Private Key: $private_key"
    log "INFO" "Public Key: $public_key"
    log "INFO" "Short ID: $short_id"
    log "INFO" "Domain: $domain"
    log "INFO" "Reality Port: $reality_port"
    
    # 写入配置文件
    if [[ "$config_type" == "reality_only" ]]; then
        # 仅 Reality 配置
        generate_reality_config "$uuid" "$private_key" "$public_key" "$short_id" "$reality_port" "$domain" > "$CONFIG_FILE"
        log "SUCCESS" "Reality 配置已写入 $CONFIG_FILE"
        
        # 输出客户端配置信息
        echo ""
        log "SUCCESS" "===== Reality 客户端配置信息 ====="
        echo "服务器IP: $(curl -s ipinfo.io/ip)"
        echo "端口: $reality_port"
        echo "协议: vless"
        echo "UUID: $uuid"
        echo "目标域名: $domain"
        echo "私钥: $private_key"
        echo "公钥: $public_key"
        echo "短ID: $short_id"
        log "SUCCESS" "================================="
        
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
        
        log "INFO" "ShadowSocks Password: $ss_password"
        log "INFO" "ShadowSocks Port: $ss_port"
        
        generate_reality_ss_config "$uuid" "$private_key" "$public_key" "$short_id" "$reality_port" "$domain" "$ss_password" "$ss_port" > "$CONFIG_FILE"
        log "SUCCESS" "Reality + ShadowSocks 配置已写入 $CONFIG_FILE"
        
        # 输出客户端配置信息
        echo ""
        log "SUCCESS" "===== Reality 客户端配置信息 ====="
        echo "服务器IP: $(curl -s ipinfo.io/ip)"
        echo "端口: $reality_port"
        echo "协议: vless"
        echo "UUID: $uuid"
        echo "目标域名: $domain"
        echo "私钥: $private_key"
        echo "公钥: $public_key"
        echo "短ID: $short_id"
        log "SUCCESS" "================================="
        
        echo ""
        log "SUCCESS" "===== ShadowSocks 客户端配置信息 ====="
        echo "服务器IP: $(curl -s ipinfo.io/ip)"
        echo "端口: $ss_port"
        echo "协议: shadowsocks"
        echo "加密方式: aes-128-gcm"
        echo "密码: $ss_password"
        log "SUCCESS" "===================================="
    fi
    
    return 0
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
    log "INFO" "开始安装过程..."
    
    # 选择安装类型
    local install_type=""
    if [[ -n "$INSTALL_TYPE" ]]; then
        install_type="$INSTALL_TYPE"
    else
        echo ""
        echo "请选择安装类型："
        echo "1) 仅安装 Reality"
        echo "2) 安装 Reality + ShadowSocks"
        read -p "请输入选择 (1-2): " choice
        
        case $choice in
            1) install_type="reality_only" ;;
            2) install_type="reality_ss" ;;
            *)
                log "ERROR" "无效选择"
                return 1
                ;;
        esac
    fi
    
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
    
    log "SUCCESS" "安装完成！"
}

# 检查版本
check_version() {
    log "INFO" "检查 Xray 版本..."
    
    local version_info
    version_info=$(bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ check 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo "$version_info"
        
        # 提取当前版本和最新版本
        local current_version=$(echo "$version_info" | grep "The current version of Xray is" | sed 's/.*is \(.*\)\./\1/')
        local latest_version=$(echo "$version_info" | grep "The latest release version of Xray is" | sed 's/.*is \(.*\)\./\1/')
        
        if [[ "$current_version" != "$latest_version" ]]; then
            log "INFO" "发现新版本: $latest_version (当前版本: $current_version)"
            return 1  # 需要更新
        else
            log "SUCCESS" "已是最新版本: $current_version"
            return 0  # 无需更新
        fi
    else
        log "ERROR" "版本检查失败"
        return 2  # 检查失败
    fi
}

# 更新功能
update_function() {
    log "INFO" "开始更新检查..."
    
    check_version
    local check_result=$?
    
    if [[ $check_result -eq 1 ]]; then
        # 发现新版本，询问用户是否更新
        read -p "是否更新到最新版本？(y/n): " update_choice
        
        if [[ "$update_choice" =~ ^[Yy]$ ]]; then
            log "INFO" "开始更新 Xray..."
            
            if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --without-geodata; then
                log "SUCCESS" "Xray 更新成功"
                
                # 重启服务
                if restart_service; then
                    log "SUCCESS" "更新完成！"
                else
                    log "ERROR" "服务重启失败，请检查配置"
                fi
            else
                log "ERROR" "Xray 更新失败"
            fi
        else
            log "INFO" "用户取消更新"
        fi
    elif [[ $check_result -eq 0 ]]; then
        # 已是最新版本，直接退出
        log "INFO" "当前已是最新版本，无需更新"
        return 0
    else
        log "ERROR" "版本检查失败，无法进行更新"
        return 1
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
    echo "1) 安装"
    echo "2) 更新"
    echo "3) 卸载"
    echo "4) 退出"
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
                install_function
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
    
    # 显示菜单循环
    while true; do
        show_menu
        read -p "请选择操作 (1-4): " choice
        
        case $choice in
            1)
                install_function
                ;;
            2)
                update_function
                ;;
            3)
                uninstall_function
                ;;
            4)
                log "INFO" "退出脚本"
                exit 0
                ;;
            *)
                log "ERROR" "无效选择，请重新输入"
                ;;
        esac
        
        echo ""
        read -p "按任意键继续..." -n 1
    done
}

# 执行主函数
main "$@"
