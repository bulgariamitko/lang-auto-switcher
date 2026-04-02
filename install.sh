#!/bin/bash
# Install LangAutoSwitcher as a macOS Input Method
#
# Input Methods live in ~/Library/Input Methods/
# After installing, log out and back in (or restart) for it to appear.

set -e

APP_NAME="LangAutoSwitcher.app"
BUILD_DIR="build/Debug"
INSTALL_DIR="$HOME/Library/Input Methods"

echo "=== LangAutoSwitcher Installer ==="
echo ""

# Check if built
if [ ! -d "$BUILD_DIR/$APP_NAME" ]; then
    echo "App not found at $BUILD_DIR/$APP_NAME"
    echo "Building first..."
    xcodebuild -project LangAutoSwitcher.xcodeproj \
               -target LangAutoSwitcher \
               -configuration Debug \
               -quiet build
fi

# Kill existing instance if running
echo "Stopping existing instance (if any)..."
killall LangAutoSwitcher 2>/dev/null || true

# Create install directory if needed
mkdir -p "$INSTALL_DIR"

# Remove old version
if [ -d "$INSTALL_DIR/$APP_NAME" ]; then
    echo "Removing previous version..."
    rm -rf "$INSTALL_DIR/$APP_NAME"
fi

# Copy new version
echo "Installing to $INSTALL_DIR/$APP_NAME ..."
cp -R "$BUILD_DIR/$APP_NAME" "$INSTALL_DIR/$APP_NAME"

echo ""
echo "Installed successfully!"
echo ""
echo "=== Next steps ==="
echo "1. Log out and log back in (or restart your Mac)"
echo "   This is needed for macOS to discover the new input source."
echo ""
echo "2. Go to: System Settings → Keyboard → Input Sources → Edit..."
echo "   Click '+', find 'LangAutoSwitcher' and add it."
echo ""
echo "3. Switch to it from the input menu in your menu bar (🌐 or flag icon)."
echo ""
echo "4. Start typing! English stays English, Bulgarian auto-converts to Cyrillic."
echo ""
echo "To uninstall: rm -rf '$INSTALL_DIR/$APP_NAME' and restart."
