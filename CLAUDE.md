# Redefluss – Hinweise für Claude Code

Lokale Diktier-App für macOS (Wispr-Flow-Nachbau): Fn halten → sprechen → loslassen → Text steht am Cursor.
Swift Package (AppKit + SwiftUI), Transkription mit whisper.cpp (vorkompiliertes XCFramework, Metal).

## Installieren auf diesem Mac

```sh
./scripts/install.sh --with-model
```

Das Skript prüft macOS ≥ 14 und Swift, holt whisper.cpp (Checksumme geprüft), baut für die
Architektur dieses Macs, installiert nach `/Applications/Redefluss.app`, lädt das empfohlene
Modell (574 MB, wird übersprungen, wenn in `~/.cache/whisper-cpp` schon ein Turbo-Modell liegt)
und startet die App. Xcode ist **nicht** nötig – die Command Line Tools reichen
(`xcode-select --install`, falls `swift` fehlt).

**Was nur der Mensch kann – danach ausdrücklich darum bitten:**
1. Mikrofon-Dialog bestätigen
2. Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → Redefluss einschalten
3. Einführung durchklicken; falls die Emoji-Auswahl bei Fn aufgeht: Tastatur → „🌐-Taste drücken für" → „Keine Aktion"

Nicht versuchen, TCC-Berechtigungen per Skript oder `sqlite3` zu setzen – das geht nicht und soll nicht gehen.

## Entwickeln

- `make test` – Unit-Tests; der Ende-zu-Ende-Test läuft nur, wenn `~/.cache/whisper-cpp/ggml-large-v3-turbo.bin` existiert
- `make run` – bauen und aus `dist/` starten
- `make snapshots` – UI als PNG rendern (`Redefluss --snapshot <ordner>`), für README-Bilder und Sichtprüfung ohne Bildschirmaufnahme-Rechte
- Nach jedem Neubau mit anderer Signatur verlangt macOS die Bedienungshilfen neu; `install.sh` setzt den alten Eintrag dann per `tccutil reset` zurück.

## Regeln

- `Vendor/`, `dist/`, `.build/` und Signaturmaterial (`*.p12`, `~/.redefluss-signing`) nie committen.
- UI-Texte sind deutsch; Füllwortliste nie um „um"/„er" erweitern (normale deutsche Wörter).
- Tastenverhalten (Fn halten, Doppeltipp = Dauer-Modus, Esc, ⌃⌘V) ist durch `HotkeyMonitorTests` festgelegt – bei Änderungen Tests anpassen, nicht umgehen.
- Release: `git tag vX.Y.Z && git push origin vX.Y.Z` → GitHub Actions baut, signiert (Secrets `SIGNING_P12_*`) und veröffentlicht DMG + ZIP.
