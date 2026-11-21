#!/usr/bin/env bash
# Checks that the bundled viewer starts without the build prefix around:
# the prefix is moved away while the test runs, so any leftover absolute
# path to it makes dyld fail loudly.
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"

APP="$DIST_DIR/$ARCH/Chili.app"
VC="$APP/Contents/Helpers/Chili Viewer.app/Contents"
[[ -d "$APP" ]] || die "app not found: run scripts/bundle-app.sh first"

hidden="$PREFIX.hidden"
mv "$PREFIX" "$hidden"
trap 'mv "$hidden" "$PREFIX"' EXIT

msg "remote-viewer --version"
out="$("$VC/MacOS/remote-viewer" --version 2>&1)" || die "remote-viewer failed to start: $out"
echo "    $out"

msg "GStreamer plugin scan"
export GST_PLUGIN_SYSTEM_PATH_1_0="$VC/Resources/lib/gstreamer-1.0"
export GST_PLUGIN_SCANNER_1_0="$VC/MacOS/gst-plugin-scanner"
export GST_REGISTRY_1_0="$(mktemp -d)/registry.bin"
for p in "$VC"/Resources/lib/gstreamer-1.0/*.dylib; do
    # dlopen every plugin through dyld; a missing dependency aborts here.
    /usr/bin/python3 -c "import ctypes,sys; ctypes.CDLL(sys.argv[1])" "$p" \
        || die "plugin does not load: $(basename "$p")"
done
echo "    $(ls "$VC"/Resources/lib/gstreamer-1.0 | wc -l | tr -d ' ') plugins load"

msg "gdk-pixbuf loaders"
for so in "$VC"/Resources/lib/gdk-pixbuf/loaders/*; do
    /usr/bin/python3 -c "import ctypes,sys; ctypes.CDLL(sys.argv[1])" "$so" || die "loader does not load: $so"
done

msg "Code signature"
codesign --verify --deep --strict "$APP"
echo "    ok"
msg "Smoke test passed"
