#!/usr/bin/env bash
# Lädt das vorkompilierte whisper.cpp-XCFramework (Metal + Core ML) nach Vendor/.
# Seit v1.9.3 hängen die Binaries nicht mehr am v-Tag, sondern am zugehörigen
# Nightly-Tag (b<nummer>) – der v-Release-Text nennt ihn.
set -euo pipefail

WHISPER_BUILD="${WHISPER_BUILD:-b5130}"   # entspricht whisper.cpp v1.9.4
WHISPER_SHA256="${WHISPER_SHA256:-033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
STAMP="$VENDOR/.whisper-build"

if [[ -d "$VENDOR/whisper.xcframework" && "$(cat "$STAMP" 2>/dev/null)" == "$WHISPER_BUILD" ]]; then
  echo "whisper.xcframework ($WHISPER_BUILD) ist schon da."
  exit 0
fi

URL="https://github.com/ggml-org/whisper.cpp/releases/download/$WHISPER_BUILD/whisper-$WHISPER_BUILD-xcframework.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "⬇  $URL"
curl -fL --retry 3 -o "$TMP/whisper.zip" "$URL"

ACTUAL="$(shasum -a 256 "$TMP/whisper.zip" | awk '{print $1}')"
if [[ "$ACTUAL" != "$WHISPER_SHA256" ]]; then
  echo "❌ Checksumme stimmt nicht: $ACTUAL (erwartet $WHISPER_SHA256)" >&2
  exit 1
fi

unzip -q "$TMP/whisper.zip" -d "$TMP/x"
FRAMEWORK="$(find "$TMP/x" -maxdepth 3 -type d -name whisper.xcframework | head -1)"
[[ -n "$FRAMEWORK" ]] || { echo "❌ whisper.xcframework nicht im Archiv gefunden" >&2; exit 1; }

rm -rf "$VENDOR/whisper.xcframework"
mkdir -p "$VENDOR"
mv "$FRAMEWORK" "$VENDOR/whisper.xcframework"
echo "$WHISPER_BUILD" > "$STAMP"
echo "✅ whisper.xcframework ($WHISPER_BUILD) liegt in Vendor/"
