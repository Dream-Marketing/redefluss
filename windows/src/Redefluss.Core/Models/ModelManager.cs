namespace Redefluss.Core.Models;

/// <summary>Ein Modell aus dem whisper.cpp-Katalog auf Hugging Face.</summary>
public sealed record CatalogModel(string Id, string Name, string Note, long SizeBytes)
{
    public string FileName => $"ggml-{Id}.bin";
    public Uri Url => new($"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{FileName}");

    /// <summary>Nur mehrsprachige Modelle – die .en-Varianten können kein Deutsch.</summary>
    public static readonly IReadOnlyList<CatalogModel> Catalog =
    [
        new("large-v3-turbo-q5_0", "Turbo", "Empfohlen · schnell und genau, Deutsch & Englisch", 574_041_195),
        new("large-v3-turbo-q8_0", "Turbo (q8)", "Etwas genauer, etwas größer", 874_188_075),
        new("large-v3-turbo", "Turbo (voll)", "Volle Präzision, braucht mehr Speicher", 1_624_555_275),
        new("small-q5_1", "Small", "Leicht, für ältere PCs ohne Grafikkarte", 190_085_487),
        new("base-q5_1", "Base", "Minimal, deutlich ungenauer", 59_707_625),
    ];

    public static CatalogModel Recommended => Catalog[0];
}

/// <summary>Eine Modelldatei auf der Platte.</summary>
public sealed record InstalledModel(string Path, long SizeBytes, bool IsExternal)
{
    public string FileName => System.IO.Path.GetFileName(Path);

    /// <summary>"ggml-large-v3-turbo-q5_0.bin" → "large-v3-turbo-q5_0"</summary>
    public string ModelId
    {
        get
        {
            var name = System.IO.Path.GetFileNameWithoutExtension(FileName);
            return name.StartsWith("ggml-", StringComparison.Ordinal) ? name[5..] : name;
        }
    }

    public string DisplayName => CatalogModel.Catalog.FirstOrDefault(m => m.Id == ModelId)?.Name ?? ModelId;

    /// <summary>Englisch-Modelle (.en) verstehen kein Deutsch.</summary>
    public bool IsEnglishOnly => ModelId.EndsWith(".en", StringComparison.Ordinal) || ModelId.Contains(".en-", StringComparison.Ordinal);

    public static string DisplayNameFor(string path) => new InstalledModel(path, 0, false).DisplayName;
}

/// <summary>Findet, lädt und löscht Modelle. Ereignisse kommen im SynchronizationContext des Erzeugers an.</summary>
public sealed class ModelManager
{
    public event Action? Changed;

    public string ModelsDirectory { get; }
    /// <summary>Weitere Orte, an denen whisper.cpp-Modelle üblicherweise liegen – dort wird nie gelöscht.</summary>
    private readonly string[] _externalDirectories;
    private readonly SynchronizationContext? _context = SynchronizationContext.Current;
    private readonly HttpClient _http;
    private readonly Dictionary<string, CancellationTokenSource> _tasks = [];
    private readonly Dictionary<string, double> _downloads = [];

    public IReadOnlyList<InstalledModel> Installed { get; private set; } = [];
    /// <summary>Fortschritt 0…1 je Katalog-ID.</summary>
    public IReadOnlyDictionary<string, double> Downloads => _downloads;
    public string? LastError { get; private set; }

    public ModelManager(string? modelsDirectory = null, IEnumerable<string>? externalDirectories = null, HttpClient? http = null)
    {
        ModelsDirectory = modelsDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Redefluss", "Models");
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _externalDirectories = (externalDirectories ??
        [
            Path.Combine(home, ".cache", "whisper-cpp"),
            Path.Combine(home, ".cache", "whisper"),
            Path.Combine(home, "whisper.cpp", "models"),
        ]).ToArray();
        _http = http ?? new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        Directory.CreateDirectory(ModelsDirectory);
        Refresh();
    }

