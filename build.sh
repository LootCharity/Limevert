#!/bin/bash
# Builds Limevert.app. Usage: ./build.sh [--install]   (--install copies it to /Applications)
# Build products live outside the source folder so file sync never touches them.
set -euo pipefail
cd "$(dirname "$0")"

OUT="$HOME/Library/Caches/Limevert-build"
swift build -c release --scratch-path "$OUT/spm"
BIN="$(swift build -c release --scratch-path "$OUT/spm" --show-bin-path)/Limevert"

APP="$OUT/Limevert.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Limevert"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"
swift Support/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Limevert || true
  rm -rf /Applications/Limevert.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Limevert.app"
fi
