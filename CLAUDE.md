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
4. Beim ersten mitgeschriebenen Meeting den Dialog „Systemaudioaufnahme" bestätigen (sonst wird nur das eigene Mikrofon mitgeschrieben)

Nicht versuchen, TCC-Berechtigungen per Skript oder `sqlite3` zu setzen – das geht nicht und soll nicht gehen.

## Entwickeln

- `make test` – Unit-Tests; der Ende-zu-Ende-Test läuft nur, wenn `~/.cache/whisper-cpp/ggml-large-v3-turbo.bin` existiert
- `make run` – bauen und aus `dist/` starten
- `make snapshots` – UI als PNG rendern (`Redefluss --snapshot <ordner>`), für README-Bilder und Sichtprüfung ohne Bildschirmaufnahme-Rechte
- Nach jedem Neubau mit anderer Signatur verlangt macOS die Bedienungshilfen neu; `install.sh` setzt den alten Eintrag dann per `tccutil reset` zurück. Damit das nicht passiert, signiert `build-app.sh` automatisch mit der Identität, mit der `/Applications/Redefluss.app` schon signiert ist (hier: „Apple Development: Mohamad Hani Esmaty"), sofern sie im Schlüsselbund liegt. Eine Test-App aus `dist/` mit anderer Signatur sieht in den Systemeinstellungen „eingeschaltet" aus, bekommt aber keine Rechte (tccd: „Failed to match existing code requirement").
- Klicks und Ziehen auf der Leiste sind durch `FlowBarClickTests` abgesichert (Events direkt ans Panel). Keine SwiftUI-`Button` in der Leiste verwenden – das Panel wird nie Key-Fenster, Buttons schlucken dort den ersten Klick; `onTapGesture` nehmen.

## Regeln

- `Vendor/`, `dist/`, `.build/` und Signaturmaterial (`*.p12`, `~/.redefluss-signing`) nie committen.
- UI-Texte sind deutsch; Füllwortliste nie um „um"/„er" erweitern (normale deutsche Wörter).
- Tastenverhalten (Fn halten, Doppeltipp = Dauer-Modus, Esc, ⌃⌘V) ist durch `HotkeyMonitorTests` festgelegt – bei Änderungen Tests anpassen, nicht umgehen. Die Diktiertaste ist ein Modifier (flagsChanged) oder eine normale Taste (keyDown/keyUp, Autorepeat wird geschluckt); neue Tasten nimmt `HotkeyRecorder` per lokalem NSEvent-Monitor auf und schaltet den Tap derweil stumm. Fn von Fremdtastaturen (Logitech MX Keys) erreicht macOS nie – das ist kein Redefluss-Fehler. F5 der Apple-Tastatur ist ohne „Standardfunktionstasten" die Mikrofontaste und kommt als haltbares keyDown/keyUp mit Keycode 176 (Autorepeat) an; die Voreinstellung `HotkeyOption.f5` nimmt 96 und 176 (`matches`) und schluckt sie – erst dadurch bleiben macOS-Diktat (Tipp) und Siri (Halten) still. hidutil `UserKeyMapping` nicht wieder versuchen: die Eigenschaft steht danach in der Registry, greift bei der internen Tastatur aber nicht (2026-10-23 gemessen). Logi Options+ fängt die Diktat-Taste der MX Keys S ab und postet selbst nur einen sofortigen 176-Tipp (Down/Up < 1 ms, Halten kommt nie an); `HotkeyMonitor` wertet einen Tipp unter `instantTap` (20 ms) als Software-Tipp und schaltet damit den Dauer-Modus um statt zu verwerfen. Ein in Options+ zugewiesenes „Tastenkürzel“ F5 (per Fn+F5 aufgenommen, Redefluss dabei beendet) hält Options+ dagegen so lange wie die Taste – so ist es beim Nutzer eingerichtet und bestätigt; einen Eintrag „F5“ bietet Options+ für die Diktat-Taste nicht an. Fn+F5 dort sendet ein echtes F5 (96). Die globale Einstellung „Standardfunktionstasten" will der Nutzer nicht.
- Die Leiste ist ein 360 × 64 Punkte großes, durchsichtiges Panel; Klicks nimmt es nur über der Kapsel an (`FlowBarController` schaltet `ignoresMouseEvents` nach Mausposition). Lage und Ziehen sind durch `FlowBarGeometryTests` festgelegt.
- Meeting-Mitschrift (`Sources/RedeflussKit/Meeting/`): Erkennung über die Prozess-Objekte der Audio-HAL (wer nutzt das Mikrofon), Systemaudio über Prozess-Tap + Aggregatgerät (macOS 14.2+, ohne Mikrofon), Mikrofon getrennt über `AudioRecorder` mit Voice Processing, beides gemischt in `MeetingMixer`. Grund: Bei Anrufen vom Mac (`com.apple.avconferenced`, FaceTime/iPhone-Anrufe) dämpft macOS das eingebaute Mikrofon für Nicht-VP-Clients um ~40 dB (gemessen 2026-11-16, Teams nicht betroffen); mit eigenem Voice Processing kommt die Stimme voll an. Umgekehrt dämpft Redeflusses eigenes VP das Mikrofon für Teams & Co. (Gegenseite hört den Nutzer kaum) und kostet beim Start 0,5–0,9 s – deshalb VP nur, wenn `VoiceProcessingPolicy` einen Mac-Anruf unter den Mikrofon-Nutzern sieht (Meeting-Start und jedes Diktat). Mit VP liefert die Engine 9 Kanäle, `AVAudioConverter` macht daraus ohne `channelMap = [0]` nur Nullen. Transkription in ~30-s-Abschnitten in den Verlauf. Audio wird nur gespeichert, wenn `meetingSaveAudio` eingeschaltet ist (Standard: aus): `MeetingAudioWriter` schreibt dann während des Gesprächs eine absturzsichere Rohdatei (`….m4a.pcm`) nach `Application Support/Redefluss/Aufnahmen` und wandelt sie am Ende – nach einem Absturz beim nächsten Start (`recoverUnfinished`) – in die .m4a, die am Verlaufseintrag hängt (`HistoryItem.audioFile`) und mit ihm gelöscht wird – diese Voreinstellung nie auf „an" drehen. Die Windows-Version speichert weiterhin kein Audio. Logs: `/usr/bin/log stream --predicate 'subsystem == "eu.dream-marketing.redefluss"'` (in zsh ist `log` ein eingebauter Befehl – ohne vollen Pfad scheitert die Abfrage still). Mikrofon-Pegel stehen in der Kategorie `audio`.
- Objective-C-Exceptions aus AVFoundation (fehlendes/wechselndes Mikrofon) werden über `RDFCatchException` (Target `RedeflussObjC`) gefangen – neue AVAudioEngine-Aufrufe dort hinein, sonst stürzt die App statt eine Meldung zu zeigen.
- Release: `git tag vX.Y.Z && git push origin vX.Y.Z` → GitHub Actions baut, signiert (Secrets `SIGNING_P12_*`) und veröffentlicht DMG + ZIP.

## Windows-Version (`windows/`)

C#/.NET 10 + WPF, eigenständiger Nachbau (kein gemeinsamer Code mit Swift). Details: `windows/README.md`.
- `make windows-test` (läuft auf dem Mac) · `make windows-build` (kompiliert auf dem Mac, starten nur unter Windows) · `make windows-package` (ZIP in `windows/dist`)
- Plattformneutrale Logik gehört nach `windows/src/Redefluss.Core` (testbar ohne Windows), Win32/WPF nach `Redefluss.App`.
- Diktiertaste dort: F5 voreingestellt (Fn erreicht Windows nie); Verhalten durch `HotkeyEngineTests` festgelegt – bei Änderungen an `HotkeyMonitor` die Windows-Tests mitziehen. Strg+Alt+V (linke Alt, nicht AltGr) statt ⌃⌘V.
- Meeting-Mitschrift dort: Erkennung über den ConsentStore in der Registry (`MicrophoneMonitor`, Logik in `Core/Meeting/MicrophoneUsage`), Aufnahme Mikrofon + WASAPI-Loopback (`MeetingCapture`, Mikrofon gibt den Takt vor – Loopback liefert bei Stille nichts). NAudio-Capture-Objekte immer ohne SynchronizationContext erzeugen, sonst landet RecordingStopped auf dem UI-Thread.
