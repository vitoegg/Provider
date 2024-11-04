#!/bin/bash

if [[ $EUID -ne 0 ]]; then
    clear
    echo "Error: This script must be run as root!" 1>&2
    exit 1
fi

# Set common variables
sspasswd=$(cat /proc/sys/kernel/random/uuid)
ssport=$(shuf -i 20000-40000 -n 1)  # Shadowsocks port range: 20000-40000
tls_password=$(cat /proc/sys/kernel/random/uuid)

# Function to print progress
print_progress() {
    echo -e "\n>>> $1"
}

# Function to get user input for ShadowTLS listen port
get_user_port() {
    echo -e "\n=== ShadowTLS Port Configuration ==="
    echo "Please select how to set the ShadowTLS listen port:"
    echo "1. Input manually (Port range: 50000-60000)"
    echo "2. Generate randomly"
    echo -e "----------------------------------------\n"
    
    while true; do
        read -p "Your choice (1/2): " choice
        case $choice in
            1)
                while true; do
                    read -p "Please enter the listen port (50000-60000): " port
                    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 50000 ] && [ "$port" -le 60000 ]; then
                        listen_port=$port
                        echo -e "\n>>> Selected port: $listen_port"
                        break
                    else
                        echo "Error: Please enter a valid port number (50000-60000)"
                    fi
                done
                break
                ;;
            2)
                listen_port=$(shuf -i 50000-60000 -n 1)
                echo -e "\n>>> Randomly generated port: $listen_port"
                break
                ;;
            *)
                echo "Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done
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

    cat > /etc/systemd/system/shadowsocks.service << EOF
[Unit]
Description=Shadowsocks Server
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=on-failure
RestartSec=5s

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

# Configure ShadowTLS
configure_shadowtls() {
    print_progress "Configuring ShadowTLS..."
    cat > /etc/systemd/system/shadowtls.service << EOF
[Unit]
Description=ShadowTLS Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-tls --fastopen --v3 server --listen ::0:${listen_port} --server 127.0.0.1:${ssport} --tls m.hypai.org --password ${tls_password}
Restart=on-failure
RestartSec=5s

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

# Show final configuration
show_configuration() {
    print_progress "Installation completed successfully!"
    
    echo -e "\n==========Shadowsocks Configuration==========="
    echo "Internal Port: ${ssport}"
    echo "Password: ${sspasswd}"
    echo "Method: aes-128-gcm"
    
    echo -e "\n===========ShadowTLS Configuration==========="
    echo "Listen Port: ${listen_port}"
    echo "Password: ${tls_password}"
    echo "TLS Server: m.hypai.org"
    echo -e "===========================================\n"
    
    echo "Service status:"
    echo "----- Shadowsocks Service -----"
    systemctl status shadowsocks.service --no-pager
    echo
    echo "----- ShadowTLS Service -----"
    systemctl status shadowtls.service --no-pager
}

# Main execution
main() {
    clear
    echo "=== ShadowTLS Installation Script ==="
    echo "This script will install and configure Shadowsocks and ShadowTLS."
    echo -e "=====================================\n"
    
    install_packages
    detect_arch
    install_shadowsocks
    configure_shadowsocks
    get_user_port
    install_shadowtls
    configure_shadowtls
    show_configuration
    
    # Clean up the installation script
    rm -f "$(readlink -f "$0")"
}

main
