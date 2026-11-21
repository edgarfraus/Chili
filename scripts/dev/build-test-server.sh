#!/usr/bin/env bash
# Development helper: builds spice-server's demo server (test-display-no-ssl)
# against the stack in build/<arch>/prefix, to test the client without a VM.
#   scripts/dev/build-test-server.sh && build/<arch>/devtools/test-input-server
# Listens on port 5912 (no password), draws animated content and prints the
# keyboard/mouse events it receives.
source "$(dirname "$0")/../env.sh"
source "$(dirname "$0")/../lib.sh"

SPICE_SERVER=(https://gitlab.freedesktop.org/-/project/62/uploads/54a0f9f5d1840e1ad8060cb560f3dde6/spice-0.16.0.tar.bz2 0a6ec9528f05371261bbb2d46ff35e7b5c45ff89bb975a99af95a5f20ff4717d)
DEV="$BUILD_ROOT/$ARCH/devtools"
mkdir -p "$DEV"

s=$(unpack "$(fetch "${SPICE_SERVER[@]}")" spice-server)
cd "$s"
ac_cv_path_GST_INSPECT_1_0= ./configure --prefix="$DEV" --disable-static --enable-shared \
    --disable-celt051 --disable-smartcard --disable-manual --enable-gstreamer=no
make -j "$JOBS"
# Our instrumented server replaces the stock demo program's source.
cp "$REPO_ROOT/scripts/dev/test-input-server.c" server/tests/test-display-no-ssl.c
make -C server/tests -j "$JOBS" test-display-no-ssl
cp server/tests/test-display-no-ssl "$DEV/test-input-server"
msg "Test server: $DEV/test-input-server [server]  (port 5912)"
