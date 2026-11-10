using Redefluss.Core.Audio;
using Redefluss.Core.FlowBar;
using Redefluss.Core.Hotkey;
using Redefluss.Core.Models;
using Redefluss.Core.Storage;
using Redefluss.Core.Text;

namespace Redefluss.Core.Tests;

public sealed class TextPostProcessorTests
{
    private readonly TextPostProcessor _processor = new();

    [Fact] public void TrimsAndCapitalizes() => Assert.Equal("Hallo welt.", _processor.Process("  hallo welt. "));

    [Fact]
    public void RemovesGermanAndEnglishFillers()
    {
        Assert.Equal("Ich wollte, kurz fragen.", _processor.Process("Ähm, ich wollte, äh, kurz fragen."));
        Assert.Equal("So I think this works.", _processor.Process("So umm, I think uh this works."));
    }

    [Fact]
    public void KeepsGermanWordsThatLookLikeFillers()
    {
        Assert.Equal("Wir treffen uns um acht Uhr, er kommt auch.", _processor.Process("Wir treffen uns um acht Uhr, er kommt auch."));
        Assert.Equal("Der Ähnlichkeitswert und der Uhrmacher.", _processor.Process("Der Ähnlichkeitswert und der Uhrmacher."));
    }

    [Fact] public void FillerRemovalCanBeDisabled() => Assert.Equal("Äh, ja.", new TextPostProcessor(removeFillers: false).Process("Äh, ja."));

    [Fact]
    public void StripsWhisperMarkers()
    {
        Assert.Equal("Hallo zusammen", _processor.Process("[Musik] Hallo zusammen (lacht)"));
        Assert.Null(_processor.Process("[BLANK_AUDIO]"));
    }

    [Fact]
    public void DropsKnownHallucinations()
    {
        Assert.Null(_processor.Process("Untertitel der Amara.org-Community"));
        Assert.Null(_processor.Process("Vielen Dank fürs Zuschauen!"));
        Assert.Null(_processor.Process("Thank you for watching."));
        Assert.NotNull(_processor.Process("Vielen Dank für die schnelle Antwort."));
    }

    [Fact]
    public void ReplacementsMatchWholeWordsCaseInsensitive()
    {
        var p = new TextPostProcessor(replacements: [new("mfg", "Mit freundlichen Grüßen"), new("dream crm", "DreamCRM")]);
        Assert.Equal("Danke, Mit freundlichen Grüßen", p.Process("Danke, MFG"));
        Assert.Equal("Öffne DreamCRM bitte", p.Process("Öffne dream CRM bitte"));
        Assert.Equal("Die mfgx bleibt", p.Process("Die mfgx bleibt"));
    }

    [Fact]
    public void ReplacementWithSpecialCharacters() =>
        Assert.Equal("Das kostet zehn $1", new TextPostProcessor(replacements: [new("dollar", "$1")]).Process("Das kostet zehn dollar"));

    [Fact] public void PunctuationSpacing() => Assert.Equal("Hallo, wie geht es?", _processor.Process("Hallo , wie geht es ?"));
}

public sealed class AudioMathTests
{
    [Fact] public void SilenceIsNotSpeech() => Assert.False(AudioMath.ContainsSpeech(new float[16_000]));

    [Fact]
    public void LowNoiseIsNotSpeech()
    {
        var r = new Random(1);
        Assert.False(AudioMath.ContainsSpeech(Enumerable.Range(0, 16_000).Select(_ => (float)(r.NextDouble() * 0.006 - 0.003)).ToArray()));
    }

    [Fact]
    public void ToneIsSpeechLike() =>
        Assert.True(AudioMath.ContainsSpeech(Enumerable.Range(0, 16_000).Select(i => (float)(Math.Sin(i * 2 * Math.PI * 220 / 16_000) * 0.1)).ToArray()));

    [Fact]
    public void VeryShortBlipIsIgnored()
    {
        var s = new float[16_000];
        for (var i = 0; i < 800; i++) s[i] = (float)(Math.Sin(i * 0.3) * 0.2);
        Assert.False(AudioMath.ContainsSpeech(s));
    }

    [Fact]
    public void ResampleKeepsDurationAndToneAmplitude()
    {
        const int rate = 48_000;
        var tone = Enumerable.Range(0, rate).Select(i => (float)Math.Sin(i * 2 * Math.PI * 440 / rate) * 0.5f).ToArray();
        var output = AudioMath.Resample(tone, rate);
        Assert.Equal(16_000, output.Length);
        var peak = output.Skip(1000).Take(10_000).Max(Math.Abs);
        Assert.InRange(peak, 0.45f, 0.55f);
    }

    [Fact]
    public void ResampleRemovesFrequenciesAboveNewNyquist()
    {
        const int rate = 48_000;
        // 12 kHz liegt über 8 kHz (Nyquist bei 16 kHz) – darf nicht als Spiegelfrequenz durchkommen.
        var high = Enumerable.Range(0, rate).Select(i => (float)Math.Sin(i * 2 * Math.PI * 12_000 / rate) * 0.5f).ToArray();
        var output = AudioMath.Resample(high, rate);
        Assert.True(AudioMath.Level(output.AsSpan(1000, 10_000)) < 0.2f);
    }

