namespace Redefluss.Core.Hotkey;

/// <summary>Lesbare deutsche Namen für virtuelle Tastencodes – für die Anzeige einer selbst aufgenommenen Taste.</summary>
public static class KeyNames
{
    /// <summary>Optionaler Rückgriff auf das System (GetKeyNameText), von der App gesetzt.</summary>
    public static Func<int, string?>? SystemName { get; set; }

    public static string Name(int vk)
    {
        if (Special.TryGetValue(vk, out var name)) return name;
        if (vk >= Vk.F1 && vk <= Vk.F24) return $"F{vk - Vk.F1 + 1}";
        if (vk is >= 0x60 and <= 0x69) return $"Num {vk - 0x60}";
        if (vk is >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A) return ((char)vk).ToString();
        var system = SystemName?.Invoke(vk);
        return string.IsNullOrWhiteSpace(system) ? $"Taste {vk}" : system;
    }

    private static readonly Dictionary<int, string> Special = new()
    {
        [Vk.LShift] = "Linke Umschalt", [Vk.RShift] = "Rechte Umschalt",
        [Vk.LControl] = "Linke Strg", [Vk.RControl] = "Rechte Strg",
        [Vk.LMenu] = "Linke Alt", [Vk.RMenu] = "AltGr",
        [Vk.LWin] = "Linke Win", [Vk.RWin] = "Rechte Win",
        [Vk.Shift] = "Umschalt", [Vk.Control] = "Strg", [Vk.Menu] = "Alt",
        [0x08] = "Rücktaste", [0x09] = "Tab", [0x0D] = "Eingabe", [0x13] = "Pause", [0x14] = "Feststell",
        [Vk.Escape] = "Esc", [Vk.Space] = "Leertaste",
        [0x21] = "Bild ↑", [0x22] = "Bild ↓", [0x23] = "Ende", [0x24] = "Pos1",
        [0x25] = "←", [0x26] = "↑", [0x27] = "→", [0x28] = "↓",
        [0x2C] = "Druck", [0x2D] = "Einfg", [0x2E] = "Entf",
        [0x5D] = "Kontextmenü",
        [0x6A] = "Num *", [0x6B] = "Num +", [0x6C] = "Num ,", [0x6D] = "Num −", [0x6E] = "Num ,", [0x6F] = "Num /",
        [0x90] = "Num", [0x91] = "Rollen",
        [0xAD] = "Stumm", [0xAE] = "Leiser", [0xAF] = "Lauter",
        [0xB0] = "Nächster Titel", [0xB1] = "Voriger Titel", [0xB2] = "Stopp", [0xB3] = "Wiedergabe/Pause",
        [0xB4] = "E-Mail", [0xB7] = "Rechner",
    };
}
