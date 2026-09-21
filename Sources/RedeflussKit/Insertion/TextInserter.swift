import AppKit
import Carbon.HIToolbox

/// Fügt Text in die fokussierte App ein: Zwischenablage setzen, ⌘V simulieren,
/// danach den vorherigen Inhalt der Zwischenablage zurückholen.
public final class TextInserter {
    /// Markierungen nach nspasteboard.org: Clipboard-Manager speichern den Text nicht.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    public init() {}

    public enum Outcome {
        case pasted
        /// Keine Bedienungshilfen-Berechtigung: Text liegt nur in der Zwischenablage.
        case copiedOnly
    }

    @discardableResult
    public func insert(_ text: String, restoreClipboard: Bool) -> Outcome {
        let pasteboard = NSPasteboard.general

        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedOnly
        }

        let saved = restoreClipboard ? snapshot(pasteboard) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: Self.concealedType)
        pasteboard.setString("", forType: Self.transientType)
        let ourChange = pasteboard.changeCount

        postPaste()

        if let saved {
            // Manche Apps (Electron, Browser) lesen die Zwischenablage verzögert.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                // Hat der Nutzer inzwischen selbst etwas kopiert, nichts überschreiben.
                guard pasteboard.changeCount == ourChange else { return }
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
        return .pasted
    }

    public func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// ⌘ drücken, V drücken/loslassen, ⌘ loslassen – wie eine echte Tastatur.
    /// Manche Apps (Electron, Browser) werten den Modifier-Zustand über eigene
    /// flagsChanged-Events aus; ein nacktes V-mit-⌘-Flag reicht dort nicht.
    private func postPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey = CGKeyCode(KeyboardLayout.keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V))
        let commandKey = CGKeyCode(kVK_Command)

        let events = [
            CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
            CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
            CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false),
        ]
        // Flags explizit setzen – sonst mischt sich ein evtl. noch gedrücktes Fn/⌥ hinein.
        for (index, event) in events.enumerated() {
            event?.flags = index == 3 ? [] : .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}

public enum KeyboardLayout {
    /// Sucht den Keycode, der im aktuellen Layout das Zeichen erzeugt (z. B. „v" bei Dvorak ≠ 9).
    public static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
        let target = String(character).lowercased()

        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for keyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
                if status == noErr, length > 0,
                   String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return CGKeyCode(keyCode)
                }
            }
            return nil
        }
    }
}
