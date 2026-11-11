using Redefluss.Core.Audio;
using Redefluss.Core.Meeting;
using Redefluss.Core.Storage;

namespace Redefluss.Core.Tests;

public sealed class MeetingDetectionLogicTests
{
    private const double T0 = 1000;

    [Fact]
    public void ShortMicrophoneUseIsIgnored()
    {
        var logic = new MeetingDetectionLogic();
        Assert.Null(logic.Observe(true, T0));
        Assert.Null(logic.Observe(true, T0 + 0.5));
        Assert.Null(logic.Observe(false, T0 + 0.8));
        Assert.False(logic.IsMeeting);
    }

    [Fact]
    public void DefaultsReactWithinSeconds()
    {
        var logic = new MeetingDetectionLogic();
        Assert.Null(logic.Observe(true, T0));
        Assert.Equal(MeetingDetectionLogic.Change.Started, logic.Observe(true, T0 + 1.05));
        Assert.Null(logic.Observe(false, T0 + 30));
        Assert.Equal(MeetingDetectionLogic.Change.Ended, logic.Observe(false, T0 + 32.05));
    }

    [Fact]
    public void ShortDropoutDoesNotEndMeeting()
    {
        var logic = new MeetingDetectionLogic { StartAfter = 4, EndAfter = 10 };
        logic.Observe(true, T0);
        Assert.Equal(MeetingDetectionLogic.Change.Started, logic.Observe(true, T0 + 4.5));
        Assert.Null(logic.Observe(false, T0 + 61));
        Assert.Null(logic.Observe(false, T0 + 65));
        Assert.Null(logic.Observe(true, T0 + 66));
        Assert.True(logic.IsMeeting);
        Assert.Null(logic.Observe(false, T0 + 100));
        Assert.Equal(MeetingDetectionLogic.Change.Ended, logic.Observe(false, T0 + 110.5));
    }

    [Fact]
    public void ClockFormatting()
    {
        Assert.Equal("00:00", MeetingClock.Format(0));
        Assert.Equal("12:34", MeetingClock.Format(754.9));
        Assert.Equal("1:02:03", MeetingClock.Format(3723));
    }
}

public sealed class TranscriptChunkerTests
{
    private const int Rate = 16_000;
    private static float[] Tone(double s) => Enumerable.Range(0, (int)(Rate * s)).Select(i => (float)(Math.Sin(i * 2 * Math.PI * 220 / Rate) * 0.2)).ToArray();
    private static float[] Silence(double s) => new float[(int)(Rate * s)];

    [Fact]
    public void CutsAtFirstPauseAfterTarget()
    {
        var chunker = new TranscriptChunker { TargetSeconds = 10, MaxSeconds = 20 };
        var stream = Tone(12).Concat(Silence(1)).Concat(Tone(5)).ToArray();
        var chunks = new List<float[]>();
        for (var i = 0; i < stream.Length; i += 1024) chunks.AddRange(chunker.Append(stream.AsSpan(i, Math.Min(1024, stream.Length - i))));
        var chunk = Assert.Single(chunks);
        var cut = chunk.Length / (double)Rate;
        Assert.InRange(cut, 12, 13);
        Assert.Equal(18 - cut, chunker.BufferedSeconds, 1);
    }

    [Fact]
    public void CutsAtMaximumWithoutPause()
    {
        var chunker = new TranscriptChunker { TargetSeconds = 10, MaxSeconds = 20 };
        var chunks = chunker.Append(Tone(45));
        Assert.Equal(2, chunks.Count);
        Assert.Equal(20, chunks[0].Length / (double)Rate, 1);
        Assert.Equal(5, chunker.BufferedSeconds, 1);
    }

    [Fact]
    public void FlushReturnsRestAndResets()
    {
        var chunker = new TranscriptChunker();
        chunker.Append(Tone(3));
        Assert.Equal(Rate * 3, chunker.Flush()?.Length);
        Assert.Null(chunker.Flush());
        Assert.Equal(0, chunker.BufferedSeconds);
    }
}

