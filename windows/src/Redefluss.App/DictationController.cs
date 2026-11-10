using System.ComponentModel;
using System.Windows.Threading;
using Redefluss.App.Audio;
using Redefluss.App.Meeting;
using Redefluss.App.Native;
using Redefluss.App.Transcription;
using Redefluss.App.UI;
using Redefluss.Core.Audio;
using Redefluss.Core.Hotkey;
using Redefluss.Core.Meeting;
using Redefluss.Core.Models;
using Redefluss.Core.Storage;
using Redefluss.Core.Text;
using static Redefluss.App.Native.NativeMethods;

namespace Redefluss.App;

public enum Phase { Idle, Recording, RecordingHandsFree, Transcribing }

public abstract record ModelState
{
    public sealed record None : ModelState;
    public sealed record Loading(string Name) : ModelState;
    public sealed record Ready(string Name) : ModelState;
    public sealed record Failed(string Message) : ModelState;

    public bool IsUsable => this is Ready or Loading;
}

public enum SettingsTab { General, Model, Dictionary, History, About }

/// <summary>Herzstück: verbindet Taste → Aufnahme → whisper.cpp → Nachbearbeitung → Einfügen.</summary>
public sealed class DictationController : IDisposable
{
    public event Action? StateChanged;
    /// <summary>Der Nutzer sollte die Einstellungen sehen (z. B. kein Modell).</summary>
    public event Action<SettingsTab>? NeedsAttention;

    public AppSettings Settings { get; }
    public ModelManager Models { get; }
    public HistoryStore History { get; }
    public FlowBarWindow FlowBar { get; }
    public KeyboardHook Hook { get; }
    public WhisperTranscriber Transcriber { get; } = new();
    public MeetingRecorder Meeting { get; }
    public MicrophoneMonitor MicrophoneMonitor { get; }
    /// <summary>Apps, die gerade das Mikrofon benutzen (für die Statusanzeige in den Einstellungen).</summary>
    public IReadOnlyList<MicrophoneUser> MicrophoneUsers => MicrophoneMonitor.Users;

    public Phase Phase { get; private set; } = Phase.Idle;
    public ModelState ModelState { get; private set; } = new ModelState.None();
    public bool HotkeyActive => Hook.IsRunning;
    public string? LastTranscript { get; private set; }

    private readonly Dispatcher _ui;
    private readonly AudioRecorder _recorder = new();
    private readonly TextInserter _inserter = new();
    private readonly CuePlayer _cues = new();
    private DateTime _recordingStarted;
    private DateTime _lastStartSound = DateTime.MinValue;
    private IntPtr _targetWindow;
    private DispatcherTimer? _maxDuration;
    private DispatcherTimer? _pendingIdle;
    private DispatcherTimer? _meetingClock;

    /// <summary>Obergrenze pro Diktat – danach wird automatisch transkribiert.</summary>
    private static readonly TimeSpan MaxRecording = TimeSpan.FromMinutes(10);

    public DictationController(AppSettings settings, ModelManager models, HistoryStore history, Dispatcher ui)
    {
        Settings = settings;
        Models = models;
        History = history;
        _ui = ui;
        FlowBar = new FlowBarWindow();
        Hook = new KeyboardHook(new HotkeyEngine(), ui);
        Meeting = new MeetingRecorder(Transcriber, history, settings, ui);
        MicrophoneMonitor = new MicrophoneMonitor(ui);
    }

    public void Start()
    {
        Hook.Event += Handle;
        _recorder.Level += level => _ui.BeginInvoke(() => FlowBar.PushLevel(level));
        _recorder.Interrupted += () => _ui.BeginInvoke(RecordingInterrupted);

        FlowBar.StartHandsFreeRequested += StartFromBar;
        FlowBar.StopRequested += FinishRecording;
        FlowBar.CancelRequested += () => CancelRecording(settle: false);
        FlowBar.PositionChanged += p => Settings.FlowBarPosition = p;

        ApplySettings();
        Settings.PropertyChanged += SettingChanged;
        Microsoft.Win32.SystemEvents.SessionSwitch += (_, _) => Hook.WithEngine(e => e.ForgetPressedKeys());
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (_, _) => _ui.BeginInvoke(FlowBar.Reposition);

        FlowBar.ShowIdlePill = Settings.ShowIdlePill;
        FlowBar.Position = Settings.FlowBarPosition;
        FlowBar.SetIdle();
        FlowBar.Show();

        SetUpMeetings();
        if (!Hook.Start())
            FlowBar.ShowMessage("Tastatur-Hook konnte nicht starten – Redefluss neu starten", isError: true, seconds: 6);
        LoadInitialModel();
        Notify();
    }

