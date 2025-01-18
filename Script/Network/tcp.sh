#!/usr/bin/env bash

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Green_font_prefix}[注意]${Font_color_suffix}"

# 调优类型选择
tune_selection() {
    echo -e "${Info} 请选择调优类型:"
    echo "1. 仅TCP调优"
    echo "2. TCP + 系统资源调优"
    
    read -p "请输入数字选择 (1-2): " tune_choice
    
    case $tune_choice in
        1)
            tcp_only=true
            ;;
        2)
            tcp_only=false
            ;;
        *)
            echo -e "${Error} 无效的选择，默认使用仅TCP调优"
            tcp_only=true
            ;;
    esac
}

# 服务器选择和内存参数设置
server_selection() {
    echo -e "${Info} 请选择服务器类型:"
    echo "1. HK Server"
    echo "2. JP Server"
    echo "3. MY Server"
    echo "4. US Server"
    echo "5. Customized"
    
    read -p "请输入数字选择 (1-4): " server_choice
    
    case $server_choice in
        1)
            Rmem=6875000
            Wmem=6875000
            ;;
        2)
            Rmem=7786000
            Wmem=7786000
            ;;
        3)
            Rmem=10500000
            Wmem=10500000
            ;;
        4)
            Rmem=18750000
            Wmem=18750000
            ;;
        5)
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

# TCP调优函数
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
# 禁用显式拥塞通��� (ECN)
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

# 系统资源调优函数
ulimit_tune(){

echo "1000000" > /proc/sys/fs/file-max
sed -i '/fs.file-max/d' /etc/sysctl.conf
cat >> '/etc/sysctl.conf' << EOF
fs.file-max=1000000
EOF

ulimit -SHn 1000000 && ulimit -c unlimited
echo "root     soft   nofile    1000000
root     hard   nofile    1000000
root     soft   nproc     1000000
root     hard   nproc     1000000
root     soft   core      1000000
root     hard   core      1000000
root     hard   memlock   unlimited
root     soft   memlock   unlimited

*     soft   nofile    1000000
*     hard   nofile    1000000
*     soft   nproc     1000000
*     hard   nproc     1000000
*     soft   core      1000000
*     hard   core      1000000
*     hard   memlock   unlimited
*     soft   memlock   unlimited
">/etc/security/limits.conf
if grep -q "ulimit" /etc/profile; then
  :
else
  sed -i '/ulimit -SHn/d' /etc/profile
  echo "ulimit -SHn 1000000" >>/etc/profile
fi
if grep -q "pam_limits.so" /etc/pam.d/common-session; then
  :
else
  sed -i '/required pam_limits.so/d' /etc/pam.d/common-session
  echo "session required pam_limits.so" >>/etc/pam.d/common-session
fi

sed -i '/DefaultTimeoutStartSec/d' /etc/systemd/system.conf
sed -i '/DefaultTimeoutStopSec/d' /etc/systemd/system.conf
sed -i '/DefaultRestartSec/d' /etc/systemd/system.conf
sed -i '/DefaultLimitCORE/d' /etc/systemd/system.conf
sed -i '/DefaultLimitNOFILE/d' /etc/systemd/system.conf
sed -i '/DefaultLimitNPROC/d' /etc/systemd/system.conf

cat >>'/etc/systemd/system.conf' <<EOF
[Manager]
#DefaultTimeoutStartSec=90s
DefaultTimeoutStopSec=30s
#DefaultRestartSec=100ms
DefaultLimitCORE=infinity
DefaultLimitNOFILE=65535
DefaultLimitNPROC=65535
EOF

systemctl daemon-reload

}

clean_file() {
    # 清理安装脚本
    rm -f "$(readlink -f "$0")"
}

# 主执行流程
echo -e "${Info} 开始系统调优..."

# 选择调优类型
tune_selection

# 选择服务器类型
server_selection

# 根据选择执行调优
if [ "$tcp_only" = true ]; then
    echo -e "${Info} 执行TCP调优..."
    system_tune
else
    echo -e "${Info} 执行TCP和系统资源调优..."
    system_tune
    ulimit_tune
fi

echo -e "${Info} 系统调优完成"

echo -e "${Info} 开始清理脚本文件..."
clean_file
echo -e "${Info} 脚本文件清理完成"

echo -e "${Tip} 部分设置可能需要重启系统才能生效"
echo -e "${Tip} 已禁用IPv6，如果需要使用IPv6，请手动修改 /etc/sysctl.conf 文件"
