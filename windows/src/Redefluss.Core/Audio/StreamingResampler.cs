namespace Redefluss.Core.Audio;

/// <summary>
/// Fortlaufende Umrechnung auf 16 kHz für lange Mitschnitte (Meetings): gleicher gefensterter
/// Sinc-Filter wie <see cref="AudioMath.Resample"/>, aber in Blöcken, ohne Knackser an den Blockgrenzen.
/// </summary>
public sealed class StreamingResampler
{
    private readonly double _ratio;
    private readonly double _cutoff;
    private readonly double _support;
    private readonly List<float> _input = [];
    /// <summary>Position des nächsten Ausgabesamples in Eingabe-Koordinaten, relativ zu <see cref="_input"/>[0].</summary>
    private double _position;
    private readonly bool _passThrough;

    public StreamingResampler(int fromRate, int toRate = AudioMath.SampleRate)
    {
        _passThrough = fromRate == toRate;
        _ratio = (double)toRate / fromRate;
        _cutoff = Math.Min(1.0, _ratio) * 0.95;
        _support = 16 / _cutoff;
    }

    public float[] Process(ReadOnlySpan<float> samples)
    {
        if (_passThrough) return samples.ToArray();
        foreach (var s in samples) _input.Add(s);
        var output = new List<float>();
        while (_position + _support < _input.Count)
        {
            output.Add(Sample(_position));
            _position += 1 / _ratio;
        }
        // Alles vor dem Filterfenster wird nicht mehr gebraucht.
        var drop = (int)Math.Floor(_position - _support) - 1;
        if (drop > 0)
        {
            _input.RemoveRange(0, Math.Min(drop, _input.Count));
            _position -= drop;
        }
        return output.ToArray();
    }

    private float Sample(double center)
    {
        var start = (int)Math.Ceiling(center - _support);
        var end = (int)Math.Floor(center + _support);
        double sum = 0, weightSum = 0;
        for (var k = Math.Max(0, start); k <= end && k < _input.Count; k++)
        {
            var d = k - center;
            var x = d * _cutoff;
            var sinc = x == 0 ? 1.0 : Math.Sin(Math.PI * x) / (Math.PI * x);
            var w = 0.42 + 0.5 * Math.Cos(Math.PI * d / _support) + 0.08 * Math.Cos(2 * Math.PI * d / _support);
            sum += _input[k] * sinc * w;
            weightSum += sinc * w;
        }
        return weightSum == 0 ? 0 : (float)(sum / weightSum);
    }
}
