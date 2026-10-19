#!/bin/bash
# Packages a universal Limevert.app into a DMG. Usage: ./release.sh [--publish]
#   --publish  create GitHub Release v<version> with the DMG attached (needs gh, logged in)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
OUT="$HOME/Library/Caches/Limevert-build"
DMG="$OUT/Limevert-$VERSION.dmg"
GH="$(command -v gh || echo "$HOME/.local/bin/gh")"

./build.sh --universal
APP="$OUT/Limevert.app"

# Signing and notarization hook, for when a Developer ID is available:
#   codesign --force --deep --options runtime --sign "Developer ID Application: …" "$APP"
#   (then after the DMG is built)
#   xcrun notarytool submit "$DMG" --keychain-profile limevert --wait
#   xcrun stapler staple "$DMG"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Limevert" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "Built $DMG"
echo "SHA-256 $SHA"

if [[ "${1:-}" == "--publish" ]]; then
  NOTES="$STAGE/notes.md"
  cat > "$NOTES" <<NOTES_EOF
## Install

1. Open \`Limevert-$VERSION.dmg\` and drag **Limevert** into **Applications**.
2. Open Limevert. macOS will say it can't verify the developer, because this build isn't notarized by Apple.
3. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**, then confirm.

Alternatively, in Terminal: \`xattr -dr com.apple.quarantine /Applications/Limevert.app\`

Requires macOS 14 or later, on Apple silicon or Intel. The Liquid Glass wheel appears on macOS 26 and later.

SHA-256: \`$SHA\`
NOTES_EOF
  "$GH" release create "v$VERSION" "$DMG" --title "Limevert $VERSION" --notes-file "$NOTES"
fi
