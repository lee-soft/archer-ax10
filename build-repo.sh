#!/bin/sh
# ============================================================
# build-repo.sh — build the ax10-* opkg feed from repo-src/ into repo/.
# Each repo-src/<pkg>/ has: control, data/ (file tree), and optional
# maintainer scripts (preinst postinst prerm postrm conffiles).
# Produces repo/<pkg>_<ver>_<arch>.ipk + repo/Packages(.gz) index.
# Then deploy with deploy-to-pages.sh (which also publishes repo/).
# ============================================================
set -e
BASE="${BASE:-$(cd "$(dirname "$0")" && pwd)}"
SRC="${SRC:-$BASE/repo-src}"
OUT="${OUT:-$BASE/repo}"

rm -rf "$OUT"; mkdir -p "$OUT"
: > "$OUT/Packages"

built=0
for pkgdir in "$SRC"/*/; do
    [ -f "$pkgdir/control" ] || continue
    name=$(basename "$pkgdir")
    ver=$(awk -F': *' '/^Version:/{print $2; exit}' "$pkgdir/control")
    arch=$(awk -F': *' '/^Architecture:/{print $2; exit}' "$pkgdir/control")
    [ -n "$ver" ] && [ -n "$arch" ] || { echo "SKIP $name: missing Version/Architecture"; continue; }

    tmp=$(mktemp -d); cdir=$(mktemp -d)
    # data.tar.gz (the file tree; include the ./ root entry, root-owned)
    ( cd "$pkgdir/data" && tar --owner=0 --group=0 -czf "$tmp/data.tar.gz" . )
    # control.tar.gz (control + maintainer scripts)
    cp "$pkgdir/control" "$cdir/control"
    for s in preinst postinst prerm postrm conffiles; do
        [ -f "$pkgdir/$s" ] && { cp "$pkgdir/$s" "$cdir/$s"; chmod 755 "$cdir/$s"; }
    done
    ( cd "$cdir" && tar --owner=0 --group=0 -czf "$tmp/control.tar.gz" . )
    echo "2.0" > "$tmp/debian-binary"

    # This opkg (Entware/old-ipkg) wants the OUTER container as a gzipped TAR of
    # the three members (./debian-binary ./data.tar.gz ./control.tar.gz), NOT ar.
    ipk="${name}_${ver}_${arch}.ipk"
    ( cd "$tmp" && tar --owner=0 --group=0 -czf "$OUT/$ipk" ./debian-binary ./data.tar.gz ./control.tar.gz )

    sz=$(wc -c < "$OUT/$ipk")
    sha=$(sha256sum "$OUT/$ipk" | awk '{print $1}')
    md5=$(md5sum "$OUT/$ipk" | awk '{print $1}')
    {
        grep -vE '^[[:space:]]*$' "$pkgdir/control"
        echo "Filename: $ipk"
        echo "Size: $sz"
        echo "SHA256sum: $sha"
        echo "MD5Sum: $md5"
        echo ""
    } >> "$OUT/Packages"
    rm -rf "$tmp" "$cdir"
    echo "  built $ipk ($sz bytes)"
    built=$((built+1))
done

gzip -9 -c "$OUT/Packages" > "$OUT/Packages.gz"
echo "Done: $built package(s) -> $OUT ; index has $(grep -c '^Package:' "$OUT/Packages") entries"
