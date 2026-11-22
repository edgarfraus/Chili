#!/usr/bin/env bash
# Assembles "Chili.app" from the built stack (scripts/build-stack.sh)
# and the Swift launcher.
#
#   Chili.app/Contents/
#     MacOS/Chili                     launcher: Proxmox, quick connect, built-in SPICE console
#                                     (SpiceKit on spice-glib), .vv handler
#     Resources/                      launcher icon + translations
#     Helpers/Chili Viewer.app/       remote-viewer and its whole runtime
#       Contents/MacOS/               remote-viewer, gst-plugin-scanner
#       Contents/Frameworks/          every bundled dylib
#       Contents/Resources/           lib/ (GStreamer + gdk-pixbuf modules, signed one by one),
#                                     share/ (icons, schemas, locale), etc/ (fonts, gtk-3.0)
#
# Environment: BUNDLE_ID, PROJECT_URL, CODESIGN_IDENTITY (default "-" = ad-hoc).

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"

BUNDLE_ID="${BUNDLE_ID:-io.github.edgarfraus.chili}"
PROJECT_URL="${PROJECT_URL:-https://github.com/edgarfraus/Chili}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION="$(cat "$REPO_ROOT/VERSION")"
BUILD="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

[[ -x "$PREFIX/bin/remote-viewer" ]] || die "remote-viewer not built yet: run scripts/build-stack.sh"

OUT="$DIST_DIR/$ARCH"
APP="$OUT/Chili.app"
VIEWER="$APP/Contents/Helpers/Chili Viewer.app"
VC="$VIEWER/Contents"

msg "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$VC/MacOS" "$VC/Frameworks" "$VC/Resources/lib/gstreamer-1.0" "$VC/Resources/lib/gdk-pixbuf/loaders" \
         "$VC/Resources/share" "$VC/Resources/etc" "$VC/Resources/lib/gdk-pixbuf-2.0"

render() {  # render TEMPLATE DEST
    sed -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" -e "s|@VERSION@|$VERSION|g" \
        -e "s|@BUILD@|$BUILD|g" -e "s|@PROJECT_URL@|$PROJECT_URL|g" "$1" > "$2"
}

# --- Launcher --------------------------------------------------------------
msg "Compiling launcher"
"$REPO_ROOT/scripts/build-launcher.sh" "$APP/Contents/MacOS/Chili"
render "$REPO_ROOT/resources/Info.plist.in" "$APP/Contents/Info.plist"
cp "$REPO_ROOT/resources/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$REPO_ROOT"/launcher/Resources/*.lproj "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- Viewer helper ---------------------------------------------------------
msg "Copying viewer runtime"
render "$REPO_ROOT/resources/Viewer-Info.plist.in" "$VC/Info.plist"
cp "$REPO_ROOT/resources/AppIcon.icns" "$VC/Resources/"
printf 'APPL????' > "$VC/PkgInfo"
cp "$PREFIX/bin/remote-viewer" "$VC/MacOS/"
cp "$PREFIX/libexec/gstreamer-1.0/gst-plugin-scanner" "$VC/MacOS/"

cp "$PREFIX"/lib/gstreamer-1.0/*.dylib "$VC/Resources/lib/gstreamer-1.0/"
pixbuf_moddir="$("$PKG_CONFIG" --variable=gdk_pixbuf_moduledir gdk-pixbuf-2.0)"
cp "$pixbuf_moddir"/*.so "$pixbuf_moddir"/*.dylib "$VC/Resources/lib/gdk-pixbuf/loaders/" 2>/dev/null || true


# share/: only what remote-viewer actually uses.
S="$VC/Resources/share"
mkdir -p "$S/glib-2.0/schemas" "$S/icons" "$S/locale"
cp "$PREFIX"/share/glib-2.0/schemas/*.gschema.xml "$S/glib-2.0/schemas/"
"$PREFIX/bin/glib-compile-schemas" "$S/glib-2.0/schemas"
cp -R "$PREFIX/share/icons/hicolor" "$PREFIX/share/icons/Adwaita" "$S/icons/"
for theme in "$S"/icons/*; do
    "$PREFIX/bin/gtk-update-icon-cache" --quiet --force --ignore-theme-index "$theme"
done
for lang_dir in "$PREFIX"/share/locale/*/LC_MESSAGES; do
    lang="$(basename "$(dirname "$lang_dir")")"
    for domain in virt-viewer spice-gtk gtk30 gtk30-properties glib20; do
        if [[ -f "$lang_dir/$domain.mo" ]]; then
            mkdir -p "$S/locale/$lang/LC_MESSAGES"
            cp "$lang_dir/$domain.mo" "$S/locale/$lang/LC_MESSAGES/"
        fi
    done
done

cp -R "$REPO_ROOT/resources/etc/" "$VC/Resources/etc/"

# --- Make it self-contained ------------------------------------------------
msg "Relocating libraries"
# The launcher's built-in console links spice-glib too; it shares the helper's Frameworks.
roots=("$APP/Contents/MacOS/Chili" "$VC/MacOS/remote-viewer" "$VC/MacOS/gst-plugin-scanner"
       "$VC"/Resources/lib/gstreamer-1.0/*.dylib)
for so in "$VC"/Resources/lib/gdk-pixbuf/loaders/*; do [[ -e "$so" ]] && roots+=("$so"); done
"$TOOLS/venv/bin/python3" "$REPO_ROOT/scripts/relocate.py" \
    --prefix "$PREFIX" --frameworks "$VC/Frameworks" --bundle "$APP" "${roots[@]}"

# gdk-pixbuf wants absolute module paths; the launcher fills @PLUGINS@ in at runtime.
# Runs after relocation: the loaders only resolve their @rpath deps inside the bundle.
"$PREFIX/bin/gdk-pixbuf-query-loaders" "$VC"/Resources/lib/gdk-pixbuf/loaders/* \
    | sed -e "s|$VC/Resources/lib|@PLUGINS@|g" -e '/^#/d' \
    > "$VC/Resources/lib/gdk-pixbuf-2.0/loaders.cache.in"
grep -q '@PLUGINS@/gdk-pixbuf/' "$VC/Resources/lib/gdk-pixbuf-2.0/loaders.cache.in" || die "no SVG loader found"

msg "Stripping"
find "$VC" -type f \( -name '*.dylib' -o -name '*.so' \) -exec strip -x {} \; 2>/dev/null
strip -x "$VC/MacOS/remote-viewer" "$VC/MacOS/gst-plugin-scanner"

# --- Code signing (inside out) --------------------------------------------
msg "Signing (identity: $CODESIGN_IDENTITY)"
sign_opts=(--force --sign "$CODESIGN_IDENTITY")
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    sign_opts+=(--timestamp --options runtime --entitlements "$REPO_ROOT/resources/entitlements.plist")
fi
find "$VC/Frameworks" "$VC/Resources/lib" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 \
    | xargs -0 codesign "${sign_opts[@]}"
codesign "${sign_opts[@]}" "$VC/MacOS/gst-plugin-scanner"
codesign "${sign_opts[@]}" "$VIEWER"
codesign "${sign_opts[@]}" "$APP"
codesign --verify --deep --strict "$APP"

du -sh "$APP" | awk '{print "    app size: " $1}'
msg "Done: $APP"