    private void ApplySettings()
    {
        Hook.WithEngine(e =>
        {
            e.Hotkey = Settings.Hotkey;
            e.HandsFreeEnabled = Settings.HandsFreeEnabled;
        });
        FlowBar.HotkeyLabel = Settings.Hotkey.ShortLabel;
    }

    private void SettingChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppSettings.Hotkey):
            case nameof(AppSettings.HandsFreeEnabled):
                ApplySettings();
                break;
            case nameof(AppSettings.ShowIdlePill):
                FlowBar.ShowIdlePill = Settings.ShowIdlePill;
                break;
            case nameof(AppSettings.FlowBarPosition):
                FlowBar.Position = Settings.FlowBarPosition;
                break;
            case nameof(AppSettings.MeetingAutoRecord):
                if (Settings.MeetingAutoRecord) MicrophoneMonitor.Start(); else MicrophoneMonitor.Stop();
                break;
            case nameof(AppSettings.ModelPath):
                _ = LoadModelAsync(Settings.ModelPath);
                break;
        }
        Notify();
    }

    // MARK: Modell

    private void LoadInitialModel()
    {
        Models.Refresh();
        var path = Settings.ModelPath;
        if (path.Length > 0 && File.Exists(path)) _ = LoadModelAsync(path);
        else if (Models.BestInstalled() is { } best) Settings.ModelPath = best.Path;   // lädt über SettingChanged
        else SetModelState(new ModelState.None());
    }

    public async Task LoadModelAsync(string path)
    {
        if (path.Length == 0)
        {
            SetModelState(new ModelState.None());
            await Transcriber.UnloadAsync();
            return;
        }
        var name = InstalledModel.DisplayNameFor(path);
        SetModelState(new ModelState.Loading(name));
        try
        {
            await Transcriber.LoadAsync(path);
            if (Settings.ModelPath == path) SetModelState(new ModelState.Ready(name));
        }
        catch (Exception e)
        {
            Log.Error("Modell laden", e);
            if (Settings.ModelPath == path) SetModelState(new ModelState.Failed(e.Message));
        }
    }

    private void SetModelState(ModelState state)
    {
        ModelState = state;
        Notify();
    }

    // MARK: Ablauf

    private void Handle(HotkeyEvent e)
    {
        switch (e)
        {
            case HotkeyEvent.Start: BeginRecording(handsFree: false); break;
            case HotkeyEvent.LockHandsFree:
                if (Phase is not (Phase.Recording or Phase.RecordingHandsFree)) return;
                Phase = Phase.RecordingHandsFree;
                FlowBar.SetRecording(handsFree: true);
                Notify();
                break;
            case HotkeyEvent.Stop: FinishRecording(); break;
            case HotkeyEvent.Cancel: CancelRecording(settle: true); break;
            case HotkeyEvent.PasteLast: PasteLast(); break;
        }
    }

    private void ResetHotkey() => Hook.WithEngine(e => e.Reset());

    private void StartFromBar()
    {
        if (Phase != Phase.Idle) return;
        Hook.WithEngine(e => e.EnterHandsFree());
        BeginRecording(handsFree: true);
        if (Phase != Phase.RecordingHandsFree) ResetHotkey();
    }

    private void BeginRecording(bool handsFree)
    {
        // Während noch transkribiert wird, keine neue Aufnahme – und die Taste nicht im Dauer-Modus hängen lassen.
        if (Phase != Phase.Idle)
        {
            if (Phase == Phase.Transcribing) ResetHotkey();
            return;
        }

        if (!ModelState.IsUsable)
        {
            ResetHotkey();
            _cues.Play(Cue.Error);
            FlowBar.ShowMessage("Kein Sprachmodell – hier klicken", isError: true, seconds: 3.5,
                onTap: () => NeedsAttention?.Invoke(SettingsTab.Model));
            return;
        }

        try
        {
            _recorder.Start(Settings.InputDeviceId);
        }
        catch (AudioRecorderException e)
        {
            Log.Error("Aufnahme starten", e);
            ResetHotkey();
            _cues.Play(Cue.Error);
            FlowBar.ShowMessage(e.Message, isError: true, seconds: 4,
                onTap: e.IsAccessDenied ? () => Shell.Open("ms-settings:privacy-microphone") : null);
            return;
        }

        _pendingIdle?.Stop();
        _targetWindow = GetForegroundWindow();
        _recordingStarted = DateTime.Now;
        Phase = handsFree ? Phase.RecordingHandsFree : Phase.Recording;
        FlowBar.SetRecording(handsFree);
        // Beim Doppeltipp nicht zweimal hintereinander piepen.
        if (Settings.PlaySounds && (DateTime.Now - _lastStartSound).TotalSeconds > 0.6)
        {
            _cues.Play(Cue.Start);
            _lastStartSound = DateTime.Now;
        }

        _maxDuration?.Stop();
        _maxDuration = After(MaxRecording, () =>
        {
            ResetHotkey();
            FinishRecording();
        });
        Notify();
    }

    /// <summary>Das Mikrofon ist während des Diktats weggefallen – beenden und das bis dahin Gesagte verwenden.</summary>
    private void RecordingInterrupted()
    {
        if (Phase is not (Phase.Recording or Phase.RecordingHandsFree)) return;
        ResetHotkey();
        FinishRecording();
    }

    /// <param name="settle">Leiste kurz stehen lassen – nach einem kurzen Tipp kommt oft gleich der zweite (Doppeltipp).</param>
    private void CancelRecording(bool settle)
    {
        if (Phase is not (Phase.Recording or Phase.RecordingHandsFree)) return;
        _maxDuration?.Stop();
        _recorder.Discard();
        ResetHotkey();
        Phase = Phase.Idle;
        _pendingIdle?.Stop();
        Notify();
        if (!settle)
        {
            FlowBar.SetIdle();
            return;
        }
        FlowBar.ResetLevels();
        _pendingIdle = After(TimeSpan.FromSeconds(0.45), () => { if (Phase == Phase.Idle) FlowBar.SetIdle(); });
    }

    private async void FinishRecording()
    {
        if (Phase is not (Phase.Recording or Phase.RecordingHandsFree)) return;
        _maxDuration?.Stop();
        ResetHotkey();
        if (Settings.PlaySounds) _cues.Play(Cue.Stop);
        Phase = Phase.Transcribing;
        FlowBar.SetTranscribing();
        Notify();

        // Stoppen wartet auf die letzten Puffer und rechnet auf 16 kHz um – nicht auf dem UI-Thread.
        var samples = await Task.Run(_recorder.Stop);
        var seconds = samples.Length / (double)AudioMath.SampleRate;
        if (!AudioMath.ContainsSpeech(samples))
        {
            Phase = Phase.Idle;
            Notify();
            FlowBar.ShowMessage("Nichts gehört", seconds: 1.4);
            return;
        }

        var processor = new TextPostProcessor(Settings.RemoveFillers, Settings.Replacements);
        var target = _targetWindow;
        TranscriptionResult result;
        try
        {
            result = await Task.Run(() => Transcriber.TranscribeAsync(samples, Settings.Language, Settings.WhisperPrompt));
        }
        catch (Exception e)
        {
            Log.Error("Transkription", e);
            Phase = Phase.Idle;
            Notify();
            _cues.Play(Cue.Error);
            FlowBar.ShowMessage(e.Message, isError: true);
            return;
        }

        Phase = Phase.Idle;
        Notify();
        var cleaned = processor.Process(result.Text);
        if (cleaned is null)
        {
            FlowBar.ShowMessage("Nichts erkannt", seconds: 1.4);
            return;
        }
        var text = Settings.AppendTrailingSpace ? cleaned + " " : cleaned;
        LastTranscript = text;
        var appName = target != IntPtr.Zero ? NativeMethods.AppName(target) : null;
        await DeliverAsync(text, target);
        if (Settings.SaveHistory)
        {
            History.Add(new HistoryItem
            {
                Date = DateTimeOffset.Now,
                Text = cleaned,
                AudioSeconds = seconds,
                AppName = appName,
                Language = result.Language,
                Kind = HistoryKind.Dictation,
            });
        }
        Log.Info($"Diktat: {seconds:0.0} s Audio, {result.Duration.TotalSeconds:0.00} s Rechenzeit ({Transcriber.Runtime})");
    }

    private async Task DeliverAsync(string text, IntPtr target)
    {
        // Falls der Fokus zwischendurch gewechselt ist, zurück zum Zielfenster.
        if (target != IntPtr.Zero && IsWindow(target) && GetForegroundWindow() != target
            && ProcessId(target) != (uint)Environment.ProcessId)
        {
            SetForegroundWindow(target);
            await Task.Delay(120);
        }
        await PasteAsync(text);
    }

    private async Task PasteAsync(string text)
    {
        switch (await _inserter.InsertAsync(text, Settings.RestoreClipboard))
        {
            case TextInserter.Outcome.Pasted:
                FlowBar.SetIdle();
                break;
            case TextInserter.Outcome.CopiedOnly:
                FlowBar.ShowMessage("In die Zwischenablage kopiert (Strg+V)", seconds: 2.6);
                break;
        }
    }

    public void PasteLast()
    {
        if (LastTranscript is { } text && Phase == Phase.Idle) _ = PasteAsync(text);
    }

    public void CopyLast()
    {
        if (LastTranscript is { } text) _inserter.CopyToClipboard(text.Trim());
    }

    // MARK: Meetings

    private void SetUpMeetings()
    {
        MicrophoneMonitor.Changed += _ => Notify();
        MicrophoneMonitor.Started += MeetingDetected;
        // Die Meeting-App hat das Mikrofon freigegeben → Mitschrift abschließen.
        MicrophoneMonitor.Ended += () => { if (Meeting.CurrentState == MeetingRecorder.State.Recording) Meeting.Stop(); };
        if (Settings.MeetingAutoRecord) MicrophoneMonitor.Start();

        FlowBar.StopMeetingRequested += StopMeeting;
        Meeting.Level += level => { if (FlowBar.CurrentMode == FlowBarWindow.Mode.Meeting) FlowBar.PushLevel(level); };
        Meeting.StateChanged += MeetingStateChanged;
        Meeting.Finished += item =>
        {
            if (item is null)
                FlowBar.ShowMessage("Meeting ohne Sprache – nichts gespeichert", seconds: 3);
            else
                FlowBar.ShowMessage("Meeting-Mitschrift im Verlauf gespeichert", seconds: 4,
                    onTap: () => NeedsAttention?.Invoke(SettingsTab.History));
        };
    }

    private void MeetingDetected(IReadOnlyList<MicrophoneUser> users)
    {
        if (!Settings.MeetingAutoRecord || Meeting.IsActive) return;
        if (!ModelState.IsUsable)
        {
            FlowBar.ShowMessage("Meeting erkannt – kein Sprachmodell zum Mitschreiben", isError: true, seconds: 4,
                onTap: () => NeedsAttention?.Invoke(SettingsTab.Model));
            return;
        }
        StartMeeting(users.Select(u => u.Name).Distinct().Order().FirstOrDefault() ?? "Meeting");
    }

    /// <summary>Mitschrift von Hand starten (Menü) – z. B. für ein Gespräch ohne Meeting-App.</summary>
    public void StartMeetingManually()
    {
        if (!ModelState.IsUsable)
        {
            NeedsAttention?.Invoke(SettingsTab.Model);
            return;
        }
        StartMeeting(MicrophoneUsers.FirstOrDefault()?.Name ?? "Meeting");
    }

    private void StartMeeting(string appName)
    {
        try
        {
            Meeting.Start(appName);
            if (Meeting.SystemAudioProblem is { } problem) FlowBar.ShowMessage(problem, isError: true, seconds: 4);
        }
        catch (AudioRecorderException e)
        {
            Log.Error("Meeting starten", e);
            _cues.Play(Cue.Error);
            FlowBar.ShowMessage(e.Message, isError: true, seconds: 4,
                onTap: e.IsAccessDenied ? () => Shell.Open("ms-settings:privacy-microphone") : null);
        }
    }

    public void StopMeeting() => Meeting.Stop();

    private void MeetingStateChanged()
    {
        _meetingClock?.Stop();
        _meetingClock = null;
        switch (Meeting.CurrentState)
        {
            case MeetingRecorder.State.Idle:
                FlowBar.MeetingFinishing = false;
                FlowBar.MeetingLabel = null;
                break;
            case MeetingRecorder.State.Recording:
                FlowBar.MeetingFinishing = false;
                FlowBar.MeetingClock = MeetingClock.Format(0);
                FlowBar.MeetingLabel = Meeting.AppName;
                _meetingClock = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Normal,
                    (_, _) => FlowBar.MeetingClock = MeetingClock.Format(Meeting.Elapsed), _ui);
                _meetingClock.Start();
                break;
            case MeetingRecorder.State.Finishing:
                FlowBar.MeetingLabel = null;
                FlowBar.MeetingFinishing = true;
                break;
        }
        Notify();
    }

    private DispatcherTimer After(TimeSpan delay, Action action)
    {
        var timer = new DispatcherTimer(DispatcherPriority.Normal, _ui) { Interval = delay };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            action();
        };
        timer.Start();
        return timer;
    }

    private void Notify() => StateChanged?.Invoke();

    public void Dispose()
    {
        MicrophoneMonitor.Dispose();
        Meeting.Stop();
        Hook.Dispose();
        if (_recorder.IsRecording) _recorder.Discard();
        Transcriber.Dispose();
    }
}
