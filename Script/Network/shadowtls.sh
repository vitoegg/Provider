#!/bin/bash

if [[ $EUID -ne 0 ]]; then
    clear
    echo "Error: This script must be run as root!" 1>&2
    exit 1
fi

# Set common variables
generate_port() {
    while true; do
        port=$(shuf -i $1-$2 -n 1)
        if [[ ! "$port" =~ "4" ]]; then
            echo "$port"
            break
        fi
    done
}

sspasswd=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
ssport=$(generate_port 20000 40000)  # Shadowsocks port range: 20000-40000
tls_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)

# Function to print progress
print_progress() {
    echo -e "\n>>> $1"
}

# Install necessary packages
install_packages() {
    print_progress "Installing required packages..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y gzip wget curl unzip xz-utils jq
    elif command -v yum >/dev/null 2>&1; then
        yum update -y
        yum install -y epel-release
        yum install -y gzip wget curl unzip xz jq
    else
        echo "Error: Unsupported package manager" 1>&2
        exit 1
    fi
    echo "✓ Packages installed successfully"
}

# Detect system architecture
detect_arch() {
    print_progress "Detecting system architecture..."
    case $(uname -m) in
        i686|i386)
            ss_arch="i686"
            ;;
        armv7*|armv6l)
            ss_arch="arm"
            ;;
        armv8*|aarch64)
            ss_arch="aarch64"
            tls_arch_suffix="aarch64-unknown-linux-musl"
            ;;
        x86_64)
            ss_arch="x86_64"
            tls_arch_suffix="x86_64-unknown-linux-musl"
            ;;
        *)
            echo "Error: Unsupported architecture: $(uname -m)" 1>&2
            exit 1
            ;;
    esac
    echo "✓ Detected architecture: $ss_arch"
}

# Install Shadowsocks
install_shadowsocks() {
    print_progress "Installing Shadowsocks-rust..."
    local new_ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | 
                    jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    
    echo ">>> Downloading version: $new_ver"
    local archive_name="shadowsocks-${new_ver}.${ss_arch}-unknown-linux-gnu.tar.xz"
    wget --no-check-certificate -N "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${new_ver}/${archive_name}"
    
    if [[ ! -f "$archive_name" ]]; then
        echo "Error: Failed to download Shadowsocks Rust!" 1>&2
        exit 1
    fi
    
    echo ">>> Extracting files..."
    tar -xf "$archive_name"
    if [[ ! -f "ssserver" ]]; then
        echo "Error: Failed to extract Shadowsocks Rust!" 1>&2
        exit 1
    fi
    
    chmod +x ssserver
    mv -f ssserver /usr/local/bin/
    rm -f sslocal ssmanager ssservice ssurl "$archive_name"
    
    echo "✓ Shadowsocks-rust installation completed"
}

# Configure Shadowsocks
configure_shadowsocks() {
    print_progress "Configuring Shadowsocks..."
    mkdir -p /etc/shadowsocks
    
    cat > /etc/shadowsocks/config.json << EOF
{
    "server":"127.0.0.1",
    "server_port":$ssport,
    "password":"$sspasswd",
    "timeout":600,
    "mode":"tcp_and_udp",
    "method":"aes-128-gcm"
}
EOF

    cat > /lib/systemd/system/shadowsocks.service << EOF
[Unit]
Description=Shadowsocks Server
After=network.target
Before=network-online.target
StartLimitBurst=0
StartLimitIntervalSec=60

[Service]
Type=simple
LimitNOFILE=65536
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo ">>> Starting Shadowsocks service..."
    systemctl enable shadowsocks.service
    systemctl start shadowsocks.service
    
    if ! systemctl is-active --quiet shadowsocks.service; then
        echo "Error: Shadowsocks service failed to start!" 1>&2
        exit 1
    fi
    echo "✓ Shadowsocks configured and started successfully"
}

