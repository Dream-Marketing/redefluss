#!/usr/bin/env bash
# Baut Redefluss für diesen Mac und installiert es nach /Applications.
#
#   ./scripts/install.sh               bauen + installieren + starten
#   ./scripts/install.sh --with-model  zusätzlich das empfohlene Sprachmodell (574 MB) laden
#
# Umgebungsvariablen (vor allem für Tests):
#   INSTALL_DIR=/pfad   Zielordner statt /Applications
#   NO_TCC_RESET=1      Berechtigungen nie zurücksetzen
#   NO_OPEN=1           App danach nicht starten
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="eu.dream-marketing.redefluss"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
TARGET="$INSTALL_DIR/Redefluss.app"
WITH_MODEL=0
[[ "${1:-}" == "--with-model" ]] && WITH_MODEL=1

# --- Voraussetzungen ---------------------------------------------------------
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MACOS_MAJOR < 14 )); then
  echo "❌ Redefluss braucht macOS 14 (Sonoma) oder neuer – hier läuft $(sw_vers -productVersion)." >&2
  exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "❌ Swift fehlt. Einmal ausführen und dem Dialog folgen:  xcode-select --install" >&2
  exit 1
fi

# --- Bauen -------------------------------------------------------------------
ARCHS="$(uname -m)" ./scripts/build-app.sh

# --- Installieren ------------------------------------------------------------
designated_requirement() {
  codesign -dr - "$1" 2>/dev/null | sed -n 's/^#* *designated => //p'
}

OLD_DR=""
[[ -d "$TARGET" ]] && OLD_DR="$(designated_requirement "$TARGET")"
NEW_DR="$(designated_requirement dist/Redefluss.app)"

if pgrep -f "$TARGET/Contents/MacOS/Redefluss" >/dev/null; then
  echo "▸ Laufende Redefluss-Instanz beenden"
  pkill -f "$TARGET/Contents/MacOS/Redefluss" || true
  sleep 1
fi

echo "▸ Nach $TARGET kopieren"
mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET"
ditto dist/Redefluss.app "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# macOS merkt sich Bedienungshilfen/Mikrofon anhand der Signatur. Hat die sich geändert
# (typisch bei ad-hoc-signierten Neubauten), bleibt ein toter Eintrag stehen, der
# „eingeschaltet" aussieht, aber nicht greift. Dann lieber sauber neu fragen lassen.
if [[ -n "$OLD_DR" && "$OLD_DR" != "$NEW_DR" ]]; then
  echo "▸ Signatur hat sich geändert – Berechtigungen werden neu abgefragt"
fi
if [[ -n "$OLD_DR" && "$OLD_DR" != "$NEW_DR" && -z "${NO_TCC_RESET:-}" ]]; then
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

# --- Optional: Modell --------------------------------------------------------
if (( WITH_MODEL )); then
  MODELS="$HOME/Library/Application Support/Redefluss/Models"
  MODEL_FILE="$MODELS/ggml-large-v3-turbo-q5_0.bin"
  if [[ -f "$MODEL_FILE" ]] || ls "$HOME/.cache/whisper-cpp"/ggml-large-v3-turbo*.bin >/dev/null 2>&1; then
    echo "▸ Sprachmodell ist schon vorhanden"
  else
    echo "▸ Sprachmodell laden (574 MB)"
    mkdir -p "$MODELS"
    curl -fL --retry 3 -C - -o "$MODEL_FILE.part" \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
    mv "$MODEL_FILE.part" "$MODEL_FILE"
  fi
fi

if [[ -z "${NO_OPEN:-}" ]]; then
  open "$TARGET"
fi

cat <<EOF

✅ Redefluss ist installiert: $TARGET

Jetzt bitte selbst (das kann kein Skript übernehmen):
  1. Mikrofon erlauben          – die Einführung fragt danach
  2. Bedienungshilfen erlauben  – Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → Redefluss einschalten
  3. Sprachmodell wählen/laden  – in der Einführung (entfällt mit --with-model)
Dann: Fn halten → sprechen → loslassen.
EOF
