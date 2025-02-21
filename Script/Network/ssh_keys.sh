#!/bin/bash

# Help function
show_help() {
    echo "Usage: $0 -k <public_key>"
    echo "Options:"
    echo "  -k    SSH public key (required)"
    echo "  -h    Show this help message"
    exit 1
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Parse command line arguments
while getopts "k:h" opt; do
    case $opt in
        k)
            SSH_PUBLIC_KEY="$OPTARG"
            ;;
        h)
            show_help
            ;;
        \?)
            echo "Invalid option: -$OPTARG"
            show_help
            ;;
    esac
done

# Check if SSH key is provided
if [ -z "$SSH_PUBLIC_KEY" ]; then
    echo "Error: SSH public key is required"
    show_help
fi

# Configuration variables
SSH_DIR="$HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Create function to log steps
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')][INFO] $1${NC}"
}

# Step 1: Create SSH directory
log "Creating SSH directory..."
mkdir -p "$SSH_DIR"

# Step 2: Add public key to authorized_keys
log "Adding public key to authorized_keys..."
echo "$SSH_PUBLIC_KEY" >> "$AUTH_KEYS"

# Step 3: Set correct permissions
log "Setting correct permissions..."
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"

# Step 4: Add SSH configuration
log "Adding SSH configuration..."
cat >> "$SSHD_CONFIG" << EOL

# Disable password login and enable key-based authentication
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile     .ssh/authorized_keys
EOL

# Step 5: Restart SSH service
log "Restarting SSH service..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh
else
    service ssh restart
fi

# Step 6: Delete script file
log "Deleting script file..."
rm -f "$(readlink -f "$0")"

log "SSH configuration completed successfully!"
