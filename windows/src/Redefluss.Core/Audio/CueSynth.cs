namespace Redefluss.Core.Audio;

public enum Cue { Start, Stop, Error }

/// <summary>Kurze, leise Signaltöne – synthetisch erzeugt, damit sie nicht wie System-Hinweise klingen.</summary>
public static class CueSynth
{
    public static byte[] Wav(Cue cue) => cue switch
    {
        Cue.Start => Make([(784, 0.055), (1175, 0.075)], 0.22),
        Cue.Stop => Make([(1175, 0.05), (784, 0.07)], 0.18),
        _ => Make([(330, 0.09), (262, 0.12)], 0.2),
    };

    /// <summary>Baut eine WAV-Datei im Speicher aus Sinustönen mit weicher Hüllkurve.</summary>
    internal static byte[] Make((double Frequency, double Seconds)[] notes, double volume)
    {
        const int sampleRate = 44_100;
        var pcm = new List<short>();
        foreach (var (frequency, seconds) in notes)
        {
            var count = (int)(sampleRate * seconds);
            for (var i = 0; i < count; i++)
            {
                var t = (double)i / sampleRate;
                var attack = Math.Min(1, i / (sampleRate * 0.006));
                var release = Math.Min(1, (count - i) / (sampleRate * 0.03));
                // Grundton + leiser Oberton → wärmer als ein reiner Sinus.
                var value = (Math.Sin(2 * Math.PI * frequency * t) + 0.25 * Math.Sin(4 * Math.PI * frequency * t)) / 1.25;
                pcm.Add((short)(Math.Clamp(value * attack * release * volume, -1, 1) * short.MaxValue));
            }
        }

        using var stream = new MemoryStream();
        using var w = new BinaryWriter(stream);
        var byteCount = pcm.Count * 2;
        w.Write("RIFF"u8); w.Write(36 + byteCount);
        w.Write("WAVE"u8);
        w.Write("fmt "u8); w.Write(16); w.Write((short)1); w.Write((short)1);
        w.Write(sampleRate); w.Write(sampleRate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8); w.Write(byteCount);
        foreach (var s in pcm) w.Write(s);
        w.Flush();
        return stream.ToArray();
    }
}
