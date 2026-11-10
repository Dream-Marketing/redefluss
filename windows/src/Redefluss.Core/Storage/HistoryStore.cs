using System.Text.Json;
using System.Text.Json.Serialization;

namespace Redefluss.Core.Storage;

public enum HistoryKind { Dictation, Meeting }

/// <summary>Ein Verlaufseintrag – gleiches JSON-Schema wie die Mac-Version (history.json).</summary>
public sealed record HistoryItem
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public DateTimeOffset Date { get; init; }
    public string Text { get; init; } = "";
    /// <summary>Aufnahmedauer in Sekunden.</summary>
    public double AudioSeconds { get; init; }
    public string? AppName { get; init; }
    public string? Language { get; init; }
    /// <summary>null = Diktat.</summary>
    public HistoryKind? Kind { get; init; }
    public bool? InProgress { get; init; }

    [JsonIgnore] public bool IsMeeting => Kind == HistoryKind.Meeting;
}

/// <summary>Lokaler Verlauf als JSON in %APPDATA%\Redefluss\history.json, neueste zuerst.</summary>
public sealed class HistoryStore
{
    public event Action? Changed;

    private readonly string _filePath;
    private const int Limit = 500;
    private readonly List<HistoryItem> _items;

    public IReadOnlyList<HistoryItem> Items => _items;

    public HistoryStore(string? directory = null)
    {
        var dir = directory ?? AppSettings.DefaultDirectory;
        Directory.CreateDirectory(dir);
        _filePath = Path.Combine(dir, "history.json");
        _items = File.Exists(_filePath) ? Decode(File.ReadAllText(_filePath)) : [];
        // Ein Eintrag, der beim letzten Beenden noch lief, ist jetzt vorbei.
        for (var i = 0; i < _items.Count; i++)
            if (_items[i].InProgress == true) _items[i] = _items[i] with { InProgress = false };
    }

    internal static List<HistoryItem> Decode(string json)
    {
        try { return JsonSerializer.Deserialize<List<HistoryItem>>(json, AppSettings.Json) ?? []; }
        catch (JsonException) { return []; }
    }

    public int TotalWords => _items.Sum(i => i.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length);

    public void Add(HistoryItem item)
    {
        _items.Insert(0, item);
        if (_items.Count > Limit) _items.RemoveRange(Limit, _items.Count - Limit);
        Save();
    }

    /// <summary>Ersetzt den Eintrag mit derselben ID (z. B. wachsende Meeting-Mitschrift).</summary>
    public void Update(HistoryItem item)
    {
        var index = _items.FindIndex(i => i.Id == item.Id);
        if (index < 0) return;
        _items[index] = item;
        Save();
    }

    public void Delete(Guid id)
    {
        _items.RemoveAll(i => i.Id == id);
        Save();
    }

    public void Clear()
    {
        _items.Clear();
        Save();
    }

    private void Save()
    {
        try
        {
            var temp = _filePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(_items, AppSettings.Json));
            File.Move(temp, _filePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        Changed?.Invoke();
    }
}
