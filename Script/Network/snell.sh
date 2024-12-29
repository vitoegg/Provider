#!/usr/bin/env bash

# 设置严格模式
set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 全局变量
CONF="/etc/snell.conf"
SYSTEMD="/lib/systemd/system/snell.service"
DEFAULT_VERSION="4.1.1"
DOWNLOAD_BASE="https://dl.nssurge.com/snell"
INSTALL_DIR="/usr/local/bin"
VERSION=""
ACTION=""

# 帮助信息
show_usage() {
    cat << EOF
用法: $0 [选项]
选项:
    -i, --install        安装 Snell 服务
    -u, --uninstall      卸载 Snell 服务
    -v, --version        指定 Snell 版本 (例如: 4.1.1)
    -h, --help           显示此帮助信息

示例:
    $0 -i                     # 安装最新版本
    $0 -i -v 4.1.1            # 安装指定版本
    $0 -u                     # 卸载服务
EOF
    exit 1
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--install)
                ACTION="install"
                shift
                ;;
            -u|--uninstall)
                ACTION="uninstall"
                shift
                ;;
            -v|--version)
                VERSION="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                ;;
            *)
                echo -e "${RED}错误: 未知参数 $1${NC}"
                show_usage
                ;;
        esac
    done

    # 设置默认值
    [[ -z "$VERSION" ]] && VERSION="$DEFAULT_VERSION"
    [[ -z "$ACTION" ]] && ACTION="install"
}

# 日志函数
log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以root用户运行"
        exit 1
    fi
}

# 检查依赖
check_dependencies() {
    local deps=("wget" "unzip" "curl" "systemctl")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -ne 0 ]]; then
        log_info "正在安装缺失的依赖: ${missing[*]}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y "${missing[@]}"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing[@]}"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${missing[@]}"
        else
            log_error "未找到支持的包管理器"
            exit 1
        fi
    fi
}

# 检查端口是否有效
is_valid_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ && "$port" -ge 50000 && "$port" -le 60000 ]]; then
        return 0
    fi
    return 1
}

# 获取有效端口
get_valid_port() {
    while true; do
        read -p "请输入端口号 (50000-60000): " PORT
        if is_valid_port "$PORT"; then
            break
        else
            log_error "无效的端口号，请输入50000-60000之间的数字"
        fi
    done
}

# 检测系统架构
detect_architecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        i386|i686) echo "i386" ;;
        aarch64) echo "aarch64" ;;
        armv7l) echo "armv7l" ;;
        *)
            log_error "不支持的系统架构: $arch"
            exit 1
            ;;
    esac
}

# 生成PSK
generate_psk() {
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    log_info "已生成PSK: ${PSK}"
}

# 检查服务状态
check_service_status() {
    local retries=5
    local wait_time=2

    for ((i=1; i<=retries; i++)); do
        if systemctl is-active snell >/dev/null 2>&1; then
            return 0
        fi
        log_warn "等待服务启动... ($i/$retries)"
        sleep $wait_time
    done
    return 1
}

# 清理安装文件
cleanup() {
    rm -f ~/snell.zip
}

# 卸载服务
uninstall_service() {
    log_info "开始卸载 Snell 服务..."
    
    if systemctl is-active snell >/dev/null 2>&1; then
        systemctl stop snell
        systemctl disable snell
    fi
    
    rm -f "$SYSTEMD"
    rm -f "$CONF"
    rm -f "$INSTALL_DIR/snell-server"
    rm -rf /etc/snell
    
    systemctl daemon-reload
    
    log_info "Snell 服务已完全卸载"
}

# 安装服务
install_service() {
    # 下载和安装
    local arch=$(detect_architecture)
    local download_url="${DOWNLOAD_BASE}/snell-server-v${VERSION}-linux-${arch}.zip"
    
    cd ~/
    log_info "正在下载: $download_url"
    wget --no-check-certificate -O snell.zip "$download_url" || {
        log_error "下载失败"
        exit 1
    }
    
    unzip -o snell.zip
    chmod +x snell-server
    mv -f snell-server "$INSTALL_DIR/"
    
    # 获取端口和生成PSK
    get_valid_port
    generate_psk
    
    # 创建配置文件
    mkdir -p /etc/snell
    cat > "$CONF" << EOF
[snell-server]
listen = 0.0.0.0:${PORT}
psk = ${PSK}
ipv6 = false
EOF
    
    # 创建系统服务
    cat > "$SYSTEMD" << EOF
[Unit]
Description=Snell Service
After=network.target
Before=network-online.target
StartLimitBurst=0
StartLimitIntervalSec=60

[Service]
Type=simple
LimitNOFILE=65536
ExecStart=${INSTALL_DIR}/snell-server -c ${CONF}
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
    
    # 启动服务
    systemctl daemon-reload
    systemctl enable snell
    systemctl start snell
    
    # 检查服务状态
    if check_service_status; then
        log_info "Snell 服务已成功启动"
        echo "==========================================="
        echo -e "${GREEN}Snell 安装完成！配置信息如下：${NC}"
        echo "版本: ${VERSION}"
        echo "端口: ${PORT}"
        echo "PSK: ${PSK}"
        echo "==========================================="
    else
        log_error "Snell 服务启动失败，请检查日志"
        systemctl status snell
        exit 1
    fi
    
    # 清理临时文件
    cleanup
}

# 主函数
main() {
    # 解析命令行参数
    parse_args "$@"
    
    # 检查root权限
    check_root
    
    # 检查依赖
    check_dependencies
    
    # 执行操作
    case "$ACTION" in
        install)
            install_service
            ;;
        uninstall)
            uninstall_service
            ;;
        *)
            log_error "未知操作: $ACTION"
            show_usage
            ;;
    esac
}

# 错误处理
trap 'echo -e "${RED}脚本执行中断${NC}"; cleanup; exit 1' INT TERM

# 执行主程序
main "$@"
