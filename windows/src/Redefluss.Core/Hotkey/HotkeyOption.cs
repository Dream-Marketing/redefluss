using System.Text.Json.Serialization;

namespace Redefluss.Core.Hotkey;

/// <summary>Virtuelle Tastencodes von Windows (VK_…), soweit Redefluss sie braucht.</summary>
public static class Vk
{
    public const int Shift = 0x10, Control = 0x11, Menu = 0x12;
    public const int Escape = 0x1B, Space = 0x20;
    public const int V = 0x56;
    public const int LWin = 0x5B, RWin = 0x5C;
    public const int F1 = 0x70, F5 = 0x74, F24 = 0x87;
    public const int LShift = 0xA0, RShift = 0xA1;
    public const int LControl = 0xA2, RControl = 0xA3;
    public const int LMenu = 0xA4, RMenu = 0xA5;

    /// <summary>Modifier-Tasten (Umschalt, Strg, Alt, Windows) – auch einzeln als Diktiertaste möglich.</summary>
    public static bool IsModifier(int vk) => vk is Shift or Control or Menu or LWin or RWin
        or LShift or RShift or LControl or RControl or LMenu or RMenu;

    public static bool IsControl(int vk) => vk is Control or LControl or RControl;
    public static bool IsShift(int vk) => vk is Shift or LShift or RShift;
    public static bool IsWin(int vk) => vk is LWin or RWin;
}

public enum HotkeyKind
{
    /// <summary>Modifier (Strg, Alt, Umschalt, Win) – wird nie geschluckt, damit Strg+C &amp; Co. weiter gehen.</summary>
    Modifier,
    /// <summary>Normale Taste (F5, F13 …) – wird immer geschluckt und landet nie in der App.</summary>
    Key,
}

/// <summary>
/// Taste, die das Diktat auslöst (gedrückt halten = aufnehmen).
/// Gleich ist, was dieselbe Taste meint – der Name spielt keine Rolle.
/// </summary>
public sealed record HotkeyOption(HotkeyKind Kind, int KeyCode, string Name)
{
    public static readonly HotkeyOption F5 = new(HotkeyKind.Key, Vk.F5, "F5");
    public static readonly HotkeyOption RightControl = new(HotkeyKind.Modifier, Vk.RControl, "Rechte Strg");
    public static readonly HotkeyOption RightAlt = new(HotkeyKind.Modifier, Vk.RMenu, "AltGr");
    public static readonly HotkeyOption RightShift = new(HotkeyKind.Modifier, Vk.RShift, "Rechte Umschalt");

    /// <summary>Feste Auswahl in der Reihenfolge der Oberfläche.</summary>
    public static readonly IReadOnlyList<HotkeyOption> Presets = [F5, RightControl, RightAlt, RightShift];

    /// <summary>Voreinstellung unter Windows: F5 (Fn ist dort nicht abfangbar).</summary>
    public static HotkeyOption Default => F5;

    [JsonIgnore] public string Id => $"{Kind}-{KeyCode}";
    [JsonIgnore] public bool IsPreset => Presets.Contains(this);

    /// <summary>Langer Name für Auswahllisten.</summary>
    [JsonIgnore]
    public string Label =>
        Equals(F5) ? "F5" :
        Equals(RightControl) ? "Rechte Strg-Taste" :
        Equals(RightAlt) ? "Rechte Alt-Taste (AltGr)" :
        Equals(RightShift) ? "Rechte Umschalttaste" :
        Name;

    /// <summary>Kurzform für die Leiste („F5 halten oder klicken").</summary>
    [JsonIgnore] public string ShortLabel => Name;

    public bool Matches(int keyCode) => keyCode == KeyCode;

    /// <summary>Eine aufgenommene Taste, die einer Voreinstellung entspricht, wird zu dieser.</summary>
    [JsonIgnore] public HotkeyOption Canonical => Presets.FirstOrDefault(p => p.Equals(this)) ?? this;

    public static HotkeyOption FromRecordedKey(int vk) =>
        new HotkeyOption(Vk.IsModifier(vk) ? HotkeyKind.Modifier : HotkeyKind.Key, vk, KeyNames.Name(vk)).Canonical;

    /// <summary>
    /// Warum diese Taste nicht als Diktiertaste taugt – oder null, wenn sie geht.
    /// Buchstaben, Ziffern und Tasten wie Leertaste/Eingabe würden das normale Tippen unmöglich machen.
    /// </summary>
    public static string? Unsuitable(int vk) => vk switch
    {
        Vk.Escape => "Esc bricht ab und kann keine Diktiertaste sein.",
        Vk.Space or 0x0D or 0x09 or 0x08 => "Diese Taste wird zum Schreiben gebraucht.",
        >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A => "Buchstaben und Ziffern werden zum Schreiben gebraucht.",
        >= 0xBA and <= 0xC0 or >= 0xDB and <= 0xDF or 0xE2 => "Satzzeichen-Tasten werden zum Schreiben gebraucht.",
        Vk.LWin or Vk.RWin => "Die Windows-Taste öffnet sonst das Startmenü – bitte eine andere wählen.",
        _ => null,
    };

    public bool Equals(HotkeyOption? other) => other is not null && Kind == other.Kind && KeyCode == other.KeyCode;
    public override int GetHashCode() => HashCode.Combine(Kind, KeyCode);
}
