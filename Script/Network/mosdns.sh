#!/bin/bash

# Define color codes for different log categories
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
MOSDNS_VERSION=""
ARCH_TYPE=""
USE_CUSTOM_DNS=0
CUSTOM_DNS_SERVER=""
DOMAIN_SELECTION=""
UNINSTALL=0
INTERACTIVE_MODE=0

# Domain list configuration
DOMAIN_LISTS=(
    "https://mirror.1991991.xyz/RuleSet/Extra/MosDNS/google.txt|Google"
    "https://mirror.1991991.xyz/RuleSet/Extra/MosDNS/openai.txt|OpenAI"
)

# Logging functions
log_info() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')][INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')][WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')][ERROR] $1${NC}"
}

log_debug() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')][DEBUG] $1${NC}"
}

# Check if running as root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "此脚本必须以root用户运行"
        exit 1
    fi
}

# Check system architecture
check_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH_TYPE="amd64"
            ;;
        aarch64)
            ARCH_TYPE="arm64"
            ;;
        *)
            log_error "不支持的系统架构: $ARCH"
            log_error "此脚本仅支持 amd64 和 arm64 架构"
            exit 1
            ;;
    esac
    log_info "检测到系统架构: $ARCH_TYPE"
}

# Check if mosdns service already exists
check_installed() {
    if systemctl is-active mosdns &>/dev/null || systemctl status mosdns &>/dev/null 2>&1; then
        log_error "mosdns服务已存在，请先卸载后再安装"
        exit 1
    fi
    
    if [ -f "/usr/local/bin/mosdns" ]; then
        log_warn "检测到mosdns执行文件已存在于/usr/local/bin/mosdns"
        log_error "请先执行卸载操作"
        exit 1
    fi
}

