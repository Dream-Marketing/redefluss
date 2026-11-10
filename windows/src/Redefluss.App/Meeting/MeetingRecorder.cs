using System.Diagnostics;
using System.Windows.Threading;
using Redefluss.App.Transcription;
using Redefluss.Core.Audio;
using Redefluss.Core.Meeting;
using Redefluss.Core.Storage;
using Redefluss.Core.Text;

namespace Redefluss.App.Meeting;

/// <summary>
/// Zeichnet ein Meeting auf: Systemaudio + Mikrofon (oder nur Mikrofon), schneidet den Strom in
/// Abschnitte, transkribiert sie nacheinander und schreibt den Text fortlaufend in den Verlauf.
/// Es wird kein Audio gespeichert – nur der Text. Alle öffentlichen Methoden auf dem UI-Thread.
/// </summary>
public sealed class MeetingRecorder
{
    public enum State { Idle, Recording, Finishing }

    public event Action? StateChanged;
    /// <summary>Pegel 0…1 für die Wellenform (UI-Thread).</summary>
    public event Action<float>? Level;
    /// <summary>Meeting ist fertig im Verlauf – oder null, wenn nichts Verwertbares gesagt wurde.</summary>
    public event Action<HistoryItem?>? Finished;

    public State CurrentState { get; private set; } = State.Idle;
    public string? AppName { get; private set; }
    public bool IsActive => CurrentState != State.Idle;
    /// <summary>Grund, warum nur das Mikrofon läuft – für die Einstellungen.</summary>
    public string? SystemAudioProblem { get; private set; }
    public double Elapsed => _started?.Elapsed.TotalSeconds ?? 0;

    private readonly WhisperTranscriber _transcriber;
    private readonly HistoryStore _history;
    private readonly AppSettings _settings;
    private readonly Dispatcher _ui;

    // Unter _lock (Audio-Thread schreibt, UI-Thread liest am Ende):
    private readonly object _lock = new();
    private TranscriptChunker _chunker = new();
    private long _emittedSamples;
    private int _levelCounter;

    // Nur UI-Thread:
    private MeetingCapture? _capture;
    private HistoryItem? _item;
    private int _pending;
    private bool _dropped;
    private Stopwatch? _started;
    private DispatcherTimer? _maxDuration;

    /// <summary>Mehr Abschnitte warten nicht – sonst frisst ein zu langsamer Rechner den Speicher.</summary>
    private const int MaxPendingChunks = 6;
    private static readonly TimeSpan MaxDuration = TimeSpan.FromHours(4);

    public MeetingRecorder(WhisperTranscriber transcriber, HistoryStore history, AppSettings settings, Dispatcher ui)
    {
        _transcriber = transcriber;
        _history = history;
        _settings = settings;
        _ui = ui;
    }

    /// <summary>Startet die Aufzeichnung; <paramref name="appName"/> erscheint in Leiste und Verlauf.</summary>
    /// <exception cref="Audio.AudioRecorderException">Mikrofon lässt sich nicht öffnen.</exception>
    public void Start(string appName)
    {
        if (CurrentState != State.Idle) return;
        lock (_lock)
        {
            _chunker = new TranscriptChunker();
            _emittedSamples = 0;
        }
        var capture = new MeetingCapture();
        capture.Samples += Ingest;
        SystemAudioProblem = capture.Start(_settings.InputDeviceId, _settings.MeetingSystemAudio);
        _capture = capture;
        _pending = 0;
        _dropped = false;

        var entry = new HistoryItem
        {
            Date = DateTimeOffset.Now, AppName = appName, Kind = HistoryKind.Meeting, InProgress = true,
        };
        _history.Add(entry);
        _item = entry;
        _started = Stopwatch.StartNew();
        AppName = appName;
        CurrentState = State.Recording;
        Log.Info($"Mitschrift gestartet ({appName}, Systemaudio: {capture.HasSystemAudio})");

        _maxDuration?.Stop();
        _maxDuration = new DispatcherTimer(MaxDuration, DispatcherPriority.Normal, (_, _) => Stop(), _ui);
        _maxDuration.Start();
        StateChanged?.Invoke();
    }

