#!/bin/bash

# 检查是否以root用户运行
if [ "$EUID" -ne 0 ]; then
  echo "请以root用户运行此脚本"
  exit 1
fi

# 检查系统和安装依赖的函数
check_system_and_install() {
    # 检查系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
            echo "此脚本仅支持 Debian 和 Ubuntu 系统"
            return 1
        fi
    else
        echo "无法确定系统类型，脚本退出"
        return 1
    fi

    # 检查并安装必要的依赖
    echo "检查并安装必要的依赖..."
    if ! command -v iptables >/dev/null 2>&1; then
        apt-get update
        apt-get install -y iptables
    fi

    if ! command -v iptables-persistent >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    fi

    return 0
}

# 函数：添加转发规则
add_forward_rule() {
    local local_port=$1
    local target_ip=$2
    local target_port=$3

    iptables -t nat -A PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $target_ip:$target_port
    iptables -t nat -A PREROUTING -p udp --dport $local_port -j DNAT --to-destination $target_ip:$target_port
    iptables -t nat -A POSTROUTING -p tcp -d $target_ip --dport $target_port -j SNAT --to-source $LOCAL_IP
    iptables -t nat -A POSTROUTING -p udp -d $target_ip --dport $target_port -j SNAT --to-source $LOCAL_IP

    echo "已添加转发规则：本机端口 $local_port -> $target_ip:$target_port"
}

# 清除规则的函数
clean_rules() {
    echo "正在清除所有转发规则..."
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    netfilter-persistent save
    netfilter-persistent reload
    echo "所有转发规则已清除"
}

# 主菜单
while true; do
    echo -e "\n请选择操作："
    echo "1. 添加新的转发规则"
    echo "2. 查看当前转发规则"
    echo "3. 清除所有转发规则"
    echo "4. 退出"
    read -p "请输入选项 [1-4]: " choice

    case $choice in
        1)
            # 只在添加规则时检查系统和依赖
            if ! check_system_and_install; then
                continue
            fi

            # 自动获取本机IP
            LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
            if [ -z "$LOCAL_IP" ]; then
                echo "无法自动获取本机IP，请手动输入："
                read -p "请输入本机IP: " LOCAL_IP
            else
                echo "检测到本机IP: $LOCAL_IP"
                read -p "是否使用此IP? [Y/n] " use_detected_ip
                if [[ "$use_detected_ip" =~ ^[Nn]$ ]]; then
                    read -p "请输入本机IP: " LOCAL_IP
                fi
            fi

            while true; do
                echo -e "\n当前转发规则："
                iptables -t nat -L PREROUTING -n --line-numbers
                echo -e "\n请输入新的转发规则（或按 Ctrl+C 退出）："
                read -p "请输入本机端口: " LOCAL_PORT
                read -p "请输入目标IP: " TARGET_IP
                read -p "请输入目标端口: " TARGET_PORT

                if [[ ! "$LOCAL_PORT" =~ ^[0-9]+$ ]] || \
                   [[ ! "$TARGET_PORT" =~ ^[0-9]+$ ]] || \
                   [[ ! "$TARGET_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo "输入格式错误，请重新输入！"
                    continue
                fi

                add_forward_rule "$LOCAL_PORT" "$TARGET_IP" "$TARGET_PORT"

                read -p "是否继续添加转发规则？[Y/n] " continue_add
                if [[ "$continue_add" =~ ^[Nn]$ ]]; then
                    echo "保存所有规则并退出..."
                    netfilter-persistent save
                    netfilter-persistent reload
                    echo -e "\n当前转发规则："
                    iptables -t nat -L PREROUTING -n --line-numbers
                    exit 0
                fi
            done
            ;;
        2)
            echo -e "\n当前转发规则："
            echo "PREROUTING 规则："
            iptables -t nat -L PREROUTING -n --line-numbers
            echo -e "\nPOSTROUTING 规则："
            iptables -t nat -L POSTROUTING -n --line-numbers
            ;;
        3)
            read -p "确定要清除所有转发规则吗？[y/N] " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                clean_rules
            fi
            ;;
        4)
            echo -e "\n请选择退出方式："
            echo "1. 直接退出"
            echo "2. 保存规则并退出"
            read -p "请选择 [1-2]: " exit_choice
            case $exit_choice in
                1)
                    echo "直接退出程序..."
                    exit 0
                    ;;
                2)
                    echo "保存规则并退出..."
                    if ! command -v netfilter-persistent >/dev/null 2>&1; then
                        echo "正在安装 netfilter-persistent..."
                        apt-get update
                        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
                    fi
                    netfilter-persistent save
                    netfilter-persistent reload
                    echo "规则已保存，退出程序..."
                    exit 0
                    ;;
                *)
                    echo "无效的选项，返回主菜单"
                    ;;
            esac
            ;;
        *)
            echo "无效的选项，请重新选择"
            ;;
    esac
done
