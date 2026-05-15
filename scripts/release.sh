#!/bin/bash
# Build → sign → notarize → staple → zip a Release of LangAutoSwitcher.
#
# Usage: bash scripts/release.sh <version>     e.g. bash scripts/release.sh 2.7.3
#
# Requires:
#   - "Developer ID Application" identity in login keychain
#   - notarytool keychain profile "langauto-notary" (Apple Connect API key based)
#   - Sparkle EdDSA private key in macOS Keychain (from generate_keys)
#
# Builds into /tmp (outside Dropbox) so xattrs from File Provider sync don't
# fight codesign. Final signed zip is copied back into the repo root.

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>   e.g. $0 2.7.3"
    exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
BUILD_NUMBER=$(( MAJOR * 10000 + MINOR * 100 + PATCH ))

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BUILD="$(mktemp -d -t langauto-build)"
APP="LangAutoSwitcher.app"
APP_PATH="$TMP_BUILD/Release/$APP"
ZIP_NAME="LangAutoSwitcher-v${VERSION}.zip"
ZIP_PATH="$TMP_BUILD/$ZIP_NAME"
FINAL_ZIP="$REPO_ROOT/$ZIP_NAME"
IDENTITY="Developer ID Application: Dimitar Klaturov (75668RQCMG)"
NOTARY_PROFILE="langauto-notary"
ENTITLEMENTS="$REPO_ROOT/LangAutoSwitcher/LangAutoSwitcher.entitlements"

cleanup() { rm -rf "$TMP_BUILD"; }
trap cleanup EXIT

echo "▸ Building v$VERSION (build $BUILD_NUMBER) into $TMP_BUILD"
cd "$REPO_ROOT"
rm -f "$FINAL_ZIP"
xattr -cr LangAutoSwitcher.xcodeproj 2>/dev/null || true

echo "▸ Regenerating Xcode project"
xcodegen generate

echo "▸ Building Release configuration"
xcodebuild -project LangAutoSwitcher.xcodeproj \
           -target LangAutoSwitcher \
           -configuration Release \
           SYMROOT="$TMP_BUILD" \
           OBJROOT="$TMP_BUILD/obj" \
           MARKETING_VERSION="$VERSION" \
           CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
           -quiet build

# Now we're outside Dropbox — no xattr races.

echo "▸ Signing Sparkle's nested helpers and XPC services"
FRAMEWORKS="$APP_PATH/Contents/Frameworks"
if [ -d "$FRAMEWORKS/Sparkle.framework" ]; then
    SPARKLE_VER="$FRAMEWORKS/Sparkle.framework/Versions/B"
    # 1. Sign the plain Autoupdate Mach-O binary (not caught by .app/.xpc/.framework regex).
    if [ -f "$SPARKLE_VER/Autoupdate" ]; then
        echo "    sign: Autoupdate"
        codesign --force --options runtime --timestamp \
            --sign "$IDENTITY" "$SPARKLE_VER/Autoupdate"
    fi
    # 2. Sign nested bundles (.app, .xpc) deepest-first.
    find -E "$FRAMEWORKS/Sparkle.framework" -depth \
        -regex '.*\.(app|xpc)$' -print0 | \
    while IFS= read -r -d '' item; do
        echo "    sign: ${item#$TMP_BUILD/}"
        codesign --force --options runtime --timestamp \
            --sign "$IDENTITY" "$item"
    done
    # 3. Sign the framework itself last.
    echo "    sign: Sparkle.framework"
    codesign --force --options runtime --timestamp \
        --sign "$IDENTITY" "$FRAMEWORKS/Sparkle.framework"
fi

echo "▸ Signing the main app bundle"
codesign --force \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" \
    "$APP_PATH"

echo "▸ Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1

echo "▸ Zipping for notarization (ditto preserves macOS metadata)"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "▸ Submitting to Apple notary service (blocks until done)"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ Stapling notarization ticket to the app"
xcrun stapler staple "$APP_PATH"

echo "▸ Final verification via Gatekeeper"
spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1 || true

echo "▸ Re-zipping the stapled app"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# Sparkle EdDSA signature for the appcast entry.
# We sign from a key FILE rather than the Keychain to avoid auth prompts.
# The key was exported with `generate_keys -x $SPARKLE_PRIVATE_KEY` once.
echo "▸ Signing zip with Sparkle EdDSA key"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-$HOME/.sparkle_langauto_ed25519.key}"
if [ ! -f "$SPARKLE_PRIVATE_KEY" ]; then
    echo "error: $SPARKLE_PRIVATE_KEY not found."
    echo "       Re-export with: generate_keys -x \"$SPARKLE_PRIVATE_KEY\""
    exit 1
fi
# Cache Sparkle tooling at ~/.cache/sparkle so we don't redownload every release.
SPARKLE_VERSION="2.9.1"
SPARKLE_CACHE="$HOME/.cache/sparkle/${SPARKLE_VERSION}"
SIGN_UPDATE="$SPARKLE_CACHE/bin/sign_update"
if [ ! -x "$SIGN_UPDATE" ]; then
    echo "  sign_update not cached — downloading Sparkle ${SPARKLE_VERSION} tools"
    mkdir -p "$SPARKLE_CACHE"
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
        -o "$SPARKLE_CACHE/sparkle.tar.xz"
    tar -xJf "$SPARKLE_CACHE/sparkle.tar.xz" -C "$SPARKLE_CACHE"
fi
SPARKLE_SIG_LINE=$("$SIGN_UPDATE" -f "$SPARKLE_PRIVATE_KEY" "$ZIP_PATH")
echo "$SPARKLE_SIG_LINE"
ED_SIG=$(echo "$SPARKLE_SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')

# Move final zip back into the repo
cp "$ZIP_PATH" "$FINAL_ZIP"

echo "▸ Updating docs/appcast.xml"
NOTES_URL="https://github.com/bulgariamitko/lang-auto-switcher/releases/tag/v${VERSION}"
python3 "$REPO_ROOT/scripts/append_appcast.py" "$VERSION" "$BUILD_NUMBER" \
    "$FINAL_ZIP" "$ED_SIG" "$NOTES_URL"

ls -lh "$FINAL_ZIP"
echo ""
echo "✓ Release ready: $FINAL_ZIP"
echo "✓ docs/appcast.xml updated — commit + push so GitHub Pages serves it."
