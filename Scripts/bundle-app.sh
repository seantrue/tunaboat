#!/bin/bash
# Builds Tunaboat.app from the SPM executables.
#
#   Scripts/bundle-app.sh [debug|release] [--sign | --notarize] [--universal] [--profile NAME]
#
#   (no flag)    ad-hoc signature — runs locally, not distributable
#   --sign       Developer ID + hardened runtime + secure timestamp
#   --notarize   --sign, then submit to Apple, staple, and verify with Gatekeeper
#   --universal  arm64 + x86_64 — required for anything you hand to someone else
#
# SwiftPM produces bare Mach-O binaries; a menu bar app needs a bundle with an Info.plist
# (LSUIElement, bundle id) before AppKit treats it as a real app. Output: .build/Tunaboat.app
#
# No credentials live in this repo. Signing uses the Developer ID identity in the login
# keychain; notarization uses a notarytool keychain profile created once with:
#
#   xcrun notarytool store-credentials tunaboat-notary \
#       --apple-id <apple-id> --team-id 78DGVG7MYU --password <app-specific-password>
set -euo pipefail

CONFIG="release"
MODE="adhoc"
UNIVERSAL=0
NOTARY_PROFILE="${TUNABOAT_NOTARY_PROFILE:-tunaboat-notary}"
TEAM_ID="${TUNABOAT_TEAM_ID:-78DGVG7MYU}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        debug|release) CONFIG="$1"; shift ;;
        --sign)        MODE="sign"; shift ;;
        --notarize)    MODE="notarize"; shift ;;
        --universal)   UNIVERSAL=1; shift ;;
        --profile)     NOTARY_PROFILE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# CFBundleShortVersionString must be a dotted number a human reads as a version. Deriving it
# from `git describe --tags --always` looked right while the repo had no tags AND no commits —
# the fallback fired — but the moment a commit existed it started yielding a bare hash, and the
# app reported its version as "30069bc". Take the marketing version from a v-prefixed tag only,
# and fall back to a real number.
VERSION="$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || echo 0.1.0)"
VERSION="${VERSION#v}"
# CFBundleVersion has to increase between builds and be numeric; the commit count is both.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP=".build/Tunaboat.app"
IDENTITY="Developer ID Application: Sean True ($TEAM_ID)"

# A default build targets only the machine doing the building, so a Mac built on Apple silicon
# will not launch at all on an Intel one. The arch flags must also be passed to
# --show-bin-path: a universal build lands in .build/apple/Products, not the per-arch directory,
# and without them the script would sign yesterday's single-arch binaries without complaint.
ARCH_FLAGS=()
if [[ "$UNIVERSAL" -eq 1 ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
# bash 3.2 under `set -u` treats an empty array expansion as unbound, hence the guard.
ARCHS=(${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})

echo "==> swift build -c $CONFIG${ARCH_FLAGS[*]:+ ${ARCH_FLAGS[*]}}"
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product TunaboatApp
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product tunaboat
BIN_DIR="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN_DIR/TunaboatApp" "$APP/Contents/MacOS/Tunaboat"
# The CLI goes in Contents/Helpers, NOT Contents/MacOS: the filesystem is case-insensitive,
# so "MacOS/tunaboat" and "MacOS/Tunaboat" are the same file and the CLI silently replaces
# the app binary. Helpers is a standard nested-code location and keeps the CLI's real name.
cp "$BIN_DIR/tunaboat" "$APP/Contents/Helpers/tunaboat"

# The icon. Without it macOS shows a generic blank in Finder, the Dock, Login Items, System
# Settings and the About box. Generated from Art/ by Scripts/make-assets.py and committed, so
# an ordinary build needs neither Pillow nor the source artwork.
# SwiftPM puts a target's declared resources in a side bundle next to the executable, and
# `Bundle.module` calls fatalError when it cannot find it — so omitting this does not degrade
# gracefully, it crashes the packaged app the moment the empty editor pane appears.
for resource_bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$resource_bundle" ]] || continue
    echo "    resources: $(basename "$resource_bundle")"
    cp -R "$resource_bundle" "$APP/Contents/Resources/"
done

ICNS="$ROOT/Resources/Tunaboat.icns"
if [[ -f "$ICNS" ]]; then
    cp "$ICNS" "$APP/Contents/Resources/Tunaboat.icns"
else
    echo "    warning: $ICNS missing — the app will have no icon"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tunaboat</string>
    <key>CFBundleDisplayName</key><string>Tunaboat</string>
    <key>CFBundleIdentifier</key><string>dev.impressionist.tunaboat</string>
    <key>CFBundleExecutable</key><string>Tunaboat</string>
    <key>CFBundleIconFile</key><string>Tunaboat</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <!-- Menu bar utility: no Dock icon. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"

# Report what actually got built rather than what was asked for.
echo "==> architectures"
for binary in "$APP/Contents/MacOS/Tunaboat" "$APP/Contents/Helpers/tunaboat"; do
    echo "    $(basename "$binary"): $(lipo -archs "$binary")"
done
if [[ "$UNIVERSAL" -eq 1 ]] && ! lipo -archs "$APP/Contents/MacOS/Tunaboat" | grep -q x86_64; then
    echo "error: --universal asked for, but the app binary is not universal" >&2
    exit 1
fi

if [[ "$MODE" == "adhoc" ]]; then
    echo "==> codesign (ad-hoc — local use only)"
    codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/    /'
    echo "==> built $APP ($(du -sh "$APP" | cut -f1))"
    exit 0
fi

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "error: no signing identity '$IDENTITY' in the keychain" >&2
    security find-identity -v -p codesigning >&2
    exit 1
fi

# Inner executables first, then the bundle: codesign seals what it contains, so anything
# signed after the outer signature invalidates it.
echo "==> codesign with Developer ID (hardened runtime, secure timestamp)"
for binary in "$APP/Contents/Helpers/tunaboat" "$APP/Contents/MacOS/Tunaboat"; do
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$binary"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"

echo "==> verifying signature"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
codesign -dvv "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|flags' | sed 's/^/    /'

if [[ "$MODE" == "sign" ]]; then
    echo "==> signed. Gatekeeper will still reject it until notarized:"
    spctl -a -vv "$APP" 2>&1 | sed 's/^/    /' || true
    echo "    run with --notarize to submit it to Apple"
    exit 0
fi

ZIP=".build/Tunaboat.zip"
echo "==> notarizing (uploads to Apple, waits for the result)"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<MSG
error: no notarytool keychain profile '$NOTARY_PROFILE'.
Create it once (needs an app-specific password from appleid.apple.com):

  xcrun notarytool store-credentials $NOTARY_PROFILE \\
      --apple-id <your-apple-id> --team-id $TEAM_ID --password <app-specific-password>
MSG
    exit 1
fi

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> stapling the ticket"
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip the stapled app for distribution

echo "==> Gatekeeper assessment"
spctl -a -vv "$APP" 2>&1 | sed 's/^/    /'
echo "==> done: $APP (notarized) and $ZIP (shareable)"
