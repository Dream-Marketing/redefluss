import Foundation
import Combine

/// Taste, die das Diktat auslöst (gedrückt halten = aufnehmen).
///
/// Vier Voreinstellungen (Fn und die rechten Modifier) – oder eine beliebige selbst aufgenommene
/// Taste, z. B. F13–F19, Ziffernblock oder eine Sondertaste einer Fremdtastatur (Logitech MX Keys & Co.,
/// deren Fn-Taste macOS nie erreicht).
public struct HotkeyOption: Codable, Hashable, Identifiable {
    public enum Kind: String, Codable {
        /// Modifier-Taste (Fn, ⌘, ⌥, ⌃, ⇧) – kommt als flagsChanged-Event.
        case modifier
        /// Normale Taste – kommt als keyDown/keyUp.
        case key
    }

    public let kind: Kind
    /// Virtueller Keycode (kVK_…), unabhängig vom Layout.
    public let keyCode: Int64
    /// Anzeigename, z. B. „F18", „Num =" oder „Linke ⇧".
    public let name: String

    public init(kind: Kind, keyCode: Int64, name: String) {
        self.kind = kind
        self.keyCode = keyCode
        self.name = name
    }

    public static let fn = HotkeyOption(kind: .modifier, keyCode: 63, name: "Fn")
    public static let rightOption = HotkeyOption(kind: .modifier, keyCode: 61, name: "⌥")
    public static let rightCommand = HotkeyOption(kind: .modifier, keyCode: 54, name: "⌘")
    public static let rightControl = HotkeyOption(kind: .modifier, keyCode: 62, name: "⌃")
    /// F5. Auf der Apple-Tastatur ist das ohne „Standardfunktionstasten" die Mikrofontaste (Keycode 176),
    /// mit Fn oder auf Fremdtastaturen ein normales F5 (Keycode 96) – beides zählt, siehe `matches`.
    public static let f5 = HotkeyOption(kind: .key, keyCode: 96, name: "F5")
    /// Feste Auswahl in der Reihenfolge der Oberfläche.
    public static let presets: [HotkeyOption] = [.fn, .rightOption, .rightCommand, .rightControl, .f5]

    public var id: String { "\(kind.rawValue)-\(keyCode)" }
    public var isPreset: Bool { Self.presets.contains(self) }

    /// F1–F12 außer F5: auf der Apple-Tastatur nur mit „Standardfunktionstasten" erreichbar.
    public var isFunctionKey: Bool { kind == .key && Self.functionKeyCodes.contains(keyCode) && !isMicrophoneKey }
    /// F5 bzw. die Mikrofontaste der Apple-Tastatur – die Voreinstellung `f5`.
    public var isMicrophoneKey: Bool { kind == .key && Self.microphoneKeyCodes.contains(keyCode) }
    private static let functionKeyCodes: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    /// 96 = F5, 176 = Mikrofontaste (F5 der Apple-Tastatur ohne Fn – auch das, was Logi Options+ für „Diktat" schickt).
    static let microphoneKeyCodes: Set<Int64> = [96, 176]

    /// Löst ein Event mit diesem Keycode diese Diktiertaste aus? Die Voreinstellung F5 nimmt beide Codes.
    public func matches(keyCode: Int64, kind: Kind) -> Bool {
        guard kind == self.kind else { return false }
        return keyCode == self.keyCode || (self == .f5 && Self.microphoneKeyCodes.contains(keyCode))
    }

    /// Langer Name für Auswahllisten.
    public var label: String {
        switch self {
        case .fn: return "Fn / 🌐"
        case .rightOption: return "Rechte ⌥ Option"
        case .rightCommand: return "Rechte ⌘ Command"
        case .rightControl: return "Rechte ⌃ Control"
        case .f5: return "F5 / 🎤 Mikrofontaste"
        default: return name
        }
    }

    /// Kurzform für die Leiste („Fn halten oder klicken").
    public var shortLabel: String { name }

    /// Gleiche Taste → gleiche Option, egal wie sie benannt wurde.
    public static func == (lhs: HotkeyOption, rhs: HotkeyOption) -> Bool {
        lhs.kind == rhs.kind && lhs.keyCode == rhs.keyCode
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(keyCode)
    }

    /// Eine aufgenommene Taste, die einer Voreinstellung entspricht, wird zu dieser (die Mikrofontaste zu F5).
    public var canonical: HotkeyOption {
        if isMicrophoneKey { return .f5 }
        return Self.presets.first { $0 == self } ?? self
    }

    /// Frühere Versionen speicherten nur den Namen der Voreinstellung.
    static func legacy(rawValue: String) -> HotkeyOption? {
        switch rawValue {
        case "fn": return .fn
        case "rightOption": return .rightOption
        case "rightCommand": return .rightCommand
        case "rightControl": return .rightControl
        default: return nil
        }
    }
}

/// Vom Nutzer verschobene Lage der Leiste: Mittelpunkt als Anteil 0…1 der sichtbaren Bildschirmfläche,
/// dazu der Bildschirm, auf dem sie abgelegt wurde (nil = der, auf dem sie gerade ist).
public struct FlowBarPosition: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var displayID: UInt32?

    public init(x: Double, y: Double, displayID: UInt32? = nil) {
        self.x = x
        self.y = y
        self.displayID = displayID
    }
}

