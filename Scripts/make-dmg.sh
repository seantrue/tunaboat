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

# Detach a disk image device, allowing for Finder and Spotlight still holding it.
detach_device() {
    local device="$1"
    [[ -n "$device" ]] || return 1
    for attempt in 1 2 3 4 5 6; do
        if hdiutil detach "$device" >/dev/null 2>&1; then return 0; fi
        sleep 2
        if hdiutil detach "$device" -force >/dev/null 2>&1; then return 0; fi
    done
    return 1
}

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

# The window backdrop. Finder looks for it inside the image, so it has to be staged in — and
# in a dot-directory, or it appears as a file next to the app.
BACKGROUND_SRC="$ROOT/Resources/dmg-background.png"
BACKGROUND_2X="$ROOT/Resources/dmg-background@2x.png"
HAS_BACKGROUND=0
if [[ -f "$BACKGROUND_SRC" ]]; then
    mkdir -p "$STAGE/.background"
    # A multi-representation TIFF is how one backdrop serves Retina and non-Retina; without it
    # Finder upscales the 1x image and the line art goes soft on every modern display.
    if [[ -f "$BACKGROUND_2X" ]] && command -v tiffutil >/dev/null; then
        tiffutil -cathidpicheck "$BACKGROUND_SRC" "$BACKGROUND_2X" \
            -out "$STAGE/.background/background.tiff" >/dev/null 2>&1 \
            && BACKGROUND_NAME="background.tiff"
    fi
    if [[ -z "${BACKGROUND_NAME:-}" ]]; then
        cp "$BACKGROUND_SRC" "$STAGE/.background/background.png"
        BACKGROUND_NAME="background.png"
    fi
    HAS_BACKGROUND=1
    echo "==> backdrop: $BACKGROUND_NAME"
fi

# A read/write image first, so Finder can record the window layout into it; converted to a
# compressed read-only image at the end.
RW_DMG=".build/Tunaboat-rw.dmg"
rm -f "$RW_DMG"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -ov "$RW_DMG" >/dev/null

# AppleScript has no conditional for this, so the clause is either present or empty.
if [[ "$HAS_BACKGROUND" -eq 1 ]]; then
    BACKGROUND_CLAUSE="set background picture of opts to file \".background:$BACKGROUND_NAME\""
else
    BACKGROUND_CLAUSE=""
fi

echo "==> laying out the window"
MOUNT_DIR="/Volumes/$VOLNAME"

# Finder can only be told to arrange a volume it can see, which means mounting under /Volumes
# under the product's own name — so a *previously* mounted Tunaboat image (an earlier release
# left attached, say) collides with this one. Clear it first rather than laying out the wrong
# volume and then failing to eject.
if mount | grep -q " $MOUNT_DIR "; then
    echo "    $MOUNT_DIR already mounted — detaching it first"
    detach_device "$(mount | awk -v m=" $MOUNT_DIR " '$0 ~ m {print $1}')" || {
        echo "error: $MOUNT_DIR is mounted and will not detach; eject it and re-run" >&2
        exit 1
    }
fi

# Keep the device this attach produced. Detaching by mount point is what fails once anything
# else has looked at the volume; detaching the specific device is both more precise and what
# lets the retry below mean anything.
ATTACH_OUT="$(hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noverify)"
RW_DEVICE="$(echo "$ATTACH_OUT" | awk '/^\/dev\/disk/{print $1; exit}')"

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
        set text size of opts to 12
        $BACKGROUND_CLAUSE
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
# Ejecting straight after Finder has touched the volume regularly fails with "Resource busy":
# Finder and Spotlight are still finishing with it. One immediate attempt then a short backoff
# is enough; giving up silently would leave a stale mount that breaks the *next* run.
if ! detach_device "$RW_DEVICE"; then
    echo "error: could not detach $MOUNT_DIR (still busy after retries)" >&2
    echo "       eject it in Finder, then re-run" >&2
    exit 1
fi

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
