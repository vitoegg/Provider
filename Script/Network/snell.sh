#!/usr/bin/env bash

# 设置路径
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 定义常量
CONF="/etc/snell.conf"
SYSTEMD="/lib/systemd/system/snell.service"
VERSION="v4.1.1"
DOWNLOAD_BASE="https://dl.nssurge.com/snell"

# 检测包管理器并安装unzip
install_dependencies() {
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
        read -p "请输入端口号 (50000-60000): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 50000 && "$PORT" -le 60000 ]]; then
            break
        else
            echo "错误：端口号必须在50000-60000之间"
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

# 主程序
main() {
    # 安装依赖
    echo "正在安装依赖..."
    install_dependencies

    # 检测架构
    ARCH=$(detect_architecture)
    echo "检测到系统架构: $ARCH"

    # 下载对应版本
    cd ~/
    DOWNLOAD_URL="${DOWNLOAD_BASE}/snell-server-${VERSION}-linux-${ARCH}.zip"
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

    # 创建配置文件
    mkdir -p /etc/snell
    echo "正在生成配置文件..."
    cat > ${CONF} << EOF
[snell-server]
listen = 0.0.0.0:${PORT}
psk = ${PSK}
ipv6 = false
EOF

    # 创建systemd服务
    echo "正在创建系统服务..."
    cat > ${SYSTEMD} << EOF
[Unit]
Description=Snell Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
LimitNOFILE=65536
ExecStart=/usr/local/bin/snell-server -c ${CONF}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable snell
    systemctl start snell
    systemctl status snell

    # 输出配置信息
    echo "==========================================="
    echo "Snell 安装完成！配置信息如下："
    echo "端口: ${PORT}"
    echo "PSK: ${PSK}"
    echo "==========================================="
}

# 执行主程序
main
