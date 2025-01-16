#!/usr/bin/env bash

# 设置路径
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 定义常量
CONF="/etc/snell/snell.conf"
SYSTEMD="/lib/systemd/system/snell.service"
DOWNLOAD_BASE="https://dl.nssurge.com/snell"

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "错误：此脚本必须以root权限运行。请使用sudo执行。"
        exit 1
    fi
}

# 检测依赖包是否已安装
check_dependencies() {
    local deps=("unzip" "wget")
    local missing_deps=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "缺少以下依赖包: ${missing_deps[*]}"
        return 1
    fi
    return 0
}

# 安装依赖
install_dependencies() {
    if ! check_dependencies; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install unzip wget -y
        elif command -v yum >/dev/null 2>&1; then
            yum install unzip wget -y
        elif command -v dnf >/dev/null 2>&1; then
            dnf install unzip wget -y
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy unzip wget --noconfirm
        else
            echo "未能找到支持的包管理器，请手动安装unzip和wget"
            exit 1
        fi
    fi
}

# 检测系统架构
detect_architecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "amd64"
            ;;
        i386|i686)
            echo "i386"
            ;;
        aarch64)
            echo "aarch64"
            ;;
        armv7l)
            echo "armv7l"
            ;;
        *)
            echo "不支持的系统架构: $arch"
            exit 1
            ;;
    esac
}

# 获取用户输入的端口号
get_valid_port() {
    while true; do
        read -p "请输入端口号 (10000-60000): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 10000 && "$PORT" -le 60000 ]]; then
            break
        else
            echo "错误：端口号必须在10000-60000之间"
        fi
    done
}

# 生成或使用已有的PSK
generate_psk() {
    if [ -z "${PSK}" ]; then
        PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
        echo "已生成PSK: ${PSK}"
    else
        echo "使用预定义的PSK: ${PSK}"
    fi
}

# 卸载脚本
uninstall() {
    echo "正在卸载Snell服务..."
    
    # 停止并禁用服务
    systemctl stop snell
    systemctl disable snell

    # 删除服务文件
    rm -f "${SYSTEMD}"
    rm -f "${CONF}"
    rm -f /usr/local/bin/snell-server

    # 重新加载systemd
    systemctl daemon-reload

    echo "Snell服务已成功卸载。"
    exit 0
}

# 主程序
main() {
    # 检查root权限
    check_root

    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--version)
                VERSION="$2"
                shift 2
                ;;
            -u|--uninstall)
                uninstall
                ;;
            *)
                echo "未知参数: $1"
                exit 1
                ;;
        esac
    done

    # 检查版本是否传入
    if [ -z "$VERSION" ]; then
        echo "错误：请使用 -v 或 --version 指定Snell版本"
        exit 1
    fi

    # 安装依赖
    echo "正在检查和安装依赖..."
    install_dependencies

    # 检测架构
    ARCH=$(detect_architecture)
    echo "检测到系统架构: $ARCH"

    # 下载对应版本
    cd ~/ || exit
    DOWNLOAD_URL="${DOWNLOAD_BASE}/snell-server-v${VERSION}-linux-${ARCH}.zip"
    echo "正在下载: $DOWNLOAD_URL"
    wget --no-check-certificate -O snell.zip "$DOWNLOAD_URL"

    # 解压和安装
    unzip -o snell.zip
    rm -f snell.zip
    chmod +x snell-server
    mv -f snell-server /usr/local/bin/

    # 获取端口号
    get_valid_port

    # 生成PSK
    generate_psk

    # 创建配置目录
    mkdir -p /etc/snell

    # 创建配置文件
    echo "正在生成配置文件..."
    cat > "${CONF}" << EOF
[snell-server]
listen = 0.0.0.0:${PORT}
psk = ${PSK}
ipv6 = false
EOF

    # 创建systemd服务
    echo "正在创建系统服务..."
    cat > "${SYSTEMD}" << EOF
[Unit]
Description=Snell Service
After=network.target
Before=network-online.target
StartLimitBurst=0
StartLimitIntervalSec=60

[Service]
Type=simple
LimitNOFILE=65536
ExecStart=/usr/local/bin/snell-server -c ${CONF}
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

# 启动服务并检查状态
systemctl daemon-reload
systemctl enable snell
systemctl start snell

# 检查服务是否成功启动
if systemctl is-active snell &> /dev/null; then
    echo "Snell 服务启动成功！"
else
    echo "错误：Snell 服务启动失败，请检查日志："
    systemctl status snell
    exit 1
fi

# 输出配置信息
echo "===========================================" 
echo "Snell 安装完成！配置信息如下："
echo "版本: ${VERSION}"
echo "端口: ${PORT}"
echo "PSK: ${PSK}"
echo "===========================================" 

}

# 执行主程序
main "$@"
