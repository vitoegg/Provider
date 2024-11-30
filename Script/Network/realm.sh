#!/usr/bin/env bash

# 设置路径
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 定义常量
CONF="/etc/realm/config.toml"
SYSTEMD="/lib/systemd/system/realm.service"

# 用户输入函数
get_user_input() {
    # 输入监听端口
    while true; do
        read -p "请输入本地监听端口 (推荐范围 1024-65535): " LISTEN_PORT
        if [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && [ "$LISTEN_PORT" -ge 1024 ] && [ "$LISTEN_PORT" -le 65535 ]; then
            break
        else
            echo "错误: 请输入1024-65535之间的有效端口号"
        fi
    done

    # 输入远程地址
    while true; do
        read -p "请输入远程服务器地址 (IP或域名): " REMOTE_ADDRESS
        if [[ -n "$REMOTE_ADDRESS" ]]; then
            break
        else
            echo "错误: 远程地址不能为空"
        fi
    done

    # 输入远程端口
    while true; do
        read -p "请输入远程服务器端口 (推荐范围 1024-65535): " REMOTE_PORT
        if [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] && [ "$REMOTE_PORT" -ge 1024 ] && [ "$REMOTE_PORT" -le 65535 ]; then
            break
        else
            echo "错误: 请输入1024-65535之间的有效端口号"
        fi
    done

    # 确认配置
    echo ""
    echo "确认配置信息:"
    echo "本地监听端口: $LISTEN_PORT"
    echo "远程服务器地址: $REMOTE_ADDRESS"
    echo "远程服务器端口: $REMOTE_PORT"
    
    read -p "是否确认这些配置? [y/n]: " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "已取消安装"
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

# 检测Realm最新版本
get_latest_version() {
    curl -s https://api.github.com/repos/zhboner/realm/releases/latest \
        | grep tag_name \
        | cut -d ":" -f2 \
        | sed 's/\"//g;s/\,//g;s/\ //g;s/v//'
}

# 主程序
main() {
    # 检查是否为root用户
    if [[ $EUID -ne 0 ]]; then
       echo "错误: 此脚本必须以root权限运行" 
       exit 1
    fi

    # 获取用户输入
    get_user_input

    # 检测架构
    ARCH=$(detect_architecture)
    echo "检测到系统架构: $ARCH"

    # 检测版本
    VERSION=$(get_latest_version)
    echo "检测到最新版本: $VERSION"
    
    # 下载对应版本
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/v${VERSION}/realm-${ARCH}-unknown-linux-gnu.tar.gz"
    echo "正在下载Realm"
    wget --no-check-certificate -O realm.tar.gz "$DOWNLOAD_URL"

    # 解压和安装
    tar -zxvf realm.tar.gz
    chmod +x realm
    mv -f realm /usr/local/bin/
    rm -f realm.tar.gz

    # 创建配置文件目录
    mkdir -p /etc/realm

    # 生成配置文件
    echo "正在生成配置文件..."
    cat > ${CONF} << EOF
[log]
level = "warn"
output = "realm.log"

[network]
no_tcp = false
use_udp = true

[[endpoints]]
listen = "0.0.0.0:${LISTEN_PORT}"
remote = "${REMOTE_ADDRESS}:${REMOTE_PORT}"
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
ExecStart=/usr/local/bin/realm -c ${CONF}
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
    echo "Realm 安装完成！配置信息如下："
    echo "监听端口: ${LISTEN_PORT}"
    echo "远程地址: ${REMOTE_ADDRESS}"
    echo "远程端口: ${REMOTE_PORT}"
    echo "==========================================="
}

# 执行主程序
main