public sealed class MicrophoneUsageTests
{
    private const string Own = @"C:\Users\x\AppData\Local\Programs\Redefluss\Redefluss.exe";

    [Fact]
    public void FindsAppsThatAreRecordingRightNow()
    {
        var users = MicrophoneUsage.ActiveUsers(
        [
            new(@"C:#Users#x#AppData#Roaming#Zoom#bin#Zoom.exe", false, 133_000, 0),               // nimmt gerade auf
            new(@"C:#Program Files#Google#Chrome#Application#chrome.exe", false, 133_000, 133_500), // fertig
            new("MSTeams_8wekyb3d8bbwe", true, 134_000, 0),
            new("Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe", true, 134_000, 0),                  // ignoriert
            new(Own.Replace('\\', '#'), false, 135_000, 0),                                          // wir selbst
            new(@"C:#Tools#never.exe", false, 0, 0),                                                 // nie benutzt
        ], Own);
        Assert.Equal(["Zoom", "Teams"], users.Select(u => u.Name));
        Assert.Equal(@"C:\Users\x\AppData\Roaming\Zoom\bin\Zoom.exe", users[0].ExecutablePath);
        Assert.Null(users[1].ExecutablePath);
    }

    [Fact]
    public void CrashedProgramWithStaleEntryIsNotAMeeting()
    {
        var users = MicrophoneUsage.ActiveUsers([new(@"C:#Apps#Zoom.exe", false, 1, 0)], Own, isRunning: _ => false);
        Assert.Empty(users);
    }

    [Fact]
    public void DisplayNames()
    {
        Assert.Equal("Edge", MicrophoneUsage.DisplayName("msedge.exe"));
        Assert.Equal("Meetapp", MicrophoneUsage.DisplayName("meetapp.exe"));
        Assert.Equal("FancyCall", MicrophoneUsage.DisplayName("Contoso.FancyCall"));
    }
}

public sealed class StreamingResamplerTests
{
    [Fact]
    public void BlockwiseMatchesBatch()
    {
        const int rate = 48_000;
        var tone = Enumerable.Range(0, rate).Select(i => (float)Math.Sin(i * 2 * Math.PI * 300 / rate) * 0.5f).ToArray();
        var batch = AudioMath.Resample(tone, rate);
        var streaming = new StreamingResampler(rate);
        var output = new List<float>();
        for (var i = 0; i < tone.Length; i += 480) output.AddRange(streaming.Process(tone.AsSpan(i, 480)));
        // Am Ende fehlt nur das Filterfenster (~16 Samples bei 16 kHz).
        Assert.InRange(output.Count, batch.Length - 40, batch.Length);
        for (var i = 100; i < output.Count - 100; i++) Assert.Equal(batch[i], output[i], 0.002f);
    }

    [Fact]
    public void SameRatePassesThrough() => Assert.Equal([1f, 2f], new StreamingResampler(16_000).Process([1f, 2f]));
}

public sealed class HistoryUpdateTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "redefluss-hist-" + Guid.NewGuid());
    public HistoryUpdateTests() => Directory.CreateDirectory(_dir);
    public void Dispose() => Directory.Delete(_dir, true);

    [Fact]
    public void GrowingMeetingIsUpdatedAndClosedAfterCrash()
    {
        var store = new HistoryStore(_dir);
        var meeting = new HistoryItem { Date = DateTimeOffset.Now, AppName = "Zoom", Kind = HistoryKind.Meeting, InProgress = true };
        store.Add(meeting);
        store.Add(new HistoryItem { Date = DateTimeOffset.Now, Text = "Diktat nebenbei" });
        store.Update(meeting with { Text = "[00:00] Guten Morgen zusammen.", AudioSeconds = 31 });
        Assert.Equal(2, store.Items.Count);
        Assert.Equal("[00:00] Guten Morgen zusammen.", store.Items.First(i => i.Id == meeting.Id).Text);

        var restored = new HistoryStore(_dir).Items.First(i => i.Id == meeting.Id);
        Assert.False(restored.InProgress);
        Assert.True(restored.IsMeeting);
    }
}