    public void Refresh()
    {
        var found = new List<InstalledModel>();
        foreach (var (dir, external) in new[] { (ModelsDirectory, false) }.Concat(_externalDirectories.Select(d => (d, true))))
        {
            if (!Directory.Exists(dir)) continue;
            foreach (var path in Directory.EnumerateFiles(dir, "ggml-*.bin"))
            {
                var size = new FileInfo(path).Length;
                // Unvollständige Dateien und VAD-Modelle ausblenden.
                if (size <= 20_000_000 || path.Contains("silero", StringComparison.OrdinalIgnoreCase)) continue;
                found.Add(new InstalledModel(path, size, external));
            }
        }
        var rank = CatalogModel.Catalog.Select((m, i) => (m.Id, i)).ToDictionary(x => x.Id, x => x.i);
        Installed = found
            .OrderBy(m => rank.GetValueOrDefault(m.ModelId, 99))
            .ThenBy(m => m.FileName, StringComparer.Ordinal)
            .ToList();
        Notify();
    }

    public InstalledModel? InstalledVersion(CatalogModel model) => Installed.FirstOrDefault(m => m.ModelId == model.Id);

    /// <summary>Bestes vorhandenes Modell für den Start: zuerst Turbo-Varianten, nie reine Englisch-Modelle.</summary>
    public InstalledModel? BestInstalled() => Installed.FirstOrDefault(m => !m.IsEnglishOnly);

    public bool IsDownloading(CatalogModel model) => _tasks.ContainsKey(model.Id);

    /// <summary>Lädt ein Modell herunter. Liefert null bei Abbruch oder Fehler (dann steht <see cref="LastError"/>).</summary>
    public async Task<InstalledModel?> DownloadAsync(CatalogModel model)
    {
        if (_tasks.ContainsKey(model.Id)) return null;
        LastError = null;
        var cts = new CancellationTokenSource();
        _tasks[model.Id] = cts;
        _downloads[model.Id] = 0;
        Notify();

        var destination = Path.Combine(ModelsDirectory, model.FileName);
        var partial = destination + ".part";
        try
        {
            using var response = await _http.GetAsync(model.Url, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            var expected = response.Content.Headers.ContentLength ?? model.SizeBytes;

            await using (var source = await response.Content.ReadAsStreamAsync(cts.Token).ConfigureAwait(false))
            await using (var target = File.Create(partial))
            {
                var buffer = new byte[1 << 16];
                long written = 0;
                double reported = 0;
                int read;
                while ((read = await source.ReadAsync(buffer, cts.Token).ConfigureAwait(false)) > 0)
                {
                    await target.WriteAsync(buffer.AsMemory(0, read), cts.Token).ConfigureAwait(false);
                    written += read;
                    var progress = Math.Min((double)written / expected, 1);
                    // Nicht jedes Paket neu zeichnen.
                    if (progress - reported > 0.004 || progress >= 1)
                    {
                        reported = progress;
                        Post(() => { if (_tasks.ContainsKey(model.Id)) { _downloads[model.Id] = progress; Changed?.Invoke(); } });
                    }
                }
                if (written < expected) throw new IOException("Download unvollständig.");
            }

            File.Move(partial, destination, overwrite: true);
            var installed = new InstalledModel(destination, new FileInfo(destination).Length, false);
            Post(Refresh);
            return installed;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (Exception e)
        {
            LastError = $"Download fehlgeschlagen: {e.Message}";
            return null;
        }
        finally
        {
            try { if (File.Exists(partial)) File.Delete(partial); } catch { /* egal */ }
            Post(() =>
            {
                _tasks.Remove(model.Id);
                _downloads.Remove(model.Id);
                Changed?.Invoke();
            });
        }
    }

    public void CancelDownload(CatalogModel model)
    {
        if (_tasks.Remove(model.Id, out var cts)) cts.Cancel();
        _downloads.Remove(model.Id);
        Notify();
    }

    public void Delete(InstalledModel model)
    {
        if (model.IsExternal) return;
        try { File.Delete(model.Path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        Refresh();
    }

    private void Notify() => Post(() => Changed?.Invoke());

    private void Post(Action action)
    {
        if (_context is null || _context == SynchronizationContext.Current) action();
        else _context.Post(_ => action(), null);
    }
}

public static class ByteFormat
{
    public static string Format(long bytes) => bytes switch
    {
        >= 1_000_000_000 => $"{bytes / 1e9:0.0} GB",
        >= 1_000_000 => $"{bytes / 1e6:0} MB",
        >= 1_000 => $"{bytes / 1e3:0} KB",
        _ => $"{bytes} Byte",
    };
}
