#!/usr/bin/env bash
# Build StenoDrop.app from the Swift package.
# Usage: ./scripts/make-app.sh [output-dir]   (default: mac/dist)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-dist}"
APP="$OUT_DIR/StenoDrop.app"

echo "Building release binary..."
swift build -c release

BIN=".build/release/StenoDrop"
[[ -x "$BIN" ]] || { echo "Build product not found: $BIN"; exit 1; }

echo "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StenoDrop"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>StenoDrop</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.fahdi.stenodrop</string>
    <key>CFBundleName</key>
    <string>StenoDrop</string>
    <key>CFBundleDisplayName</key>
    <string>StenoDrop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>StenoDrop records audio only to transcribe it on your Mac. Nothing is uploaded.</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Fahd Murtaza</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper is happy on the local machine.
codesign --force --deep --sign - "$APP"

echo "Done: $APP"
echo "Install: cp -R \"$APP\" /Applications/"
