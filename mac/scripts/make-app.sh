#!/usr/bin/env bash
# Build VibeTranscribe.app from the Swift package.
# Usage: ./scripts/make-app.sh [output-dir]   (default: mac/dist)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-dist}"
APP="$OUT_DIR/VibeTranscribe.app"

echo "Building release binary..."
swift build -c release

BIN=".build/release/VibeTranscribe"
[[ -x "$BIN" ]] || { echo "Build product not found: $BIN"; exit 1; }

echo "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VibeTranscribe"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VibeTranscribe</string>
    <key>CFBundleIdentifier</key>
    <string>com.fahdi.vibetranscribe</string>
    <key>CFBundleName</key>
    <string>VibeTranscribe</string>
    <key>CFBundleDisplayName</key>
    <string>VibeTranscribe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Fahd Murtaza</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper is happy on the local machine.
codesign --force --deep --sign - "$APP"

echo "Done: $APP"
echo "Install: cp -R \"$APP\" /Applications/"
