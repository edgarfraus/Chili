#!/usr/bin/env bash
# Packs dist/<arch>/Chili.app into a drag-to-install DMG.
# Uses dmgbuild (pure Python), so it also works headless on CI.
# Set NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile) to notarize.
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"

VERSION="$(cat "$REPO_ROOT/VERSION")"
APP="$DIST_DIR/$ARCH/Chili.app"
DMG="$DIST_DIR/Chili-$VERSION-$ARCH.dmg"
[[ -d "$APP" ]] || die "app not found: run scripts/bundle-app.sh first"

"$TOOLS/venv/bin/pip" install --quiet "dmgbuild==2.0.0"

msg "Creating $(basename "$DMG")"
rm -f "$DMG"
"$TOOLS/venv/bin/dmgbuild" -s "$REPO_ROOT/resources/dmg-settings.py" \
    -D app="$APP" -D background="$REPO_ROOT/resources/dmg-background.tiff" \
    -D icon="$REPO_ROOT/resources/AppIcon.icns" \
    "Chili" "$DMG"

if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    msg "Notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
msg "Done: $DMG"
