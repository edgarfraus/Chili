#!/usr/bin/env bash
# Collects remote-viewer (virt-viewer) from MSYS2 into a self-contained folder that the app
# ships as viewer\ next to Chili.exe:
#
#   viewer/bin/        remote-viewer.exe, chili-spice.dll (built-in console), every DLL they need
#   viewer/lib/        gstreamer-1.0 plugins, gdk-pixbuf loaders + loaders.cache (relative paths)
#   viewer/share/      GSettings schemas, Adwaita/hicolor icons, translations
#
# Run from an MSYS2 UCRT64 (or CLANGARM64) shell with these packages installed:
#   pacman -S mingw-w64-ucrt-x86_64-{virt-viewer,ntldd,gst-plugins-good,gst-plugins-bad}
# GTK, GLib and GStreamer find their data relative to the DLLs on Windows, so the folder
# works from anywhere. Chili sets GST_REGISTRY_FORK=no (no plugin scanner needed) and puts
# the registry and caches in %LOCALAPPDATA%Chili when it starts the viewer.
set -euo pipefail

PREFIX=${MINGW_PREFIX:?run this from an MSYS2 MINGW shell (UCRT64 / CLANGARM64)}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$REPO/windows/build/viewer}

msg() { printf '\033[1m==> %s\033[0m\n' "$*"; }

mkdir -p "$OUT"
find "$OUT" -mindepth 1 -delete   # empty it (the folder itself may be open in a shell)
mkdir -p "$OUT"/{bin,lib/gstreamer-1.0,share/glib-2.0/schemas,share/icons,share/locale}

msg "Executables and plugins"
cp "$PREFIX/bin/remote-viewer.exe" "$OUT/bin/"
# The built-in console: a thin C layer over spice-client-glib, called from C#.
gcc -O2 -Wall -Wno-deprecated-declarations -shared -o "$OUT/bin/chili-spice.dll" \
    "$REPO/windows/native/chili-spice.c" $(pkg-config --cflags --libs spice-client-glib-2.0)

# Same set as the macOS build: playback plumbing, audio out, MJPEG/VP8/H.264 video streams.
plugins=(
    coreelements app typefindfunctions playback audioconvert audioresample volume
    videoconvertscale autodetect directsound wasapi wasapi2 jpeg vpx videoparsersbad d3d11
)
for p in "${plugins[@]}"; do
    cp "$PREFIX/lib/gstreamer-1.0/libgst$p.dll" "$OUT/lib/gstreamer-1.0/"
done

pixbuf_rel=lib/gdk-pixbuf-2.0/2.10.0
mkdir -p "$OUT/$pixbuf_rel/loaders"
for l in png jpeg gif bmp ico; do
    cp "$PREFIX/$pixbuf_rel/loaders/libpixbufloader-$l.dll" "$OUT/$pixbuf_rel/loaders/"
done
cp "$PREFIX/$pixbuf_rel/loaders/pixbufloader_svg.dll" "$OUT/$pixbuf_rel/loaders/"
# Keep only the cache entries for the loaders we ship (entries are blank-line separated
# blocks; their paths are already relative to the prefix).
awk -v dir="$OUT/$pixbuf_rel/loaders" '
    BEGIN { RS = ""; ORS = "\n\n" }
    /^#/ { next }
    {
        match($0, /loaders\\\\[^"]+\.dll/)
        name = substr($0, RSTART + 9, RLENGTH - 9)   # after `loaders\`
        if ((getline _ < (dir "/" name)) >= 0) print
        close(dir "/" name)
    }' "$PREFIX/$pixbuf_rel/loaders.cache" > "$OUT/$pixbuf_rel/loaders.cache"
grep -q 'pixbufloader_svg' "$OUT/$pixbuf_rel/loaders.cache" || { echo "no SVG loader in loaders.cache" >&2; exit 1; }

msg "Libraries"
roots=("$OUT/bin/remote-viewer.exe" "$OUT/bin/chili-spice.dll"
       "$OUT"/lib/gstreamer-1.0/*.dll "$OUT/$pixbuf_rel"/loaders/*.dll)
prefix_win=$(cygpath -w "$PREFIX" | tr '\\' '/')
ntldd -R "${roots[@]}" 2>/dev/null | tr '\\' '/' \
    | grep -ioE "$prefix_win/bin/[^ ]+\.dll" | sort -u \
    | while read -r dll; do cp -n "$(cygpath -u "$dll")" "$OUT/bin/"; done

msg "Data files"
cp "$PREFIX"/share/glib-2.0/schemas/*.xml "$OUT/share/glib-2.0/schemas/"
glib-compile-schemas "$OUT/share/glib-2.0/schemas"
rm "$OUT"/share/glib-2.0/schemas/*.xml
cp -R "$PREFIX/share/icons/hicolor" "$PREFIX/share/icons/Adwaita" "$OUT/share/icons/"
for theme in "$OUT"/share/icons/*; do gtk-update-icon-cache --quiet --force --ignore-theme-index "$theme"; done
for lang_dir in "$PREFIX"/share/locale/*/LC_MESSAGES; do
    lang=$(basename "$(dirname "$lang_dir")")
    for domain in virt-viewer spice-gtk gtk30 gtk30-properties glib20; do
        if [[ -f "$lang_dir/$domain.mo" ]]; then
            mkdir -p "$OUT/share/locale/$lang/LC_MESSAGES"
            cp "$lang_dir/$domain.mo" "$OUT/share/locale/$lang/LC_MESSAGES/"
        fi
    done
done

strip --strip-unneeded "$OUT"/bin/*.exe "$OUT"/bin/*.dll "$OUT"/lib/gstreamer-1.0/*.dll 2>/dev/null || true

# The GPL asks us to ship the corresponding sources: record exactly what went in.
pacman -Qo "$PREFIX"/bin/remote-viewer.exe > /dev/null
{
    echo "remote-viewer and its libraries come from MSYS2 (https://www.msys2.org)."
    echo "Sources: https://packages.msys2.org/ - the packages and versions below."
    echo
    for f in "$OUT"/bin/* "$OUT"/lib/gstreamer-1.0/* "$OUT/$pixbuf_rel"/loaders/*; do
        pacman -Qqo "$PREFIX/${f#"$OUT"/}" 2>/dev/null || true
    done | sort -u | xargs pacman -Q
} > "$OUT/PACKAGES.txt"

msg "Done: $OUT ($(du -sh "$OUT" | cut -f1), $(ls "$OUT/bin" | wc -l) files in bin)"