# Install ShadowTLS
install_shadowtls() {
    print_progress "Installing ShadowTLS..."
    local latest_version=$(curl -s https://api.github.com/repos/ihciah/shadow-tls/releases/latest | jq -r .tag_name)
    if [[ -z "$latest_version" ]]; then
        echo "Error: Failed to get latest ShadowTLS version!" 1>&2
        exit 1
    fi

    echo ">>> Installing version: ${latest_version}"
    
    wget -q --show-progress "https://github.com/ihciah/shadow-tls/releases/download/${latest_version}/shadow-tls-${tls_arch_suffix}" -O /usr/local/bin/shadow-tls
    
    if [[ ! -f "/usr/local/bin/shadow-tls" ]]; then
        echo "Error: Failed to download ShadowTLS!" 1>&2
        exit 1
    fi

    chmod +x /usr/local/bin/shadow-tls
    echo "✓ ShadowTLS binary installed successfully"
}

# Function to get user input for ShadowTLS listen port
get_user_port() {
    echo -e "\n=== ShadowTLS Port Configuration ==="
    echo "请选择如何设置 ShadowTLS 监听端口："
    echo "1. 手动输入 (端口范围: 50000-60000)"
    echo "2. 随机生成"
    echo -e "----------------------------------------\n"
    
    while true; do
        read -p "请选择 (1/2): " choice
        case $choice in
            1)
                while true; do
                    read -p "请输入监听端口 (50000-60000): " port
                    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 50000 ] && [ "$port" -le 60000 ] && [[ ! "$port" =~ "4" ]]; then
                        listen_port=$port
                        echo -e "\n>>> 选择的端口: $listen_port"
                        break
                    else
                        echo "错误：请输入一个有效的端口号 (50000-60000，且不包含数字4)"
                    fi
                done
                break
                ;;
            2)
                listen_port=$(generate_port 50000 60000)
                echo -e "\n>>> 随机生成端口: $listen_port"
                break
                ;;
            *)
                echo "无效选择。请输入 1 或 2。"
                ;;
        esac
    done
}

# 新增预设域名数组
PRESET_DOMAINS=(
    "updates.cdn-apple.com"
    "osxapps.itunes.apple.com"
    "publicassets.cdn-apple.com"
    "cdn-dynmedia-1.microsoft.com"
    "software.download.prss.microsoft.com"
    "s0.awsstatic.com"
    "m.media-amazon.com"
    "player.live-video.net"
)

# 获取用户域名选择
get_user_domain() {
    echo -e "\n=== TLS Domain Configuration ==="
    echo "请选择 TLS 域名设置方式："
    echo "1. 随机使用预设域名"
    echo "2. 使用指定域名"
    echo "3. 手动输入域名"
    echo -e "----------------------------------------\n"
    
    while true; do
        read -p "请选择 (1/2/3): " domain_choice
        case $domain_choice in
            1)
                # 随机选择一个预设域名
                random_index=$((RANDOM % ${#PRESET_DOMAINS[@]}))
                domain="${PRESET_DOMAINS[$random_index]}"
                echo -e "\n>>> 随机选择域名: $domain"
                break
                ;;
            2)
                echo -e "\n可用的预设域名："
                for i in "${!PRESET_DOMAINS[@]}"; do
                    echo "$((i+1)). ${PRESET_DOMAINS[$i]}"
                done
                while true; do
                    read -p "请选择域名编号 (1-${#PRESET_DOMAINS[@]}): " domain_index
                    if [[ "$domain_index" =~ ^[0-9]+$ ]] && [ "$domain_index" -ge 1 ] && [ "$domain_index" -le "${#PRESET_DOMAINS[@]}" ]; then
                        domain="${PRESET_DOMAINS[$((domain_index-1))]}"
                        echo -e "\n>>> 使用指定域名: $domain"
                        break
                    else
                        echo "错误：请输入有效的编号 (1-${#PRESET_DOMAINS[@]})"
                    fi
                done
                break
                ;;
            3)
                while true; do
                    read -p "请输入域名: " custom_domain
                    if [[ $custom_domain =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                        domain=$custom_domain
                        echo -e "\n>>> 使用自定义域名: $domain"
                        break
                    else
                        echo "错误：请输入有效的域名格式"
                    fi
                done
                break
                ;;
            *)
                echo "无效选择。请输入 1、2 或 3。"
                ;;
        esac
    done
}

# Configure ShadowTLS
configure_shadowtls() {
    print_progress "Configuring ShadowTLS..."
    cat > /lib/systemd/system/shadowtls.service << EOF
[Unit]
Description=ShadowTLS Service
After=network.target
Before=network-online.target
StartLimitBurst=0
StartLimitIntervalSec=60

[Service]
LimitNOFILE=65536
ExecStart=/usr/local/bin/shadow-tls --fastopen --v3 server --listen ::0:${listen_port} --server 127.0.0.1:${ssport} --tls ${domain} --password ${tls_password}
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo ">>> Starting ShadowTLS service..."
    systemctl enable shadowtls.service
    systemctl start shadowtls.service

    if ! systemctl is-active --quiet shadowtls.service; then
        echo "Error: ShadowTLS service failed to start!" 1>&2
        echo "Please check the logs with: journalctl -u shadowtls.service" 1>&2
        exit 1
    fi
    echo "✓ ShadowTLS configured and started successfully"
}

# 添加新函数来获取本机的 IPv4 地址
get_ipv4_address() {
    # 使用 ip 命令获取本机的 IPv4 地址
    local ip=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n 1)
    
    if [[ -z "$ip" ]]; then
        echo "无法获取 IP 地址"
    else
        echo "$ip"
    fi
}

