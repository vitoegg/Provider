#!/bin/bash

# 帮助信息函数
usage() {
    echo "用法: $0 -k <ssh_public_key>"
    echo "示例: $0 -k 'ssh-rsa AAAAB...'"
    exit 1
}

# 解析命令行参数
while getopts "k:h" opt; do
    case $opt in
        k) SSH_PUBLIC_KEY="$OPTARG" ;;
        h) usage ;;
        ?) usage ;;
    esac
done

# 检查是否提供了SSH密钥
if [ -z "$SSH_PUBLIC_KEY" ]; then
    echo "错误: 必须提供SSH公钥"
    usage
fi

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   echo "此脚本必须以root用户运行"
   exit 1
fi

# 设置变量
SSH_DIR="/root/.ssh"
AUTH_KEYS_FILE="${SSH_DIR}/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"

# 验证SSH公钥格式
if [[ ! $SSH_PUBLIC_KEY =~ ^ssh-rsa\ [A-Za-z0-9+/]+[=]{0,3}\ .+ ]]; then
    echo "无效的SSH公钥格式"
    exit 1
fi

# 创建.ssh目录（如果不存在）
mkdir -p "$SSH_DIR"

# 添加公钥到authorized_keys
echo "$SSH_PUBLIC_KEY" >> "$AUTH_KEYS_FILE"

# 设置正确的权限
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS_FILE"

# 检查并添加SSH配置
CONFIG_CHANGES=(
    "PubkeyAuthentication yes"
    "PasswordAuthentication no"
    "AuthorizedKeysFile .ssh/authorized_keys"
)

# 为每个配置项检查是否存在，如果不存在则添加
for config in "${CONFIG_CHANGES[@]}"; do
    key=$(echo "$config" | cut -d' ' -f1)
    if ! grep -q "^${key}" "$SSHD_CONFIG"; then
        echo "添加配置: $config"
        echo "$config" >> "$SSHD_CONFIG"
    else
        echo "配置 ${key} 已存在，跳过"
    fi
done

# 测试SSH配置语法
sshd -t
if [ $? -ne 0 ]; then
    echo "SSH配置测试失败，请检查配置"
    exit 1
fi

# 重启SSH服务
if command -v systemctl &> /dev/null; then
    systemctl restart sshd
else
    service ssh restart
fi

echo "SSH密钥认证设置完成！"
echo "请保持当前SSH会话连接，并在新的终端窗口测试密钥登录是否正常工作。"
