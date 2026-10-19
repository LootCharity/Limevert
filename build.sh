#!/bin/bash
# Builds Limevert.app. Usage: ./build.sh [--universal] [--install]
#   --universal  build for Apple silicon and Intel (used for releases)
#   --install    copy the app to /Applications
# Build products live outside the source folder so file sync never touches them.
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0 INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

OUT="$HOME/Library/Caches/Limevert-build"
if [[ $UNIVERSAL == 1 ]]; then
  # Command Line Tools can't build multi-arch in one go, so build each triple and merge.
  SLICES=()
  for triple in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
    swift build -c release --triple "$triple" --scratch-path "$OUT/spm-$triple"
    SLICES+=("$(swift build -c release --triple "$triple" --scratch-path "$OUT/spm-$triple" --show-bin-path)/Limevert")
  done
  BIN="$OUT/Limevert-universal"
  lipo -create "${SLICES[@]}" -output "$BIN"
else
  swift build -c release --scratch-path "$OUT/spm"
  BIN="$(swift build -c release --scratch-path "$OUT/spm" --show-bin-path)/Limevert"
fi

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

if [[ $INSTALL == 1 ]]; then
  pkill -x Limevert || true
  rm -rf /Applications/Limevert.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Limevert.app"
fi
