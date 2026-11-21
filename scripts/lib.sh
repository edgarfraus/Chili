# shellcheck shell=bash
# Helpers shared by the build scripts: fetch + verify + unpack sources,
# and run meson / autotools / cmake builds with logging and stamps.

msg()  { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# fetch URL SHA256 [FILENAME] -> prints local path
fetch() {
    local url="$1" sha="$2" file="${3:-$(basename "${1%%\?*}")}"
    local dest="$SOURCES_DIR/$file"
    if [[ ! -f "$dest" ]]; then
        curl -fL --retry 3 --retry-delay 2 -o "$dest.part" "$url" >&2 || die "download failed: $url"
        mv "$dest.part" "$dest"
    fi
    local got
    got="$(shasum -a 256 "$dest" | cut -d' ' -f1)"
    if [[ "$got" != "$sha" ]]; then
        rm -f "$dest"
        die "checksum mismatch for $file: expected $sha, got $got"
    fi
    echo "$dest"
}

# unpack TARBALL NAME -> prints source dir (fresh copy every time)
unpack() {
    local tarball="$1" name="$2"
    local dir="$WORK_DIR/$name"
    rm -rf "$dir" && mkdir -p "$dir"
    tar -xf "$tarball" -C "$dir" --strip-components 1
    echo "$dir"
}

# git_checkout URL COMMIT NAME -> prints source dir
git_checkout() {
    local url="$1" commit="$2" name="$3"
    local dir="$WORK_DIR/$name"
    rm -rf "$dir" && mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" fetch -q --depth 1 "$url" "$commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    echo "$dir"
}

# apply_patches NAME SRCDIR: applies patches/NAME/*.patch in order
apply_patches() {
    local name="$1" src="$2" p
    for p in "$REPO_ROOT/patches/$name"/*.patch; do
        [[ -e "$p" ]] || continue
        msg "  patch $(basename "$p")"
        patch -d "$src" -p1 --forward --quiet < "$p" || die "patch failed: $p"
    done
}

done_already() { [[ -f "$STAMPS/$1" ]]; }
mark_done()    { touch "$STAMPS/$1"; }

# step NAME FUNCTION: runs FUNCTION once, logging to $LOGS/NAME.log
step() {
    local name="$1" fn="$2"
    if done_already "$name"; then
        echo "    $name (cached)"
        return
    fi
    msg "Building $name"
    local log="$LOGS/$name.log" start=$SECONDS
    # Not inside `if`: there bash would silently disable `set -e` for the whole step.
    local rc=0
    set +e
    ( set -euo pipefail; "$fn" ) >"$log" 2>&1
    rc=$?
    set -e
    if (( rc == 0 )); then
        mark_done "$name"
        echo "    done in $((SECONDS - start))s"
    else
        echo "---- last 60 lines of $log ----" >&2
        tail -n 60 "$log" >&2
        die "$name failed (full log: $log)"
    fi
}

meson_build() {
    local src="$1"; shift
    local bld="$src/_build"
    meson setup "$bld" "$src" \
        --prefix="$PREFIX" --libdir=lib --buildtype=release \
        --wrap-mode=nofallback -Ddefault_library=shared \
        "$@"
    meson compile -C "$bld" -j "$JOBS"
    meson install -C "$bld"
}

autotools_build() {
    local src="$1"; shift
    (
        cd "$src"
        ./configure --prefix="$PREFIX" --disable-static --enable-shared "$@"
        make -j "$JOBS"
        make install
    )
}

cmake_build() {
    local src="$1"; shift
    cmake -S "$src" -B "$src/_build" -G Ninja \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_OSX_SYSROOT="$SDKROOT" \
        -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
        "$@"
    cmake --build "$src/_build" -j "$JOBS"
    cmake --install "$src/_build"
}
