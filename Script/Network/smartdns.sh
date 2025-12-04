#!/bin/bash

# Define color codes for different log categories
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Global variables for versions
RELEASE_NUMBER=""
PACKAGE_VERSION=""
ARCH_TYPE=""

# ECS region variable
ECS_REGION=""

# ECS region to IP mapping
declare -A ECS_IPS=(
    ["HK"]="42.2.2.2"
    ["TYO"]="106.152.210.210"
    ["LA"]="107.119.53.53"
    ["SEA"]="68.86.93.93"
)

# Logging functions
log_info() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')][INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')][WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')][ERROR] $1${NC}"
}

# Check if running as root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Check if SmartDNS is already installed
check_installed() {
    if systemctl is-active smartdns &>/dev/null; then
        log_error "SmartDNS is already installed and running"
        exit 1
    fi
}

# Check system architecture
check_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH_TYPE="x86_64"
            ;;
        aarch64)
            ARCH_TYPE="aarch64"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            log_error "This script only supports x86_64 and aarch64 architectures"
            exit 1
            ;;
    esac
    log_info "Detected architecture: $ARCH_TYPE"
}

# Install jq if not present
install_jq() {
    if command -v jq &>/dev/null; then
        log_info "jq is already installed"
        return 0
    fi
    
    log_info "Installing jq..."
    if [ -f /etc/debian_version ]; then
        apt-get update -qq && apt-get install -y jq >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y jq >/dev/null 2>&1
    else
        log_error "Unsupported distribution for automatic jq installation"
        exit 1
    fi
    
    if command -v jq &>/dev/null; then
        log_info "jq installed successfully"
    else
        log_error "Failed to install jq"
        exit 1
    fi
}

# Get the latest SmartDNS versions from GitHub
get_latest_version() {
    install_jq
    
    # Get the latest release page content
    local release_page
    release_page=$(wget -qO- https://api.github.com/repos/pymumu/smartdns/releases/latest)
    
    if [ -z "$release_page" ]; then
        log_error "Failed to fetch release information"
        exit 1
    fi
    
    # Extract Release number
    RELEASE_NUMBER=$(echo "$release_page" | jq -r '.tag_name' | sed 's/Release//')
    if [ -z "$RELEASE_NUMBER" ]; then
        log_error "Failed to extract Release number"
        exit 1
    fi
    
    # Extract package version from assets
    PACKAGE_VERSION=$(echo "$release_page" | jq -r '.assets[0].name' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+-[0-9]\+')
    if [ -z "$PACKAGE_VERSION" ]; then
        log_error "Failed to extract package version"
        exit 1
    fi
    
    log_info "Latest versions - Release: ${RELEASE_NUMBER}, Package: ${PACKAGE_VERSION}"
    return 0
}

# Parse command line arguments
parse_args() {
    UNINSTALL=0
    
    # If no arguments provided, use default installation
    if [ $# -eq 0 ]; then
        log_info "No parameters specified, proceeding with default installation"
        return 0
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--uninstall)
                UNINSTALL=1
                shift
                ;;
            -e|--ecs)
                if [ -z "$2" ] || [[ "$2" == -* ]]; then
                    log_error "ECS region not specified"
                    echo "Available regions: HK, TYO, LA, SEA"
                    exit 1
                fi
                ECS_REGION=$(echo "$2" | tr '[:lower:]' '[:upper:]')
                if [ -z "${ECS_IPS[$ECS_REGION]}" ]; then
                    log_error "Invalid ECS region: $2"
                    echo "Available regions: HK, TYO, LA, SEA"
                    exit 1
                fi
                log_info "ECS region set to: $ECS_REGION (IP: ${ECS_IPS[$ECS_REGION]})"
                shift 2
                ;;
            *)
                log_error "Unknown parameter: $1"
                echo "Usage: $0 [-u|--uninstall] [-e|--ecs REGION]"
                echo "       $0 (no parameters for default installation)"
                echo "Available ECS regions: HK, TYO, LA, SEA"
                exit 1
                ;;
        esac
    done

    if [ $UNINSTALL -eq 1 ]; then
        log_info "Preparing to uninstall SmartDNS..."
    else
        log_info "Proceeding with default installation"
    fi
}

