#!/usr/bin/env bash
# Verpackt dist/Redefluss.app als DMG (mit Programme-Verknüpfung) und ZIP.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Redefluss.app"
[[ -d "$APP" ]] || { echo "❌ Erst scripts/build-app.sh ausführen" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/Redefluss-$VERSION.dmg"
ZIP="$ROOT/dist/Redefluss-$VERSION.zip"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Redefluss.app"
ln -s /Applications "$STAGE/Programme"

rm -f "$DMG" "$ZIP"
hdiutil create -volname "Redefluss $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "✅ $(basename "$DMG") ($(du -h "$DMG" | cut -f1)), $(basename "$ZIP") ($(du -h "$ZIP" | cut -f1))"
