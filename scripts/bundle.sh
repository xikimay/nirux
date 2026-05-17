#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: bundle.sh <version> <build-number>}"
BUILD_NUMBER="${2:?Usage: bundle.sh <version> <build-number>}"
SIGN_IDENTITY="${NIRUX_CODESIGN_IDENTITY:--}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
APP="$ROOT/Nirux.app"

# Find the release binary
BINARY="$ROOT/.build/release/Nirux"
if [[ ! -f "$BINARY" ]]; then
    # Try arm64-specific path
    BINARY="$ROOT/.build/arm64-apple-macosx/release/Nirux"
fi
if [[ ! -f "$BINARY" ]]; then
    echo "Error: release binary not found. Run 'swift build -c release' first."
    exit 1
fi

# Find Sparkle.framework
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FW" ]]; then
    echo "Error: Sparkle.framework not found at $SPARKLE_FW"
    exit 1
fi

echo "Bundling Nirux.app v${VERSION} (build ${BUILD_NUMBER})..."

# Clean previous bundle
rm -rf "$APP" "$ROOT/Nirux.app.zip"

# Create .app structure
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP/Contents/MacOS/Nirux"

# Copy Sparkle.framework
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

# Copy editor assets (Monaco + bridge). At runtime EditorColumn first tries
# Bundle.module (the SPM-generated resource bundle, which works in dev) and
# falls back to Bundle.main.resourceURL/EditorAssets — that fallback is what
# this copy populates for the packaged .app.
EDITOR_ASSETS_SRC="$ROOT/Sources/Nirux/EditorAssets"
if [[ -d "$EDITOR_ASSETS_SRC" ]]; then
    cp -R "$EDITOR_ASSETS_SRC" "$APP/Contents/Resources/EditorAssets"
fi

# Copy and patch Info.plist
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"

# Set rpath so the binary can find Sparkle.framework at runtime
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Nirux"

# Code sign. Local developer builds default to ad-hoc signing. Release builds
# can pass NIRUX_CODESIGN_IDENTITY="Developer ID Application: ..." to produce
# notarizable Developer ID-signed artifacts with hardened runtime enabled.
CODESIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    CODESIGN_ARGS+=(--options runtime --timestamp)
fi

codesign "${CODESIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${CODESIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Create zip for distribution
ditto -c -k --keepParent "$APP" "$ROOT/Nirux.app.zip"

echo "Done: $ROOT/Nirux.app.zip"
