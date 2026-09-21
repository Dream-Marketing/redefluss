import Foundation

/// Lokale Nachbearbeitung des Whisper-Rohtexts – bewusst regelbasiert, ohne LLM.
public struct TextPostProcessor {
    public var removeFillers: Bool
    public var replacements: [Replacement]

    public init(removeFillers: Bool = true, replacements: [Replacement] = []) {
        self.removeFillers = removeFillers
        self.replacements = replacements
    }

    /// Gibt den bereinigten Text zurück – oder `nil`, wenn nichts Verwertbares gesagt wurde.
    public func process(_ raw: String) -> String? {
        var text = raw

        // Whisper-Marker wie [Musik], (Applaus), [BLANK_AUDIO], ♪ …
        text = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|♪+"#, with: " ", options: .regularExpression)
        text = collapseWhitespace(text)

        if Self.isHallucination(text) { return nil }

        if removeFillers {
            text = Self.stripFillers(text)
        }

        for replacement in replacements where !replacement.from.trimmingCharacters(in: .whitespaces).isEmpty {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: replacement.from) + #"(?![\p{L}\p{N}])"#
            text = text.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: replacement.to),
                options: [.regularExpression, .caseInsensitive]
            )
        }

        text = collapseWhitespace(text)
        text = Self.capitalizeFirstLetter(text)
        return text.isEmpty ? nil : text
    }

    // MARK: - Bausteine

    private func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Füllwörter (de/en), inklusive eines direkt folgenden Kommas.
    /// Bewusst ohne „um" und „er" – das sind im Deutschen normale Wörter.
    static func stripFillers(_ text: String) -> String {
        let fillers = #"(?:ähm+|äh+|öhm+|öh+|ehm+|hmm+|uhm+|uh+|umm+|erm+)"#
        let pattern = #"(?<![\p{L}\p{N}])"# + fillers + #"(?![\p{L}\p{N}])[,]?\s*"#
        var result = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        // Übrig gebliebene Satzzeichen-Reste wie ", ," oder führendes Komma glätten.
        result = result.replacingOccurrences(of: #",(\s*,)+"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^\s*[,;:]\s*"#, with: "", options: .regularExpression)
        return result
    }

    static func capitalizeFirstLetter(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Typische Whisper-Halluzinationen bei Stille oder Rauschen.
    static func isHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if normalized.isEmpty { return true }
        let known: [String] = [
            "untertitel der amara.org-community",
            "untertitel im auftrag des zdf",
            "untertitelung des zdf",
            "untertitel von stephanie geiges",
            "vielen dank fürs zuschauen",
            "vielen dank für's zuschauen",
            "danke fürs zuschauen",
            "bis zum nächsten mal",
            "thank you for watching",
            "thanks for watching",
            "subtitles by the amara.org community",
            "you",
        ]
        return known.contains { normalized == $0 || (normalized.hasPrefix($0) && $0.count > 12) }
    }
}
