#!/bin/bash

# Text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Print formatted messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_header() {
    echo -e "\n${BOLD}=== $1 ===${NC}"
}

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root!"
    exit 1
fi

# Common variables
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
ssport=$(generate_port 20000 40000)
tls_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)

# Preset domains array
PRESET_DOMAINS=(
    "publicassets.cdn-apple.com"
    "s0.awsstatic.com"
    "p11.douyinpic.com"
    "cmsassets.rgpub.io"
)

# Get current versions
get_current_versions() {
    if [[ -f "/usr/local/bin/ssserver" ]]; then
        SS_CURRENT_VERSION=$(/usr/local/bin/ssserver --version 2>&1 | awk '{print $2}')
    fi
    
    if [[ -f "/usr/local/bin/shadow-tls" ]]; then
        STLS_CURRENT_VERSION=$(/usr/local/bin/shadow-tls --version 2>&1 | awk '{print $2}')
    fi
}

# Check for updates
check_updates() {
    print_header "Checking for Updates"
    
    # Check Shadowsocks updates
    local ss_latest_ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | 
                         jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    
    print_info "Shadowsocks-rust:"
    print_info "Current version: ${SS_CURRENT_VERSION:-Not installed}"
    print_info "Latest version: $ss_latest_ver"
    
    # Check ShadowTLS updates
    local stls_latest_ver=$(curl -s https://api.github.com/repos/ihciah/shadow-tls/releases/latest | jq -r .tag_name)
    
    print_info "\nShadowTLS:"
    print_info "Current version: ${STLS_CURRENT_VERSION:-Not installed}"
    print_info "Latest version: $stls_latest_ver"
    
    # Return values for update decision
    echo "$ss_latest_ver:$stls_latest_ver"
}

# Install necessary packages
install_packages() {
    print_header "Installing Required Packages"
    
    if command -v apt-get >/dev/null 2>&1; then
        print_info "Using apt package manager..."
        apt-get update
        apt-get install -y wget curl xz-utils jq
    elif command -v yum >/dev/null 2>&1; then
        print_info "Using yum package manager..."
        yum update -y
        yum install -y epel-release
        yum install -y wget curl xz jq
    else
        print_error "Unsupported package manager"
        exit 1
    fi
    print_success "Packages installed successfully"
}

# Detect system architecture
detect_arch() {
    print_header "Detecting System Architecture"
    
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
            print_error "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac
    print_success "Detected architecture: $ss_arch"
}

# Install/Update Shadowsocks
install_shadowsocks() {
    print_header "Installing Shadowsocks-rust"
    local new_ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | 
                    jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    
    print_info "Installing version: $new_ver"
    local archive_name="shadowsocks-${new_ver}.${ss_arch}-unknown-linux-gnu.tar.xz"
    
    if ! wget --no-check-certificate -N "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${new_ver}/${archive_name}"; then
        print_error "Failed to download Shadowsocks Rust!"
        exit 1
    fi
    
    print_info "Extracting files..."
    tar -xf "$archive_name"
    
    if [[ ! -f "ssserver" ]]; then
        print_error "Failed to extract Shadowsocks Rust!"
        exit 1
    fi
    
    chmod +x ssserver
    mv -f ssserver /usr/local/bin/
    rm -f sslocal ssmanager ssservice ssurl "$archive_name"
    
    print_success "Shadowsocks-rust installation completed"
}

# Configure Shadowsocks
configure_shadowsocks() {
    print_header "Configuring Shadowsocks"
    mkdir -p /etc/shadowsocks
    
    cat > /etc/shadowsocks/config.json << EOF
{
    "server":"0.0.0.0",
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
    print_info "Starting Shadowsocks service..."
    systemctl enable shadowsocks.service
    systemctl start shadowsocks.service
    
    if ! systemctl is-active --quiet shadowsocks.service; then
        print_error "Shadowsocks service failed to start!"
        exit 1
    fi
    print_success "Shadowsocks configured and started successfully"
}

# Install/Update ShadowTLS
install_shadowtls() {
    print_header "Installing ShadowTLS"
    local latest_version=$(curl -s https://api.github.com/repos/ihciah/shadow-tls/releases/latest | jq -r .tag_name)
    
    print_info "Installing version: ${latest_version}"
    
    if ! wget -q --show-progress "https://github.com/ihciah/shadow-tls/releases/download/${latest_version}/shadow-tls-${tls_arch_suffix}" -O /usr/local/bin/shadow-tls; then
        print_error "Failed to download ShadowTLS!"
        exit 1
    fi

    chmod +x /usr/local/bin/shadow-tls
    print_success "ShadowTLS binary installed successfully"
}

# Function to get user input for ShadowTLS listen port
get_user_port() {
    print_header "ShadowTLS Port Configuration"
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
                        print_info "选择的端口: $listen_port"
                        break
                    else
                        print_error "请输入一个有效的端口号 (50000-60000，且不包含数字4)"
                    fi
                done
                break
                ;;
            2)
                listen_port=$(generate_port 50000 60000)
                print_info "随机生成端口: $listen_port"
                break
                ;;
            *)
                print_error "无效选择。请输入 1 或 2。"
                ;;
        esac
    done
}

# Get user domain selection
get_user_domain() {
    print_header "TLS Domain Configuration"
    echo "请选择 TLS 域名设置方式："
    echo "1. 随机使用预设域名"
    echo "2. 使用指定域名"
    echo "3. 手动输入域名"
    echo -e "----------------------------------------\n"
    
    while true; do
        read -p "请选择 (1/2/3): " domain_choice
        case $domain_choice in
            1)
                random_index=$((RANDOM % ${#PRESET_DOMAINS[@]}))
                domain="${PRESET_DOMAINS[$random_index]}"
                print_info "随机选择域名: $domain"
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
                        print_info "使用指定域名: $domain"
                        break
                    else
                        print_error "请输入有效的编号 (1-${#PRESET_DOMAINS[@]})"
                    fi
                done
                break
                ;;
            3)
                while true; do
                    read -p "请输入域名: " custom_domain
                    if [[ $custom_domain =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                        domain=$custom_domain
                        print_info "使用自定义域名: $domain"
                        break
                    else
                        print_error "请输入有效的域名格式"
                    fi
                done
                break
                ;;
            *)
                print_error "无效选择。请输入 1、2 或 3。"
                ;;
        esac
    done
}

# Configure ShadowTLS
configure_shadowtls() {
    print_header "Configuring ShadowTLS"
    cat > /lib/systemd/system/shadowtls.service << EOF
[Unit]
Description=ShadowTLS Service
After=network.target
Before=network-online.target
StartLimitBurst=0
StartLimitIntervalSec=60

[Service]
LimitNOFILE=65536
ExecStart=/usr/local/bin/shadow-tls --fastopen --v3 --strict server --listen ::0:${listen_port} --server 127.0.0.1:${ssport} --tls ${domain} --password ${tls_password}
Restart=always
RestartSec=2
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_info "Starting ShadowTLS service..."
    systemctl enable shadowtls.service
    systemctl start shadowtls.service

    if ! systemctl is-active --quiet shadowtls.service; then
        print_error "ShadowTLS service failed to start!"
        print_warning "Please check the logs with: journalctl -u shadowtls.service"
        exit 1
    fi
    print_success "ShadowTLS configured and started successfully"
}

# Show configuration
show_configuration() {
    print_header "Installation Status"
    
    local server_ip=$(curl -s https://api.ipify.org)
    
    echo -e "${BOLD}Service Status:${NC}"
    echo -e "\n${BOLD}Shadowsocks Service:${NC}"
    systemctl status shadowsocks.service --no-pager
    
    echo -e "\n${BOLD}ShadowTLS Service:${NC}"
    systemctl status shadowtls.service --no-pager
    
    print_header "Configuration Details"
    echo -e "${BOLD}Server IP:${NC} ${server_ip}"
    echo -e "${BOLD}Shadowsocks Port:${NC} ${ssport}"
    echo -e "${BOLD}Shadowsocks Password:${NC} ${sspasswd}"
    echo -e "${BOLD}ShadowTLS Port:${NC} ${listen_port}"
    echo -e "${BOLD}ShadowTLS Password:${NC} ${tls_password}"
    echo -e "${BOLD}ShadowTLS SNI:${NC} ${domain}"
}

# Update services
update_services() {
    get_current_versions
    
    local versions=$(check_updates)
    local ss_latest_ver=$(echo $versions | cut -d: -f1)
    local stls_latest_ver=$(echo $versions | cut -d: -f2)
    
    print_header "Update Process"
    
    read -p "Do you want to proceed with the updates? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        print_info "Update cancelled"
        return
    fi
    
    # Update Shadowsocks if needed
    if [[ "$ss_latest_ver" != "$SS_CURRENT_VERSION" ]]; then
        systemctl stop shadowsocks.service 2>/dev/null
        install_shadowsocks
        systemctl start shadowsocks.service
    fi
    
    # Update ShadowTLS if needed
    if [[ "$stls_latest_ver" != "$STLS_CURRENT_VERSION" ]]; then
        systemctl stop shadowtls.service 2>/dev/null
        install_shadowtls
        systemctl start shadowtls.service
    fi
    
    print_success "All services updated successfully"
}

# Uninstall services
uninstall_service() {
    print_header "Uninstalling Services"
    
    print_info "Stopping and disabling Shadowsocks service..."
    systemctl stop shadowsocks.service 2>/dev/null
    systemctl disable shadowsocks.service 2>/dev/null
    print_success "Shadowsocks service stopped and disabled"
    
    print_info "Stopping and disabling ShadowTLS service..."
    systemctl stop shadowtls.service 2>/dev/null
    systemctl disable shadowtls.service 2>/dev/null
    print_success "ShadowTLS service stopped and disabled"
    
    print_info "Removing service files..."
    rm -f /lib/systemd/system/shadowsocks.service
    rm -f /lib/systemd/system/shadowtls.service
    print_success "Service files removed"
    
    print_info "Removing configuration files..."
    rm -rf /etc/shadowsocks
    rm -f /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
    print_success "Configuration files removed"
    
    print_info "Removing binary files..."
    rm -f /usr/local/bin/ssserver
    rm -f /usr/local/bin/shadow-tls
    print_success "Binary files removed"
    
    print_info "Reloading systemd daemon..."
    systemctl daemon-reload
    systemctl reset-failed
    print_success "Systemd daemon reloaded"
    
    print_success "Uninstallation completed successfully"
}

# Main menu
main_menu() {
    while true; do
        clear
        print_header "ShadowTLS Management Script"
        echo "1. Install Shadowsocks and ShadowTLS"
        echo "2. Update Services"
        echo "3. Uninstall Services"
        echo "4. Show Current Configuration"
        echo "5. Exit"
        echo -e "=====================================\n"
        
        read -p "Please select an option (1-5): " choice
        
        case $choice in
            1)
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
                update_services
                ;;
            3)
                uninstall_service
                ;;
            4)
                show_configuration
                ;;
            5)
                print_info "Exiting..."
                exit 0
                ;;
            *)
                print_error "Invalid option. Please try again."
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
}

# Start script execution
main_menu