# Download and install SmartDNS
install_smartdns() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    cd "$tmp_dir" || exit 1
    
    log_info "Downloading SmartDNS..."
    local download_url="https://github.com/pymumu/smartdns/releases/download/Release${RELEASE_NUMBER}/smartdns.${PACKAGE_VERSION}.${ARCH_TYPE}-linux-all.tar.gz"
    
    wget --no-check-certificate -q "$download_url" -O smartdns.tar.gz || {
        log_error "Download failed"
        cd / && rm -rf "$tmp_dir"
        exit 1
    }
    
    log_info "Installing SmartDNS..."
    tar zxf smartdns.tar.gz >/dev/null 2>&1 || {
        log_error "Failed to extract archive"
        cd / && rm -rf "$tmp_dir"
        exit 1
    }
    
    cd smartdns && chmod +x ./install
    ./install -i >/dev/null 2>&1 || {
        log_error "SmartDNS installation failed"
        cd / && rm -rf "$tmp_dir"
        exit 1
    }
    
    log_info "SmartDNS installed successfully"
    cd / && rm -rf "$tmp_dir"
}

# Configure SmartDNS
configure_smartdns() {
    mkdir -p /etc/smartdns

    # Generate ECS suffix for DNS servers (except 1.1.1.1)
    local ecs_suffix=""
    if [ -n "$ECS_REGION" ]; then
        ecs_suffix=" -subnet ${ECS_IPS[$ECS_REGION]}/24"
        log_info "Applying ECS configuration with IP: ${ECS_IPS[$ECS_REGION]}"
    fi

    cat > /etc/smartdns/smartdns.conf << EOF
server-name smartdns
log-level error
bind 127.0.0.1:53
server 1.1.1.1
server 8.8.8.8${ecs_suffix}
server 94.140.14.140${ecs_suffix}
server 208.67.222.222${ecs_suffix}
speed-check-mode ping,tcp:80,tcp:443
serve-expired yes
serve-expired-ttl 129600
serve-expired-reply-ttl 1
prefetch-domain yes
serve-expired-prefetch-time 21600
cache-size 4096
cache-persist yes
cache-file /etc/smartdns/smartdns.cache
dualstack-ip-selection yes
force-qtype-SOA 65
EOF

    systemctl enable smartdns >/dev/null 2>&1
    log_info "Starting SmartDNS service..."
    systemctl start smartdns
    
    if systemctl is-active smartdns &>/dev/null; then
        log_info "SmartDNS installed and started successfully!"
        
        log_info "Configuring system DNS..."
        chattr -i /etc/resolv.conf 2>/dev/null
        rm -f /etc/resolv.conf
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        chattr +i /etc/resolv.conf
        
        log_info "System DNS configuration completed!"
        
        echo "----------------------------------------"
        systemctl status smartdns
        echo "----------------------------------------"
    else
        log_error "SmartDNS failed to start. Please check logs"
        exit 1
    fi
}

# Uninstall SmartDNS
uninstall_smartdns() {
    log_info "Starting SmartDNS uninstallation..."
    
    if systemctl is-active smartdns &>/dev/null; then
        log_info "Stopping SmartDNS service..."
        systemctl stop smartdns
    fi
    
    if systemctl is-enabled smartdns &>/dev/null; then
        log_info "Disabling SmartDNS service..."
        systemctl disable smartdns >/dev/null 2>&1
    fi
    
    log_info "Restoring system DNS configuration..."
    chattr -i /etc/resolv.conf 2>/dev/null
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    
    log_info "Removing SmartDNS files..."
    rm -rf /etc/smartdns
    rm -f /usr/sbin/smartdns
    rm -f /usr/lib/systemd/system/smartdns.service
    
    systemctl daemon-reload >/dev/null 2>&1
    
    log_info "SmartDNS uninstallation completed!"
}

# Main function
main() {
    check_root
    parse_args "$@"
    
    if [ $UNINSTALL -eq 1 ]; then
        uninstall_smartdns
    else
        check_installed
        check_arch
        get_latest_version
        install_smartdns
        configure_smartdns
    fi
}

# Execute main function with all command line arguments
main "$@"
