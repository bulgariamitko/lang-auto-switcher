#!/bin/bash
# Build → sign → notarize → staple → zip a Release of LangAutoSwitcher.
#
# Usage: bash scripts/release.sh <version>     e.g. bash scripts/release.sh 2.7.2
#
# Requires:
#   - "Developer ID Application" identity in login keychain
#   - notarytool keychain profile "langauto-notary" (Apple Connect API key based)

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>   e.g. $0 2.7.2"
    exit 1
fi

APP="LangAutoSwitcher.app"
BUILD_DIR="build/Release"
APP_PATH="$BUILD_DIR/$APP"
ZIP="LangAutoSwitcher-v${VERSION}.zip"
IDENTITY="Developer ID Application: Dimitar Klaturov (75668RQCMG)"
NOTARY_PROFILE="langauto-notary"
ENTITLEMENTS="LangAutoSwitcher/LangAutoSwitcher.entitlements"

echo "▸ Cleaning previous build"
rm -rf build/ "$ZIP"
xattr -cr LangAutoSwitcher.xcodeproj 2>/dev/null || true

echo "▸ Regenerating Xcode project"
xcodegen generate

echo "▸ Building Release configuration"
xcodebuild -project LangAutoSwitcher.xcodeproj \
           -target LangAutoSwitcher \
           -configuration Release \
           -quiet build

echo "▸ Signing with Developer ID + hardened runtime"
codesign --force --deep \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" \
    "$APP_PATH"

echo "▸ Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1

echo "▸ Zipping for notarization (ditto preserves macOS metadata)"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"

echo "▸ Submitting to Apple notary service (will block until done)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ Stapling notarization ticket to the app"
xcrun stapler staple "$APP_PATH"

echo "▸ Final verification via Gatekeeper"
spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1 || true

echo "▸ Re-zipping the stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"

ls -lh "$ZIP"
echo ""
echo "✓ Release ready: $ZIP"
