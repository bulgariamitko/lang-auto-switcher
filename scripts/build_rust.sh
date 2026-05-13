#!/bin/bash
# Build the Rust core for both arm64 and x86_64, then lipo them into a
# universal static library that Xcode links into LangAutoSwitcher.app.
#
# Run by an Xcode Pre-Build script phase. Idempotent — caches in target/.

set -euo pipefail

# Locate repo root regardless of where this is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="$REPO_ROOT/langauto-core"

# Source rustup env if cargo isn't on PATH (Xcode build phases have a clean env).
if ! command -v cargo >/dev/null 2>&1; then
    if [ -f "$HOME/.cargo/env" ]; then
        # shellcheck source=/dev/null
        . "$HOME/.cargo/env"
    fi
fi

if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found. Install Rust: https://rustup.rs"
    exit 1
fi

# Build from the workspace root so cargo puts artifacts in the shared target/.
# (Workspace members share <root>/target/ — they no longer have their own.)
cd "$REPO_ROOT"
TARGET_ROOT="$REPO_ROOT/target"

PROFILE="${CONFIGURATION:-Release}"
case "$PROFILE" in
    Debug)   CARGO_PROFILE_FLAG="" ; PROFILE_DIR="debug"   ;;
    *)       CARGO_PROFILE_FLAG="--release" ; PROFILE_DIR="release" ;;
esac

echo "→ Building langauto-core ($PROFILE) for aarch64-apple-darwin"
cargo build $CARGO_PROFILE_FLAG -p langauto_core --target aarch64-apple-darwin

echo "→ Building langauto-core ($PROFILE) for x86_64-apple-darwin"
cargo build $CARGO_PROFILE_FLAG -p langauto_core --target x86_64-apple-darwin

# Universal binary still lands under langauto-core/ so the Xcode linker config
# (which references langauto-core/target/universal/<config>) doesn't change.
UNIVERSAL_DIR="$CORE_DIR/target/universal/$PROFILE_DIR"
mkdir -p "$UNIVERSAL_DIR"

echo "→ Lipo'ing into universal static library"
lipo -create \
    "$TARGET_ROOT/aarch64-apple-darwin/$PROFILE_DIR/liblangauto_core.a" \
    "$TARGET_ROOT/x86_64-apple-darwin/$PROFILE_DIR/liblangauto_core.a" \
    -output "$UNIVERSAL_DIR/liblangauto_core.a"

echo "✓ $UNIVERSAL_DIR/liblangauto_core.a"
lipo -info "$UNIVERSAL_DIR/liblangauto_core.a"
