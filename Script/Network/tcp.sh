#!/usr/bin/env bash

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Green_font_prefix}[注意]${Font_color_suffix}"

system_tune() {
    cat > /etc/sysctl.conf << EOF
# 文件描述符限制
fs.file-max=1000000

# TCP congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# 增强链接稳定性
net.ipv4.neigh.default.base_reachable_time_ms = 600000
net.ipv4.neigh.default.mcast_solicit = 20
net.ipv4.neigh.default.retrans_time_ms = 250
# TCP活动控制
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 30
# 关闭慢启动重启(Slow-Start Restart)
net.ipv4.tcp_slow_start_after_idle = 0
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
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 16384 33554432
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
# 禁用IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    echo "1000000" > /proc/sys/fs/file-max
    sysctl -p && sysctl --system
}

ulimit_tune() {
    ulimit -SHn 1000000 && ulimit -c unlimited
    cat > /etc/security/limits.conf << EOF
root     soft   nofile    1000000
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
EOF

    if ! grep -q "ulimit" /etc/profile; then
        echo "ulimit -SHn 1000000" >> /etc/profile
    fi
    if ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    fi

    cat > /etc/systemd/system.conf << EOF
[Manager]
DefaultTimeoutStopSec=30s
DefaultLimitCORE=infinity
DefaultLimitNOFILE=65535
DefaultLimitNPROC=65535
EOF

    systemctl daemon-reload
}

echo -e "${Info} 开始执行系统调优..."
system_tune
echo -e "${Info} 系统调优完成"

echo -e "${Info} 开始执行系统资源限制调优..."
ulimit_tune
echo -e "${Info} 系统资源限制调优完成"

echo -e "${Tip} 部分设置可能需要重启系统才能生效"
echo -e "${Tip} 已禁用IPv6，如果需要使用IPv6，请手动修改 /etc/sysctl.conf 文件"
