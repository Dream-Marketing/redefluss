using Redefluss.Core.Audio;

namespace Redefluss.Core.Meeting;

/// <summary>
/// Entscheidet mit kurzer Verzögerung, ob ein Meeting läuft – ein Mikrofon-Zucker beim Gerätewechsel
/// soll das Meeting nicht beenden, ein Soundtest von einer Sekunde keins beginnen.
/// </summary>
public sealed class MeetingDetectionLogic
{
    public enum Change { Started, Ended }

    /// <summary>So lange muss das Mikrofon fremd belegt sein, bevor ein Meeting gilt …</summary>
    public double StartAfter { get; set; } = 1;
    /// <summary>… und so lange frei, bevor es als beendet gilt.</summary>
    public double EndAfter { get; set; } = 2;

    public bool IsMeeting { get; private set; }
    private double? _pendingSince;
    private bool _pendingBusy;

    /// <param name="now">Zeit in Sekunden (beliebiger, monotoner Ursprung).</param>
    public Change? Observe(bool busy, double now)
    {
        if (busy == IsMeeting)
        {
            _pendingSince = null;
            return null;
        }
        if (_pendingSince is not { } since || _pendingBusy != busy)
        {
            _pendingSince = now;
            _pendingBusy = busy;
            return null;
        }
        if (now - since < (busy ? StartAfter : EndAfter)) return null;
        IsMeeting = busy;
        _pendingSince = null;
        return busy ? Change.Started : Change.Ended;
    }

    public void Reset()
    {
        IsMeeting = false;
        _pendingSince = null;
    }
}

/// <summary>
/// Schneidet den Audiostrom eines Meetings in Abschnitte für Whisper – möglichst in Sprechpausen,
/// damit keine Wörter zerteilt werden, und spätestens nach <see cref="MaxSeconds"/> auch ohne Pause.
/// </summary>
public sealed class TranscriptChunker
{
    public int SampleRate { get; init; } = AudioMath.SampleRate;
    /// <summary>Ab dieser Länge wird bei der nächsten Pause geschnitten …</summary>
    public double TargetSeconds { get; init; } = 30;
    /// <summary>… und spätestens hier, auch mitten im Satz.</summary>
    public double MaxSeconds { get; init; } = 45;
    /// <summary>Effektivwert, unter dem ein Fenster als still gilt (≈ -42 dBFS).</summary>
    public float SilenceRms { get; init; } = 0.008f;
    public double WindowSeconds { get; init; } = 0.03;
    /// <summary>So viele stille Fenster hintereinander gelten als Pause (8 × 30 ms ≈ 240 ms).</summary>
    public int MinimumSilentWindows { get; init; } = 8;

    private readonly List<float> _buffer = [];
    private int _analyzed;
    private int _silentRun;

    public double BufferedSeconds => _buffer.Count / (double)SampleRate;

    /// <summary>Hängt neue Samples an und liefert alle Abschnitte, die dadurch vollständig wurden.</summary>
    public List<float[]> Append(ReadOnlySpan<float> samples)
    {
        foreach (var s in samples) _buffer.Add(s);
        var window = Math.Max(1, (int)(SampleRate * WindowSeconds));
        var target = (int)(SampleRate * TargetSeconds);
        var maximum = (int)(SampleRate * MaxSeconds);
        var chunks = new List<float[]>();

        while (true)
        {
            int? cut = null;
            while (_analyzed + window <= _buffer.Count)
            {
                float sum = 0;
                for (var i = _analyzed; i < _analyzed + window; i++) sum += _buffer[i] * _buffer[i];
                _silentRun = MathF.Sqrt(sum / window) < SilenceRms ? _silentRun + 1 : 0;
                _analyzed += window;
                if (_analyzed >= maximum || (_analyzed >= target && _silentRun >= MinimumSilentWindows))
                {
                    cut = _analyzed;
                    break;
                }
            }
            if (cut is not { } c) break;
            chunks.Add(_buffer.GetRange(0, c).ToArray());
            _buffer.RemoveRange(0, c);
            _analyzed = 0;
            _silentRun = 0;
        }
        return chunks;
    }

    /// <summary>Gibt den Rest zurück (z. B. am Ende des Meetings) und leert den Puffer.</summary>
    public float[]? Flush()
    {
        var rest = _buffer.Count == 0 ? null : _buffer.ToArray();
        _buffer.Clear();
        _analyzed = 0;
        _silentRun = 0;
        return rest;
    }
}

public static class MeetingClock
{
    /// <summary>„12:34" bzw. „1:02:03".</summary>
    public static string Format(double seconds)
    {
        var total = (int)Math.Floor(Math.Max(0, seconds));
        var h = total / 3600;
        var m = total % 3600 / 60;
        var s = total % 60;
        return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m:00}:{s:00}";
    }
}
