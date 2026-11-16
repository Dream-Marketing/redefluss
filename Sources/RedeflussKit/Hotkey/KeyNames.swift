import CoreGraphics

/// Lesbare Namen für Keycodes – für die Anzeige einer selbst aufgenommenen Diktiertaste.
public enum KeyNames {
    public static func name(forKeyCode keyCode: Int64, kind: HotkeyOption.Kind) -> String {
        switch kind {
        case .modifier:
            return modifierNames[keyCode] ?? "Taste \(keyCode)"
        case .key:
            if let special = specialNames[keyCode] { return special }
            if let character = KeyboardLayout.character(for: CGKeyCode(truncatingIfNeeded: keyCode)),
               isPrintable(character) {
                return character.uppercased()
            }
            return "Taste \(keyCode)"
        }
    }

    /// Steuerzeichen und die privaten Unicode-Codes der Sondertasten (U+F700 …) sind keine Namen.
    private static func isPrintable(_ string: String) -> Bool {
        !string.isEmpty && string.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xE000...0xF8FF).contains(scalar.value)
        }
    }

    private static let modifierNames: [Int64: String] = [
        63: "Fn",
        54: "Rechte ⌘", 55: "Linke ⌘",
        56: "Linke ⇧", 60: "Rechte ⇧",
        58: "Linke ⌥", 61: "Rechte ⌥",
        59: "Linke ⌃", 62: "Rechte ⌃",
    ]

    private static let specialNames: [Int64: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        115: "Pos1", 119: "Ende", 116: "Bild ↑", 121: "Bild ↓", 114: "Einfg / Hilfe", 117: "Entf ⌦",
        51: "Rücktaste ⌫", 48: "Tab ⇥", 36: "Eingabe ↩", 49: "Leertaste", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        65: "Num ,", 67: "Num *", 69: "Num +", 71: "Num Clear", 75: "Num /", 76: "Num ⌅",
        78: "Num −", 81: "Num =",
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4",
        87: "Num 5", 88: "Num 6", 89: "Num 7", 91: "Num 8", 92: "Num 9",
        160: "Mission Control", 131: "Launchpad", 176: "F5",
    ]
}
