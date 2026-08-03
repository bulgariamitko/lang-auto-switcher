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

PROJECT_YML="$REPO_ROOT/project.yml"
PBXPROJ="$REPO_ROOT/LangAutoSwitcher.xcodeproj/project.pbxproj"
XCODEPROJ_DIR="$REPO_ROOT/LangAutoSwitcher.xcodeproj"

cleanup() { rm -rf "$TMP_BUILD"; }
trap cleanup EXIT

# ---- version helpers ---------------------------------------------------------

project_yml_version() {
    /usr/bin/sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$PROJECT_YML" | head -1
}
project_yml_build() {
    /usr/bin/sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$PROJECT_YML" | head -1
}
# First MARKETING_VERSION in a .pbxproj (all targets share one value here).
pbxproj_version() {
    /usr/bin/grep -m1 -o 'MARKETING_VERSION = [^;]*;' "$1" 2>/dev/null \
        | /usr/bin/sed 's/.*= *//; s/;$//'
}

# Names of Dropbox's "conflicted copy" duplicates of the project file, if any.
list_conflicted_copies() {
    /usr/bin/find "$XCODEPROJ_DIR" -maxdepth 1 -name '*conflicted copy*' 2>/dev/null
}

# Delete them. They are never wanted: project.pbxproj is generated from
# project.yml, so the authoritative content is always one `xcodegen generate`
# away and a file Dropbox invented is never worth trusting.
remove_conflicted_copies() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        echo "    removing Dropbox cruft: $(basename "$f")"
        rm -f "$f"
    done < <(list_conflicted_copies)
}

# Run xcodegen and make the result stick, despite Dropbox.
#
# This repo lives inside Dropbox (File Provider). `xcodegen generate` rewrites
# project.pbxproj in place, which races Dropbox's sync daemon: Dropbox can
# decide the rewrite conflicts with the copy it is holding, put the OLD content
# back into project.pbxproj, and park xcodegen's fresh output next to it as
# "project (<user>'s conflicted copy <date>).pbxproj".
#
# The shipped binary is unaffected — MARKETING_VERSION is forced on the
# xcodebuild line — but the repo would be left claiming the previous version
# while shipping the new one. That happened silently during the v2.8.4 build.
#
# So: generate, wait for Dropbox to make its move, verify the version actually
# landed, and retry. We re-generate from project.yml rather than promoting a
# conflicted copy, so we never have to trust a file Dropbox invented.
generate_project() {
    local attempt got
    for attempt in 1 2 3; do
        remove_conflicted_copies
        xcodegen generate

        # Dropbox reconciles asynchronously; a clobber lands a beat later.
        sleep 3

        got="$(pbxproj_version "$PBXPROJ")"
        if [ "$got" = "$VERSION" ]; then
            # The version landed. Any duplicate Dropbox spawned alongside it is
            # now just cruft — drop it so it can't be committed by accident.
            remove_conflicted_copies
            if [ "$attempt" -gt 1 ]; then
                echo "    project file settled on attempt $attempt"
            fi
            return 0
        fi

        echo "    project.pbxproj says '${got:-<none>}', expected '$VERSION' —" \
             "Dropbox clobbered it (attempt $attempt/3)"
        sleep 5
    done

    echo ""
    echo "error: could not get project.pbxproj to hold v$VERSION."
    echo "       Dropbox keeps reverting it. Pause Dropbox syncing and re-run,"
    echo "       or run 'xcodegen generate' by hand and check:"
    echo "         grep MARKETING_VERSION '$PBXPROJ'"
    exit 1
}

# Staple with retries — the staple step talks to Apple's CloudKit ticket
# service and occasionally times out (NSURLErrorTimedOut / "error 68") even
# though notarization already succeeded. Retry a few times before giving up.
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

echo "▸ Building v$VERSION (build $BUILD_NUMBER) into $TMP_BUILD"
cd "$REPO_ROOT"
rm -f "$FINAL_ZIP"
xattr -cr LangAutoSwitcher.xcodeproj 2>/dev/null || true