    [Fact]
    public void DownmixAveragesChannels() => Assert.Equal([0.5f, 0f], AudioMath.DownmixToMono([1f, 0f, 0.5f, -0.5f], 2));

    [Fact]
    public void ShortClipsArePadded() => Assert.Equal(19_200, AudioMath.PadForWhisper(new float[100]).Length);

    [Fact]
    public void LevelMapsDecibels()
    {
        Assert.Equal(0, AudioMath.Level(new float[100]));
        Assert.Equal(1, AudioMath.Level(Enumerable.Repeat(0.9f, 100).ToArray()));
    }

    [Fact]
    public void CueSoundsAreValidWav()
    {
        var wav = CueSynth.Wav(Cue.Start);
        Assert.Equal("RIFF"u8.ToArray(), wav[..4]);
        Assert.Equal(BitConverter.ToInt32(wav, 4), wav.Length - 8);
    }
}

public sealed class HotkeyOptionTests
{
    [Fact]
    public void EqualityIgnoresName()
    {
        Assert.Equal(HotkeyOption.F5, new HotkeyOption(HotkeyKind.Key, Vk.F5, "irgendwas"));
        Assert.NotEqual(HotkeyOption.F5, new HotkeyOption(HotkeyKind.Modifier, Vk.F5, "F5"));
    }

    [Fact]
    public void RecordedKeysBecomePresetsOrCustom()
    {
        Assert.Same(HotkeyOption.F5, HotkeyOption.FromRecordedKey(Vk.F5));
        Assert.Same(HotkeyOption.RightControl, HotkeyOption.FromRecordedKey(Vk.RControl));
        var f13 = HotkeyOption.FromRecordedKey(0x7C);
        Assert.Equal(HotkeyKind.Key, f13.Kind);
        Assert.Equal("F13", f13.Name);
        Assert.Equal(HotkeyKind.Modifier, HotkeyOption.FromRecordedKey(Vk.LShift).Kind);
    }

    [Fact]
    public void TypingKeysAreRejectedAsHotkey()
    {
        Assert.NotNull(HotkeyOption.Unsuitable(0x41));
        Assert.NotNull(HotkeyOption.Unsuitable(Vk.Space));
        Assert.NotNull(HotkeyOption.Unsuitable(Vk.Escape));
        Assert.NotNull(HotkeyOption.Unsuitable(0xBE));   // Punkt
        Assert.Null(HotkeyOption.Unsuitable(Vk.F5));
        Assert.Null(HotkeyOption.Unsuitable(0x7C));      // F13
        Assert.Null(HotkeyOption.Unsuitable(Vk.RControl));
    }

    [Fact]
    public void KeyNamesAreGerman()
    {
        Assert.Equal("F24", KeyNames.Name(Vk.F24));
        Assert.Equal("Num 7", KeyNames.Name(0x67));
        Assert.Equal("Pos1", KeyNames.Name(0x24));
        Assert.Equal("Taste 255", KeyNames.Name(0xFF));
    }
}

