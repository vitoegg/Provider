#!/usr/bin/env bash

# 设置路径
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 定义常量
CONF="/etc/realm/config.toml"
SYSTEMD="/lib/systemd/system/realm.service"

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

# 检测Realm最新版本
get_latest_version() {
    curl -s https://api.github.com/repos/zhboner/realm/releases/latest \
        | grep tag_name \
        | cut -d ":" -f2 \
        | sed 's/\"//g;s/\,//g;s/\ //g;s/v//'
}

# 主程序
main() {

    # 检测架构
    ARCH=$(detect_architecture)
    echo "检测到系统架构: $ARCH"

    # 检测版本
    VERSION=$(get_latest_version)
    echo "检测到最新版本: $VERSION"
    
    # 下载对应版本
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/v${VERSION}/realm-${ARCH}-unknown-linux-gnu.tar.gz"
    echo "正在下载Realm"
    wget -P /etc/realm "$DOWNLOAD_URL"

    # 解压和安装
    tar -zxvf -C /etc/realm /etc/realm/realm-x86_64-unknown-linux-gnu.tar.gz
    chmod +x /etc/realm/realm

    # 创建配置文件
    echo "正在生成配置文件..."
    cat > ${CONF} << EOF
[log]
level = "warn"
output = "realm.log"

[network]
no_tcp = false
use_udp = true

[[endpoints]]
listen = "0.0.0.0:51187"
remote = "1.1.1.1:59187"
EOF

    # 创建systemd服务
    echo "正在创建系统服务..."
    cat > ${SYSTEMD} << EOF
[Unit]
Description=Realm Service
After=network.target
Before=network-online.target
StartLimitBurst=0
StartLimitIntervalSec=60

[Service]
Type=simple
LimitNOFILE=65536
ExecStart=/etc/realm/realm -c ${CONF}
WorkingDirectory=/etc/realm
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable realm
    systemctl start realm
    systemctl status realm

    # 输出配置信息
    echo "==========================================="
    echo "Relam 安装完成！配置信息如下："
    echo "端口: 59187"
    echo "==========================================="
}

# 执行主程序
main
