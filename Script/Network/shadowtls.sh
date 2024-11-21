#!/usr/bin/env bash

# Strict error handling
set -euo pipefail

# Global variables with defaults
DEFAULT_PORT_RANGE_START=50000
DEFAULT_PORT_RANGE_END=60000
LISTEN_PORT=""

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root. Use sudo." >&2
        exit 1
    fi
}

# Function to generate random password
generate_random_password() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

# Function to generate random port
generate_random_port() {
    shuf -i "$1"-"$2" -n 1
}

# Log and print progress
log_progress() {
    echo -e "\n>>> $1"
}

# Install necessary packages
install_packages() {
    log_progress "Installing required packages..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq gzip wget curl unzip xz-utils jq
    elif command -v yum >/dev/null 2>&1; then
        yum update -y -q
        yum install -y -q epel-release
        yum install -y -q gzip wget curl unzip xz jq
    else
        echo "Error: Unsupported package manager" >&2
        exit 1
    fi
}

# Detect system architecture
detect_arch() {
    case "$(uname -m)" in
        x86_64)
            SS_ARCH="x86_64"
            TLS_ARCH_SUFFIX="x86_64-unknown-linux-musl"
            ;;
        aarch64)
            SS_ARCH="aarch64"
            TLS_ARCH_SUFFIX="aarch64-unknown-linux-musl"
            ;;
        *)
            echo "Unsupported architecture: $(uname -m)" >&2
            exit 1
            ;;
    esac
}

# Port selection logic
select_port() {
    # Prefer command line argument, then random
    if [[ -n "${1:-}" ]]; then
        LISTEN_PORT="$1"
    else
        LISTEN_PORT=$(generate_random_port "$DEFAULT_PORT_RANGE_START" "$DEFAULT_PORT_RANGE_END")
    fi
}

# Install Shadowsocks
install_shadowsocks() {
    local SS_DOWNLOAD_URL SS_VERSION SS_ARCHIVE

    log_progress "Installing Shadowsocks-rust..."
    
    SS_VERSION=$(curl -sL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | 
                 jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    
    SS_ARCHIVE="shadowsocks-${SS_VERSION}.${SS_ARCH}-unknown-linux-gnu.tar.xz"
    SS_DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SS_VERSION}/${SS_ARCHIVE}"

    wget -q "$SS_DOWNLOAD_URL"
    tar xf "$SS_ARCHIVE"
    
    chmod +x ssserver
    mv ssserver /usr/local/bin/
    rm -f "$SS_ARCHIVE" sslocal ssmanager ssservice ssurl
}

# Configure Shadowsocks service
configure_shadowsocks() {
    local SS_PORT SS_PASSWD
    
    SS_PORT=$(generate_random_port 20000 40000)
    SS_PASSWD=$(generate_random_password)

    mkdir -p /etc/shadowsocks

    cat > /etc/shadowsocks/config.json << EOF
{
    "server":"127.0.0.1",
    "server_port":$SS_PORT,
    "password":"$SS_PASSWD",
    "timeout":600,
    "mode":"tcp_and_udp",
    "method":"aes-128-gcm"
}
EOF

    cat > /lib/systemd/system/shadowsocks.service << EOF
[Unit]
Description=Shadowsocks Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now shadowsocks.service
}

# Install ShadowTLS
install_shadowtls() {
    local TLS_VERSION TLS_DOWNLOAD_URL

    log_progress "Installing ShadowTLS..."
    
    TLS_VERSION=$(curl -sL https://api.github.com/repos/ihciah/shadow-tls/releases/latest | jq -r .tag_name)
    TLS_DOWNLOAD_URL="https://github.com/ihciah/shadow-tls/releases/download/${TLS_VERSION}/shadow-tls-${TLS_ARCH_SUFFIX}"

    wget -q "$TLS_DOWNLOAD_URL" -O /usr/local/bin/shadow-tls
    chmod +x /usr/local/bin/shadow-tls
}

# Configure ShadowTLS service
configure_shadowtls() {
    local TLS_PASSWD

    TLS_PASSWD=$(generate_random_password)

    cat > /lib/systemd/system/shadowtls.service << EOF
[Unit]
Description=ShadowTLS Service
After=network.target shadowsocks.service

[Service]
ExecStart=/usr/local/bin/shadow-tls --fastopen --v3 server --listen ::0:${LISTEN_PORT} --server 127.0.0.1:${SS_PORT} --tls m.hypai.org --password ${TLS_PASSWD}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now shadowtls.service
}

# Display configuration
show_configuration() {
    echo "Installation completed!"
    echo "ShadowTLS Listen Port: ${LISTEN_PORT}"
    systemctl status shadowsocks.service
    systemctl status shadowtls.service
}

# Main execution
main() {
    # Parse optional port argument
    select_port "${1:-}"

    check_root
    install_packages
    detect_arch
    install_shadowsocks
    configure_shadowsocks
    install_shadowtls
    configure_shadowtls
    show_configuration
}

# Execute main with optional port argument
main "$@"