# Show final configuration
show_configuration() {
    print_progress "Installation completed successfully!"
    
    # 获取 IPv4 地址
    local server_ip=$(get_ipv4_address)

    echo "Service status:"
    echo "----- Shadowsocks Service -----"
    systemctl status shadowsocks.service --no-pager
    echo
    echo "----- ShadowTLS Service -----"
    systemctl status shadowtls.service --no-pager
    
    echo -e "\n==========ShadowTLS Configuration==========="
    echo "Server IP: ${server_ip}"
    echo "Shadowsocks Port: ${ssport}"
    echo "ShadowsocksPassword: ${sspasswd}"
    echo "ShadowTLS Port: ${listen_port}"
    echo "ShadowTLS Password: ${tls_password}"
    echo "ShadowTLS SNI: ${domain}"
    echo -e "===========================================\n"
}

# Uninstalling Shadowsocks and ShadowTLS
uninstall_service() {
    clear
    echo "=== Uninstalling Shadowsocks and ShadowTLS ==="
    
    # 停止并禁用服务
    echo ">>> Stopping and disabling Shadowsocks service..."
    systemctl stop shadowsocks.service 2>/dev/null
    systemctl disable shadowsocks.service 2>/dev/null
    echo "✓ Shadowsocks service stopped and disabled"
    
    echo ">>> Stopping and disabling ShadowTLS service..."
    systemctl stop shadowtls.service 2>/dev/null
    systemctl disable shadowtls.service 2>/dev/null
    echo "✓ ShadowTLS service stopped and disabled"
    
    # 删除服务文件
    echo ">>> Removing service files..."
    rm -f /lib/systemd/system/shadowsocks.service
    rm -f /lib/systemd/system/shadowtls.service
    echo "✓ Service files removed"
    
    # 删除配置文件
    echo ">>> Removing configuration files..."
    rm -rf /etc/shadowsocks
    rm -f /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
    echo "✓ Configuration files removed"
    
    # 删除二进制文件
    echo ">>> Removing binary files..."
    rm -f /usr/local/bin/ssserver
    rm -f /usr/local/bin/shadow-tls
    echo "✓ Binary files removed"
    
    # 重新加载systemd
    echo ">>> Reloading systemd daemon..."
    systemctl daemon-reload
    systemctl reset-failed
    echo "✓ Systemd daemon reloaded"
    
    echo "=== Uninstallation Complete ==="
}

# Main execution
main() {
    clear
    echo "=== ShadowTLS Installation Script ==="
    echo "1. Install Shadowsocks and ShadowTLS"
    echo "2. Uninstall Shadowsocks and ShadowTLS"
    echo -e "=====================================\n"
    
    read -p "Please select an option (1/2): " choice
    
    case $choice in
        1)
            # 原有的安装流程
            install_packages
            detect_arch
            install_shadowsocks
            configure_shadowsocks
            install_shadowtls
            get_user_port
            get_user_domain
            configure_shadowtls
            show_configuration
            ;;
        2)
            uninstall_service
            ;;
        *)
            echo "Invalid option. Exiting."
            exit 1
            ;;
    esac
}

main
