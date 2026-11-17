#!/bin/bash
# Build and install the INTERNAL build on this Mac only. Never distribute it.
#
# Differences from a release build (all via the INTERNAL_BUILD flag):
#   • the mistake log (MistakeLog.swift) is compiled in and on, writing to
#     ~/Library/Application Support/LangAutoSwitcher/mistakes.log
#   • Sparkle never starts, so this build is not replaced by the public release
#
# Re-run after every code change you want to live with. To go back to the
# public version, install the latest release DMG — it updates normally again.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' project.yml)
# Outside Dropbox: it races the build with xattrs and file reverts.
OUT="$HOME/Library/Caches/LangAutoSwitcher-internal"
APP="$OUT/Release/LangAutoSwitcher.app"
DEST="$HOME/Library/Input Methods/LangAutoSwitcher.app"

echo "▸ Regenerating Xcode project"
xcodegen generate --quiet

echo "▸ Building internal $VERSION"
rm -rf "$OUT"
xcodebuild -project LangAutoSwitcher.xcodeproj \
           -target LangAutoSwitcher \
           -configuration Release \
           SYMROOT="$OUT" \
           OBJROOT="$OUT/obj" \
           MARKETING_VERSION="$VERSION-internal" \
           CURRENT_PROJECT_VERSION="$BUILD" \
           SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) INTERNAL_BUILD' \
           -quiet build

# The build must really be the internal one, or it would quietly do nothing.
if ! /usr/bin/strings -a "$APP/Contents/MacOS/LangAutoSwitcher" | grep -c "DeletionWatch" >/dev/null; then
    echo "error: built app has no mistake log — INTERNAL_BUILD did not apply" >&2
    exit 1
fi

echo "▸ Installing to $DEST"
killall LangAutoSwitcher 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "✓ Internal $VERSION installed. Type something — the next keystroke starts it."
echo "  Log: ~/Library/Application Support/LangAutoSwitcher/mistakes.log"
