#!/usr/bin/env bash
# Regenerates resources/AppIcon.icns and the DMG background from their SVG
# sources. The outputs are committed, so this only runs when artwork changes.
# Needs rsvg-convert (built by build-stack.sh, or from any other install).
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"

RSVG="${RSVG:-$PREFIX/bin/rsvg-convert}"
[[ -x "$RSVG" ]] || RSVG="$(command -v rsvg-convert)" || die "rsvg-convert not found"
ICON_DIR="$REPO_ROOT/resources/icon"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

msg "AppIcon.icns"
set_dir="$tmp/AppIcon.iconset"
mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
    "$RSVG" -w $size -h $size "$ICON_DIR/AppIcon.svg" -o "$set_dir/icon_${size}x${size}.png"
    "$RSVG" -w $((size * 2)) -h $((size * 2)) "$ICON_DIR/AppIcon.svg" -o "$set_dir/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$set_dir" -o "$REPO_ROOT/resources/AppIcon.icns"

msg "DMG background"
"$RSVG" -w 660 -h 420 "$ICON_DIR/dmg-background.svg" -o "$tmp/bg.png"
"$RSVG" -w 1320 -h 840 "$ICON_DIR/dmg-background.svg" -o "$tmp/bg@2x.png"
tiffutil -cathidpicheck "$tmp/bg.png" "$tmp/bg@2x.png" -out "$REPO_ROOT/resources/dmg-background.tiff" >/dev/null
msg "Done"
