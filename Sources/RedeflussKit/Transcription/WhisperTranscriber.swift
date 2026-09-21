import Foundation
import whisper

public enum TranscriberError: LocalizedError {
    case modelLoadFailed(String)
    case noModel
    case inferenceFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path): return "Modell konnte nicht geladen werden: \((path as NSString).lastPathComponent)"
        case .noModel: return "Kein Sprachmodell geladen."
        case .inferenceFailed(let code): return "Transkription fehlgeschlagen (Code \(code))."
        }
    }
}

public struct TranscriptionResult {
    public let text: String
    public let language: String?
    public let duration: TimeInterval
}

/// Dünne Hülle um die whisper.cpp-C-API. Das Modell bleibt geladen, damit
/// jedes Diktat ohne Ladezeit startet. Alle Aufrufe laufen seriell auf `queue`.
public final class WhisperTranscriber {
    private let queue = DispatchQueue(label: "redefluss.whisper", qos: .userInitiated)
    private var context: OpaquePointer?
    public private(set) var loadedModelPath: String?

    public init() {
        // whisper.cpp schreibt sonst jede Menge Diagnose auf stderr.
        whisper_log_set({ _, _, _ in }, nil)
    }

    deinit {
        if let context { whisper_free(context) }
    }

    public func load(modelPath: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.loadedModelPath == modelPath, self.context != nil {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            if let old = self.context {
                whisper_free(old)
                self.context = nil
                self.loadedModelPath = nil
            }
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true
            let ctx = whisper_init_from_file_with_params(modelPath, params)
            guard let ctx else {
                DispatchQueue.main.async { completion(.failure(TranscriberError.modelLoadFailed(modelPath))) }
                return
            }
            self.context = ctx
            self.loadedModelPath = modelPath
            // Einmal mit Stille aufwärmen: Metal-Shader werden kompiliert, das erste echte Diktat ist schnell.
            self.runWarmup(ctx)
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    public func unload() {
        queue.async { [weak self] in
            guard let self, let ctx = self.context else { return }
            whisper_free(ctx)
            self.context = nil
            self.loadedModelPath = nil
        }
    }

    /// - Parameters:
    ///   - samples: 16 kHz Mono Float32.
    ///   - language: "auto" oder ISO-Code.
    ///   - prompt: Vokabelhinweis (eigene Wörter), darf leer sein.
    public func transcribe(
        samples: [Float],
        language: String,
        prompt: String,
        completion: @escaping (Result<TranscriptionResult, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let ctx = self.context else {
                DispatchQueue.main.async { completion(.failure(TranscriberError.noModel)) }
                return
            }
            let started = CFAbsoluteTimeGetCurrent()

            // whisper.cpp verarbeitet Clips unter 1 s nicht zuverlässig → mit Stille auffüllen.
            var audio = samples
            let minimum = Int(AudioRecorder.sampleRate * 1.2)
            if audio.count < minimum {
                audio.append(contentsOf: [Float](repeating: 0, count: minimum - audio.count))
            }

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
            params.no_context = true
            params.no_timestamps = true
            params.single_segment = false
            params.print_special = false
            params.print_progress = false
            params.print_realtime = false
            params.print_timestamps = false
            params.suppress_blank = true
            params.suppress_nst = true
            params.translate = false

            let code: Int32 = language.withCString { languagePtr in
                prompt.withCString { promptPtr in
                    params.language = languagePtr
                    params.detect_language = false
                    params.initial_prompt = prompt.isEmpty ? nil : promptPtr
                    return audio.withUnsafeBufferPointer { buffer in
                        whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
                    }
                }
            }

            guard code == 0 else {
                DispatchQueue.main.async { completion(.failure(TranscriberError.inferenceFailed(code))) }
                return
            }

            var text = ""
            let segments = whisper_full_n_segments(ctx)
            for i in 0..<segments {
                if let cString = whisper_full_get_segment_text(ctx, i) {
                    text += String(cString: cString)
                }
            }
            var detected: String?
            let langID = whisper_full_lang_id(ctx)
            if langID >= 0, let cLang = whisper_lang_str(langID) {
                detected = String(cString: cLang)
            }
            let result = TranscriptionResult(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                language: detected,
                duration: CFAbsoluteTimeGetCurrent() - started
            )
            DispatchQueue.main.async { completion(.success(result)) }
        }
    }

    private func runWarmup(_ ctx: OpaquePointer) {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = 4
        params.no_context = true
        params.no_timestamps = true
        params.single_segment = true
        params.print_progress = false
        params.print_realtime = false
        let silence = [Float](repeating: 0, count: Int(AudioRecorder.sampleRate))
        "en".withCString { lang in
            params.language = lang
            _ = silence.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
        }
    }
}

public enum SpeechDetector {
    /// Grobe Energieprüfung: Enthält die Aufnahme überhaupt Sprache?
    /// Verhindert, dass Whisper bei reiner Stille halluziniert.
    public static func containsSpeech(_ samples: [Float], sampleRate: Double = AudioRecorder.sampleRate) -> Bool {
        let window = Int(sampleRate * 0.03)
        guard samples.count >= window else { return false }
        var loudWindows = 0
        var index = 0
        while index + window <= samples.count {
            var sum: Float = 0
            for i in index..<(index + window) { sum += samples[i] * samples[i] }
            let rms = (sum / Float(window)).squareRoot()
            if rms > 0.008 { loudWindows += 1 }   // ≈ -42 dBFS
            index += window
        }
        // Mindestens ~150 ms mit hörbarem Signal.
        return loudWindows >= 5
    }
}
