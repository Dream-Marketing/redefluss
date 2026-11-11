namespace Redefluss.Core.Audio;

public static class AudioMath
{
    /// <summary>Whisper erwartet 16 kHz Mono Float32.</summary>
    public const int SampleRate = 16_000;

    /// <summary>Pegel 0…1 aus dem Effektivwert: Sprache liegt meist bei -45…-10 dBFS.</summary>
    public static float Level(ReadOnlySpan<float> chunk)
    {
        if (chunk.IsEmpty) return 0;
        float sum = 0;
        foreach (var s in chunk) sum += s * s;
        var rms = MathF.Sqrt(sum / chunk.Length);
        var db = 20 * MathF.Log10(MathF.Max(rms, 1e-7f));
        return Math.Clamp((db + 50) / 40, 0, 1);
    }

    /// <summary>
    /// Grobe Energieprüfung: Enthält die Aufnahme überhaupt Sprache?
    /// Verhindert, dass Whisper bei reiner Stille halluziniert.
    /// </summary>
    public static bool ContainsSpeech(ReadOnlySpan<float> samples, int sampleRate = SampleRate)
    {
        var window = (int)(sampleRate * 0.03);
        if (samples.Length < window) return false;
        var loudWindows = 0;
        for (var index = 0; index + window <= samples.Length; index += window)
        {
            float sum = 0;
            for (var i = index; i < index + window; i++) sum += samples[i] * samples[i];
            if (MathF.Sqrt(sum / window) > 0.008f) loudWindows++;   // ≈ -42 dBFS
        }
        // Mindestens ~150 ms mit hörbarem Signal.
        return loudWindows >= 5;
    }

    /// <summary>whisper.cpp verarbeitet Clips unter 1 s nicht zuverlässig → mit Stille auffüllen.</summary>
    public static float[] PadForWhisper(float[] samples)
    {
        var minimum = (int)(SampleRate * 1.2);
        if (samples.Length >= minimum) return samples;
        var padded = new float[minimum];
        samples.CopyTo(padded, 0);
        return padded;
    }

    /// <summary>Mischt verschachtelte Mehrkanal-Samples zu Mono.</summary>
    public static float[] DownmixToMono(ReadOnlySpan<float> interleaved, int channels)
    {
        if (channels <= 1) return interleaved.ToArray();
        var frames = interleaved.Length / channels;
        var mono = new float[frames];
        for (var f = 0; f < frames; f++)
        {
            float sum = 0;
            for (var c = 0; c < channels; c++) sum += interleaved[f * channels + c];
            mono[f] = sum / channels;
        }
        return mono;
    }

    /// <summary>
    /// Umrechnung auf 16 kHz mit gefensterter Sinc-Interpolation (Kaiser-ähnliches Blackman-Fenster).
    /// Langsamer als ein Polyphasenfilter, für Diktatlängen aber in wenigen Millisekunden fertig – und
    /// ohne Aliasing, das Whisper aus dem Takt bringt.
    /// </summary>
    public static float[] Resample(float[] input, int fromRate, int toRate = SampleRate)
    {
        if (fromRate == toRate || input.Length == 0) return input;
        var ratio = (double)toRate / fromRate;
        var outLength = (int)Math.Floor(input.Length * ratio);
        var output = new float[outLength];
        // Bei Abwärtswandlung Grenzfrequenz auf die neue Nyquist-Frequenz senken.
        var cutoff = Math.Min(1.0, ratio) * 0.95;
        const int halfTaps = 16;
        var support = halfTaps / cutoff;

        // Lange Diktate (bis 10 min) auf alle Kerne verteilen.
        Parallel.For(0, outLength, new ParallelOptions { MaxDegreeOfParallelism = outLength > 100_000 ? -1 : 1 }, n =>
        {
            var center = n / ratio;
            var start = (int)Math.Ceiling(center - support);
            var end = (int)Math.Floor(center + support);
            double sum = 0, weightSum = 0;
            for (var k = start; k <= end; k++)
            {
                if (k < 0 || k >= input.Length) continue;
                var x = (k - center) * cutoff;
                var sinc = x == 0 ? 1.0 : Math.Sin(Math.PI * x) / (Math.PI * x);
                var w = 0.42 + 0.5 * Math.Cos(Math.PI * (k - center) / support) + 0.08 * Math.Cos(2 * Math.PI * (k - center) / support);
                var weight = sinc * w;
                sum += input[k] * weight;
                weightSum += weight;
            }
            output[n] = weightSum == 0 ? 0 : (float)(sum / weightSum);
        });
        return output;
    }
}
