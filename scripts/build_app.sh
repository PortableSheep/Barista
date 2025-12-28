#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/Barista.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
ZIP_PATH="$DIST_DIR/Barista-macos.zip"

mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Build the SwiftPM executable (release)
pushd "$ROOT_DIR" > /dev/null
swift build -c release
popd > /dev/null

# Copy binary into app bundle
cp "$ROOT_DIR/.build/release/Barista" "$MACOS_DIR/Barista"
chmod +x "$MACOS_DIR/Barista"

# Install Info.plist
cp "$ROOT_DIR/AppInfo/Info.plist" "$APP_DIR/Contents/Info.plist"

# Install app icon
if [[ -f "$ROOT_DIR/AppInfo/AppIcon.icns" ]]; then
	cp "$ROOT_DIR/AppInfo/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Create a simple distribution zip
rm -f "$ZIP_PATH"
pushd "$DIST_DIR" > /dev/null
ditto -c -k --sequesterRsrc --keepParent "Barista.app" "$(basename "$ZIP_PATH")"
popd > /dev/null

echo "Built: $APP_DIR"
echo "Zipped: $ZIP_PATH"
echo "Tip: On first run, macOS Gatekeeper may warn because it's unsigned."
