import Foundation

/// Schneidet den Audiostrom eines Meetings in Abschnitte für Whisper – möglichst in Sprechpausen,
/// damit keine Wörter zerteilt werden, und spätestens nach `maxSeconds` auch ohne Pause.
struct TranscriptChunker {
    var sampleRate: Double = AudioRecorder.sampleRate
    /// Ab dieser Länge wird bei der nächsten Pause geschnitten …
    var targetSeconds: Double = 30
    /// … und spätestens hier, auch mitten im Satz.
    var maxSeconds: Double = 45
    /// Effektivwert, unter dem ein Fenster als still gilt (≈ -42 dBFS, wie der SpeechDetector).
    var silenceRMS: Float = 0.008
    var windowSeconds: Double = 0.03
    /// So viele stille Fenster hintereinander gelten als Pause (8 × 30 ms ≈ 240 ms).
    var minimumSilentWindows = 8

    private(set) var buffer: [Float] = []
    /// Bis hierhin wurden Fenster schon bewertet – damit Pausen auch über Append-Grenzen zählen.
    private var analyzed = 0
    private var silentRun = 0

    var bufferedSeconds: Double { Double(buffer.count) / sampleRate }

    /// Hängt neue Samples an und liefert alle Abschnitte, die dadurch vollständig wurden.
    mutating func append(_ samples: [Float]) -> [[Float]] {
        buffer.append(contentsOf: samples)
        let window = max(1, Int(sampleRate * windowSeconds))
        let target = Int(sampleRate * targetSeconds)
        let maximum = Int(sampleRate * maxSeconds)
        var chunks: [[Float]] = []

        while true {
            var cut: Int?
            while analyzed + window <= buffer.count {
                let slice = buffer[analyzed..<(analyzed + window)]
                var sum: Float = 0
                for sample in slice { sum += sample * sample }
                let rms = (sum / Float(window)).squareRoot()
                silentRun = rms < silenceRMS ? silentRun + 1 : 0
                analyzed += window
                if analyzed >= maximum || (analyzed >= target && silentRun >= minimumSilentWindows) {
                    cut = analyzed
                    break
                }
            }
            guard let cut else { break }
            chunks.append(Array(buffer[0..<cut]))
            buffer.removeFirst(cut)
            analyzed = 0
            silentRun = 0
        }
        return chunks
    }

    /// Gibt den Rest zurück (z. B. am Ende des Meetings) und leert den Puffer.
    mutating func flush() -> [Float]? {
        defer {
            buffer = []
            analyzed = 0
            silentRun = 0
        }
        return buffer.isEmpty ? nil : buffer
    }
}
