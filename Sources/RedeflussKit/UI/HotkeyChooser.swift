import SwiftUI
import AppKit

extension Notification.Name {
    /// `userInfo[HotkeyRecorder.recordingKey]` ist `true`, solange eine neue Diktiertaste aufgenommen wird.
    static let hotkeyRecordingChanged = Notification.Name("eu.dream-marketing.redefluss.hotkeyRecordingChanged")
}

/// Nimmt im Einstellungs- oder Einführungsfenster eine beliebige Taste als Diktiertaste auf.
///
/// Läuft über einen lokalen Event-Monitor – das Fenster muss vorn sein, Bedienungshilfen sind dafür
/// nicht nötig. Während der Aufnahme wird der globale `HotkeyMonitor` per Notification stummgeschaltet,
/// damit die bisherige Diktiertaste kein Diktat startet.
final class HotkeyRecorder: ObservableObject {
    static let recordingKey = "recording"

    @Published private(set) var isRecording = false
    private var monitor: Any?
    private var completion: ((HotkeyOption?) -> Void)?

    /// `completion` bekommt die aufgenommene Taste – oder nil bei Esc/Abbruch.
    func start(completion: @escaping (HotkeyOption?) -> Void) {
        cancel()
        self.completion = completion
        isRecording = true
        post(recording: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func cancel() { finish(with: nil) }

    /// Gibt `true` zurück, wenn das Event geschluckt werden soll (sonst würde ⌘W das Fenster schließen).
    private func handle(_ event: NSEvent) -> Bool {
        let keyCode = Int64(event.keyCode)
        switch event.type {
        case .keyDown:
            if event.isARepeat { return true }
            if keyCode == 53 { // Esc
                finish(with: nil)
                return true
            }
            finish(with: HotkeyOption(kind: .key, keyCode: keyCode, name: KeyNames.name(forKeyCode: keyCode, kind: .key)))
            return true
        case .flagsChanged:
            // Nur das Drücken zählt (Flag gesetzt). Caps Lock und Unbekanntes werden ignoriert.
            let flags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
            guard let mask = HotkeyOption.modifierMask(forKeyCode: keyCode), flags & mask.rawValue != 0 else { return false }
            finish(with: HotkeyOption(kind: .modifier, keyCode: keyCode, name: KeyNames.name(forKeyCode: keyCode, kind: .modifier)))
            return false
        default:
            return false
        }
    }

    private func finish(with option: HotkeyOption?) {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        post(recording: false)
        let completion = self.completion
        self.completion = nil
        completion?(option?.canonical)
    }

    private func post(recording: Bool) {
        NotificationCenter.default.post(name: .hotkeyRecordingChanged, object: self, userInfo: [Self.recordingKey: recording])
    }
}

/// Auswahl der Diktiertaste: feste Voreinstellungen plus „Eigene Taste", die per Tastendruck aufgenommen wird.
/// Liefert mehrere Zeilen – in einer Form-Section werden daraus Zeilen, in der Einführung ein Stapel.
struct HotkeyChooser: View {
    enum Style { case menu, radio }

    @ObservedObject var settings: AppSettings
    var title: String
    var style: Style

    @StateObject private var recorder = HotkeyRecorder()
    @State private var standardFunctionKeys = Permissions.standardFunctionKeysEnabled
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private static let customTag = "custom"

    var body: some View {
        picker
            .onDisappear { recorder.cancel() }
            .onReceive(refresh) { _ in standardFunctionKeys = Permissions.standardFunctionKeysEnabled }
        if recorder.isRecording {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Jetzt die gewünschte Taste drücken … (Esc bricht ab)")
            }
            .foregroundStyle(.secondary)
        } else if !settings.hotkey.isPreset {
            HStack(spacing: 8) {
                Text("Eigene Taste: ") + Text(settings.hotkey.name).bold()
                Button("Ändern …") { record() }
                    .buttonStyle(.link)
            }
        }
        hint
        if !standardFunctionKeys, !recorder.isRecording, settings.hotkey.isFunctionKey {
            functionKeyWarning
        }
    }

    /// Ohne „Standardfunktionstasten" kommt F5 der Mac-Tastatur als Mikrofontaste an und startet die
    /// macOS-Diktierfunktion statt Redefluss – die Aufnahme würde einfach nichts sehen.
    private var functionKeyWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Die F-Reihe der Mac-Tastatur sendet gerade Sonderfunktionen. F1–F12 kommen dort erst als Tasten an, wenn „F1, F2 usw. als Standardfunktionstasten verwenden“ eingeschaltet ist – Helligkeit und Lautstärke gehen dann nur mit Fn. Ausnahme: F5 funktioniert als Voreinstellung auch so.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Funktionstasten-Einstellung öffnen") { Permissions.openFunctionKeySettings() }
                    .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private var picker: some View {
        let base = Picker(title, selection: selection) {
            ForEach(HotkeyOption.presets) { Text($0.label).tag($0.id) }
            Text(customTitle).tag(Self.customTag)
        }
        switch style {
        case .menu: base
        case .radio: base.pickerStyle(.radioGroup)
        }
    }

    @ViewBuilder
    private var hint: some View {
        Group {
            if settings.hotkey == .fn {
                Text("Fn funktioniert nur auf Apple-Tastaturen. Bei Fremdtastaturen (z. B. Logitech MX Keys) kommt Fn gar nicht bei macOS an – dort eine rechte Modifier-Taste oder „Eigene Taste“ wählen.")
            } else if settings.hotkey == .f5 {
                Text("F5 ist auf der Mac-Tastatur die Mikrofontaste – Redefluss fängt sie ab, macOS-Diktat und Siri springen nicht an. Logitech MX Keys: Fn + F5 halten (oder Fn-Sperre). Die Diktat-Taste von Logi Options+ tippt nur kurz – ein Druck schaltet den Dauer-Modus ein, der nächste aus. Zum Halten in Options+ der Taste das Tastenkürzel F5 zuweisen (Redefluss dabei beenden, Fn + F5 aufnehmen).")
            } else if recorder.isRecording || !settings.hotkey.isPreset {
                Text("Gut geeignet sind Tasten, die du sonst nicht brauchst: F13–F19, Ziffernblock, Einfg, Bild ↑/↓ – oder eine beliebige Modifier-Taste.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var selection: Binding<String> {
        Binding(
            get: { recorder.isRecording || !settings.hotkey.isPreset ? Self.customTag : settings.hotkey.id },
            set: { tag in
                if let preset = HotkeyOption.presets.first(where: { $0.id == tag }) {
                    recorder.cancel()
                    settings.hotkey = preset
                } else if !recorder.isRecording {
                    record()
                }
            }
        )
    }

    private var customTitle: String {
        if !recorder.isRecording, !settings.hotkey.isPreset { return "Eigene Taste: \(settings.hotkey.name)" }
        return "Eigene Taste …"
    }

    private func record() {
        recorder.start { option in
            if let option { settings.hotkey = option }
        }
    }
}
