#!/bin/bash

geoipfile="$1"
tag="$2"
tmpdir="/tmp/v2dat"

cd $(cd $(dirname $BASH_SOURCE) && pwd)

mkdir -p "$tmpdir"
filename=$(basename -- "$geoipfile")
filename="${filename%.*}"
filename="$tmpdir/${filename}_$tag.txt"

# Unpacd GeoIP
/usr/bin/mosdns v2dat unpack-ip -o "$tmpdir" "$geoipfile:$tag"

if test -f "$filename"; then
    ipset destroy "$tag"
    ipset create "$tag" hash:net

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Remove comments and leading/trailing whitespace
        clean_line=$(echo "$line" | sed 's/#.*//g' | awk '{$1=$1};1')
        
        # Skip empty lines
        [[ -z "$clean_line" ]] && continue
        
        # Check if it is a valid IPv4 CIDR
        if echo "$clean_line" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'; then
            # Validate the IP address
            if ipcalc -c "$clean_line" >/dev/null 2>&1; then
                ipset add "$tag" "$clean_line"
            else
                echo "Warning: Invalid IPv4 CIDR: $clean_line"
            fi
        else
            echo "Skipping non-IPv4 CIDR entry: $clean_line"
        fi
    done < "$filename"

    echo "ipset '$tag' has been created and populated successfully"
else
    echo "Error: $filename does not exist"
fi

rm -rf "$tmpdir"
