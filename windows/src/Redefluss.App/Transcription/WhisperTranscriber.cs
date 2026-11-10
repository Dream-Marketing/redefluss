using System.Diagnostics;
using Redefluss.Core.Audio;
using Whisper.net;
using Whisper.net.LibraryLoader;
using Whisper.net.Logger;

namespace Redefluss.App.Transcription;

public sealed record TranscriptionResult(string Text, string? Language, TimeSpan Duration);

/// <summary>
/// Hülle um whisper.cpp (über Whisper.net). Das Modell bleibt geladen, damit jedes Diktat ohne
/// Ladezeit startet. Alle Aufrufe laufen nacheinander (eine Sperre).
/// Rechnet auf der Grafikkarte (Vulkan), sonst auf der CPU – Whisper.net wählt beim Laden.
/// </summary>
public sealed class WhisperTranscriber : IDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private WhisperFactory? _factory;

    public string? LoadedModelPath { get; private set; }

    /// <summary>Welche whisper.cpp-Bibliothek geladen wurde (z. B. „Vulkan" oder „Cpu") – für die Info-Seite.</summary>
    public string? Runtime { get; private set; }

    public async Task LoadAsync(string modelPath)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (LoadedModelPath == modelPath && _factory is not null) return;
            _factory?.Dispose();
            _factory = null;
            LoadedModelPath = null;

            await Task.Run(() =>
            {
                var factory = WhisperFactory.FromPath(modelPath, new WhisperFactoryOptions { UseGpu = true, UseFlashAttention = true });
                Runtime = RuntimeOptions.LoadedLibrary?.ToString();
                // Einmal mit Stille aufwärmen: Shader werden vorbereitet, das erste echte Diktat ist schnell.
                using (var warmup = factory.CreateBuilder().WithLanguage("en").WithThreads(4).WithNoContext().WithSingleSegment().Build())
                {
                    warmup.Process(new float[AudioMath.SampleRate]);
                }
                _factory = factory;
                LoadedModelPath = modelPath;
            }).ConfigureAwait(false);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            throw new InvalidOperationException($"Modell konnte nicht geladen werden: {Path.GetFileName(modelPath)}", e);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task UnloadAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            _factory?.Dispose();
            _factory = null;
            LoadedModelPath = null;
        }
        finally { _gate.Release(); }
    }

    /// <param name="samples">16 kHz Mono Float32.</param>
    /// <param name="language">"auto" oder ISO-Code.</param>
    /// <param name="prompt">Vokabelhinweis (eigene Wörter), darf leer sein.</param>
    public async Task<TranscriptionResult> TranscribeAsync(float[] samples, string language, string prompt)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var factory = _factory ?? throw new InvalidOperationException("Kein Sprachmodell geladen.");
            var started = Stopwatch.StartNew();
            var audio = AudioMath.PadForWhisper(samples);

            var builder = factory.CreateBuilder()
                .WithLanguage(string.IsNullOrEmpty(language) ? "auto" : language)
                .WithThreads(Math.Clamp(Environment.ProcessorCount - 2, 2, 8))
                .WithNoContext();
            if (!string.IsNullOrWhiteSpace(prompt)) builder = builder.WithPrompt(prompt);

            var text = new System.Text.StringBuilder();
            string? detected = null;
            await using var processor = builder.Build();
            await foreach (var segment in processor.ProcessAsync(audio).ConfigureAwait(false))
            {
                text.Append(segment.Text);
                detected ??= segment.Language;
            }
            return new TranscriptionResult(text.ToString().Trim(), detected, started.Elapsed);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>whisper.cpp schreibt sonst jede Menge Diagnose; nur Fehler ins Log.</summary>
    public static IDisposable RouteLogs(Action<string> log) =>
        LogProvider.AddLogger((level, message) =>
        {
            if (level == WhisperLogLevel.Error && message is not null) log(message.Trim());
        });

    public void Dispose()
    {
        _factory?.Dispose();
        _gate.Dispose();
    }
}
