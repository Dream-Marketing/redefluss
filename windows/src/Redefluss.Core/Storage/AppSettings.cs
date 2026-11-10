using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using Redefluss.Core.Hotkey;
using Redefluss.Core.Text;

namespace Redefluss.Core.Storage;

/// <summary>
/// Vom Nutzer verschobene Lage der Leiste: Mittelpunkt als Anteil 0…1 der Arbeitsfläche (ohne Taskleiste),
/// dazu der Bildschirm, auf dem sie abgelegt wurde (null = der, auf dem sie gerade ist).
/// </summary>
public sealed record FlowBarPosition(double X, double Y, string? Display = null);

/// <summary>Alle Nutzereinstellungen, als JSON in %APPDATA%\Redefluss\settings.json.</summary>
public sealed class AppSettings : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    [JsonIgnore] public string? FilePath { get; private set; }

    private HotkeyOption _hotkey = HotkeyOption.Default;
    private bool _handsFreeEnabled = true;
    private string _language = "auto";
    private string _modelPath = "";
    private bool _playSounds = true;
    private bool _showIdlePill = true;
    private bool _removeFillers = true;
    private bool _restoreClipboard = true;
    private bool _appendTrailingSpace = true;
    private bool _saveHistory = true;
    private string? _inputDeviceId;
    private List<string> _dictionary = [];
    private List<Replacement> _replacements = [];
    private bool _onboardingDone;
    private FlowBarPosition? _flowBarPosition;
    private bool _meetingAutoRecord = true;
    private bool _meetingSystemAudio = true;

    public HotkeyOption Hotkey { get => _hotkey; set => Set(ref _hotkey, value.Canonical); }
    public bool HandsFreeEnabled { get => _handsFreeEnabled; set => Set(ref _handsFreeEnabled, value); }
    /// <summary>"auto" oder ISO-Code ("de", "en", …).</summary>
    public string Language { get => _language; set => Set(ref _language, value); }
    /// <summary>Pfad zur ggml-Modelldatei; leer = noch keins gewählt.</summary>
    public string ModelPath { get => _modelPath; set => Set(ref _modelPath, value); }
    public bool PlaySounds { get => _playSounds; set => Set(ref _playSounds, value); }
    public bool ShowIdlePill { get => _showIdlePill; set => Set(ref _showIdlePill, value); }
    public bool RemoveFillers { get => _removeFillers; set => Set(ref _removeFillers, value); }
    public bool RestoreClipboard { get => _restoreClipboard; set => Set(ref _restoreClipboard, value); }
    public bool AppendTrailingSpace { get => _appendTrailingSpace; set => Set(ref _appendTrailingSpace, value); }
    public bool SaveHistory { get => _saveHistory; set => Set(ref _saveHistory, value); }
    /// <summary>ID des Eingabegeräts (WASAPI-Endpunkt); null = Windows-Standard.</summary>
    public string? InputDeviceId { get => _inputDeviceId; set => Set(ref _inputDeviceId, value); }
    /// <summary>Eigene Wörter (Namen, Fachbegriffe) – gehen als Hinweis an Whisper.</summary>
    public List<string> Dictionary { get => _dictionary; set => Set(ref _dictionary, value ?? []); }
    public List<Replacement> Replacements { get => _replacements; set => Set(ref _replacements, value ?? []); }
    public bool OnboardingDone { get => _onboardingDone; set => Set(ref _onboardingDone, value); }
    /// <summary>null = unten mittig (Standard).</summary>
    public FlowBarPosition? FlowBarPosition { get => _flowBarPosition; set => Set(ref _flowBarPosition, value); }
    /// <summary>Meetings automatisch mitschreiben, sobald eine andere App das Mikrofon nutzt.</summary>
    public bool MeetingAutoRecord { get => _meetingAutoRecord; set => Set(ref _meetingAutoRecord, value); }
    /// <summary>Dabei auch das Systemaudio (die anderen Teilnehmer) aufnehmen.</summary>
    public bool MeetingSystemAudio { get => _meetingSystemAudio; set => Set(ref _meetingSystemAudio, value); }

    /// <summary>Eigene Wörter als Kontext für Whisper; lange Listen werden gekürzt (Prompt ≈ 224 Tokens).</summary>
    [JsonIgnore]
    public string WhisperPrompt
    {
        get
        {
            var prompt = "";
            foreach (var word in Dictionary.Select(w => w.Trim()).Where(w => w.Length > 0))
            {
                var next = prompt.Length == 0 ? word : prompt + ", " + word;
                if (next.Length > 600) break;
                prompt = next;
            }
            return prompt.Length == 0 ? "" : prompt + ".";
        }
    }

    internal static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static string DefaultDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Redefluss");

    public static AppSettings Load(string? filePath = null)
    {
        filePath ??= Path.Combine(DefaultDirectory, "settings.json");
        AppSettings settings;
        try
        {
            settings = File.Exists(filePath)
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(filePath), Json) ?? new AppSettings()
                : new AppSettings();
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            // Kaputte Datei nicht überschreiben, sondern beiseitelegen.
            try { File.Move(filePath, filePath + ".defekt", overwrite: true); } catch { /* egal */ }
            settings = new AppSettings();
        }
        settings.FilePath = filePath;
        return settings;
    }

    public void Save()
    {
        if (FilePath is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
            File.Move(temp, FilePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Speichern ist nicht kritisch; nächster Versuch beim nächsten Ändern.
        }
    }

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        Save();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}

public static class SupportedLanguage
{
    /// <summary>Auswahl für die Einstellungen; Whisper kann mehr, das sind die gängigen.</summary>
    public static readonly IReadOnlyList<(string Code, string Name)> All =
    [
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
    ];
}
