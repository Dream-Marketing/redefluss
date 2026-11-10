using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Redefluss.Core.Audio;

namespace Redefluss.App.Audio;

public sealed class AudioRecorderException(string message, Exception? inner = null) : Exception(message, inner)
{
    /// <summary>Windows verweigert den Mikrofonzugriff (Datenschutzeinstellungen).</summary>
    public bool IsAccessDenied { get; init; }
}

public sealed record AudioInputDevice(string Id, string Name);

/// <summary>
/// Nimmt das Mikrofon über WASAPI (geteilter Modus) auf und liefert am Ende 16-kHz-Mono-Float-Samples.
/// Pro Aufnahme ein frisches Capture-Objekt – das übersteht Gerätewechsel (Headset rein/raus).
/// </summary>
public sealed class AudioRecorder
{
    /// <summary>Pegel 0…1, ca. 20× pro Sekunde, vom Audio-Thread.</summary>
    public event Action<float>? Level;
    /// <summary>Das Gerät ist während der Aufnahme weggefallen (Audio-Thread).</summary>
    public event Action? Interrupted;

    private WasapiCapture? _capture;
    private readonly object _lock = new();
    private readonly List<float> _samples = [];
    private int _sourceRate;
    private ManualResetEventSlim? _stopped;
    private bool _stopping;

    public bool IsRecording => _capture is not null;

    public static IReadOnlyList<AudioInputDevice> Devices()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            return enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
                .Select(d => new AudioInputDevice(d.ID, d.FriendlyName))
                .OrderBy(d => d.Name, StringComparer.CurrentCulture)
                .ToList();
        }
        catch (COMException) { return []; }
    }

    public void Start(string? deviceId)
    {
        StopCapture();
        lock (_lock) _samples.Clear();

        MMDevice device;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            device = (deviceId is not null ? TryGet(enumerator, deviceId) : null)
                     ?? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        }
        catch (COMException e)
        {
            throw new AudioRecorderException("Kein Mikrofon gefunden.", e);
        }

        try
        {
            // Ohne SynchronizationContext erzeugen: Sonst schickt NAudio RecordingStopped an den UI-Thread,
            // und Stop() (das darauf wartet) hinge jedes Mal bis zum Timeout.
            var previous = SynchronizationContext.Current;
            SynchronizationContext.SetSynchronizationContext(null);
            WasapiCapture capture;
            try { capture = new WasapiCapture(device, useEventSync: true, audioBufferMillisecondsLength: 50); }
            finally { SynchronizationContext.SetSynchronizationContext(previous); }
            _sourceRate = capture.WaveFormat.SampleRate;
            var format = capture.WaveFormat;
            capture.DataAvailable += (_, e) => OnData(format, e.Buffer, e.BytesRecorded);
            var stopped = new ManualResetEventSlim();
            _stopped = stopped;
            _stopping = false;
            capture.RecordingStopped += (_, e) =>
            {
                stopped.Set();
                if (e.Exception is not null && !_stopping) Interrupted?.Invoke();
            };
            capture.StartRecording();
            _capture = capture;
        }
        catch (COMException e) when ((uint)e.HResult == 0x80070005)
        {
            throw new AudioRecorderException("Kein Mikrofonzugriff – Windows-Datenschutzeinstellungen prüfen.", e) { IsAccessDenied = true };
        }
        catch (UnauthorizedAccessException e)
        {
            throw new AudioRecorderException("Kein Mikrofonzugriff – Windows-Datenschutzeinstellungen prüfen.", e) { IsAccessDenied = true };
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or ArgumentException)
        {
            throw new AudioRecorderException("Mikrofon nicht bereit – bitte noch einmal versuchen.", e);
        }
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

    /// <summary>Beendet die Aufnahme und gibt alle Samples als 16 kHz Mono zurück.</summary>
    public float[] Stop()
    {
        StopCapture();
        float[] raw;
        lock (_lock)
        {
            raw = _samples.ToArray();
            _samples.Clear();
            _samples.TrimExcess();
        }
        return AudioMath.Resample(raw, _sourceRate == 0 ? AudioMath.SampleRate : _sourceRate);
    }

    /// <summary>Beendet die Aufnahme und verwirft alles.</summary>
    public void Discard()
    {
        StopCapture();
        lock (_lock)
        {
            _samples.Clear();
            _samples.TrimExcess();
        }
    }

    private void StopCapture()
    {
        var capture = _capture;
        if (capture is null) return;
        _capture = null;
        _stopping = true;
        try
        {
            capture.StopRecording();
            // Die letzten Puffer kommen noch nach – kurz warten, damit das Satzende nicht fehlt.
            _stopped?.Wait(TimeSpan.FromMilliseconds(500));
        }
        catch (COMException) { /* Gerät schon weg */ }
        catch (InvalidOperationException) { }
        finally
        {
            capture.Dispose();
        }
    }

    private int _levelCounter;

    private void OnData(WaveFormat format, byte[] buffer, int bytes)
    {
        var mono = ToMonoFloat(format, buffer, bytes);
        if (mono.Length == 0) return;
        lock (_lock) _samples.AddRange(mono);

        // Pegel etwa 20× pro Sekunde reicht für die Wellenform.
        _levelCounter += mono.Length;
        if (_levelCounter >= format.SampleRate / 20)
        {
            _levelCounter = 0;
            Level?.Invoke(AudioMath.Level(mono));
        }
    }

    /// <summary>WASAPI liefert meist 32-Bit-Float, manche Treiber 16/24-Bit-PCM.</summary>
    internal static float[] ToMonoFloat(WaveFormat format, byte[] buffer, int bytes)
    {
        var channels = Math.Max(1, format.Channels);
        var isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat
                      || (format is WaveFormatExtensible ext && ext.SubFormat == NAudio.Dmo.AudioMediaSubtypes.MEDIASUBTYPE_IEEE_FLOAT);
        float[] interleaved;
        switch (format.BitsPerSample)
        {
            case 32 when isFloat:
                interleaved = new float[bytes / 4];
                Buffer.BlockCopy(buffer, 0, interleaved, 0, interleaved.Length * 4);
                break;
            case 16:
                interleaved = new float[bytes / 2];
                for (var i = 0; i < interleaved.Length; i++) interleaved[i] = BitConverter.ToInt16(buffer, i * 2) / 32768f;
                break;
            case 24:
                interleaved = new float[bytes / 3];
                for (var i = 0; i < interleaved.Length; i++)
                {
                    var v = buffer[i * 3] | (buffer[i * 3 + 1] << 8) | ((sbyte)buffer[i * 3 + 2] << 16);
                    interleaved[i] = v / 8388608f;
                }
                break;
            case 32:
                interleaved = new float[bytes / 4];
                for (var i = 0; i < interleaved.Length; i++) interleaved[i] = BitConverter.ToInt32(buffer, i * 4) / 2147483648f;
                break;
            default:
                return [];
        }
        return AudioMath.DownmixToMono(interleaved, channels);
    }
}