    /// <summary>Beendet die Aufnahme; der Rest wird noch transkribiert, dann kommt <see cref="Finished"/>.</summary>
    public void Stop()
    {
        if (CurrentState != State.Recording) return;
        _maxDuration?.Stop();
        _capture?.Stop();
        _capture = null;
        CurrentState = State.Finishing;
        Log.Info($"Mitschrift gestoppt nach {Elapsed:0} s, {_pending} Abschnitte offen");
        StateChanged?.Invoke();

        float[]? rest;
        long offset;
        lock (_lock)
        {
            rest = _chunker.Flush();
            offset = _emittedSamples;
            if (rest is not null) _emittedSamples += rest.Length;
        }
        if (rest is not null && AudioMath.ContainsSpeech(rest)) Transcribe(rest, offset / (double)AudioMath.SampleRate);
        FinishIfDone();
    }

    // MARK: Audio → Abschnitte (Audio-Thread)

    private void Ingest(float[] samples)
    {
        List<(float[] Chunk, double Offset)> ready = [];
        bool sendLevel;
        lock (_lock)
        {
            foreach (var chunk in _chunker.Append(samples))
            {
                ready.Add((chunk, _emittedSamples / (double)AudioMath.SampleRate));
                _emittedSamples += chunk.Length;
            }
            _levelCounter += samples.Length;
            sendLevel = _levelCounter >= AudioMath.SampleRate / 20;
            if (sendLevel) _levelCounter = 0;
        }
        if (sendLevel)
        {
            var level = AudioMath.Level(samples);
            _ui.BeginInvoke(() => Level?.Invoke(level));
        }
        foreach (var (chunk, offset) in ready)
        {
            if (!AudioMath.ContainsSpeech(chunk)) continue;   // Stille nicht transkribieren
            _ui.BeginInvoke(() => Transcribe(chunk, offset));
        }
    }

    // MARK: Transkription (UI-Thread)

    private async void Transcribe(float[] chunk, double offset)
    {
        if (!IsActive) return;
        if (_pending >= MaxPendingChunks)
        {
            _dropped = true;
            return;
        }
        _pending++;
        var processor = new TextPostProcessor(_settings.RemoveFillers, _settings.Replacements);
        try
        {
            var result = await Task.Run(() => _transcriber.TranscribeAsync(chunk, _settings.Language, _settings.WhisperPrompt));
            if (processor.Process(result.Text) is { } text) Append(text, offset, result.Language);
        }
        catch (Exception e)
        {
            Log.Error("Meeting-Abschnitt", e);
        }
        finally
        {
            _pending--;
            FinishIfDone();
        }
    }

    private void Append(string text, double offset, string? language)
    {
        if (_item is not { } item) return;
        var paragraph = $"[{MeetingClock.Format(offset)}] {text}";
        _item = item with
        {
            Text = item.Text.Length == 0 ? paragraph : item.Text + "\n\n" + paragraph,
            AudioSeconds = Elapsed,
            Language = item.Language ?? language,
        };
        _history.Update(_item);
    }

    private void FinishIfDone()
    {
        if (CurrentState != State.Finishing || _pending > 0) return;
        HistoryItem? result = null;
        if (_item is { } finished)
        {
            if (finished.Text.Trim().Length == 0)
            {
                // Nichts Verwertbares gesagt – kein leerer Eintrag im Verlauf.
                _history.Delete(finished.Id);
            }
            else
            {
                finished = finished with
                {
                    InProgress = false,
                    AudioSeconds = Elapsed,
                    Text = _dropped
                        ? finished.Text + "\n\n[…] Teile des Meetings konnten nicht transkribiert werden – der Rechner kam nicht hinterher."
                        : finished.Text,
                };
                _history.Update(finished);
                result = finished;
            }
        }
        _item = null;
        _started = null;
        AppName = null;
        CurrentState = State.Idle;
        Log.Info($"Mitschrift abgeschlossen: {result?.Text.Length ?? 0} Zeichen");
        StateChanged?.Invoke();
        Finished?.Invoke(result);
    }
}