# Install dependencies
install_dependencies() {
    local deps_to_install=()
    
    # Check wget or curl
    if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
        deps_to_install+=("wget")
    fi
    
    # Check unzip
    if ! command -v unzip &>/dev/null; then
        deps_to_install+=("unzip")
    fi
    
    # Check jq
    if ! command -v jq &>/dev/null; then
        deps_to_install+=("jq")
    fi
    
    if [ ${#deps_to_install[@]} -eq 0 ]; then
        log_info "所有必要依赖已安装"
        return 0
    fi
    
    log_info "检测到缺失的依赖包: ${deps_to_install[*]}"
    log_info "开始安装依赖包..."
    
    if [ -f /etc/debian_version ]; then
        apt-get update -qq >/dev/null 2>&1
        for dep in "${deps_to_install[@]}"; do
            log_info "正在安装 $dep..."
            if apt-get install -y "$dep" >/dev/null 2>&1; then
                log_info "✓ $dep 安装成功"
            else
                log_error "✗ $dep 安装失败"
                exit 1
            fi
        done
    elif [ -f /etc/redhat-release ]; then
        for dep in "${deps_to_install[@]}"; do
            log_info "正在安装 $dep..."
            if yum install -y "$dep" >/dev/null 2>&1; then
                log_info "✓ $dep 安装成功"
            else
                log_error "✗ $dep 安装失败"
                exit 1
            fi
        done
    else
        log_error "不支持的Linux发行版，无法自动安装依赖"
        exit 1
    fi
}

# Get the latest mosdns version from GitHub
get_latest_version() {
    log_info "正在获取最新版本信息..."
    
    local release_page
    if command -v wget &>/dev/null; then
        release_page=$(wget -qO- https://api.github.com/repos/IrineSistiana/mosdns/releases/latest)
    else
        release_page=$(curl -s https://api.github.com/repos/IrineSistiana/mosdns/releases/latest)
    fi
    
    if [ -z "$release_page" ]; then
        log_error "无法获取版本信息"
        exit 1
    fi
    
    MOSDNS_VERSION=$(echo "$release_page" | jq -r '.tag_name')
    if [ -z "$MOSDNS_VERSION" ] || [ "$MOSDNS_VERSION" = "null" ]; then
        log_error "解析版本号失败"
        exit 1
    fi
    
    log_info "最新版本: $MOSDNS_VERSION"
}

# Download selected domain lists
download_domain_lists() {
    local selection=$1
    local rule_dir="/etc/mosdns/rule"
    
    mkdir -p "$rule_dir"
    log_info "正在下载域名列表..."
    
    local downloaded_files=()
    for num in $selection; do
        if [ "$num" -ge 1 ] && [ "$num" -le "${#DOMAIN_LISTS[@]}" ]; then
            local index=$((num-1))
            local list_info="${DOMAIN_LISTS[$index]}"
            local url="${list_info%%|*}"
            local name="${list_info##*|}"
            local filename="${name,,}.txt"
            
            log_info "正在下载 $name 域名列表..."
            if command -v wget &>/dev/null; then
                wget -q "$url" -O "$rule_dir/$filename" || {
                    log_error "下载 $name 列表失败"
                    return 1
                }
            else
                curl -s "$url" -o "$rule_dir/$filename" || {
                    log_error "下载 $name 列表失败"
                    return 1
                }
            fi
            log_info "✓ $name 列表下载成功"
            downloaded_files+=("$rule_dir/$filename")
        else
            log_error "无效的选择编号: $num"
            return 1
        fi
    done
    
    # Store downloaded files for config generation
    DOWNLOADED_RULE_FILES=("${downloaded_files[@]}")
    return 0
}

# Generate mosdns configuration
generate_config() {
    local config_file="/etc/mosdns/config.yaml"
    
    log_info "正在生成配置文件..."
    
    cat > "$config_file" << 'EOF'
log:
  level: error
  file: "/etc/mosdns/mosdns.log"

plugins:
EOF

    # Add custom DNS plugins if configured
    if [ $USE_CUSTOM_DNS -eq 1 ]; then
        cat >> "$config_file" << EOF
  - tag: dns_domain
    type: "domain_set"
    args:
      files:
EOF
        for file in "${DOWNLOADED_RULE_FILES[@]}"; do
            echo "        - \"$file\"" >> "$config_file"
        done
        
        cat >> "$config_file" << EOF

  - tag: dns_reslove
    type: "forward"
    args:
      upstreams:
        - addr: "udp://${CUSTOM_DNS_SERVER}"

EOF
    fi

    # Add standard DNS plugins
    cat >> "$config_file" << 'EOF'
  - tag: main_dns
    type: "forward"
    args:
      concurrent: 2
      upstreams:
        - addr: "udp://8.8.8.8"
        - addr: "tls://1.1.1.1:853"
          bootstrap: "1.0.0.1"
          enable_pipeline: true
          idle_timeout: 60

  - tag: fallback_dns
    type: "forward"
    args:
      concurrent: 2
      upstreams:
        - addr: "udp://9.9.9.9"
        - addr: "udp://208.67.222.222"

  - tag: lazy_cache
    type: "cache"
    args:
      size: 15360
      lazy_cache_ttl: 86400
      dump_file: "/etc/mosdns/cache.dump"
      dump_interval: 1800

  - tag: has_resp_sequence
    type: "sequence"
    args:
      - matches: has_resp
        exec: accept

  - tag: core_reslove
    type: "fallback"
    args:
      primary: main_dns
      secondary: fallback_dns
      threshold: 200
      always_standby: true

  - tag: main_sequence
    type: "sequence"
    args:
      - exec: prefer_ipv4
      - exec: $lazy_cache
EOF

    # Add custom DNS matching if configured
    if [ $USE_CUSTOM_DNS -eq 1 ]; then
        cat >> "$config_file" << 'EOF'

      - matches:
        - qname $dns_domain
        exec: $dns_reslove
      - exec: jump has_resp_sequence
EOF
    fi

    # Complete main_sequence
    cat >> "$config_file" << 'EOF'

      - exec: $core_reslove

  - tag: udp_server
    type: "udp_server"
    args:
      entry: main_sequence
      listen: ":53"
EOF

    log_info "配置文件生成完成: $config_file"
}

# Download and install mosdns
install_mosdns() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    cd "$tmp_dir" || exit 1
    
    log_info "正在下载 mosdns ${MOSDNS_VERSION}..."
    local download_url="https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VERSION}/mosdns-linux-${ARCH_TYPE}.zip"
    
    if command -v wget &>/dev/null; then
        wget --no-check-certificate -q "$download_url" -O mosdns.zip || {
            log_error "下载失败"
            cd / && rm -rf "$tmp_dir"
            exit 1
        }
    else
        curl -L -s "$download_url" -o mosdns.zip || {
            log_error "下载失败"
            cd / && rm -rf "$tmp_dir"
            exit 1
        }
    fi
    
    log_info "正在解压文件..."
    unzip -q mosdns.zip || {
        log_error "解压失败"
        cd / && rm -rf "$tmp_dir"
        exit 1
    }
    
    log_info "正在安装 mosdns 执行文件..."
    chmod +x mosdns
    mv mosdns /usr/local/bin/ || {
        log_error "移动执行文件失败"
        cd / && rm -rf "$tmp_dir"
        exit 1
    }
    
    log_info "✓ mosdns 执行文件安装成功"
    cd / && rm -rf "$tmp_dir"
}

# Configure and start mosdns service
configure_mosdns() {
    mkdir -p /etc/mosdns
    
    # Download domain lists if custom DNS is configured
    if [ $USE_CUSTOM_DNS -eq 1 ]; then
        if ! download_domain_lists "$DOMAIN_SELECTION"; then
            log_error "域名列表下载失败"
            exit 1
        fi
    fi
    
    # Generate configuration file
    generate_config
    
    # Install systemd service
    log_info "正在安装 mosdns 服务..."
    /usr/local/bin/mosdns service install -d /etc/mosdns -c /etc/mosdns/config.yaml >/dev/null 2>&1 || {
        log_error "服务安装失败"
        exit 1
    }
    log_info "✓ mosdns 服务安装成功"
    
    # Modify DNS resolution
    log_info "正在配置系统DNS..."
    chattr -i /etc/resolv.conf 2>/dev/null
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    chattr +i /etc/resolv.conf
    log_info "✓ 系统DNS配置完成"
    
    # Start service
    log_info "正在启动 mosdns 服务..."
    /usr/local/bin/mosdns service start || {
        log_error "服务启动失败"
        exit 1
    }
    
    sleep 2
    
    if systemctl is-active mosdns &>/dev/null; then
        log_info "✓ mosdns 服务启动成功！"
        echo "========================================="
        systemctl status mosdns --no-pager | head -n 10
        echo "========================================="
    else
        log_error "mosdns 服务启动失败，请检查日志"
        exit 1
    fi
}

# Uninstall mosdns
uninstall_mosdns() {
    log_info "开始卸载 mosdns..."
    
    # Check if mosdns binary exists
    if [ ! -f "/usr/local/bin/mosdns" ]; then
        log_warn "mosdns 未安装"
        return 0
    fi
    
    # Stop service
    if systemctl is-active mosdns &>/dev/null; then
        log_info "正在停止 mosdns 服务..."
        /usr/local/bin/mosdns service stop 2>/dev/null
        log_info "✓ 服务已停止"
    fi
    
    # Uninstall service
    log_info "正在卸载 mosdns 服务..."
    /usr/local/bin/mosdns service uninstall 2>/dev/null
    log_info "✓ 服务已卸载"
    
    # Restore DNS configuration
    log_info "正在还原系统DNS配置..."
    chattr -i /etc/resolv.conf 2>/dev/null
    cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
    log_info "✓ DNS配置已还原"
    
    # Remove files
    log_info "正在删除 mosdns 文件..."
    rm -f /usr/local/bin/mosdns
    rm -rf /etc/mosdns
    log_info "✓ 文件已删除"
    
    systemctl daemon-reload >/dev/null 2>&1
    
    log_info "✓ mosdns 卸载完成！"
}

# Parse command line arguments
parse_args() {
    if [ $# -eq 0 ]; then
        INTERACTIVE_MODE=1
        return 0
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--install)
                log_info "快速安装模式：使用默认配置"
                shift
                ;;
            -d|--dns)
                if [ -z "$2" ]; then
                    log_error "使用 -d 选项需要提供DNS服务器地址"
                    echo "用法: $0 [-i] [-d <DNS服务器地址>] [-u]"
                    exit 1
                fi
                USE_CUSTOM_DNS=1
                CUSTOM_DNS_SERVER="$2"
                shift 2
                ;;
            -u|--uninstall)
                UNINSTALL=1
                shift
                ;;
            *)
                log_error "未知参数: $1"
                echo "用法: $0 [-i] [-d <DNS服务器地址>] [-u]"
                exit 1
                ;;
        esac
    done
    
    # Validate parameters and prompt for domain list selection if needed
    if [ $USE_CUSTOM_DNS -eq 1 ] && [ -z "$DOMAIN_SELECTION" ]; then
        log_info "检测到自定义DNS配置，需要选择域名列表"
        echo ""
        echo "可用的域名列表："
        for i in "${!DOMAIN_LISTS[@]}"; do
            local list_info="${DOMAIN_LISTS[$i]}"
            local name="${list_info##*|}"
            echo "  $(($i+1)). $name"
        done
        echo ""
        read -p "请输入要使用的列表编号（多个用空格分隔，如: 1 2）: " DOMAIN_SELECTION
        if [ -z "$DOMAIN_SELECTION" ]; then
            log_error "必须选择至少一个域名列表"
            exit 1
        fi
    fi
    
    # Display operation summary
    if [ $UNINSTALL -eq 1 ]; then
        log_info "准备卸载 mosdns..."
    elif [ $USE_CUSTOM_DNS -eq 1 ]; then
        log_info "自定义DNS服务器: $CUSTOM_DNS_SERVER"
        log_info "选择的域名列表: $DOMAIN_SELECTION"
    else
        log_info "使用默认配置安装"
    fi
}

