import AppKit
import AVFoundation
import Carbon.HIToolbox
import ApplicationServices

public enum Permissions {
    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static var microphoneGranted: Bool { microphoneStatus == .authorized }

    public static func requestMicrophone(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Bedienungshilfen: nötig für den globalen Tastatur-Tap und das Einfügen per ⌘V.
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Zeigt den System-Dialog, der die App in die Bedienungshilfen-Liste einträgt.
    public static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    public static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    /// Einstellung „🌐-Taste drücken für": 0 = Keine Aktion, 1 = Eingabequelle,
    /// 2 = Emoji & Symbole, 3 = Diktierfunktion. Alles außer 0 kollidiert mit Fn als Diktiertaste.
    public static var globeKeyAction: Int? {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
    }

    public static var globeKeyConflicts: Bool {
        guard let action = globeKeyAction else { return false }
        return action != 0
    }

    public static var globeKeyActionName: String {
        switch globeKeyAction {
        case 1: return "Eingabequelle wechseln"
        case 2: return "Emoji & Symbole anzeigen"
        case 3: return "Diktierfunktion starten"
        default: return "Keine Aktion"
        }
    }

    /// „Sichere Tastatureingabe" (z. B. im Terminal oder bei Passwortfeldern) blockiert globale Tastenkürzel.
    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
