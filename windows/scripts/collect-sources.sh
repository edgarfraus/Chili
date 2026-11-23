#!/usr/bin/env bash
# GPL/LGPL source offer for the Windows build: downloads the MSYS2 source package of every
# package that went into windows/build/viewer (listed in PACKAGES.txt by bundle-viewer.sh)
# and packs them with Chili's own source into one tarball.
#
# Run from an MSYS2 shell after bundle-viewer.sh:  windows/scripts/collect-sources.sh [out-dir]
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
VIEWER="$REPO/windows/build/viewer"
OUT=${1:-$REPO/windows/build/dist}
VERSION=${CHILI_VERSION:-$(cat "$REPO/VERSION")}
name="Chili-$VERSION-windows-sources"
stage="$REPO/windows/build/$name"

[[ -f "$VIEWER/PACKAGES.txt" ]] || { echo "run bundle-viewer.sh first" >&2; exit 1; }
rm -rf "$stage" && mkdir -p "$stage/msys2" "$OUT"

# "name version" lines after the header of PACKAGES.txt.
grep -E '^mingw-w64-' "$VIEWER/PACKAGES.txt" | while read -r pkg ver; do
    # Split packages (e.g. gcc-libs) come from a base package: its sources carry the base name.
    desc=$(ls -d /var/lib/pacman/local/"$pkg-$ver"/desc 2>/dev/null | head -1)
    base=$(awk '/^%BASE%$/ { getline; print; exit }' "$desc")
    file="$base-$ver.src.tar.zst"
    [[ -f "$stage/msys2/$file" ]] && continue
    echo "==> $file"
    curl -fsSL --retry 3 -o "$stage/msys2/$file" "https://repo.msys2.org/mingw/sources/$file" \
        || { echo "missing source package: $file" >&2; exit 1; }
done

cp "$VIEWER/PACKAGES.txt" "$stage/"
git -C "$REPO" archive --format=tar --prefix="Chili/" HEAD | tar -x -C "$stage"
tar -cf "$OUT/$name.tar" -C "$(dirname "$stage")" "$name"
rm -rf "$stage"
echo "==> Done: $OUT/$name.tar ($(du -h "$OUT/$name.tar" | cut -f1))"
