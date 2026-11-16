import AVFoundation
import RedeflussObjC

/// Speichert den Audiostrom eines Meetings (16 kHz mono) – nur wenn der Nutzer das eingeschaltet hat.
///
/// Absturzsicher in zwei Schritten: Während der Aufnahme wächst eine Rohdatei (16-Bit-PCM ohne Kopf,
/// `<name>.m4a.pcm`), die zu jedem Zeitpunkt gültig ist. Erst am Ende wird daraus die .m4a (AAC) und die
/// Rohdatei gelöscht. Stirbt die App vorher, holt `recoverUnfinished` das beim nächsten Start nach.
/// Nicht threadsicher: alle Aufrufe von derselben Queue.
final class MeetingAudioWriter {
    enum Failure: LocalizedError {
        case exception(String)
        case create(String)

        var errorDescription: String? {
            switch self {
            case .exception(let reason): return "Audiodatei konnte nicht geschrieben werden (\(reason))."
            case .create(let path): return "Audiodatei konnte nicht angelegt werden (\(path))."
            }
        }
    }

    /// Die fertige .m4a.
    let url: URL
    /// Die Rohdatei, solange aufgenommen wird.
    let rawURL: URL
    private var handle: FileHandle?
    private var unsyncedSamples = 0

    static let rawExtension = "pcm"
    /// Sprache in 16 kHz mono: 32 kbit/s AAC ≈ 15 MB pro Stunde.
    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: AudioRecorder.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]
    /// So oft wird die Rohdatei auf die Platte gezwungen – mehr geht auch bei Stromausfall nicht verloren.
    private static let syncSamples = Int(AudioRecorder.sampleRate * 5)
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
    )!

    init(url: URL) throws {
        self.url = url
        rawURL = url.appendingPathExtension(Self.rawExtension)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: rawURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.create(rawURL.lastPathComponent)
        }
        handle = try FileHandle(forWritingTo: rawURL)
    }

    deinit { try? handle?.close() }

    func append(_ samples: [Float]) throws {
        guard let handle, !samples.isEmpty else { return }
        let pcm = samples.map { sample -> Int16 in
            // NaN/∞ würden die Umwandlung zum Absturz bringen.
            sample.isFinite ? Int16(max(-1, min(1, sample)) * 32767) : 0
        }
        try pcm.withUnsafeBufferPointer { try handle.write(contentsOf: Data(buffer: $0)) }
        unsyncedSamples += samples.count
        if unsyncedSamples >= Self.syncSamples {
            unsyncedSamples = 0
            try handle.synchronize()
        }
    }

    /// Aufnahme zu Ende: Rohdatei schließen und in die .m4a wandeln. Schlägt das fehl, bleibt die Rohdatei liegen.
    func finish() throws {
        closeRaw()
        try Self.encode(raw: rawURL, to: url)
    }

    /// Verwerfen (Start fehlgeschlagen): nichts bleibt zurück.
    func discard() {
        closeRaw()
        try? FileManager.default.removeItem(at: rawURL)
    }

    private func closeRaw() {
        guard let handle else { return }
        try? handle.synchronize()
        try? handle.close()
        self.handle = nil
    }

    /// Wandelt eine Rohdatei in eine .m4a und löscht sie danach. Eine leere Rohdatei ergibt keine .m4a.
    /// Die Rohdatei wird erst entfernt, wenn die .m4a vollständig geschrieben ist.
    static func encode(raw: URL, to url: URL) throws {
        let reader = try FileHandle(forReadingFrom: raw)
        defer { try? reader.close() }
        let blockSamples = Int(AudioRecorder.sampleRate) * 10
        var file: AVAudioFile?
        var written = 0

        while let data = try reader.read(upToCount: blockSamples * MemoryLayout<Int16>.size), data.count >= MemoryLayout<Int16>.size {
            // Nach einem Absturz kann am Ende ein halbes Sample stehen.
            let count = data.count / MemoryLayout<Int16>.size
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { break }
            data.withUnsafeBytes { bytes in
                for index in 0..<count {
                    channel[index] = Float(bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)) / 32767
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)

            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            var failure: Error?
            let exception = RDFCatchException {
                do { try file?.write(from: buffer) } catch { failure = error }
            }
            if let exception { throw Failure.exception(exception.reason ?? exception.name.rawValue) }
            if let failure { throw failure }
            written += count
        }

        file = nil // schließt die .m4a ab
        try? FileManager.default.removeItem(at: raw)
        if written == 0 { try? FileManager.default.removeItem(at: url) }
    }

    /// Nach einem Absturz liegen gebliebene Rohdateien in ihre .m4a wandeln. Liefert die geretteten Dateien.
    @discardableResult
    static func recoverUnfinished(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var recovered: [URL] = []
        for raw in files where raw.pathExtension == rawExtension {
            let target = raw.deletingPathExtension()
            do {
                try encode(raw: raw, to: target)
                if FileManager.default.fileExists(atPath: target.path) { recovered.append(target) }
                meetingLog.notice("Aufnahme nach Abbruch wiederhergestellt: \(target.lastPathComponent, privacy: .public)")
            } catch {
                meetingLog.error("Aufnahme nicht wiederherstellbar (\(raw.lastPathComponent, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
        }
        return recovered
    }

    /// „Meeting 2026-11-16 14-30-05 Zoom.m4a" – ohne Zeichen, die im Dateinamen stören.
    static func fileName(date: Date, appName: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters).union(.newlines)
        let name = appName.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        let suffix = name.isEmpty ? "" : " " + String(name.prefix(40))
        return "Meeting \(formatter.string(from: date))\(suffix).m4a"
    }
}
