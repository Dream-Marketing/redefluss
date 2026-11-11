# Änderungen

## 0.3.0

- **Windows-Version:** Redefluss läuft jetzt auch unter Windows 10 und 11 (x64), mit Installer ohne Adminrechte. F5 halten → sprechen → loslassen (die Taste ist frei wählbar), Dauer-Modus, Verlauf, Wörterbuch und Meeting-Mitschrift mit Mikrofon und Systemaudio, wie auf dem Mac.

## 0.2.0 – 2026-10-01

- **Meeting-Mitschrift:** Sobald eine andere App (Zoom, Teams, FaceTime, Browser) das Mikrofon nutzt, schreibt Redefluss das Gespräch mit – eigene Stimme plus Systemaudio der anderen Teilnehmer – und legt den Text im Verlauf ab. Reagiert innerhalb von etwa einer Sekunde, endet zwei Sekunden nach dem Auflegen. Abschaltbar in den Einstellungen, von Hand startbar über die Menüleiste. macOS fragt beim ersten Mal nach der Erlaubnis für Systemaudio (macOS 14.2+).
- **Leiste:** lässt sich an jede Stelle ziehen (nahe der Mitte unten rastet sie wieder ein), bleibt auf ihrem Bildschirm und schluckt keine Klicks mehr auf Fenster dahinter. Die Knöpfe in der Freihand-Kapsel reagieren jetzt zuverlässig.
- **Stabilität:** Fehlendes oder wechselndes Mikrofon (z. B. Bluetooth-Headset) führt zu einer Meldung statt zu einem Absturz; ein Gerätewechsel während des Diktats beendet die Aufnahme sauber.
- **Installation:** Der Installer nimmt automatisch die Signatur der schon installierten App (Berechtigungen bleiben erhalten) und legt alte Kopien in den Papierkorb. Die App bietet das beim Start auch selbst an.

## 0.1.0 – 2026-09-21

- Erste Version: Fn halten → sprechen → loslassen, Freihand-Modus, Verlauf, Wörterbuch, lokale Transkription mit whisper.cpp.
