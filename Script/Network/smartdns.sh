#!/bin/bash

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "错误: 必须使用 root 用户运行此脚本"
        exit 1
    fi
}

# 检查 smartdns 是否已安装
check_installed() {
    if systemctl is-active smartdns &>/dev/null; then
        echo "SmartDNS 已经安装并正在运行"
        exit 1
    fi
}

# 设置默认版本
VERSION="1.2024.06.12-2222"

# 解析命令行参数
parse_args() {
    USE_AI_DNS=0
    AI_DNS_SERVER=""
    UNINSTALL=0
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
                VERSION="$2"
                shift 2
                ;;
            -a|--ai-dns)
                USE_AI_DNS=1
                AI_DNS_SERVER="$2"
                shift 2
                ;;
            -u|--uninstall)
                UNINSTALL=1
                shift
                ;;
            *)
                echo "未知参数: $1"
                echo "用法: $0 [-v|--version <版本号>] [-a|--ai-dns <AI DNS服务器IP>] [-u|--uninstall]"
                exit 1
                ;;
        esac
    done

    if [ $UNINSTALL -eq 1 ]; then
        echo "准备卸载 SmartDNS..."
    else
        echo "使用 SmartDNS 版本: $VERSION"
        if [ $USE_AI_DNS -eq 1 ]; then
            echo "启用 AI DNS 解锁服务器: $AI_DNS_SERVER"
        fi
    fi
}

# 下载并安装 smartdns
install_smartdns() {
    # 创建临时目录
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR" || exit 1
    
    # 下载指定版本的 smartdns
    echo "正在下载 SmartDNS..."
    DOWNLOAD_URL="https://github.com/pymumu/smartdns/releases/download/Release46/smartdns.${VERSION}.x86_64-linux-all.tar.gz"
    if ! wget --no-check-certificate -qO smartdns.tar.gz "$DOWNLOAD_URL"; then
        echo "下载失败，请检查版本号是否正确"
        cd / && rm -rf "$TMP_DIR"
        exit 1
    fi
    
    # 解压和安装
    echo "正在解压并安装 SmartDNS..."
    if tar zxf smartdns.tar.gz && cd smartdns && chmod +x ./install && ./install -i; then
        echo "SmartDNS 安装成功"
    else
        echo "SmartDNS 安装失败"
        cd / && rm -rf "$TMP_DIR"
        exit 1
    fi
    
    # 清理临时文件
    cd / && rm -rf "$TMP_DIR"
}

# 配置 smartdns
configure_smartdns() {
    # 如果启用 AI DNS，先下载域名文件
    if [ $USE_AI_DNS -eq 1 ]; then
        echo "正在下载 AI 域名配置文件..."
        if ! wget https://raw.githubusercontent.com/vitoegg/Unlock/main/proxy-domains.txt -O /etc/smartdns/agi.conf; then
            echo "下载 AI 域名配置文件失败"
            exit 1
        fi
    fi

    # 创建配置文件
    cat > /etc/smartdns/smartdns.conf << EOF
# 服务名称
server-name smartdns
# 日志等级配置
log-level error
# 监听端口
bind :53
# DNS服务器
server 1.1.1.1
server 8.8.8.8
server 208.67.220.220
EOF

    # 如果启用 AI DNS，添加相关配置
    if [ $USE_AI_DNS -eq 1 ]; then
        cat >> /etc/smartdns/smartdns.conf << EOF
server ${AI_DNS_SERVER} -group ai -exclude-default-group
# 设置AGI域名集合
domain-set -name agi -file /etc/smartdns/agi.conf
# 指定AGI单独DNS
domain-rules /domain-set:agi/ -nameserver ai
EOF
    fi

    # 继续添加其他通用配置
    cat >> /etc/smartdns/smartdns.conf << EOF
# 测速模式
speed-check-mode ping,tcp:80,tcp:443
# 缓存大小
cache-size 32768
# 开启过期缓存
serve-expired yes
# 过期缓存响应TTL
serve-expired-reply-ttl 5
# 过期缓存超时时间
serve-expired-ttl 259200
# 过期缓存预获取
prefetch-domain yes
serve-expired-prefetch-time 21600
# 缓存持久化
cache-persist yes
cache-file /etc/smartdns/smartdns.cache
cache-checkpoint-time 86400
# 禁用IPV6
force-AAAA-SOA yes
# 禁用HTTPS
force-qtype-SOA 65
EOF

    # 设置开机自启
    systemctl enable smartdns
    
    # 启动服务
    echo "正在启动 SmartDNS 服务..."
    systemctl start smartdns
    
    # 检查服务状态
    if systemctl is-active smartdns &>/dev/null; then
        echo "SmartDNS 安装并启动成功！"
        
        # 配置系统 DNS
        echo "正在配置系统 DNS..."
        # 解锁 resolv.conf 的编辑权限
        chattr -i /etc/resolv.conf 2>/dev/null
        # 配置 DNS 为本地
        rm -f /etc/resolv.conf
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        # 锁定 resolv.conf 的编辑权限
        chattr +i /etc/resolv.conf
        
        echo "系统 DNS 配置完成！"
    else
        echo "SmartDNS 启动失败，请检查日志"
        exit 1
    fi
}

# 卸载 smartdns
uninstall_smartdns() {
    echo "开始卸载 SmartDNS..."
    
    # 停止服务
    if systemctl is-active smartdns &>/dev/null; then
        echo "停止 SmartDNS 服务..."
        systemctl stop smartdns
    fi
    
    # 禁用服务
    if systemctl is-enabled smartdns &>/dev/null; then
        echo "禁用 SmartDNS 服务..."
        systemctl disable smartdns
    fi
    
    # 恢复 DNS 配置
    echo "恢复系统 DNS 配置..."
    chattr -i /etc/resolv.conf 2>/dev/null
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    
    # 删除相关文件
    echo "删除 SmartDNS 相关文件..."
    rm -rf /etc/smartdns
    rm -f /usr/sbin/smartdns
    rm -f /usr/lib/systemd/system/smartdns.service
    
    # 重新加载 systemd
    systemctl daemon-reload
    
    echo "SmartDNS 卸载完成！"
}

main() {
    check_root
    parse_args "$@"
    
    if [ $UNINSTALL -eq 1 ]; then
        uninstall_smartdns
    else
        check_installed
        install_smartdns
        configure_smartdns
    fi
}

# 修改主函数调用，传入所有命令行参数
main "$@"
