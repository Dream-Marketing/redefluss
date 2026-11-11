# Redefluss für Windows

Dieselbe Idee wie auf dem Mac: **Taste halten → sprechen → loslassen → Text steht am Cursor.**
Lokal mit whisper.cpp, ohne Konto und ohne Cloud. Windows 10 (1809+) und 11, x64.

## Installieren

**Fertiges Paket:** Vom GitHub-Release `Redefluss-X.Y.Z-windows-x64-setup.exe` laden und starten.
Es braucht keine Adminrechte und installiert nach `%LOCALAPPDATA%\Programs\Redefluss`. Die App ist
nicht signiert, deshalb warnt SmartScreen beim ersten Start: **Weitere Informationen → Trotzdem ausführen**.
Alternativ das ZIP entpacken und `Redefluss.exe` starten.

**Aus dem Quellcode** auf dem Windows-PC (installiert bei Bedarf das .NET-SDK 10 per winget):

```powershell
powershell -ExecutionPolicy Bypass -File windows\install.ps1 -WithModel
```

Danach durch die Einführung klicken. Falls Diktate stumm bleiben: **Einstellungen → Datenschutz und
Sicherheit → Mikrofon → „Desktop-Apps Zugriff auf Ihr Mikrofon erlauben"** einschalten.
Eine Freigabe wie „Bedienungshilfen" auf dem Mac gibt es unter Windows nicht.

## Bedienung

| | |
|---|---|
| **F5 halten** | diktieren, beim Loslassen wird eingefügt |
| **F5 zweimal tippen** oder **F5 + Leertaste** | Dauer-Modus, beenden mit erneutem F5 |
| **Esc** | Diktat verwerfen |
| **Strg + Alt + V** | letztes Diktat erneut einfügen |
| Klick auf die Leiste | Diktat ohne Taste starten; ziehen verschiebt sie |

Die Diktiertaste lässt sich ändern (Einstellungen → Allgemein): rechte Strg, AltGr, rechte Umschalt
oder eine beliebige aufgenommene Taste (z. B. F13–F24, Ziffernblock). **Fn geht unter Windows nicht**,
denn die Taste wird in der Tastatur selbst verarbeitet und kommt bei Windows nie an.

- F5 wird abgefangen und lädt im Browser nicht mehr neu (Strg+R geht weiter).
- **Logitech MX Keys:** In Logi Options+ der Diktat-Taste ein „Tastenkürzel" F5 zuweisen. Die
  Werkseinstellung (Win+H, Windows-Spracheingabe) startet sonst das Windows-Diktat. Schickt Options+ nur einen
  sofortigen Tipp, schaltet jeder Tipp den Dauer-Modus um, wie auf dem Mac.
- In Programme, die **als Administrator** laufen, kann Redefluss nicht tippen (Windows-Schutz UIPI).
  Dann landet der Text in der Zwischenablage und die Leiste sagt das.

## Meeting-Mitschrift

Sobald ein anderes Programm das Mikrofon benutzt (Zoom, Teams, Meet im Browser, Webex, Slack …),
schreibt Redefluss nach etwa einer Sekunde automatisch mit. Die Leiste zeigt dann App-Name, Laufzeit und
einen Stopp-Knopf. Legt die App das Mikrofon wieder weg, ist die Mitschrift nach ~2 s fertig und steht
im **Verlauf**, in Abschnitten mit Zeitmarke (`[12:34] …`).

- **Erkennung:** Windows trägt in `HKCU\…\CapabilityAccessManager\ConsentStore\microphone` ein, welche App
  gerade aufnimmt. Das sind dieselben Daten wie beim Mikrofon-Symbol in der Taskleiste. Keine Adminrechte nötig.
  Diktier-Apps, Sprachrekorder und Redefluss selbst zählen nicht.
- **Aufnahme:** Mikrofon + Systemaudio (WASAPI-Loopback des Standard-Ausgabegeräts, also die anderen
  Teilnehmer). Anders als auf dem Mac fragt Windows dafür nicht nach. Es wird **nie Audio gespeichert**, nur Text.
- Abschaltbar unter Einstellungen → Allgemein → Meetings. Von Hand starten geht über das Infobereich-Symbol.
- Wechselt man während des Meetings das *Ausgabe*gerät (z. B. Headset ein), bleibt das Systemaudio beim alten
  Gerät. Dann die Mitschrift einmal stoppen und neu starten.

## Was gegenüber dem Mac fehlt

- Snapshot-Modus für UI-Bilder (`--snapshot`).

Daten liegen in `%APPDATA%\Redefluss` (Einstellungen, Verlauf; gleiches JSON wie auf dem Mac),
Modelle in `%LOCALAPPDATA%\Redefluss\Models` (gefunden werden auch Modelle in `%USERPROFILE%\.cache\whisper-cpp`),
Protokolle in `%LOCALAPPDATA%\Redefluss\logs`. Audio wird nie gespeichert.

## Entwickeln

```
windows/
  src/Redefluss.Core/        plattformneutral (net10.0): Tastenlogik, Textbereinigung, Audio-Mathe, Meeting-Logik,
                             Einstellungen, Verlauf, Modelle, Leisten-Geometrie – läuft und testet auch auf dem Mac
  src/Redefluss.App/         WPF-App (net10.0-windows): Tastatur-Hook, WASAPI, Whisper.net, Einfügen, Fenster
  tests/Redefluss.Core.Tests xUnit
  scripts/publish.ps1        eigenständiges x64-Paket → windows/dist (ZIP, mit Inno Setup auch Setup.exe)
  installer/Redefluss.iss    Inno-Setup-Skript
```

- `dotnet test windows/tests/Redefluss.Core.Tests`: läuft auf macOS, Linux und Windows
- `dotnet build windows/src/Redefluss.App`: kompiliert dank `EnableWindowsTargeting` auch auf dem Mac (starten nur unter Windows)
- `pwsh windows/scripts/publish.ps1 -Version 0.3.0`: Paket bauen
- Tastenverhalten ist durch `HotkeyEngineTests` festgelegt (gleiche Regeln wie `HotkeyMonitorTests` der Mac-Version).
- Leiste ohne WPF-`Button`: Klicks und Ziehen laufen über eigene Mausbehandlung, das Fenster ist `WS_EX_NOACTIVATE`.
- Release: Der Tag `vX.Y.Z` baut über `.github/workflows/windows.yml` und hängt ZIP + Setup.exe an das Release der Mac-Version.
