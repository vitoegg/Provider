#!/usr/bin/env bash

# 设置路径
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 定义常量
CONF="/etc/realm/config.toml"
SYSTEMD="/lib/systemd/system/realm.service"

# 卸载服务函数
uninstall_service() {
    clear
    echo "=== 正在卸载 Realm 服务 ==="
    
    # 停止并禁用服务
    systemctl stop realm.service 2>/dev/null
    systemctl disable realm.service 2>/dev/null
    
    # 删除服务文件
    rm -f /lib/systemd/system/realm.service
    
    # 删除配置文件
    rm -rf /etc/realm
    
    # 删除二进制文件
    rm -f /usr/local/bin/realm
    
    # 重新加载systemd
    systemctl daemon-reload
    systemctl reset-failed
    
    echo "=== Realm 卸载完成 ==="
}

# 用户输入函数（保持原脚本不变）
get_user_input() {
    # ... (原脚本中的函数内容保持不变)
}

# 检测系统架构（保持原脚本不变）
detect_architecture() {
    # ... (原脚本中的函数内容保持不变)
}

# 检测Realm最新版本（保持原脚本不变）
get_latest_version() {
    # ... (原脚本中的函数内容保持不变)
}

# 显示菜单
show_menu() {
    clear
    echo "===== Realm 管理脚本 ====="
    echo "1. 安装 Realm"
    echo "2. 卸载 Realm"
    echo "3. 退出"
    echo "======================="
}

# 主程序
main() {
    # 检查是否为root用户
    if [[ $EUID -ne 0 ]]; then
       echo "错误: 此脚本必须以root权限运行" 
       exit 1
    fi

    # 显示菜单并处理用户选择
    while true; do
        show_menu
        read -p "请选择操作 [1-3]: " choice
        case "$choice" in
            1)
                # 安装Realm
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
                
                read -p "按回车键返回主菜单" pause
                ;;
            
            2)
                # 卸载Realm
                uninstall_service
                read -p "按回车键返回主菜单" pause
                ;;
            
            3)
                echo "退出脚本"
                exit 0
                ;;
            
            *)
                echo "无效的选择，请重新输入"
                read -p "按回车键返回主菜单" pause
                ;;
        esac
    done
}

# 执行主程序
main
