#!/usr/bin/env bash

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Green_font_prefix}[注意]${Font_color_suffix}"

# 服务器选择和内存参数设置
server_selection() {
    echo -e "${Info} 请选择服务器类型:"
    echo "1. HK Server"
    echo "2. JP Server"
    echo "3. US Server"
    echo "4. Customized"
    
    read -p "请输入数字选择 (1-4): " server_choice
    
    case $server_choice in
        1)
            Rmem=6875000
            Wmem=6875000
            ;;
        2)
            Rmem=6750000
            Wmem=6750000
            ;;
        3)
            Rmem=18750000
            Wmem=18750000
            ;;
        4)
            read -p "请输入 Rmem 值: " Rmem
            read -p "请输入 Wmem 值: " Wmem
            ;;
        *)
            echo -e "${Error} 无效的选择，默认使用 HK Server 配置"
            Rmem=6875000
            Wmem=6875000
            ;;
    esac
    
    echo -e "${Info} 已选择 Rmem: ${Rmem}, Wmem: ${Wmem}"
}

system_tune() {
    cat > /etc/sysctl.conf << EOF
# 文件描述符限制
fs.file-max=6815744
# 物理内存剩余不足10%时使用Swap
vm.swappiness=10
# TCP congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# TCP连接保活优化
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 30
# 禁用显式拥塞通知 (ECN)
net.ipv4.tcp_ecn=0
# 禁用TCP快速重传优化
net.ipv4.tcp_frto=0
net.ipv4.tcp_rfc1337=0
# 关闭慢启动重启(Slow-Start Restart)
net.ipv4.tcp_slow_start_after_idle = 0
# 禁用MTU探测
net.ipv4.tcp_mtu_probing=0
# 禁用连接保存
net.ipv4.tcp_no_metrics_save=1
# 启用TCP选择确认
net.ipv4.tcp_sack=1
# 启用TCP转发确认
net.ipv4.tcp_fack=1
# TCP窗口调整
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
# 网络缓存区调整
net.ipv4.tcp_rmem=4096 87380 ${Rmem}
net.ipv4.tcp_wmem=4096 16384 ${Wmem}
# 允许流量转发
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
# 禁用IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl -p && sysctl --system
}

clean_file() {
    # 清理安装脚本
    rm -f "$(readlink -f "$0")"
}

# 主执行流程
echo -e "${Info} 开始系统调优..."

# 先进行服务器选择
server_selection

# 执行系统调优
system_tune
echo -e "${Info} 系统调优完成"

echo -e "${Info} 开始清理脚本文件..."
clean_file
echo -e "${Info} 脚本文件清理完成"

echo -e "${Tip} 部分设置可能需要重启系统才能生效"
echo -e "${Tip} 已禁用IPv6，如果需要使用IPv6，请手动修改 /etc/sysctl.conf 文件"