echo "▸ Pinning project.yml to v$VERSION"
# project.yml is the source of truth xcodegen reads. If it still holds the
# previous release's numbers the generated project — and therefore the repo —
# would claim the old version while we ship the new one. Sync it here so the
# release can never disagree with itself; the change is reported so it gets
# committed alongside the appcast.
if [ "$(project_yml_version)" != "$VERSION" ] || \
   [ "$(project_yml_build)" != "$BUILD_NUMBER" ]; then
    echo "    project.yml said $(project_yml_version)/$(project_yml_build) — setting $VERSION/$BUILD_NUMBER"
    /usr/bin/sed -i '' \
        -e "s/^\( *MARKETING_VERSION: \).*/\1\"$VERSION\"/" \
        -e "s/^\( *CURRENT_PROJECT_VERSION: \).*/\1\"$BUILD_NUMBER\"/" \
        "$PROJECT_YML"
    if [ "$(project_yml_version)" != "$VERSION" ] || \
       [ "$(project_yml_build)" != "$BUILD_NUMBER" ]; then
        echo "error: could not set the version in $PROJECT_YML — edit it by hand."
        exit 1
    fi
    echo "    ⚠ project.yml was changed — commit it with this release"
else
    echo "    already $VERSION/$BUILD_NUMBER"
fi

echo "▸ Regenerating Xcode project"
generate_project

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

echo "▸ Verifying the built app carries v$VERSION"
# Backstop: whatever went wrong upstream — a stale project file, a clobbered
# regeneration, a typo'd argument — the thing we are about to sign, notarize
# and publish must say what we think it says. Read it back from the bundle.
BUILT_SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist")
BUILT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
    "$APP_PATH/Contents/Info.plist")
if [ "$BUILT_SHORT" != "$VERSION" ] || [ "$BUILT_BUILD" != "$BUILD_NUMBER" ]; then
    echo "error: built app is $BUILT_SHORT ($BUILT_BUILD), expected $VERSION ($BUILD_NUMBER)."
    echo "       Refusing to sign and publish a mislabelled build."
    exit 1
fi
echo "    $BUILT_SHORT ($BUILT_BUILD) ✓"

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
staple_with_retry "$APP_PATH"

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
# Optional per-release inline notes file. If notes/v<X.Y.Z>.html exists in the
# repo, its HTML is embedded in the appcast <description> so Sparkle shows it
# inline in the update dialog (no GitHub page fetch).
NOTES_HTML="$REPO_ROOT/notes/v${VERSION}.html"
if [ -f "$NOTES_HTML" ]; then
    python3 "$REPO_ROOT/scripts/append_appcast.py" "$VERSION" "$BUILD_NUMBER" \
        "$FINAL_ZIP" "$ED_SIG" "$NOTES_URL" "$NOTES_HTML"
else
    python3 "$REPO_ROOT/scripts/append_appcast.py" "$VERSION" "$BUILD_NUMBER" \
        "$FINAL_ZIP" "$ED_SIG" "$NOTES_URL"
fi

ls -lh "$FINAL_ZIP"

