#!/usr/bin/env bash
# Bundles the exact upstream sources, our patches and build scripts into one
# tarball, published next to the DMGs to satisfy the GPL/LGPL source offer.
#
# Works on its own: CI restores the built stack from a cache that holds neither the
# downloaded tarballs nor the unpacked sources, so everything pinned in build-stack.sh
# is fetched (and checksum-verified) here again.
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"

VERSION="$(cat "$REPO_ROOT/VERSION")"
name="Chili-$VERSION-sources"
stage="$BUILD_ROOT/$name"
rm -rf "$stage" && mkdir -p "$stage/upstream"

# Every "NAME=(URL SHA256 [FILENAME])" line of build-stack.sh is a pinned source.
stack="$REPO_ROOT/scripts/build-stack.sh"
count=0
while IFS= read -r line; do
    eval "entry=${line#*=}"
    # shellcheck disable=SC2154  # set by eval
    cp "$(fetch "${entry[@]}")" "$stage/upstream/"
    count=$((count + 1))
done < <(grep -E '^[A-Z0-9_]+=\(https?://' "$stack")
(( count > 0 )) || die "no pinned sources found in $stack"

# virt-viewer is built from a git commit: export it as a tarball too.
url="$(sed -n 's/^VIRT_VIEWER_GIT=//p' "$stack")"
commit="$(sed -n 's/^VIRT_VIEWER_COMMIT=//p' "$stack")"
src="$WORK_DIR/virt-viewer"
if [[ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" != "$commit" ]]; then
    src="$(git_checkout "$url" "$commit" virt-viewer)"
fi
git -C "$src" archive --format=tar.gz --prefix="virt-viewer-$commit/" HEAD \
    > "$stage/upstream/virt-viewer-$commit.tar.gz"

git -C "$REPO_ROOT" archive --format=tar --prefix="Chili/" HEAD | tar -x -C "$stage"
mkdir -p "$DIST_DIR"
tar -cf "$DIST_DIR/$name.tar" -C "$BUILD_ROOT" "$name"
rm -rf "$stage"
msg "Done: $DIST_DIR/$name.tar ($count upstream tarballs + virt-viewer $commit)"
