#!/bin/bash

set -e -o pipefail

# Function to get the latest version
get_latest_version() {
    curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | grep tag_name \
        | cut -d ":" -f2 \
        | sed 's/\"//g;s/\,//g;s/\ //g;s/v//'
}

# Determine architecture
ARCH_RAW=$(uname -m)
case "${ARCH_RAW}" in
    'x86_64')    ARCH='amd64';;
    'x86' | 'i686' | 'i386')     ARCH='386';;
    'aarch64' | 'arm64') ARCH='arm64';;
    'armv7l')   ARCH='armv7';;
    's390x')    ARCH='s390x';;
    *)          echo "Unsupported architecture: ${ARCH_RAW}"; exit 1;;
esac

# Prompt user for version choice
echo "Choose a version option:"
echo "1. Latest version"
echo "2. Version 1.8.14"
echo "3. Version 1.9.6"
echo "4. Specify a custom version"
read -p "Enter your choice (1-4): " VERSION_CHOICE

case $VERSION_CHOICE in
    1)
        VERSION=$(get_latest_version)
        ;;
    2)
        VERSION="1.8.14"
        ;;
    3)
        VERSION="1.9.6"
        ;;
    4)
        read -p "Enter the custom version (e.g., 1.8.14): " VERSION
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

echo "Installing sing-box version ${VERSION}"

# Download and install the package
curl -Lo sing-box.deb "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box_${VERSION}_linux_${ARCH}.deb"
sudo dpkg -i sing-box.deb
rm sing-box.deb

echo "sing-box version ${VERSION} has been installed successfully."