# Interactive menu
show_menu() {
    echo ""
    echo "========================================="
    echo "        MosDNS 服务管理脚本"
    echo "========================================="
    echo "1) 安装 mosdns 服务"
    echo "2) 卸载 mosdns 服务"
    echo "3) 退出"
    echo "========================================="
    read -p "请选择操作 [1-3]: " choice
    
    case $choice in
        1)
            log_info "选择：安装 mosdns 服务"
            echo ""
            read -p "是否配置额外的DNS解析？(y/n) [n]: " use_custom
            if [[ "$use_custom" == "y" || "$use_custom" == "Y" ]]; then
                USE_CUSTOM_DNS=1
                read -p "请输入自定义DNS服务器地址: " CUSTOM_DNS_SERVER
                if [ -z "$CUSTOM_DNS_SERVER" ]; then
                    log_error "DNS服务器地址不能为空"
                    exit 1
                fi
                
                echo ""
                echo "可用的域名列表："
                for i in "${!DOMAIN_LISTS[@]}"; do
                    local list_info="${DOMAIN_LISTS[$i]}"
                    local name="${list_info##*|}"
                    echo "  $(($i+1)). $name"
                done
                echo ""
                read -p "请输入要使用的列表编号（多个用空格分隔，如: 1 2）: " DOMAIN_SELECTION
                if [ -z "$DOMAIN_SELECTION" ]; then
                    log_error "必须选择至少一个域名列表"
                    exit 1
                fi
            fi
            
            check_installed
            check_arch
            install_dependencies
            get_latest_version
            install_mosdns
            configure_mosdns
            ;;
        2)
            log_info "选择：卸载 mosdns 服务"
            UNINSTALL=1
            uninstall_mosdns
            ;;
        3)
            log_info "退出脚本"
            exit 0
            ;;
        *)
            log_error "无效的选择"
            exit 1
            ;;
    esac
}

# Main function
main() {
    check_root
    parse_args "$@"
    
    if [ $INTERACTIVE_MODE -eq 1 ]; then
        show_menu
    elif [ $UNINSTALL -eq 1 ]; then
        uninstall_mosdns
    else
        check_installed
        check_arch
        install_dependencies
        get_latest_version
        install_mosdns
        configure_mosdns
    fi
}

# Execute main function with all command line arguments
main "$@"

