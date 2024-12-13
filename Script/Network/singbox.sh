#!/bin/bash

set -e -o pipefail

# 检查root权限
if [ "$(id -u)" != "0" ]; then
    echo "此脚本需要root权限运行"
    exit 1
fi

# 检查并安装依赖
check_dependencies() {
    local deps=(curl dpkg jq)
    for dep in "${deps[@]}"; do
        if ! command -v $dep &>/dev/null; then
            echo "正在安装 $dep..."
            apt-get update && apt-get install -y $dep
        fi
    done
}

# 生成随机密码
generate_password() {
    tr -dc 'A-Za-z0-9!@#$%' < /dev/urandom | head -c 16
}

# 生成随机端口
generate_port() {
    local port
    while true; do
        port=$(shuf -i 50000-60000 -n 1)
        if [[ ! $port =~ 4 ]]; then
            echo "$port"
            break
        fi
    done
}

# 预定义域名列表
DOMAINS=(
    "updates.cdn-apple.com"
    "weather-data.apple.com"
    "cdn-dynmedia-1.microsoft.com"
    "software.download.prss.microsoft.com"
    "sns-video-hw.xhscdn.com"
)

# 选择域名
select_domain() {
    echo "域名选择："
    echo "1. 随机选择"
    echo "2. 从列表中选择"
    echo "3. 手动输入"
    read -p "请选择 (1-3): " domain_choice
    
    case $domain_choice in
        1)
            echo "${DOMAINS[$RANDOM % ${#DOMAINS[@]}]}"
            ;;
        2)
            echo "可用域名："
            for i in "${!DOMAINS[@]}"; do
                echo "$((i+1)). ${DOMAINS[$i]}"
            done
            read -p "请选择 (1-${#DOMAINS[@]}): " domain_index
            echo "${DOMAINS[$((domain_index-1))]}"
            ;;
        3)
            read -p "请输入域名: " custom_domain
            echo "$custom_domain"
            ;;
    esac
}

# 验证端口是否有效
validate_port() {
    local port=$1
    
    # 检查是否为数字
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "错误：端口必须是数字"
        return 1
    fi
    
    # 检查端口范围
    if [ "$port" -lt 50000 ] || [ "$port" -gt 60000 ]; then
        echo "错误：端口必须在 50000-60000 之间"
        return 1
    fi
    
    # 检查端口是否被占用
    if netstat -tuln | grep -q ":$port "; then
        echo "错误：端口 $port 已被占用"
        return 1
    fi
    
    return 0
}

# 获取有效端口
get_valid_port() {
    local port
    while true; do
        read -p "请输入端口 (50000-60000): " port
        if validate_port "$port"; then
            echo "$port"
            return 0
        fi
        echo "请重新输入端口"
    done
}

# 配置sing-box
configure_singbox() {
    local ss_password=$(generate_password)
    local tls_password=$(generate_password)
    local port
    
    echo "端口选择："
    echo "1. 随机生成"
    echo "2. 手动输入"
    read -p "请选择 (1-2): " port_choice
    
    if [ "$port_choice" = "1" ]; then
        # 随机生成有效端口
        while true; do
            port=$(generate_port)
            if validate_port "$port"; then
                break
            fi
        done
    else
        port=$(get_valid_port)
    fi
    
    local domain=$(select_domain)
    
    # 创建配置文件
    cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "disabled": true
  },
  "inbounds": [
    {
      "type": "shadowtls",
      "listen": "::",
      "listen_port": $port,
      "version": 3,
      "users": [
        {
          "name": "Cloud",
          "password": "$tls_password"
        }
      ],
      "handshake": {
        "server": "$domain",
        "server_port": 443
      },
      "detour": "shadowsocks-in"
    },
    {
      "type": "shadowsocks",
      "tag": "shadowsocks-in",
      "listen": "127.0.0.1",
      "method": "aes-128-gcm",
      "password": "$ss_password"
    }
  ]
}
EOF

    # 设置开机启动
    echo "正在设置开机启动..."
    if ! systemctl enable sing-box; then
        echo "设置开机启动失败"
        exit 1
    fi
    
    # 启动服务
    echo "正在启动 sing-box 服务..."
    if ! systemctl start sing-box; then
        echo "启动服务失败"
        exit 1
    fi
    
    # 检查服务状态
    echo "正在检查服务状态..."
    sleep 2  # 等待服务完全启动
    if ! systemctl is-active --quiet sing-box; then
        echo "sing-box 服务启动失败，请检查日志: journalctl -u sing-box"
        exit 1
    fi
    
    # 服务启动成功，输出配置信息
    echo "sing-box 服务配置成功！"
    echo "----------------------------------------"
    echo "配置信息："
    echo "IP: $(curl -s ifconfig.me)"
    echo "端口: $port"
    echo "域名: $domain"
    echo "Shadowsocks密码: $ss_password"
    echo "ShadowTLS密码: $tls_password"
    echo "----------------------------------------"
}

