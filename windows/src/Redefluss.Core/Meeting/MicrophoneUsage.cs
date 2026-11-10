namespace Redefluss.Core.Meeting;

/// <summary>Ein fremdes Programm, das gerade das Mikrofon benutzt.</summary>
/// <param name="Key">Registry-Schlüssel (Paketname oder Programmpfad) – eindeutig je App.</param>
/// <param name="Name">Anzeigename, z. B. „Zoom" oder „Teams".</param>
/// <param name="ExecutablePath">Bei klassischen Programmen der Pfad zur .exe, sonst null.</param>
public sealed record MicrophoneUser(string Key, string Name, string? ExecutablePath);

/// <summary>Ein Eintrag aus HKCU\…\CapabilityAccessManager\ConsentStore\microphone.</summary>
/// <param name="KeyName">Unterschlüssel: Paketfamilie (Store-Apps) oder Pfad mit „#" statt „\" (NonPackaged).</param>
public sealed record ConsentEntry(string KeyName, bool IsPackaged, long LastUsedStart, long LastUsedStop);

/// <summary>
/// Wertet aus, wer laut Windows gerade das Mikrofon benutzt. Windows trägt für jede App
/// LastUsedTimeStart/LastUsedTimeStop ein (dieselben Daten wie das Mikrofon-Symbol in der Taskleiste);
/// solange eine App aufnimmt, ist Stop = 0.
/// </summary>
public static class MicrophoneUsage
{
    /// <summary>Mikrofon-Nutzer, die kein Meeting bedeuten: Diktat, Sprachrekorder, andere Diktier-Apps.</summary>
    public static readonly string[] IgnoredNames =
    [
        "redefluss.exe",
        "voiceaccess.exe", "speechruntime.exe", "textinputhost.exe",
        "microsoft.windowssoundrecorder", "microsoft.549981c3f5f10",   // Sprachrekorder, Cortana
        "wispr flow.exe", "wisprflow.exe", "superwhisper.exe", "dragon.exe", "natspeak.exe",
        "audacity.exe", "obs64.exe",
    ];

    private static readonly Dictionary<string, string> KnownNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ["zoom.exe"] = "Zoom",
        ["ms-teams.exe"] = "Teams", ["teams.exe"] = "Teams", ["msteams"] = "Teams", ["microsoftteams"] = "Teams",
        ["chrome.exe"] = "Chrome", ["msedge.exe"] = "Edge", ["firefox.exe"] = "Firefox", ["brave.exe"] = "Brave",
        ["opera.exe"] = "Opera", ["arc.exe"] = "Arc", ["vivaldi.exe"] = "Vivaldi",
        ["slack.exe"] = "Slack", ["discord.exe"] = "Discord", ["skype.exe"] = "Skype", ["microsoft.skypeapp"] = "Skype",
        ["webex.exe"] = "Webex", ["ciscocollabhost.exe"] = "Webex", ["atmgr.exe"] = "Webex",
        ["gotomeeting.exe"] = "GoTo Meeting", ["g2mcomm.exe"] = "GoTo Meeting",
        ["whatsapp.exe"] = "WhatsApp", ["5319275a.whatsappdesktop"] = "WhatsApp",
        ["telegram.exe"] = "Telegram", ["signal.exe"] = "Signal",
    };

    /// <param name="ownExecutable">Pfad der eigenen .exe – nie ein Meeting.</param>
    /// <param name="isRunning">Prüft, ob ein Programm mit diesem Pfad läuft; ein abgestürztes lässt Stop = 0 stehen.</param>
    public static List<MicrophoneUser> ActiveUsers(IEnumerable<ConsentEntry> entries, string? ownExecutable, Func<string, bool>? isRunning = null)
    {
        var users = new List<MicrophoneUser>();
        foreach (var e in entries)
        {
            var inUse = e.LastUsedStart > 0 && (e.LastUsedStop == 0 || e.LastUsedStart > e.LastUsedStop);
            if (!inUse) continue;

            var path = e.IsPackaged ? null : e.KeyName.Replace('#', '\\');
            if (path is not null && ownExecutable is not null && string.Equals(path, ownExecutable, StringComparison.OrdinalIgnoreCase)) continue;

            var id = path is not null ? Path.GetFileName(path.Replace('\\', Path.DirectorySeparatorChar)) : e.KeyName.Split('_')[0];
            if (IgnoredNames.Contains(id.ToLowerInvariant())) continue;
            if (path is not null && isRunning is not null && !isRunning(path)) continue;

            var name = DisplayName(id);
            if (users.All(u => u.Key != e.KeyName)) users.Add(new MicrophoneUser(e.KeyName, name, path));
        }
        return users;
    }

    /// <summary>„zoom.exe" → „Zoom", „MSTeams" → „Teams", sonst Dateiname ohne .exe bzw. Paketname ohne Herausgeber.</summary>
    public static string DisplayName(string id)
    {
        if (KnownNames.TryGetValue(id, out var known)) return known;
        var name = id.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? id[..^4] : id;
        var dot = name.LastIndexOf('.');
        if (dot > 0 && dot < name.Length - 1 && !id.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name[(dot + 1)..];
        return name.Length == 0 ? "Meeting" : char.ToUpper(name[0]) + name[1..];
    }
}
