#!/bin/bash
# Builds GPU Monitor.app: compiles the Swift package, renders the icon, and
# assembles a self-contained bundle. No Xcode project required.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="MLX Station"
BUNDLE_ID="com.danilocanivel.mlxstation"
VERSION="0.1.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Compiling"
swift build -c release --product MLXStation

echo "==> Rendering icon"
mkdir -p "$BUILD_DIR"
swift Tools/MakeIcon.swift "$BUILD_DIR" >/dev/null
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MLXStation "$APP/Contents/MacOS/MLXStation"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>MLXStation</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Menu bar only: no Dock icon, no window in the app switcher. -->
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

rm -rf "$BUILD_DIR/AppIcon.iconset" "$BUILD_DIR/AppIcon.icns"
echo
echo "Built $APP"
echo "  open '$APP'                      run it"
echo "  cp -r '$APP' /Applications/      install it"