# 卸载功能
uninstall_singbox() {
    echo "开始卸载 sing-box..."
    echo "----------------------------------------"
    
    # 停止服务
    echo "正在停止 sing-box 服务..."
    if systemctl is-active --quiet sing-box; then
        systemctl stop sing-box
        echo "✓ 服务已停止"
    else
        echo "- 服务已经处于停止状态"
    fi
    
    # 禁用开机启动
    echo "正在禁用开机启动..."
    if systemctl is-enabled --quiet sing-box; then
        systemctl disable sing-box
        echo "✓ 开机启动已禁用"
    else
        echo "- 开机启动已经处于禁用状态"
    fi
    
    # 卸载软件包
    echo "正在卸载 sing-box 软件包..."
    if dpkg -l | grep -q sing-box; then
        dpkg -r sing-box
        echo "✓ 软件包已卸载"
    else
        echo "- 软件包已经不存在"
    fi
    
    # 删除配置文件
    echo "正在删除配置文件..."
    if [ -d "/etc/sing-box" ]; then
        rm -rf /etc/sing-box
        echo "✓ 配置文件已删除"
    else
        echo "- 配置目录不存在"
    fi
    
    echo "----------------------------------------"
    echo "sing-box 已完全卸载！"
}

# 下载并安装sing-box
install_singbox() {
    local version
    
    # 获取最新版本号
    local latest_version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    
    echo "版本选择："
    echo "1. 最新版本 ($latest_version)"
    echo "2. 手动输入版本"
    read -p "请选择 (1-2): " version_choice
    
    case $version_choice in
        1)
            version=$latest_version
            ;;
        2)
            read -p "请输入版本号 (例如: v1.8.0): " input_version
            version=$input_version
            ;;
        *)
            echo "无效选择"
            exit 1
            ;;
    esac
    
    # 确定系统架构
    local ARCH_RAW=$(uname -m)
    local ARCH
    case "${ARCH_RAW}" in
        'x86_64')    ARCH='amd64';;
        'x86' | 'i686' | 'i386')     ARCH='386';;
        'aarch64' | 'arm64') ARCH='arm64';;
        'armv7l')   ARCH='armv7';;
        's390x')    ARCH='s390x';;
        *)          
            echo "不支持的系统架构: ${ARCH_RAW}"
            exit 1
            ;;
    esac
    
    # 下载安装包
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${version}/sing-box-${version#v}-linux-${ARCH}.deb"
    echo "正在下载 sing-box ${version} (${ARCH})..."
    if ! curl -L -o /tmp/sing-box.deb "$download_url"; then
        echo "下载失败，请检查版本号是否正确"
        exit 1
    fi
    
    # 安装
    echo "正在安装 sing-box..."
    if ! dpkg -i /tmp/sing-box.deb; then
        echo "安装失败"
        rm -f /tmp/sing-box.deb
        exit 1
    fi
    
    # 清理临时文件
    rm -f /tmp/sing-box.deb
    
    echo "sing-box ${version} 安装成功"
}

# 主菜单
main() {
    echo "sing-box 管理脚本"
    echo "1. 安装 sing-box"
    echo "2. 卸载 sing-box"
    read -p "请选择 (1-2): " choice

    case $choice in
        1)
            check_dependencies
            install_singbox
            configure_singbox
            ;;
        2)
            uninstall_singbox
            ;;
        *)
            echo "无效选择"
            exit 1
            ;;
    esac
}

main
