#!/usr/bin/env bash
# Baut dist/Redefluss.app (Universal: Apple Silicon + Intel) und signiert sie.
#
# Signatur, in dieser Reihenfolge:
#   1. SIGN_IDENTITY (+ optional SIGN_KEYCHAIN) aus der Umgebung
#   2. selbstsignierte Identität aus scripts/create-signing-identity.sh
#   3. die Identität, mit der /Applications/Redefluss.app signiert ist (z. B. „Apple Development"),
#      falls sie im Schlüsselbund liegt – so bleiben Bedienungshilfen & Mikrofon nach dem Update erhalten
#   4. ad-hoc (codesign -s -)
#
# VERSION=1.2.3 setzt die Versionsnummer, sonst wird sie aus dem letzten Git-Tag gelesen.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Redefluss"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ARCHS="${ARCHS:-arm64 x86_64}"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

./scripts/fetch-whisper.sh

ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

echo "▸ swift build (Release, $ARCHS)"
swift build -c release "${ARCH_FLAGS[@]}" --product "$APP_NAME"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "▸ Bundle zusammenbauen"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"

# whisper.framework (macOS-Slice) einbetten – ohne Header und Debug-Symbole.
FRAMEWORK_SRC="Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
ditto "$FRAMEWORK_SRC" "$APP/Contents/Frameworks/whisper.framework"
rm -rf "$APP/Contents/Frameworks/whisper.framework/Versions/A/Headers" \
       "$APP/Contents/Frameworks/whisper.framework/Versions/A/Modules" \
       "$APP/Contents/Frameworks/whisper.framework/Headers" \
       "$APP/Contents/Frameworks/whisper.framework/Modules"

# SwiftPM-Ressourcen-Bundles (falls vorhanden) mitnehmen.
find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

# Nur die gewünschten Architekturen behalten (spart Platz bei ARCHS=arm64).
if [[ "$ARCHS" == "arm64" || "$ARCHS" == "x86_64" ]]; then
  lipo "$APP/Contents/Frameworks/whisper.framework/Versions/A/whisper" -thin "$ARCHS" \
    -output "$APP/Contents/Frameworks/whisper.framework/Versions/A/whisper.thin"
  mv "$APP/Contents/Frameworks/whisper.framework/Versions/A/whisper.thin" \
     "$APP/Contents/Frameworks/whisper.framework/Versions/A/whisper"
fi

# Build-Rechner-Pfade aus dem Binary entfernen (nur /usr/lib/swift wird gebraucht).
for rpath in $(otool -l "$APP/Contents/MacOS/$APP_NAME" | awk '/LC_RPATH/{getline; getline; print $2}' | grep -E "Xcode|Toolchains|CommandLineTools" | sort -u || true); do
  install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/$APP_NAME"
done

echo "▸ Signieren"
SIGN_ARGS=()
IDENTITY="${SIGN_IDENTITY:-}"
KEYCHAIN="${SIGN_KEYCHAIN:-}"
LOCAL_KEYCHAIN="$HOME/.redefluss-signing/redefluss-signing.keychain-db"
if [[ -z "$IDENTITY" && -f "$LOCAL_KEYCHAIN" ]]; then
  security unlock-keychain -p "$(cat "$HOME/.redefluss-signing/.password")" "$LOCAL_KEYCHAIN"
  # codesign nimmt das selbstsignierte Zertifikat erst, wenn es als vertrauenswürdig markiert ist.
  if security find-identity -v -p codesigning "$LOCAL_KEYCHAIN" | grep -q "Redefluss Open Source"; then
    IDENTITY="Redefluss Open Source"
    KEYCHAIN="$LOCAL_KEYCHAIN"
  fi
fi
# Eine installierte App mit anderer Signatur würde alle Berechtigungen verlieren (der Eintrag in den
# Systemeinstellungen sieht dann „eingeschaltet" aus, greift aber nicht). Also dieselbe Identität nehmen.
INSTALLED_APP="${INSTALLED_APP:-/Applications/$APP_NAME.app}"
if [[ -z "$IDENTITY" && -d "$INSTALLED_APP" ]]; then
  INSTALLED_CN="$(codesign -dvv "$INSTALLED_APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  if [[ -n "$INSTALLED_CN" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$INSTALLED_CN\""; then
    IDENTITY="$INSTALLED_CN"
    echo "  (Identität der installierten App weiterverwendet: $IDENTITY)"
  fi
fi
if [[ -n "$KEYCHAIN" ]]; then SIGN_ARGS+=(--keychain "$KEYCHAIN"); fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "  (ad-hoc – Tipp: scripts/create-signing-identity.sh für update-feste Berechtigungen)"
fi
# Hardened Runtime nur mit echter Developer-ID (für Notarisierung); sonst würde die
# Library Validation das eingebettete Framework blockieren.
if [[ "$IDENTITY" == Developer\ ID* ]]; then
  SIGN_ARGS+=(--options runtime --timestamp --entitlements Resources/Redefluss.entitlements)
fi

codesign --force --sign "$IDENTITY" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$IDENTITY" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --identifier "eu.dream-marketing.redefluss" "$APP"
codesign --verify --deep --strict "$APP" 2>&1 | grep -v "^$" || true

echo "✅ $APP ($VERSION, Build $BUILD_NUMBER, signiert mit: $IDENTITY)"
