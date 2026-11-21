#!/usr/bin/env bash
# Compiles the Chili launcher: SpiceKit (Objective-C, on spice-client-glib)
# plus the SwiftUI app, linked against the stack in build/<arch>/prefix.
#
# Usage: scripts/build-launcher.sh <output-executable>
#        scripts/build-launcher.sh --snapshot-tool <output>   (dev: SpiceKit test CLI)

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"

MIN_MACOS=12.0
OBJ="$BUILD_ROOT/$ARCH/launcher-obj"
mkdir -p "$OBJ"

read -r -a SPICE_CFLAGS <<< "$("$PKG_CONFIG" --cflags spice-client-glib-2.0)"
read -r -a SPICE_LIBS <<< "$("$PKG_CONFIG" --libs spice-client-glib-2.0)"
FRAMEWORKS=(-framework AppKit -framework QuartzCore -framework Carbon -framework CoreGraphics)

objs=()
for src in "$REPO_ROOT"/launcher/SpiceKit/*.m; do
    o="$OBJ/$(basename "${src%.m}").o"
    clang -c -fobjc-arc -O2 -Wall -Wno-deprecated-declarations \
        -arch "$ARCH" -isysroot "$SDKROOT" -mmacosx-version-min="$MIN_MACOS" \
        "${SPICE_CFLAGS[@]}" "$src" -o "$o"
    objs+=("$o")
done

if [[ "${1:-}" == --snapshot-tool ]]; then
    clang -fobjc-arc -O2 -arch "$ARCH" -isysroot "$SDKROOT" -mmacosx-version-min="$MIN_MACOS" \
        "${SPICE_CFLAGS[@]}" "$REPO_ROOT/launcher/SpiceKit/Tests/cs-snapshot.m" "${objs[@]}" \
        "${SPICE_LIBS[@]}" "${FRAMEWORKS[@]}" -Wl,-rpath,"$PREFIX/lib" -o "$2"
    exit 0
fi

out="${1:?output path required}"
swiftc -swift-version 5 -O -whole-module-optimization \
    -target "$ARCH-apple-macos$MIN_MACOS" -sdk "$SDKROOT" \
    -import-objc-header "$REPO_ROOT/launcher/SpiceKit/ChiliSpice.h" \
    "$REPO_ROOT"/launcher/Sources/*.swift "${objs[@]}" \
    -L "$PREFIX/lib" "${SPICE_LIBS[@]}" "${FRAMEWORKS[@]}" \
    -Xlinker -headerpad_max_install_names \
    -o "$out"