public struct Replacement: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Alle Nutzereinstellungen, in UserDefaults gespeichert.
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults: UserDefaults

    @Published public var hotkey: HotkeyOption { didSet { saveCodable(hotkey, forKey: "hotkey") } }
    @Published public var handsFreeEnabled: Bool { didSet { defaults.set(handsFreeEnabled, forKey: "handsFreeEnabled") } }
    /// "auto" oder ISO-Code ("de", "en", …).
    @Published public var language: String { didSet { defaults.set(language, forKey: "language") } }
    /// Pfad zur ggml-Modelldatei; leer = noch keins gewählt.
    @Published public var modelPath: String { didSet { defaults.set(modelPath, forKey: "modelPath") } }
    @Published public var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published public var showIdlePill: Bool { didSet { defaults.set(showIdlePill, forKey: "showIdlePill") } }
    @Published public var removeFillers: Bool { didSet { defaults.set(removeFillers, forKey: "removeFillers") } }
    @Published public var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published public var appendTrailingSpace: Bool { didSet { defaults.set(appendTrailingSpace, forKey: "appendTrailingSpace") } }
    @Published public var saveHistory: Bool { didSet { defaults.set(saveHistory, forKey: "saveHistory") } }
    /// UID des Eingabegeräts; nil = Systemstandard.
    @Published public var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") } }
    /// Eigene Wörter (Namen, Fachbegriffe) – gehen als Hinweis an Whisper.
    @Published public var dictionary: [String] { didSet { defaults.set(dictionary, forKey: "dictionary") } }
    @Published public var replacements: [Replacement] { didSet { saveCodable(replacements, forKey: "replacements") } }
    @Published public var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    /// nil = unten mittig (Standard).
    @Published public var flowBarPosition: FlowBarPosition? {
        didSet {
            if let flowBarPosition { saveCodable(flowBarPosition, forKey: "flowBarPosition") } else { defaults.removeObject(forKey: "flowBarPosition") }
        }
    }
    /// Meetings automatisch mitschreiben, sobald eine andere App das Mikrofon nutzt.
    @Published public var meetingAutoRecord: Bool { didSet { defaults.set(meetingAutoRecord, forKey: "meetingAutoRecord") } }
    /// Dabei auch das Systemaudio (die anderen Teilnehmer) aufnehmen – braucht die Berechtigung „Systemaudioaufnahme".
    @Published public var meetingSystemAudio: Bool { didSet { defaults.set(meetingSystemAudio, forKey: "meetingSystemAudio") } }
    /// Das Gespräch zusätzlich als Audiodatei ablegen (Standard: aus – sonst wird nur Text gespeichert).
    @Published public var meetingSaveAudio: Bool { didSet { defaults.set(meetingSaveAudio, forKey: "meetingSaveAudio") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "hotkey"),
           let decoded = try? JSONDecoder().decode(HotkeyOption.self, from: data) {
            hotkey = decoded.canonical
        } else {
            hotkey = defaults.string(forKey: "hotkey").flatMap(HotkeyOption.legacy) ?? .fn
        }
        handsFreeEnabled = defaults.object(forKey: "handsFreeEnabled") as? Bool ?? true
        language = defaults.string(forKey: "language") ?? "auto"
        modelPath = defaults.string(forKey: "modelPath") ?? ""
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        showIdlePill = defaults.object(forKey: "showIdlePill") as? Bool ?? true
        removeFillers = defaults.object(forKey: "removeFillers") as? Bool ?? true
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        appendTrailingSpace = defaults.object(forKey: "appendTrailingSpace") as? Bool ?? true
        saveHistory = defaults.object(forKey: "saveHistory") as? Bool ?? true
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID")
        dictionary = defaults.stringArray(forKey: "dictionary") ?? []
        if let data = defaults.data(forKey: "replacements"),
           let decoded = try? JSONDecoder().decode([Replacement].self, from: data) {
            replacements = decoded
        } else {
            replacements = []
        }
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        if let data = defaults.data(forKey: "flowBarPosition") {
            flowBarPosition = try? JSONDecoder().decode(FlowBarPosition.self, from: data)
        } else {
            flowBarPosition = nil
        }
        meetingAutoRecord = defaults.object(forKey: "meetingAutoRecord") as? Bool ?? true
        meetingSystemAudio = defaults.object(forKey: "meetingSystemAudio") as? Bool ?? true
        meetingSaveAudio = defaults.bool(forKey: "meetingSaveAudio")
    }

    /// Eigene Wörter als Kontext für Whisper; lange Listen werden gekürzt (Prompt ≈ 224 Tokens).
    var whisperPrompt: String {
        let words = dictionary
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        var prompt = ""
        for word in words {
            let next = prompt.isEmpty ? word : prompt + ", " + word
            if next.count > 600 { break }
            prompt = next
        }
        return prompt + "."
    }

    private func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}

public enum SupportedLanguage {
    /// Auswahl für die Einstellungen; Whisper kann mehr, das sind die gängigen.
    public static let all: [(code: String, name: String)] = [
        ("auto", "Automatisch erkennen"),
        ("de", "Deutsch"),
        ("en", "Englisch"),
        ("fr", "Französisch"),
        ("es", "Spanisch"),
        ("it", "Italienisch"),
        ("nl", "Niederländisch"),
        ("pt", "Portugiesisch"),
        ("pl", "Polnisch"),
        ("tr", "Türkisch"),
        ("ar", "Arabisch"),
        ("fa", "Persisch"),
        ("ru", "Russisch"),
        ("uk", "Ukrainisch"),
    ]
}
