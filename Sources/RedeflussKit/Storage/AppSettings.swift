import Foundation
import Combine

/// Taste, die das Diktat auslöst (gedrückt halten = aufnehmen).
public enum HotkeyOption: String, CaseIterable, Identifiable, Codable {
    case fn
    case rightOption
    case rightCommand
    case rightControl

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fn: return "Fn / 🌐"
        case .rightOption: return "Rechte ⌥ Option"
        case .rightCommand: return "Rechte ⌘ Command"
        case .rightControl: return "Rechte ⌃ Control"
        }
    }

    public var shortLabel: String {
        switch self {
        case .fn: return "Fn"
        case .rightOption: return "⌥"
        case .rightCommand: return "⌘"
        case .rightControl: return "⌃"
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

    @Published public var hotkey: HotkeyOption { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }
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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = HotkeyOption(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
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
