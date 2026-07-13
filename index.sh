#!/bin/sh
# Build an opkg Packages(.gz) index from a directory of .ipk files.
# Each .ipk is the gzipped-tar format (./debian-binary ./control.tar.gz ./data.tar.gz).
set -e
FEED="${1:-feed}"
: > "$FEED/Packages"
for ipk in "$FEED"/*.ipk; do
    [ -f "$ipk" ] || continue
    tmp=$(mktemp -d)
    tar -xzf "$ipk" -C "$tmp" ./control.tar.gz
    tar -xzf "$tmp/control.tar.gz" -C "$tmp" ./control
    sz=$(wc -c < "$ipk")
    sha=$(sha256sum "$ipk" | awk '{print $1}')
    md5=$(md5sum "$ipk" | awk '{print $1}')
    {
        grep -vE '^[[:space:]]*$' "$tmp/control"
        echo "Filename: $(basename "$ipk")"
        echo "Size: $sz"
        echo "SHA256sum: $sha"
        echo "MD5Sum: $md5"
        echo ""
    } >> "$FEED/Packages"
    rm -rf "$tmp"
done
gzip -9c "$FEED/Packages" > "$FEED/Packages.gz"
echo "index: $(grep -c '^Package:' "$FEED/Packages") packages"
