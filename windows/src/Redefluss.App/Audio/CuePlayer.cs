using NAudio.Wave;
using Redefluss.Core.Audio;
using Cue = Redefluss.Core.Audio.Cue;

namespace Redefluss.App.Audio;

/// <summary>Spielt die kurzen Signaltöne über das Standard-Ausgabegerät.</summary>
public sealed class CuePlayer
{
    private readonly Dictionary<Cue, byte[]> _sounds = Enum.GetValues<Cue>().ToDictionary(c => c, CueSynth.Wav);

    public void Play(Cue cue)
    {
        try
        {
            var reader = new WaveFileReader(new MemoryStream(_sounds[cue]));
            var output = new WaveOutEvent { DesiredLatency = 60 };
            output.PlaybackStopped += (_, _) =>
            {
                output.Dispose();
                reader.Dispose();
            };
            output.Init(reader);
            output.Play();
        }
        catch (Exception)
        {
            // Kein Ausgabegerät – Töne sind nur Beiwerk.
        }
    }
}
