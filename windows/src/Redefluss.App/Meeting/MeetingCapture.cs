using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Redefluss.App.Audio;
using Redefluss.Core.Audio;

namespace Redefluss.App.Meeting;

/// <summary>
/// Nimmt für die Meeting-Mitschrift das Mikrofon und – wenn gewünscht – das Systemaudio (WASAPI-Loopback
/// des Standard-Ausgabegeräts, also die anderen Teilnehmer) auf und mischt beides zu 16 kHz Mono.
///
/// Takt gibt das Mikrofon vor: Loopback liefert bei Stille gar keine Daten. Zu jedem Mikrofon-Block wird
/// genauso viel Systemaudio aus dem Puffer genommen (fehlt etwas, ist es Stille).
/// </summary>
public sealed class MeetingCapture : IDisposable
{
    /// <summary>Gemischte 16-kHz-Blöcke, vom Audio-Thread.</summary>
    public event Action<float[]>? Samples;

    public bool HasSystemAudio => _loopback is not null;

    private readonly object _lock = new();
    private WasapiCapture? _microphone;
    private WasapiLoopbackCapture? _loopback;
    private StreamingResampler? _micResampler;
    private StreamingResampler? _sysResampler;
    private readonly Queue<float> _system = new();
    private string? _microphoneId;
    private volatile bool _running;

    /// <summary>Mehr Systemaudio puffern wir nicht – sonst laufen die beiden Quellen auseinander.</summary>
    private const int MaxSystemBacklog = AudioMath.SampleRate * 2;

    /// <exception cref="AudioRecorderException">Das Mikrofon lässt sich nicht öffnen.</exception>
    /// <returns>Fehlermeldung, wenn das Systemaudio nicht ging (dann läuft nur das Mikrofon).</returns>
    public string? Start(string? microphoneId, bool systemAudio)
    {
        _microphoneId = microphoneId;
        _running = true;
        StartMicrophone();
        if (!systemAudio) return null;
        try
        {
            StartLoopback();
            return null;
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or ArgumentException)
        {
            Log.Error("Systemaudio", e);
            return "Systemaudio ließ sich nicht aufnehmen – es wird nur das Mikrofon mitgeschrieben.";
        }
    }

    public void Stop()
    {
        _running = false;
        Close(ref _microphone);
        var loopback = _loopback;
        _loopback = null;
        Close(ref loopback);
        lock (_lock) _system.Clear();
    }

    private void StartMicrophone()
    {
        MMDevice device;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            device = (_microphoneId is { } id ? TryGet(enumerator, id) : null)
                     ?? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        }
        catch (COMException e) { throw new AudioRecorderException("Kein Mikrofon gefunden.", e); }

        try
        {
            var capture = WithoutSyncContext(() => new WasapiCapture(device, useEventSync: true, audioBufferMillisecondsLength: 100));
            var format = capture.WaveFormat;
            var resampler = new StreamingResampler(format.SampleRate);
            capture.DataAvailable += (_, e) => OnMicrophone(format, resampler, e.Buffer, e.BytesRecorded);
            capture.RecordingStopped += (_, e) =>
            {
                // Gerät weg oder gewechselt (Headset): nach kurzer Pause neu öffnen, statt stumm weiterzulaufen.
                if (e.Exception is null || !_running) return;
                Log.Error("Meeting-Mikrofon unterbrochen", e.Exception);
                Task.Delay(500).ContinueWith(_ =>
                {
                    if (!_running) return;
                    Close(ref _microphone);
                    try { StartMicrophone(); } catch (Exception ex) { Log.Error("Meeting-Mikrofon neu starten", ex); }
                });
            };
            capture.StartRecording();
            _micResampler = resampler;
            _microphone = capture;
        }
        catch (COMException e) when ((uint)e.HResult == 0x80070005)
        {
            throw new AudioRecorderException("Kein Mikrofonzugriff – Windows-Datenschutzeinstellungen prüfen.", e) { IsAccessDenied = true };
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or ArgumentException)
        {
            throw new AudioRecorderException("Mikrofon nicht bereit – bitte noch einmal versuchen.", e);
        }
    }

    private void StartLoopback()
    {
        var capture = WithoutSyncContext(() => new WasapiLoopbackCapture());
        var format = capture.WaveFormat;
        var resampler = new StreamingResampler(format.SampleRate);
        capture.DataAvailable += (_, e) =>
        {
            var mono = resampler.Process(AudioRecorder.ToMonoFloat(format, e.Buffer, e.BytesRecorded));
            lock (_lock)
            {
                foreach (var s in mono) _system.Enqueue(s);
                while (_system.Count > MaxSystemBacklog) _system.Dequeue();
            }
        };
        capture.RecordingStopped += (_, e) =>
        {
            if (e.Exception is not null) Log.Error("Systemaudio unterbrochen", e.Exception);
        };
        capture.StartRecording();
        _sysResampler = resampler;
        _loopback = capture;
    }

    private void OnMicrophone(WaveFormat format, StreamingResampler resampler, byte[] buffer, int bytes)
    {
        var mic = resampler.Process(AudioRecorder.ToMonoFloat(format, buffer, bytes));
        if (mic.Length == 0) return;
        if (_loopback is not null)
        {
            lock (_lock)
            {
                for (var i = 0; i < mic.Length; i++)
                {
                    var system = _system.Count > 0 ? _system.Dequeue() : 0f;
                    mic[i] = Math.Clamp(mic[i] + system, -1f, 1f);
                }
            }
        }
        Samples?.Invoke(mic);
    }

    private static MMDevice? TryGet(MMDeviceEnumerator enumerator, string id)
    {
        try
        {
            var d = enumerator.GetDevice(id);
            return d.State == DeviceState.Active ? d : null;
        }
        catch (COMException) { return null; }
    }

    /// <summary>NAudio würde sonst RecordingStopped an den UI-Thread schicken.</summary>
    private static T WithoutSyncContext<T>(Func<T> create)
    {
        var previous = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(null);
        try { return create(); }
        finally { SynchronizationContext.SetSynchronizationContext(previous); }
    }

    private static void Close<T>(ref T? capture) where T : class, IWaveIn
    {
        var c = capture;
        capture = null;
        if (c is null) return;
        try { c.StopRecording(); } catch (COMException) { } catch (InvalidOperationException) { }
        c.Dispose();
    }

    public void Dispose() => Stop();
}
