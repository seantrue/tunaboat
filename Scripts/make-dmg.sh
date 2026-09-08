#!/bin/bash
# Packages Tunaboat.app into a distributable disk image with a drag-to-Applications target.
#
#   Scripts/make-dmg.sh [--skip-build] [--notarize] [--profile NAME]
#
#   (no flag)      builds and Developer ID signs the app, then makes a signed .dmg
#   --notarize     …then submits the .dmg to Apple, staples it, and verifies with Gatekeeper
#   --skip-build   use the existing .build/Tunaboat.app as-is (it must already be signed)
#
# Output: .build/Tunaboat-<version>.dmg
#
# The app inside should itself be notarized and stapled before it is packaged, so that a copy
# dragged out of the image validates offline on a machine that has never seen it. Run
# `Scripts/bundle-app.sh release --notarize` first, or let this script's default build do the
# signing and pass --notarize here to cover the image.
#
# No credentials live in this repo — see Scripts/bundle-app.sh for the signing setup.
set -euo pipefail

SKIP_BUILD=0
NOTARIZE=0
NOTARY_PROFILE="${TUNABOAT_NOTARY_PROFILE:-tunaboat-notary}"
TEAM_ID="${TUNABOAT_TEAM_ID:-78DGVG7MYU}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --notarize)   NOTARIZE=1; shift ;;
        --profile)    NOTARY_PROFILE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP=".build/Tunaboat.app"
IDENTITY="Developer ID Application: Sean True ($TEAM_ID)"
VOLNAME="Tunaboat"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    "$ROOT/Scripts/bundle-app.sh" release --sign --universal
fi

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found — run Scripts/bundle-app.sh release --sign" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG=".build/Tunaboat-${VERSION}.dmg"
STAGE=".build/dmg-stage"

# An unsigned app in a signed image is a trap: the image validates and the app it installs
# does not. Fail here rather than shipping it.
if ! codesign --verify --strict "$APP" 2>/dev/null; then
    echo "error: $APP is not validly signed; refusing to package it" >&2
    exit 1
fi
# An image handed to someone else must run on their Mac, not just on the build machine.
ARCHS_IN_APP="$(lipo -archs "$APP/Contents/MacOS/Tunaboat")"
echo "==> app architectures: $ARCHS_IN_APP"
if ! echo "$ARCHS_IN_APP" | grep -q x86_64; then
    echo "    warning: this image is Apple-silicon only and will not launch on an Intel Mac."
    echo "    Build with: Scripts/bundle-app.sh release --notarize --universal"
fi

if xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "==> app is notarized and stapled"
else
    echo "==> note: the app carries no stapled ticket, so a copy dragged out of this image"
    echo "    will need an online check on first launch. Run"
    echo "    Scripts/bundle-app.sh release --notarize first to avoid that."
fi

echo "==> staging $VOLNAME $VERSION"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
# ditto rather than cp -R: it preserves the extended attributes and the signature seal.
ditto "$APP" "$STAGE/Tunaboat.app"
# The drag target. A symlink, so the image stays small and the drop lands in the real
# /Applications on whatever machine mounts it.
ln -s /Applications "$STAGE/Applications"

# A read/write image first, so Finder can record the window layout into it; converted to a
# compressed read-only image at the end.
RW_DMG=".build/Tunaboat-rw.dmg"
rm -f "$RW_DMG"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -ov "$RW_DMG" >/dev/null

echo "==> laying out the window"
MOUNT_DIR="/Volumes/$VOLNAME"
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noverify >/dev/null

# Finder scripting needs an Automation permission and a real GUI session; when it is refused
# the image is still perfectly usable, just without the arranged icons. Never fatal.
if ! osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 160, 840, 560}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 96
        set position of item "Tunaboat.app" of container window to {160, 200}
        set position of item "Applications" of container window to {480, 200}
        update without registering applications
        close
    end tell
end tell
APPLESCRIPT
then
    echo "    (Finder declined to arrange the icons — the image still works, and the"
    echo "     Applications drop target is present. Grant Automation access to arrange it.)"
fi

sync
hdiutil detach "$MOUNT_DIR" >/dev/null || hdiutil detach "$MOUNT_DIR" -force >/dev/null

echo "==> compressing"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGE"

echo "==> signing the image"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG" 2>&1 | sed 's/^/    /'

if [[ "$NOTARIZE" -eq 0 ]]; then
    echo "==> built $DMG ($(du -sh "$DMG" | cut -f1))"
    echo "    signed but not notarized — run again with --notarize to submit it"
    exit 0
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<MSG
error: no notarytool keychain profile '$NOTARY_PROFILE'.
Create it once (needs an app-specific password from appleid.apple.com):

  xcrun notarytool store-credentials $NOTARY_PROFILE \\
      --apple-id <your-apple-id> --team-id $TEAM_ID --password <app-specific-password>
MSG
    exit 1
fi

echo "==> notarizing the image (uploads to Apple, waits for the result)"
# A .dmg is submitted directly; only a bare .app needs zipping first.
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> stapling the ticket to the image"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper assessment"
# -a -t open is the assessment a double-clicked disk image actually gets; `spctl -a` on its
# own assesses it as an executable and reports a confusing rejection.
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /'
echo "==> done: $DMG ($(du -sh "$DMG" | cut -f1))"