public sealed class StorageTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "redefluss-tests-" + Guid.NewGuid());

    public StorageTests() => Directory.CreateDirectory(_dir);
    public void Dispose() => Directory.Delete(_dir, recursive: true);

    [Fact]
    public void SettingsRoundTrip()
    {
        var path = Path.Combine(_dir, "settings.json");
        var s = AppSettings.Load(path);
        Assert.Equal(HotkeyOption.F5, s.Hotkey);
        s.Hotkey = new HotkeyOption(HotkeyKind.Key, 0x7C, "F13");
        s.Language = "de";
        s.Replacements = [new("mfg", "Mit freundlichen Grüßen")];
        s.FlowBarPosition = new FlowBarPosition(0.2, 0.3, @"\\.\DISPLAY2");

        var loaded = AppSettings.Load(path);
        Assert.Equal("F13", loaded.Hotkey.Name);
        Assert.Equal(HotkeyKind.Key, loaded.Hotkey.Kind);
        Assert.Equal("de", loaded.Language);
        Assert.Equal("Mit freundlichen Grüßen", Assert.Single(loaded.Replacements).To);
        Assert.Equal(@"\\.\DISPLAY2", loaded.FlowBarPosition?.Display);
    }

    [Fact]
    public void BrokenSettingsFallBackToDefaults()
    {
        var path = Path.Combine(_dir, "settings.json");
        File.WriteAllText(path, "{ kaputt");
        Assert.True(AppSettings.Load(path).HandsFreeEnabled);
        Assert.True(File.Exists(path + ".defekt"));
    }

    [Fact]
    public void WhisperPromptIsTrimmedAndLimited()
    {
        var s = AppSettings.Load(Path.Combine(_dir, "s.json"));
        Assert.Equal("", s.WhisperPrompt);
        s.Dictionary = [" Redefluss ", "", "DreamCRM"];
        Assert.Equal("Redefluss, DreamCRM.", s.WhisperPrompt);
        s.Dictionary = Enumerable.Repeat("Wort", 500).ToList();
        Assert.True(s.WhisperPrompt.Length <= 601);
    }

    [Fact]
    public void HistoryReadsMacFormat()
    {
        // So schreibt die Mac-Version history.json (Swift Codable, ISO 8601).
        File.WriteAllText(Path.Combine(_dir, "history.json"), """
            [{"id":"4F1C2B9A-0000-4000-8000-000000000001","date":"2026-11-01T09:30:00Z","text":"Hallo Welt",
              "audioSeconds":2.5,"appName":"Mail","language":"de","kind":"dictation"},
             {"id":"4F1C2B9A-0000-4000-8000-000000000002","date":"2026-11-01T10:00:00Z","text":"Meeting","audioSeconds":600,
              "kind":"meeting","inProgress":true}]
            """);
        var store = new HistoryStore(_dir);
        Assert.Equal(2, store.Items.Count);
        Assert.Equal("Mail", store.Items[0].AppName);
        Assert.True(store.Items[1].IsMeeting);
        Assert.False(store.Items[1].InProgress);
        Assert.Equal(3, store.TotalWords);
    }

    [Fact]
    public void HistoryAddDeleteAndLimit()
    {
        var store = new HistoryStore(_dir);
        for (var i = 0; i < 510; i++) store.Add(new HistoryItem { Date = DateTimeOffset.Now, Text = $"Nr {i}" });
        Assert.Equal(500, store.Items.Count);
        Assert.Equal("Nr 509", store.Items[0].Text);
        store.Delete(store.Items[0].Id);
        Assert.Equal(499, new HistoryStore(_dir).Items.Count);
    }

    [Fact]
    public void ModelManagerFindsAndRanksModels()
    {
        var own = Path.Combine(_dir, "models");
        var cache = Path.Combine(_dir, "cache");
        Directory.CreateDirectory(cache);
        Directory.CreateDirectory(own);
        WriteSparse(Path.Combine(cache, "ggml-small-q5_1.bin"), 30_000_000);
        WriteSparse(Path.Combine(cache, "ggml-large-v3-turbo-q5_0.bin"), 30_000_000);
        WriteSparse(Path.Combine(own, "ggml-base.en.bin"), 30_000_000);
        WriteSparse(Path.Combine(own, "ggml-tiny.bin"), 1_000);   // unvollständig

        var m = new ModelManager(own, [cache]);
        Assert.Equal(["large-v3-turbo-q5_0", "small-q5_1", "base.en"], m.Installed.Select(x => x.ModelId));
        Assert.Equal("Turbo", m.BestInstalled()?.DisplayName);
        Assert.True(m.Installed[2].IsEnglishOnly);
        Assert.True(m.Installed[0].IsExternal);

        m.Delete(m.Installed[0]);
        Assert.Equal(3, m.Installed.Count);   // extern → nie gelöscht
    }

    private static void WriteSparse(string path, long size)
    {
        using var f = File.Create(path);
        f.SetLength(size);
    }
}

public sealed class FlowBarGeometryTests
{
    private static readonly Box Work = new(0, 0, 1920, 1040);   // 1080 minus Taskleiste

    [Fact]
    public void DefaultSitsBottomCenterAboveTaskbar()
    {
        var g = new FlowBarGeometry();
        Assert.Equal((780, 970), g.Origin(null, Work));
    }

    [Fact]
    public void PositionRoundTripsAndSnapsBackNearDefault()
    {
        var g = new FlowBarGeometry(1.5);
        var origin = (300.0, 200.0);
        var pos = g.Position(origin, Work, "D1");
        Assert.NotNull(pos);
        var back = g.Origin(pos, Work);
        Assert.Equal(origin.Item1, back.X, 3);
        Assert.Equal(origin.Item2, back.Y, 3);

        var standard = g.Origin(null, Work);
        Assert.Null(g.Position((standard.X + 10, standard.Y - 10), Work));
    }

    [Fact]
    public void ClampKeepsPillOnScreen()
    {
        var g = new FlowBarGeometry();
        var (x, y) = g.Clamp((-5000, -5000), Work);
        // Kapsel beginnt genau am linken bzw. oberen Rand.
        Assert.Equal(0, x + FlowBarGeometry.Width / 2 - FlowBarGeometry.PillWidth / 2, 3);
        Assert.Equal(0, y + FlowBarGeometry.Height - FlowBarGeometry.PillBottomPadding - FlowBarGeometry.PillHeight, 3);
        var (x2, y2) = g.Clamp((5000, 5000), Work);
        Assert.Equal(1920, x2 + FlowBarGeometry.Width / 2 + FlowBarGeometry.PillWidth / 2, 3);
        Assert.Equal(1040, y2 + FlowBarGeometry.Height, 3);
    }

    [Fact]
    public void BarsAreHigherInTheMiddle()
    {
        var levels = Enumerable.Repeat(1f, 14).ToArray();
        Assert.True(FlowBarGeometry.BarHeight(levels, 6) > FlowBarGeometry.BarHeight(levels, 0));
        Assert.Equal(3, FlowBarGeometry.BarHeight(new float[14], 3));
    }
}
