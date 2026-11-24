#!/usr/bin/env bash
# Prints the versions of the main bundled components ("<label><TAB><version>" per line), read from the
# pinned sources in build-stack.sh. bundle-app.sh saves it as Chili.app/Contents/Resources/COMPONENTS.txt
# for the Info page.
set -euo pipefail
stack="$(dirname "$0")/build-stack.sh"

version() {  # version VAR: the version in the tarball name of VAR=(url sha [name])
    grep -E "^$1=\(" "$stack" | head -1 | sed -E 's|^[^(]*\(([^ ]+).*|\1|; s|.*/||; s|\.tar\..*||; s|^.*-([0-9][0-9.]*)$|\1|'
}

printf '%s\t%s\n' \
    "spice-gtk (SPICE)" "$(version SPICE_GTK)" \
    "virt-viewer (remote-viewer)" "git $(grep -E '^VIRT_VIEWER_COMMIT=' "$stack" | cut -d= -f2 | cut -c1-8)" \
    "GStreamer" "$(version GSTREAMER)" \
    "GTK" "$(version GTK3)" \
    "GLib" "$(version GLIB)" \
    "OpenSSL" "$(version OPENSSL)"
