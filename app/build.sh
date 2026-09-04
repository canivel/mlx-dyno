#!/bin/bash
# Builds Dyno.app: a self-contained macOS app with the Swift UI, a bundled
# Python runtime and MLX inside it. No prerequisites for the person who runs
# the finished app -- they drag it to Applications and open it.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Dyno"
BUNDLE_ID="com.canivel.dyno"
VERSION="0.1.0"
PYTHON_VERSION="3.12"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
RESOURCES="$APP/Contents/Resources"

command -v uv >/dev/null 2>&1 || {
  echo "error: uv is required to build (it supplies the bundled Python runtime)." >&2
  echo "       install it from https://docs.astral.sh/uv/" >&2
  exit 1
}

SLIM=0
[ "${1:-}" = "--slim" ] && SLIM=1   # skip the runtime, for fast UI iteration

echo "==> Compiling the app"
swift build -c release --product Dyno

echo "==> Rendering the icon"
mkdir -p "$BUILD_DIR"
swift Tools/MakeIcon.swift "$BUILD_DIR" >/dev/null
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES"
cp .build/release/Dyno "$APP/Contents/MacOS/Dyno"
cp "$BUILD_DIR/AppIcon.icns" "$RESOURCES/AppIcon.icns"

if [ "$SLIM" -eq 0 ]; then
  echo "==> Bundling the Python runtime (this is the slow part)"
  # uv ships python-build-standalone, which is relocatable: copied into the
  # bundle it keeps working wherever the app ends up.
  PY_BIN="$(uv python find "$PYTHON_VERSION" 2>/dev/null || true)"
  [ -n "$PY_BIN" ] || { uv python install "$PYTHON_VERSION"; PY_BIN="$(uv python find "$PYTHON_VERSION")"; }
  PY_ROOT="$(python3 -c "import os,sys;print(os.path.dirname(os.path.dirname(os.path.realpath('$PY_BIN'))))")"

  rm -rf "$RESOURCES/python"
  cp -R "$PY_ROOT" "$RESOURCES/python"
  # Nothing here is reachable from a background server.
  rm -rf "$RESOURCES/python/lib/python$PYTHON_VERSION/test" \
         "$RESOURCES/python/lib/python$PYTHON_VERSION/idlelib" \
         "$RESOURCES/python/lib/python$PYTHON_VERSION/tkinter" \
         "$RESOURCES/python/lib/python$PYTHON_VERSION/lib2to3" \
         "$RESOURCES/python/share" "$RESOURCES/python/include" 2>/dev/null || true

  echo "==> Installing mlx-dyno[serve] into the bundle"
  rm -rf "$RESOURCES/pylib"
  ( cd .. && uv pip install --quiet \
      --python "$OLDPWD/$RESOURCES/python/bin/python$PYTHON_VERSION" \
      --target "$OLDPWD/$RESOURCES/pylib" ".[serve]" )
  find "$RESOURCES/pylib" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>Dyno</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Menu bar plus an on-demand window: no permanent Dock icon. -->
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

echo "==> Signing"
codesign --force --deep --sign - "$APP" 2>/dev/null

rm -rf "$BUILD_DIR/AppIcon.iconset" "$BUILD_DIR/AppIcon.icns"
echo
echo "Built $APP  ($(du -sh "$APP" | cut -f1))"
echo "  cp -r '$APP' /Applications/     install it"
[ "$SLIM" -eq 1 ] && echo "  (--slim: no Python runtime bundled; the app will look for a dyno CLI)"
exit 0
