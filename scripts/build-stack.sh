#!/usr/bin/env bash
# Builds remote-viewer (virt-viewer) and every library it needs, from source,
# into build/<arch>/prefix. Re-running skips steps that already succeeded;
# delete build/<arch>/stamps/<name> to force a rebuild of one component.
#
# Usage: scripts/build-stack.sh [step...]     (no args = everything)

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"

# ---------------------------------------------------------------------------
# Pinned sources (URL + SHA-256). Bump versions here.
# ---------------------------------------------------------------------------
PKGCONF=(https://distfiles.ariadne.space/pkgconf/pkgconf-3.0.11.tar.xz d0cd841bc8e55b9da888106c00dc256d05b7d1d8e5a46f4be4eb4c5125bd2dc4)
BISON=(https://ftpmirror.gnu.org/bison/bison-3.8.2.tar.xz 9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2)
NASM=(https://www.nasm.us/pub/nasm/releasebuilds/3.02/nasm-3.02.tar.xz 87336eba53b4acfe917424ab5d500d2b0054d9f5148d35c2273ccf2cfb712f0d)
RUSTUP_VERSION=1.29.3
CARGO_C_VERSION=0.10.26
PY_TOOLS=(meson==1.12.1 ninja==1.13.0 cmake==4.1.2 pyparsing==3.2.5 six==1.17.0 packaging docutils)

LIBFFI=(https://github.com/libffi/libffi/releases/download/v3.8.1/libffi-3.8.1.tar.gz 81e879c094cc5ec3186c48510c6385ac6b3e866192e8bc71a35245703757ee40)
GETTEXT=(https://ftpmirror.gnu.org/gettext/gettext-1.0.tar.gz 85d99b79c981a404874c02e0342176cf75c7698e2b51fe41031cf6526d974f1a)
PCRE2=(https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.bz2 53c156e1ba416a20da8e65395daa132da0d80e76910424caca3fcdae7831d384)
GLIB=(https://download.gnome.org/sources/glib/2.90/glib-2.90.1.tar.xz 93c941aa17d5eb1d53fe838365f29a8b4e539c222a256d974ec8f30fc413e396)
LIBPNG=(https://downloads.sourceforge.net/project/libpng/libpng16/1.6.59/libpng-1.6.59.tar.xz d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389)
JPEG=(https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.1/libjpeg-turbo-3.2.1.tar.gz c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f)
EXPAT=(https://github.com/libexpat/libexpat/releases/download/R_2_10_0/expat-2.10.0.tar.xz c624ba2998fc65df1163a49641ff3f9ab73138b11641d92c86bee0fb01b1bc7f)
FREETYPE=(https://downloads.sourceforge.net/project/freetype/freetype2/2.15.0/freetype-2.15.0.tar.xz 93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5)
FONTCONFIG=(https://gitlab.freedesktop.org/fontconfig/fontconfig/-/archive/2.18.4/fontconfig-2.18.4.tar.gz cecf4125622ed674d5630b6deaeff43e3695afe197bdcc560363a1820d858112)
PIXMAN=(https://cairographics.org/releases/pixman-0.46.4.tar.gz d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c)
FRIBIDI=(https://github.com/fribidi/fribidi/releases/download/v1.0.18/fribidi-1.0.18.tar.xz 1de5e8073d035388b71d0b2d452b1da1f8caeea8a7702997b401fe1b6250727f)
HARFBUZZ=(https://github.com/harfbuzz/harfbuzz/releases/download/15.1.0/harfbuzz-15.1.0.tar.xz 0fc7c565443a5f4be7da65ac5ee5bd737d9b158dc908708b7689a0a5796b0c8d)
CAIRO=(https://cairographics.org/releases/cairo-1.18.6.tar.xz 1c767308174337a74694da0f3ec069c271452163a1ef4540964c50c301f157d4)
PANGO=(https://download.gnome.org/sources/pango/1.58/pango-1.58.2.tar.xz 342385b6ca3b7c73455d7c80a13b7dbe4489e00bc3bd4c5bd6ed4dce421e374a)
GDK_PIXBUF=(https://download.gnome.org/sources/gdk-pixbuf/2.44/gdk-pixbuf-2.44.8.tar.xz 919f529512961a12e81cd4b4b466a48c3933469e7f9a310c6513cd4fb252ba3c)
LIBRSVG=(https://download.gnome.org/sources/librsvg/2.63/librsvg-2.63.4.tar.xz 31f07d9350dad3f8964fd613c31309ac160fdef13dfac59df6fd082de78d6e8f)
LIBEPOXY=(https://download.gnome.org/sources/libepoxy/1.5/libepoxy-1.5.10.tar.xz 072cda4b59dd098bba8c2363a6247299db1fa89411dc221c8b81b8ee8192e623)
ATSPI=(https://download.gnome.org/sources/at-spi2-core/2.62/at-spi2-core-2.62.1.tar.xz cca6b6a86e4389d89b370288761ce2385ddeceb10c4412da78689bc30c88af2d)
GTK3=(https://download.gnome.org/sources/gtk/3.24/gtk-3.24.52.tar.xz 80931fa472a77b9a164f6740e3c0b444fac6770054632d35a7ff9d679e5e7b9f)
HICOLOR=(https://icon-theme.freedesktop.org/releases/hicolor-icon-theme-0.18.tar.xz db0e50a80aa3bf64bb45cbca5cf9f75efd9348cf2ac690b907435238c3cf81d7)
ADWAITA=(https://download.gnome.org/sources/adwaita-icon-theme/51/adwaita-icon-theme-51.0.tar.xz ba561cf3c96305a47179fa5605856ad695c9238ea07f7093aebd9ba80c4e323b)
LIBXML2=(https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.4.tar.xz 98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821)
JSON_GLIB=(https://download.gnome.org/sources/json-glib/1.10/json-glib-1.10.8.tar.xz 55c5c141a564245b8f8fbe7698663c87a45a7333c2a2c56f06f811ab73b212dd)
OPENSSL=(https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a)
OPUS=(https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1)
LZ4=(https://github.com/lz4/lz4/archive/refs/tags/v1.11.1.tar.gz 683fed08a844ad012196381e40badf80c0bbe4962959761416d41c9e67d77ec7 lz4-1.11.1.tar.gz)
GSTREAMER=(https://gitlab.freedesktop.org/gstreamer/gstreamer/-/archive/1.28.9/gstreamer-1.28.9.tar.bz2 6f4074f5bdd071a074220a3642b5861410aa6929c179d903feff4af82d9a05d7)
SPICE_PROTOCOL=(https://www.spice-space.org/download/releases/spice-protocol-0.14.5.tar.xz baf58449f6e89d19f475899ad5fb9196fdc46c03cc53233f4e39cf2978f9cff7)
SPICE_GTK=(https://www.spice-space.org/download/gtk/spice-gtk-0.43.tar.xz cee26e5b2d22909f35b40a94398d1e863ca3962ee46494ca97aab206abc3203b)
# virt-viewer's last tag (11.0) is from 2021; master has years of GTK/meson fixes.
VIRT_VIEWER_GIT=https://gitlab.com/virt-viewer/virt-viewer.git
VIRT_VIEWER_COMMIT=a634fa8d9fbc59b093f2f07110b2c867f622599d

# ---------------------------------------------------------------------------
# Host tools (installed into $TOOLS, never shipped)
# ---------------------------------------------------------------------------
tool_pkgconf() {
    local s; s=$(unpack "$(fetch "${PKGCONF[@]}")" pkgconf)
    cd "$s" && ./configure --prefix="$TOOLS" --disable-shared \
        --with-system-libdir=/usr/lib --with-system-includedir="$SDKROOT/usr/include"
    make -j "$JOBS" && make install
}

tool_bison() {
    local s; s=$(unpack "$(fetch "${BISON[@]}")" bison)
    cd "$s" && ./configure --prefix="$TOOLS" --disable-nls
    make -j "$JOBS" && make install
}

tool_nasm() {
    local s; s=$(unpack "$(fetch "${NASM[@]}")" nasm)
    cd "$s" && ./configure --prefix="$TOOLS"
    make -j "$JOBS" && make install
}

tool_python() {
    # Any Python >= 3.10 will do: it only runs build tools and is never shipped.
    local py="" c
    for c in "${PYTHON:-}" /opt/homebrew/bin/python3 /usr/local/bin/python3 \
             /Library/Frameworks/Python.framework/Versions/Current/bin/python3 /usr/bin/python3; do
        [[ -n "$c" && -x "$c" ]] || continue
        if "$c" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then py="$c"; break; fi
    done
    [[ -n "$py" ]] || die "need Python >= 3.10 (set PYTHON=/path/to/python3)"
    rm -rf "$TOOLS/venv"
    "$py" -m venv "$TOOLS/venv"
    "$TOOLS/venv/bin/pip" install --upgrade --quiet pip
    "$TOOLS/venv/bin/pip" install --quiet "${PY_TOOLS[@]}"
}

tool_rust() {
    local triple
    case "$ARCH" in arm64) triple=aarch64-apple-darwin ;; *) triple=x86_64-apple-darwin ;; esac
    local base="https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/$triple/rustup-init"
    local sha; sha=$(curl -fsSL "$base.sha256" | cut -d' ' -f1)
    local init; init=$(fetch "$base" "$sha" "rustup-init-$RUSTUP_VERSION-$triple")
    chmod +x "$init"
    "$init" -y --no-modify-path --profile minimal --default-toolchain stable
    cargo --version
}

tool_cargo_c() {
    # librsvg builds its C library with cargo-c. Host tool: don't leak our target flags in.
    env -u CFLAGS -u LDFLAGS -u CPPFLAGS cargo install --locked --version "$CARGO_C_VERSION" cargo-c
}

# ---------------------------------------------------------------------------
# Libraries (installed into $PREFIX, shipped in the app)
# ---------------------------------------------------------------------------
# zlib comes with macOS, but without the zlib.pc that pkg-config users expect.
lib_zlib_pc() {
    local v; v=$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$SDKROOT/usr/include/zlib.h")
    mkdir -p "$PREFIX/lib/pkgconfig"
    cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<PC
Name: zlib
Description: zlib compression library (macOS SDK)
Version: $v
Libs: -lz
Cflags:
PC
}

lib_libffi() {
    local s; s=$(unpack "$(fetch "${LIBFFI[@]}")" libffi)
    autotools_build "$s" --disable-docs --disable-multi-os-directory
}

lib_gettext() {
    local s; s=$(unpack "$(fetch "${GETTEXT[@]}")" gettext)
    # macOS' iconv fails gettext's self-test since Sonoma (savannah bug #66541),
    # although it works fine for gettext's purposes. Same workaround as Homebrew.
    export am_cv_func_iconv_works=yes
    export CFLAGS="$CFLAGS -Wno-incompatible-function-pointer-types"
    autotools_build "$s" --with-included-gettext --disable-java --disable-csharp --disable-openmp \
        --disable-curses --disable-acl --disable-libasprintf \
        --without-emacs --without-git --without-cvs --without-xz --without-bzip2 \
        --with-included-glib --with-included-libcroco \
        --with-included-libunistring --with-included-libxml \
        --without-libiconv-prefix
}

lib_pcre2() {
    local s; s=$(unpack "$(fetch "${PCRE2[@]}")" pcre2)
    # JIT needs the MAP_JIT entitlement on Apple Silicon; GLib works fine without it.
    autotools_build "$s" --disable-jit --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32
}

lib_glib() {
    local s; s=$(unpack "$(fetch "${GLIB[@]}")" glib)
    meson_build "$s" -Dtests=false -Dintrospection=disabled -Dman-pages=disabled \
        -Ddocumentation=false -Dsysprof=disabled -Dlibelf=disabled -Dnls=enabled
}

lib_libpng() {
    local s; s=$(unpack "$(fetch "${LIBPNG[@]}")" libpng)
    autotools_build "$s"
}

lib_jpeg() {
    local s; s=$(unpack "$(fetch "${JPEG[@]}")" libjpeg-turbo)
    cmake_build "$s" -DENABLE_STATIC=OFF -DWITH_JPEG8=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
}

lib_expat() {
    local s; s=$(unpack "$(fetch "${EXPAT[@]}")" expat)
    autotools_build "$s" --without-docbook --without-examples --without-tests
}

lib_freetype() {
    local s; s=$(unpack "$(fetch "${FREETYPE[@]}")" freetype)
    autotools_build "$s" --with-png=yes --with-zlib=yes --without-harfbuzz \
        --without-brotli --without-bzip2
}

lib_fontconfig() {
    local s; s=$(unpack "$(fetch "${FONTCONFIG[@]}")" fontconfig)
    meson_build "$s" -Ddoc=disabled -Dtests=disabled -Dtools=disabled \
        -Dcache-build=disabled -Dnls=disabled -Dxml-backend=expat
}

lib_pixman() {
    local s; s=$(unpack "$(fetch "${PIXMAN[@]}")" pixman)
    meson_build "$s" -Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dlibpng=disabled
}

lib_fribidi() {
    local s; s=$(unpack "$(fetch "${FRIBIDI[@]}")" fribidi)
    meson_build "$s" -Ddocs=false -Dtests=false -Dbin=false
}

lib_harfbuzz() {
    local s; s=$(unpack "$(fetch "${HARFBUZZ[@]}")" harfbuzz)
    meson_build "$s" -Dcoretext=enabled -Dfreetype=enabled -Dglib=enabled \
        -Dgobject=disabled -Dcairo=disabled -Dicu=disabled -Dtests=disabled \
        -Ddocs=disabled -Dintrospection=disabled -Dutilities=disabled -Dbenchmark=disabled
}

lib_cairo() {
    local s; s=$(unpack "$(fetch "${CAIRO[@]}")" cairo)
    meson_build "$s" -Dquartz=enabled -Dxlib=disabled -Dxcb=disabled \
        -Dfreetype=enabled -Dfontconfig=enabled -Dpng=enabled -Dglib=enabled \
        -Dtee=disabled -Dtests=disabled -Dspectre=disabled -Dsymbol-lookup=disabled \
        -Dlzo=disabled -Dgtk_doc=false
}

lib_pango() {
    local s; s=$(unpack "$(fetch "${PANGO[@]}")" pango)
    meson_build "$s" -Dintrospection=disabled -Dfontconfig=enabled -Dfreetype=enabled \
        -Dcairo=enabled -Dbuild-testsuite=false -Dbuild-examples=false \
        -Ddocumentation=false -Dman-pages=false
}

lib_gdk_pixbuf() {
    local s; s=$(unpack "$(fetch "${GDK_PIXBUF[@]}")" gdk-pixbuf)
    meson_build "$s" -Dpng=enabled -Djpeg=enabled -Dtiff=disabled -Dgif=disabled \
        -Dothers=disabled -Dbuiltin_loaders=png,jpeg -Dintrospection=disabled \
        -Dman=false -Ddocumentation=false -Dtests=false -Dinstalled_tests=false \
        -Dglycin=disabled -Dthumbnailer=disabled
}

lib_librsvg() {
    local s; s=$(unpack "$(fetch "${LIBRSVG[@]}")" librsvg)
    meson_build "$s" -Dintrospection=disabled -Dpixbuf=enabled -Dpixbuf-loader=enabled \
        -Dvala=disabled -Ddocs=disabled -Dtests=false -Davif=disabled
}

lib_libepoxy() {
    local s; s=$(unpack "$(fetch "${LIBEPOXY[@]}")" libepoxy)
    meson_build "$s" -Dtests=false -Dglx=no -Degl=no -Dx11=false
}

lib_atk() {
    local s; s=$(unpack "$(fetch "${ATSPI[@]}")" at-spi2-core)
    # Only ATK: the D-Bus accessibility bridge is X11/Wayland-only.
    meson_build "$s" -Datk_only=true -Dx11=disabled -Dintrospection=disabled -Ddocs=false
}

lib_gtk3() {
    local s; s=$(unpack "$(fetch "${GTK3[@]}")" gtk3)
    apply_patches gtk3 "$s"
    meson_build "$s" -Dx11_backend=false -Dwayland_backend=false -Dquartz_backend=true \
        -Dintrospection=false -Ddemos=false -Dexamples=false -Dtests=false \
        -Dinstalled_tests=false -Dgtk_doc=false -Dman=false \
        -Dprint_backends=file -Dcolord=no -Dcloudproviders=false -Dtracker3=false
}

lib_icon_themes() {
    local s
    s=$(unpack "$(fetch "${HICOLOR[@]}")" hicolor-icon-theme)
    meson_build "$s"
    s=$(unpack "$(fetch "${ADWAITA[@]}")" adwaita-icon-theme)
    meson_build "$s"
}

lib_libxml2() {
    local s; s=$(unpack "$(fetch "${LIBXML2[@]}")" libxml2)
    meson_build "$s" -Dpython=disabled -Dhistory=disabled -Dreadline=disabled \
        -Dicu=disabled -Dzlib=disabled -Ddocs=disabled
}

lib_json_glib() {
    local s; s=$(unpack "$(fetch "${JSON_GLIB[@]}")" json-glib)
    meson_build "$s" -Dintrospection=disabled -Ddocumentation=disabled -Dman=false \
        -Dtests=false -Dconformance=false -Dnls=disabled
}

lib_openssl() {
    local s; s=$(unpack "$(fetch "${OPENSSL[@]}")" openssl)
    local target; case "$ARCH" in arm64) target=darwin64-arm64-cc ;; *) target=darwin64-x86_64-cc ;; esac
    cd "$s"
    # Configure adds its own -arch; drop ours from CFLAGS to avoid duplicates.
    CFLAGS="-isysroot $SDKROOT -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2" \
    LDFLAGS="-Wl,-headerpad_max_install_names" \
        ./Configure "$target" --prefix="$PREFIX" --libdir=lib --openssldir="$PREFIX/etc/ssl" \
        shared no-tests no-docs no-apps no-legacy
    make -j "$JOBS"
    make install_sw
}

lib_opus() {
    local s; s=$(unpack "$(fetch "${OPUS[@]}")" opus)
    autotools_build "$s" --disable-doc --disable-extra-programs
}

lib_lz4() {
    local s; s=$(unpack "$(fetch "${LZ4[@]}")" lz4)
    make -C "$s/lib" -j "$JOBS" PREFIX="$PREFIX" BUILD_STATIC=no \
        MOREFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
    make -C "$s/lib" install PREFIX="$PREFIX" BUILD_STATIC=no
}

# GStreamer is only used by spice-gtk for audio playback/recording and for
# hardware video decoding (applemedia/VideoToolbox, which needs libgstgl),
# so we build a deliberately small plugin set.
lib_gstreamer() {
    local s; s=$(unpack "$(fetch "${GSTREAMER[@]}")" gstreamer)
    local base=(-Dauto_features=disabled -Dnls=disabled -Dexamples=disabled -Dtests=disabled -Ddoc=disabled)
    local common=("${base[@]}" -Dintrospection=disabled)
    meson_build "$s/subprojects/gstreamer" "${common[@]}" -Dtools=enabled \
        -Dbenchmarks=disabled -Dcheck=enabled -Dgst_parse=true -Dregistry=true \
        -Dptp-helper=disabled -Dbash-completion=disabled -Dlibunwind=disabled -Dlibdw=disabled
    meson_build "$s/subprojects/gst-plugins-base" "${common[@]}" -Dtools=enabled \
        -Dapp=enabled -Daudioconvert=enabled -Daudioresample=enabled -Dplayback=enabled \
        -Dtypefind=enabled -Dvideoconvertscale=enabled -Dvolume=enabled -Daudiotestsrc=enabled \
        -Dorc=disabled -Dgl=enabled -Dgl_api=opengl -Dgl_platform=cgl -Dgl_winsys=cocoa \
        -Dgl-graphene=disabled -Dgl-png=disabled -Dgl-jpeg=disabled
    # gst-plugins-good has no introspection option.
    meson_build "$s/subprojects/gst-plugins-good" "${base[@]}" \
        -Dosxaudio=enabled -Dautodetect=enabled -Djpeg=enabled
    meson_build "$s/subprojects/gst-plugins-bad" "${common[@]}" \
        -Dapplemedia=enabled -Dvideoparsers=enabled -Dgl=enabled
}

lib_spice_protocol() {
    local s; s=$(unpack "$(fetch "${SPICE_PROTOCOL[@]}")" spice-protocol)
    meson_build "$s"
}

lib_spice_gtk() {
    local s; s=$(unpack "$(fetch "${SPICE_GTK[@]}")" spice-gtk)
    apply_patches spice-gtk "$s"
    # CoreGraphics: relative mouse patch (CGAssociateMouseAndMouseCursorPosition).
    LDFLAGS="$LDFLAGS -framework CoreGraphics" meson_build "$s" -Dgtk=enabled -Dwebdav=disabled -Dusbredir=disabled \
        -Dsmartcard=disabled -Dpolkit=disabled -Dsasl=disabled -Dlz4=enabled \
        -Dopus=enabled -Dintrospection=disabled -Dvapi=disabled -Dgtk_doc=disabled \
        -Dlibcap-ng=disabled -Dwayland-protocols=disabled -Dcoroutine=gthread -Dpie=false
}

lib_virt_viewer() {
    local s; s=$(git_checkout "$VIRT_VIEWER_GIT" "$VIRT_VIEWER_COMMIT" virt-viewer)
    apply_patches virt-viewer "$s"
    meson_build "$s" -Dlibvirt=disabled -Dvte=disabled -Dovirt=disabled \
        -Dvnc=disabled -Dspice=enabled -Dbash_completion=disabled
}

# ---------------------------------------------------------------------------
STEPS=(
    tool_pkgconf tool_bison tool_python tool_rust tool_cargo_c
    lib_zlib_pc lib_libffi lib_gettext lib_pcre2 lib_glib
    lib_libpng lib_jpeg lib_expat lib_freetype lib_fontconfig
    lib_pixman lib_fribidi lib_harfbuzz lib_cairo lib_pango
    lib_gdk_pixbuf lib_libxml2 lib_librsvg lib_libepoxy lib_atk lib_gtk3 lib_icon_themes
    lib_json_glib lib_openssl lib_opus lib_lz4
    lib_gstreamer lib_spice_protocol lib_spice_gtk lib_virt_viewer
)
[[ "$ARCH" == x86_64 ]] && STEPS=(tool_nasm "${STEPS[@]}")

msg "Building for $ARCH (macOS >= $MACOSX_DEPLOYMENT_TARGET) into $PREFIX"
if (( $# )); then STEPS=("$@"); fi
for s in "${STEPS[@]}"; do
    step "$s" "$s"
done
msg "Stack ready: $PREFIX/bin/remote-viewer"
