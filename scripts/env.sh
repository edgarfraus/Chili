# shellcheck shell=bash
# Common environment for every build step. Source it, don't execute it.
#
# The whole stack is built from source into $PREFIX with an explicit SDK
# sysroot, so nothing from Homebrew/MacPorts (/usr/local, /opt/homebrew,
# /opt/local) can leak into the final app bundle.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

export ARCH="${ARCH:-$(uname -m)}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

export BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/build}"
export SOURCES_DIR="$BUILD_ROOT/sources"          # downloaded tarballs (shared between arches)
export WORK_DIR="$BUILD_ROOT/$ARCH/work"          # unpacked sources + build trees
export PREFIX="$BUILD_ROOT/$ARCH/prefix"          # everything that ends up in the app
export TOOLS="$BUILD_ROOT/$ARCH/tools"            # host-only build tools
export STAMPS="$BUILD_ROOT/$ARCH/stamps"
export LOGS="$BUILD_ROOT/$ARCH/logs"
export DIST_DIR="$REPO_ROOT/dist"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT

export JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# Isolated PATH: our prefix, our tools, then only the base system.
export PATH="$PREFIX/bin:$TOOLS/venv/bin:$TOOLS/bin:$TOOLS/cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export RUSTUP_HOME="$TOOLS/rustup"
export CARGO_HOME="$TOOLS/cargo"

COMMON_FLAGS="-arch $ARCH -isysroot $SDKROOT -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CC="/usr/bin/clang"
export CXX="/usr/bin/clang++"
export OBJC="/usr/bin/clang"
export CFLAGS="$COMMON_FLAGS -O2"
export CXXFLAGS="$COMMON_FLAGS -O2"
export OBJCFLAGS="$COMMON_FLAGS -O2"
export CPPFLAGS="-I$PREFIX/include"
# headerpad leaves room for install_name_tool to rewrite paths when bundling.
export LDFLAGS="$COMMON_FLAGS -L$PREFIX/lib -Wl,-headerpad_max_install_names"

export PKG_CONFIG="$TOOLS/bin/pkgconf"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
unset PKG_CONFIG_PATH

# Keep CMake away from Homebrew/MacPorts too.
export CMAKE_PREFIX_PATH="$PREFIX"
export CMAKE_IGNORE_PREFIX_PATH="/usr/local;/opt/homebrew;/opt/local"

mkdir -p "$SOURCES_DIR" "$WORK_DIR" "$PREFIX" "$TOOLS/bin" "$STAMPS" "$LOGS"
