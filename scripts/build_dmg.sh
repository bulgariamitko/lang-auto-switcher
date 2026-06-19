#!/bin/bash
# Build (and notarize/staple) ONLY the user-facing .dmg installer for a release
# that already has its signed, notarized, stapled zip in the repo root.
#
# Usage: bash scripts/build_dmg.sh <version>     e.g. bash scripts/build_dmg.sh 2.8.2
#
# Why this exists: the DMG is a first-install convenience whose notarize/staple
# steps hit Apple network services that occasionally time out. release.sh now
# treats the DMG as best-effort and never aborts the release for it — this
# script lets you build and attach the DMG afterwards, WITHOUT re-running the
# full pipeline (it does not touch the zip, the EdDSA signature, or appcast.xml).
#
# It reuses the already-notarized + stapled LangAutoSwitcher.app extracted from
# the release zip, so only the installer and DMG get notarized here.

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>   e.g. $0 2.8.2"
    exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
BUILD_NUMBER=$(( MAJOR * 10000 + MINOR * 100 + PATCH ))

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="LangAutoSwitcher.app"
ZIP_NAME="LangAutoSwitcher-v${VERSION}.zip"
ZIP_PATH="$REPO_ROOT/$ZIP_NAME"
IDENTITY="Developer ID Application: Dimitar Klaturov (75668RQCMG)"
NOTARY_PROFILE="langauto-notary"

if [ ! -f "$ZIP_PATH" ]; then
    echo "error: $ZIP_PATH not found."
    echo "       Run scripts/release.sh $VERSION first (it produces the signed zip),"
    echo "       or download the release asset into the repo root."
    exit 1
fi

TMP_BUILD="$(mktemp -d -t langauto-dmg)"
cleanup() { rm -rf "$TMP_BUILD"; }
trap cleanup EXIT

# Same retry wrapper as release.sh — the staple step occasionally times out.
staple_with_retry() {
    local target="$1" tries="${2:-5}" i
    for (( i = 1; i <= tries; i++ )); do
        if xcrun stapler staple "$target"; then
            return 0
        fi
        if (( i < tries )); then
            echo "    staple attempt $i/$tries failed (transient?) — retrying in 15s…"
            sleep 15
        fi
    done
    echo "    staple failed after $tries attempts"
    return 1
}

echo "▸ Extracting the notarized app from $ZIP_NAME"
ditto -x -k "$ZIP_PATH" "$TMP_BUILD"
APP_PATH="$TMP_BUILD/$APP"
if [ ! -d "$APP_PATH" ]; then
    echo "error: $APP not found inside $ZIP_NAME"
    exit 1
fi

echo "▸ Verifying the extracted app is signed + stapled"
codesign --verify --deep --strict "$APP_PATH"
xcrun stapler validate "$APP_PATH" || {
    echo "error: the app in the zip is not stapled — rebuild the release first"
    exit 1
}

# -----------------------------------------------------------------------------
# Build the installer .app + DMG (identical to release.sh's tail section)
# -----------------------------------------------------------------------------
echo ""
echo "▸ Building installer .app (AppleScript applet)"
INSTALLER_NAME="Install LangAutoSwitcher.app"
INSTALLER_APP="$TMP_BUILD/$INSTALLER_NAME"
osacompile -o "$INSTALLER_APP" "$REPO_ROOT/scripts/install_applet.applescript"

cp -R "$APP_PATH" "$INSTALLER_APP/Contents/Resources/"
cp "$REPO_ROOT/LangAutoSwitcher/Resources/AppIcon.icns" \
   "$INSTALLER_APP/Contents/Resources/applet.icns"
rm -f "$INSTALLER_APP/Contents/Resources/Assets.car"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.dklaturov.inputmethod.LangAutoSwitcher.Installer" \
    "$INSTALLER_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$INSTALLER_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$INSTALLER_APP/Contents/Info.plist" 2>/dev/null || true

echo "    signing installer"
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$INSTALLER_APP"

echo "▸ Submitting installer .app to notary service"
INSTALLER_NOTARIZE_ZIP="$TMP_BUILD/installer_for_notary.zip"
ditto -c -k --keepParent "$INSTALLER_APP" "$INSTALLER_NOTARIZE_ZIP"
xcrun notarytool submit "$INSTALLER_NOTARIZE_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" --wait

echo "    stapling installer"
staple_with_retry "$INSTALLER_APP"

echo ""
echo "▸ Building DMG with the installer"
DMG_NAME="LangAutoSwitcher-v${VERSION}.dmg"
DMG_PATH="$TMP_BUILD/$DMG_NAME"
FINAL_DMG="$REPO_ROOT/$DMG_NAME"
DMG_STAGE="$TMP_BUILD/dmg_stage"
DMG_VOLNAME="LangAutoSwitcher ${VERSION}"
rm -rf "$DMG_STAGE" "$FINAL_DMG"
mkdir -p "$DMG_STAGE"
cp -R "$INSTALLER_APP" "$DMG_STAGE/"

echo "    creating writable image"
TMP_DMG="$TMP_BUILD/temp.dmg"
hdiutil create -srcfolder "$DMG_STAGE" \
    -volname "$DMG_VOLNAME" \
    -fs HFS+ -fsargs "-c c=64,a=16,e=16" \
    -format UDRW -size 20m "$TMP_DMG" >/dev/null

echo "    mounting + arranging window"
MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG" | \
    tail -1 | awk -F'\t' '{print $NF}' | sed 's/[[:space:]]*$//')
echo "    mounted at: $MOUNT_DIR"
sleep 1
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$DMG_VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {400, 100, 800, 360}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "$INSTALLER_NAME" of container window to {200, 110}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
for attempt in 1 2 3 4 5; do
    if hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; then break; fi
    sleep 1
    [ "$attempt" = "5" ] && hdiutil detach -force "$MOUNT_DIR" >/dev/null
done

echo "    compressing to read-only"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 \
    -o "$DMG_PATH" >/dev/null

echo "    signing DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"

echo "    submitting DMG to notary service"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "    stapling DMG"
staple_with_retry "$DMG_PATH"

cp "$DMG_PATH" "$FINAL_DMG"
ls -lh "$FINAL_DMG"

echo ""
echo "✓ DMG ready: $FINAL_DMG"
echo "  Attach it with:"
echo "    gh release upload v${VERSION} \"$FINAL_DMG\""
