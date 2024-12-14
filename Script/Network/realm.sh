#!/usr/bin/env bash

# 设置路径
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 定义常量
CONF="/etc/realm/config.toml"
# 根据不同系统调整systemd路径
if [ -d "/usr/lib/systemd/system" ]; then
    SYSTEMD="/usr/lib/systemd/system/realm.service"
elif [ -d "/lib/systemd/system" ]; then
    SYSTEMD="/lib/systemd/system/realm.service"
else
    echo "错误: 未找到systemd目录"
    exit 1
fi

# 卸载服务函数
uninstall_service() {
    clear
    echo "=== 开始卸载 Realm 服务 ==="
    
    # 停止并禁用服务
    if command -v systemctl >/dev/null 2>&1; then
        echo "正在停止 Realm 服务..."
        systemctl stop realm.service 2>/dev/null
        echo "正在禁用 Realm 服务..."
        systemctl disable realm.service 2>/dev/null
    else
        echo "正在停止 Realm 服务..."
        service realm stop 2>/dev/null
    fi
    
    # 删除服务文件
    echo "正在删除服务文件: $SYSTEMD"
    rm -f "$SYSTEMD"
    
    # 删除配置文件
    echo "正在删除配置目录: /etc/realm"
    rm -rf /etc/realm
    
    # 删除二进制文件
    echo "正在删除程序文件: /usr/local/bin/realm"
    rm -f /usr/local/bin/realm
    
    # 删除日志文件
    echo "正在删除日志文件: /var/log/realm.log"
    rm -f /var/log/realm.log
    
    # 重新加载systemd
    echo "正在重新加载 systemd 配置..."
    systemctl daemon-reload
    systemctl reset-failed
    
    echo "=== Realm 卸载完成 ==="
    exit 0
}

# 安装必要工具
install_required_tools() {
    local tools=("curl" "wget" "tar")
    local missing_tools=()
    
    # 检查哪些工具缺失
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    # 如果有缺失的工具，尝试安装
    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo "正在安装必要工具: ${missing_tools[*]}"
        
        # 检测包管理器并安装
        if command -v apt >/dev/null 2>&1; then
            apt update -y
            apt install -y "${missing_tools[@]}"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing_tools[@]}"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${missing_tools[@]}"
        else
            echo "错误: 无法识别��包管理器，请手动安装所需工具"
            exit 1
        fi
    fi
}

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

    return 0
}

# 检测系统架构
detect_architecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "x86_64"
            ;;
        aarch64)
            echo "aarch64"
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

# 显示菜单
show_menu() {
    clear
    echo "===== Realm 管理脚本 ====="
    echo "1. 安装 Realm"
    echo "2. 卸载 Realm"
    echo "3. 退出"
    echo "======================="
}

# 解压和安装
install_binary() {
    local temp_dir=$(mktemp -d)
    echo "正在解压和安装二进制文件..."
    
    # 解压到临时目录
    tar -xzf realm.tar.gz -C "$temp_dir"
    
    # 设置权限并移动文件
    chmod 755 "$temp_dir/realm"
    mv -f "$temp_dir/realm" /usr/local/bin/
    
    # 清理临时文件
    rm -f realm.tar.gz
    rm -rf "$temp_dir"
    
    # 验证安装
    if [ ! -x "/usr/local/bin/realm" ]; then
        echo "错误: 安装失败，请检查权限和磁盘空间"
        exit 1
    fi
}

# 安装Realm
install_realm() {
    # 安装必要工具
    install_required_tools

    # 检测架构
    ARCH=$(detect_architecture)
    echo "检测到系统架构: $ARCH"

    # 检测版本
    VERSION=$(get_latest_version)
    echo "检测到最新版本: $VERSION"
    
    # 下载对应版本
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/v${VERSION}/realm-${ARCH}-unknown-linux-gnu.tar.gz"
    echo "正在下载Realm"
    if ! wget --no-check-certificate -O realm.tar.gz "$DOWNLOAD_URL"; then
        echo "下载失败，尝试使用curl下载..."
        if ! curl -L -o realm.tar.gz "$DOWNLOAD_URL"; then
            echo "错误: 下载失败"
            exit 1
        fi
    fi

    # 下载完成后调用安装函数
    install_binary
    
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
    mkdir -p "$(dirname "$SYSTEMD")"
    cat > "${SYSTEMD}" << EOF
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
WorkingDirectory=/etc/realm

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable realm
    systemctl start realm

    # 检查服务状态
    if systemctl is-active --quiet realm; then
        echo "Realm 服务已成功启动"
    else
        echo "错误: Realm 服务启动失败，请检查日志"
    fi

    # 输出配置信息
    echo "==========================================="
    echo "Realm 安装完成！配置信息如下："
    echo "监听端口: ${LISTEN_PORT}"
    echo "远程地址: ${REMOTE_ADDRESS}"
    echo "远程端口: ${REMOTE_PORT}"
    echo "==========================================="
    
    # 直接退出
    exit 0
}

# 主程序 (移除确认环节)
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
                install_realm
                # install_realm 函数会自行退出
                ;;
            
            2)
                # 卸载Realm
                uninstall_service
                # uninstall_service 函数会自行退出
                ;;
            
            3)
                echo "退出脚本"
                exit 0
                ;;
            
            *)
                echo "无效的选择，请重新输入"
                sleep 2
                ;;
        esac
    done
}

# 执行主程序
main
