using System.Diagnostics;
using System.Windows.Threading;
using Microsoft.Win32;
using Redefluss.Core.Meeting;

namespace Redefluss.App.Meeting;

/// <summary>
/// Erkennt Meetings daran, dass ein anderes Programm (Zoom, Teams, der Browser für Meet …) das
/// Mikrofon benutzt. Quelle ist der ConsentStore in der Registry – dieselben Daten, aus denen Windows
/// das Mikrofon-Symbol in der Taskleiste speist. Braucht keine Adminrechte. Abfrage einmal pro Sekunde.
/// </summary>
public sealed class MicrophoneMonitor : IDisposable
{
    private const string ConsentStore = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    /// <summary>Meeting hat begonnen (mit den beteiligten Apps).</summary>
    public event Action<IReadOnlyList<MicrophoneUser>>? Started;
    public event Action? Ended;
    /// <summary>Bei jeder Änderung: wer das Mikrofon gerade benutzt – für die Statusanzeige.</summary>
    public event Action<IReadOnlyList<MicrophoneUser>>? Changed;

    private readonly DispatcherTimer _timer;
    private readonly MeetingDetectionLogic _logic = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private IReadOnlyList<MicrophoneUser> _last = [];
    private readonly string? _ownExecutable = Environment.ProcessPath;

    public bool IsRunning => _timer.IsEnabled;
    public IReadOnlyList<MicrophoneUser> Users => _last;

    public MicrophoneMonitor(Dispatcher dispatcher)
    {
        // Etwas öfter als die Schwellen, damit Start/Ende nach ~1 s bzw. ~2 s entschieden sind.
        _timer = new DispatcherTimer(TimeSpan.FromMilliseconds(500), DispatcherPriority.Background, (_, _) => Poll(), dispatcher);
        _timer.Stop();
    }

    public void Start()
    {
        if (_timer.IsEnabled) return;
        _logic.Reset();
        Poll();
        _timer.Start();
    }

    public void Stop()
    {
        _timer.Stop();
        _logic.Reset();
        if (_last.Count > 0)
        {
            _last = [];
            Changed?.Invoke(_last);
        }
    }

    private void Poll()
    {
        IReadOnlyList<MicrophoneUser> users;
        try
        {
            users = MicrophoneUsage.ActiveUsers(ReadConsentStore(), _ownExecutable, ProcessRunning);
        }
        catch (Exception e)
        {
            Log.Error("Mikrofon-Nutzung lesen", e);
            return;
        }

        if (!users.Select(u => u.Key).SequenceEqual(_last.Select(u => u.Key)))
        {
            _last = users;
            Changed?.Invoke(users);
        }
        switch (_logic.Observe(users.Count > 0, _clock.Elapsed.TotalSeconds))
        {
            case MeetingDetectionLogic.Change.Started:
                Log.Info($"Meeting erkannt: {string.Join(", ", users.Select(u => u.Name))}");
                Started?.Invoke(users);
                break;
            case MeetingDetectionLogic.Change.Ended:
                Log.Info("Meeting zu Ende – Mikrofon ist wieder frei");
                Ended?.Invoke();
                break;
        }
    }

    private static List<ConsentEntry> ReadConsentStore()
    {
        var entries = new List<ConsentEntry>();
        using var root = Registry.CurrentUser.OpenSubKey(ConsentStore);
        if (root is null) return entries;
        foreach (var name in root.GetSubKeyNames())
        {
            if (name == "NonPackaged")
            {
                using var nonPackaged = root.OpenSubKey(name);
                if (nonPackaged is null) continue;
                foreach (var path in nonPackaged.GetSubKeyNames())
                {
                    using var key = nonPackaged.OpenSubKey(path);
                    if (key is not null) entries.Add(Entry(path, false, key));
                }
            }
            else
            {
                using var key = root.OpenSubKey(name);
                if (key is not null) entries.Add(Entry(name, true, key));
            }
        }
        return entries;
    }

    private static ConsentEntry Entry(string name, bool packaged, RegistryKey key) =>
        new(name, packaged, ReadLong(key, "LastUsedTimeStart"), ReadLong(key, "LastUsedTimeStop"));

    private static long ReadLong(RegistryKey key, string value) => key.GetValue(value) switch
    {
        long l => l,
        int i => i,
        _ => 0,
    };

    /// <summary>Ein abgestürztes Programm lässt „Stop = 0" stehen – nur zählen, was wirklich läuft.</summary>
    private static bool ProcessRunning(string path)
    {
        var processes = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(path));
        var running = processes.Length > 0;
        foreach (var p in processes) p.Dispose();
        return running;
    }

    public void Dispose() => _timer.Stop();
}
