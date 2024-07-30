#!/bin/bash

tag="$1"
custom_file="/etc/script/GeoIP_${tag}.txt"

# Function to download the file
download_file() {
    local url=""
    case "$tag" in
        "telegram")
            url='https://raw.gitmirror.com/vitoegg/Provider/master/RuleSet/Extra/GeoIP_telegram.txt'
            ;;
        "netflix")
            url='https://raw.gitmirror.com/vitoegg/Provider/master/RuleSet/Extra/GeoIP_netflix.txt'
            ;;
        *)
            echo "Error: No download URL specified for tag: $tag"
            exit 1
            ;;
    esac

    echo "Downloading file for tag: $tag"
    wget --timeout 5 -O "$custom_file" "$url"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to download file for tag: $tag"
        exit 1
    fi
    echo "File downloaded successfully."
}

if [ -z "$tag" ]; then
    echo "Usage: $0 <tag>"
    exit 1
fi

if [ ! -f "$custom_file" ]; then
    echo "Custom file $custom_file does not exist. Attempting to download..."
    download_file
fi

echo "Using file: $custom_file"

ipset destroy "$tag" 2>/dev/null
ipset create "$tag" hash:net

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines
    [ -z "$line" ] && continue
    
    ipset add "$tag" "$line"
done < "$custom_file"

echo "ipset '$tag' has been created and populated."