# -----------------------------------------------------------------------------
# Build the user-facing .dmg installer (BEST-EFFORT)
# -----------------------------------------------------------------------------
# The zip + appcast above are already final and published-ready. The installer
# and DMG are a convenience for first-time manual installs, and their notarize
# / staple steps depend on Apple network services that occasionally time out.
# Run the whole section in a subshell so a transient failure here degrades to a
# warning instead of aborting the release — `set -e` stays active *inside* the
# subshell, so the first real failure stops the DMG build cleanly.
DMG_NAME="LangAutoSwitcher-v${VERSION}.dmg"
FINAL_DMG="$REPO_ROOT/$DMG_NAME"
rm -f "$FINAL_DMG"
DMG_OK=0
if (
    set -e
    echo ""
    echo "▸ Building installer .app (AppleScript applet)"
    INSTALLER_NAME="Install LangAutoSwitcher.app"
    INSTALLER_APP="$TMP_BUILD/$INSTALLER_NAME"
osacompile -o "$INSTALLER_APP" "$REPO_ROOT/scripts/install_applet.applescript"

# Embed the stapled LangAutoSwitcher.app inside the installer's Resources.
cp -R "$APP_PATH" "$INSTALLER_APP/Contents/Resources/"

# Give the installer the Аб app icon (so the user sees a familiar icon in the
# DMG window, not the generic AppleScript scroll icon).
cp "$REPO_ROOT/LangAutoSwitcher/Resources/AppIcon.icns" \
   "$INSTALLER_APP/Contents/Resources/applet.icns"

# osacompile also drops an Assets.car asset catalog that contains the default
# scroll icon and overrides applet.icns at runtime in some places (notably
# `display dialog`'s app-icon rendering). Remove it so applet.icns is the
# sole source of truth.
rm -f "$INSTALLER_APP/Contents/Resources/Assets.car"

# Bump the installer's bundle id + version so its signature is distinct from
# the inner app. (Optional, but keeps logs cleaner.)
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.dklaturov.inputmethod.LangAutoSwitcher.Installer" \
    "$INSTALLER_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$INSTALLER_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$INSTALLER_APP/Contents/Info.plist" 2>/dev/null || true

# Sign only the installer's outer bundle. The nested LangAutoSwitcher.app
# keeps its own pre-stapled signature; we don't pass --deep so codesign
# doesn't try to re-sign and break it.
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

# Only the installer .app is visible in the DMG — no second confusing icon.
cp -R "$INSTALLER_APP" "$DMG_STAGE/"

echo "    creating writable image"
TMP_DMG="$TMP_BUILD/temp.dmg"
hdiutil create -srcfolder "$DMG_STAGE" \
    -volname "$DMG_VOLNAME" \
    -fs HFS+ -fsargs "-c c=64,a=16,e=16" \
    -format UDRW -size 20m "$TMP_DMG" >/dev/null

echo "    mounting + arranging window"
# Mount points may contain spaces — parse the tab-separated last field of the
# attach output rather than splitting on whitespace.
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
# Retry detach — sometimes the AppleScript leaves a handle open briefly.
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
); then
    DMG_OK=1
fi

echo ""
if [ "$DMG_OK" = "1" ] && [ -f "$FINAL_DMG" ]; then
    echo "✓ Release artifacts:"
    echo "    $FINAL_ZIP   (used by Sparkle for auto-update)"
    echo "    $FINAL_DMG   (user-facing first-install download)"
else
    echo "✓ Release artifact (core):"
    echo "    $FINAL_ZIP   (used by Sparkle for auto-update)"
    echo ""
    echo "⚠ The installer DMG was NOT produced (a transient notarize/staple"
    echo "  failure, e.g. an Apple network timeout). The release itself is fine:"
    echo "  the zip is notarized + stapled and the appcast is updated. Re-run"
    echo "  'bash scripts/build_dmg.sh $VERSION' to build and attach the DMG"
    echo "  later — it does NOT touch the zip or appcast."
fi
echo "✓ docs/appcast.xml updated — commit + push so GitHub Pages serves it."

# Dropbox can spawn a conflicted copy at any point while the release runs, not
# only during generation. Say so now rather than letting it be committed or
# leaving the repo claiming the wrong version.
LEFTOVERS="$(list_conflicted_copies)"
if [ -n "$LEFTOVERS" ]; then
    echo ""
    echo "⚠ Dropbox left conflicted copies behind — delete them before committing:"
    echo "$LEFTOVERS" | while IFS= read -r f; do echo "    $f"; done
fi
if [ "$(pbxproj_version "$PBXPROJ")" != "$VERSION" ]; then
    echo ""
    echo "⚠ project.pbxproj no longer says $VERSION (Dropbox clobbered it after"
    echo "  the build). The published artifacts are correct — they were verified"
    echo "  against the built bundle — but re-run 'xcodegen generate' before"
    echo "  committing so the repo matches what shipped."
fi
