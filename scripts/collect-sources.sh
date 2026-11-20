#!/usr/bin/env bash
# Bundles the exact upstream sources, our patches and build scripts into one
# tarball, published next to the DMGs to satisfy the GPL/LGPL source offer.
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"

VERSION="$(cat "$REPO_ROOT/VERSION")"
name="Chili-$VERSION-sources"
stage="$BUILD_ROOT/$name"
rm -rf "$stage" && mkdir -p "$stage/upstream"
cp "$SOURCES_DIR"/*.tar.* "$SOURCES_DIR"/*.tgz "$stage/upstream/" 2>/dev/null || true
# virt-viewer is built from a git commit: export it as a tarball too.
commit="$(sed -n 's/^VIRT_VIEWER_COMMIT=//p' "$REPO_ROOT/scripts/build-stack.sh")"
git -C "$WORK_DIR/virt-viewer" archive --format=tar.gz --prefix="virt-viewer-$commit/" HEAD \
    > "$stage/upstream/virt-viewer-$commit.tar.gz"
git -C "$REPO_ROOT" archive --format=tar --prefix="chili-spice-macos/" HEAD | tar -x -C "$stage"
tar -cf "$DIST_DIR/$name.tar" -C "$BUILD_ROOT" "$name"
rm -rf "$stage"
msg "Done: $DIST_DIR/$name.tar"
