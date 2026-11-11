using System.Text.RegularExpressions;

namespace Redefluss.Core.Text;

public sealed record Replacement(string From, string To)
{
    public Guid Id { get; init; } = Guid.NewGuid();
}

/// <summary>Lokale Nachbearbeitung des Whisper-Rohtexts – bewusst regelbasiert, ohne LLM.</summary>
public sealed class TextPostProcessor(bool removeFillers = true, IReadOnlyList<Replacement>? replacements = null)
{
    private readonly IReadOnlyList<Replacement> _replacements = replacements ?? [];

    private const RegexOptions IgnoreCase = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
    private const string NotWordBefore = @"(?<![\p{L}\p{N}])";
    private const string NotWordAfter = @"(?![\p{L}\p{N}])";

    /// <summary>Gibt den bereinigten Text zurück – oder <c>null</c>, wenn nichts Verwertbares gesagt wurde.</summary>
    public string? Process(string raw)
    {
        // Whisper-Marker wie [Musik], (Applaus), [BLANK_AUDIO], ♪ …
        var text = Regex.Replace(raw, @"\[[^\]]*\]|\([^)]*\)|♪+", " ");
        text = CollapseWhitespace(text);

        if (IsHallucination(text)) return null;

        if (removeFillers) text = StripFillers(text);

        foreach (var r in _replacements)
        {
            if (string.IsNullOrWhiteSpace(r.From)) continue;
            var pattern = NotWordBefore + Regex.Escape(r.From) + NotWordAfter;
            text = Regex.Replace(text, pattern, r.To.Replace("$", "$$"), IgnoreCase);
        }

        text = CollapseWhitespace(text);
        text = CapitalizeFirstLetter(text);
        return text.Length == 0 ? null : text;
    }

    private static string CollapseWhitespace(string text)
    {
        text = Regex.Replace(text, @"\s+", " ");
        text = Regex.Replace(text, @"\s+([,.;:!?])", "$1");
        return text.Trim();
    }

    /// <summary>
    /// Füllwörter (de/en), inklusive eines direkt folgenden Kommas.
    /// Bewusst ohne „um" und „er" – das sind im Deutschen normale Wörter.
    /// </summary>
    internal static string StripFillers(string text)
    {
        const string fillers = "(?:ähm+|äh+|öhm+|öh+|ehm+|hmm+|uhm+|uh+|umm+|erm+)";
        var result = Regex.Replace(text, NotWordBefore + fillers + NotWordAfter + @"[,]?\s*", "", IgnoreCase);
        // Übrig gebliebene Satzzeichen-Reste wie ", ," oder führendes Komma glätten.
        result = Regex.Replace(result, @",(\s*,)+", ",");
        result = Regex.Replace(result, @"^\s*[,;:]\s*", "");
        return result;
    }

    internal static string CapitalizeFirstLetter(string text) =>
        text.Length > 0 && char.IsLower(text[0]) ? char.ToUpper(text[0]) + text[1..] : text;

    private static readonly string[] KnownHallucinations =
    [
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
    ];

    /// <summary>Typische Whisper-Halluzinationen bei Stille oder Rauschen.</summary>
    internal static bool IsHallucination(string text)
    {
        var normalized = text.ToLowerInvariant().Trim().Trim(PunctuationAndSpace(text));
        if (normalized.Length == 0) return true;
        return KnownHallucinations.Any(k => normalized == k || (normalized.StartsWith(k, StringComparison.Ordinal) && k.Length > 12));
    }

    private static char[] PunctuationAndSpace(string text) =>
        text.Where(c => char.IsWhiteSpace(c) || char.IsPunctuation(c)).Distinct().ToArray();
}
