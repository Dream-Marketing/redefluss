import AVFoundation
import Combine
import os.log

let meetingLog = Logger(subsystem: "eu.dream-marketing.redefluss", category: "meeting")

/// Zeichnet ein Meeting auf: Systemaudio + Mikrofon (oder nur Mikrofon), schneidet den Strom in
/// Abschnitte, transkribiert sie nacheinander und schreibt den Text fortlaufend in den Verlauf.
/// Es wird kein Audio gespeichert – nur der Text.
public final class MeetingRecorder: ObservableObject {
    public enum State: Equatable {
        case idle
        case recording(appName: String, started: Date)
        /// Aufnahme gestoppt, die letzten Abschnitte werden noch transkribiert.
        case finishing(appName: String)
    }

    public enum Source: Equatable {
        case systemAndMicrophone
        case microphoneOnly
    }

    public enum StartError: LocalizedError {
        case alreadyRunning
        case capture(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "Es läuft schon eine Meeting-Aufzeichnung."
            case .capture(let message): return message
            }
        }
    }

    @Published public private(set) var state: State = .idle
    /// Was gerade aufgenommen wird; nil = nichts.
    @Published public private(set) var source: Source?
    /// Grund, warum nur das Mikrofon läuft (Systemaudio fehlgeschlagen) – für die Einstellungen.
    @Published public private(set) var systemAudioProblem: String?

    /// Pegel 0…1 für die Wellenform (Main-Thread).
    var onLevel: ((Float) -> Void)?
    /// Meeting ist fertig im Verlauf – oder nil, wenn nichts Verwertbares gesagt wurde.
    var onFinished: ((HistoryItem?) -> Void)?

    private let transcriber: WhisperTranscriber
    private let history: HistoryStore
    private let settings: AppSettings
    private let queue = DispatchQueue(label: "redefluss.meeting", qos: .userInitiated)

    // Nur auf `queue`:
    private var chunker = TranscriptChunker()
    private var emittedSamples = 0

    // Nur auf dem Main-Thread:
    private var systemCapture: AnyObject?
    private var microphone: AudioRecorder?
    private var item: HistoryItem?
    private var pendingChunks = 0
    private var droppedChunks = false
    private var startedAt: Date?
    private var maxDurationTimer: Timer?

    /// Mehr Abschnitte warten nicht – sonst frisst ein zu langsamer Rechner den Speicher.
    private let maxPendingChunks = 6
    /// Sicherheitsgrenze pro Meeting.
    private let maxDuration: TimeInterval = 4 * 60 * 60

    init(transcriber: WhisperTranscriber, history: HistoryStore, settings: AppSettings) {
        self.transcriber = transcriber
        self.history = history
        self.settings = settings
    }

    public var isActive: Bool { state != .idle }

    public var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// Startet die Aufzeichnung; `appName` erscheint in Leiste und Verlauf.
    func start(appName: String) throws {
        guard state == .idle else { throw StartError.alreadyRunning }
        let microphoneUID = settings.inputDeviceUID
        var source: Source = .microphoneOnly
        systemAudioProblem = nil

        if settings.meetingSystemAudio, #available(macOS 14.2, *) {
            let capture = SystemAudioCapture()
            capture.onSamples = { [weak self] samples in self?.ingest(samples) }
            do {
                try capture.start(microphoneUID: microphoneUID)
                systemCapture = capture
                source = .systemAndMicrophone
            } catch {
                systemAudioProblem = error.localizedDescription
                meetingLog.error("Systemaudio nicht verfügbar, nur Mikrofon: \(error.localizedDescription, privacy: .public)")
            }
        }

        if source == .microphoneOnly {
            let recorder = AudioRecorder()
            recorder.accumulates = false
            recorder.onSamples = { [weak self] samples in self?.ingest(samples) }
            recorder.onInterruption = { [weak self] in self?.restartMicrophone() }
            do {
                try recorder.start(deviceUID: microphoneUID)
            } catch {
                throw StartError.capture(error.localizedDescription)
            }
            microphone = recorder
        }

        queue.sync {
            chunker = TranscriptChunker()
            emittedSamples = 0
        }
        pendingChunks = 0
        droppedChunks = false

        let started = Date()
        let entry = HistoryItem(date: started, text: "", audioSeconds: 0, appName: appName, language: nil, kind: .meeting, inProgress: true)
        history.add(entry)
        item = entry
        startedAt = started
        self.source = source
        state = .recording(appName: appName, started: started)
        meetingLog.notice("Mitschrift gestartet (\(appName, privacy: .public), Quelle: \(String(describing: source), privacy: .public))")

        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in self?.stop() }
    }

    /// Beendet die Aufnahme; der Rest wird noch transkribiert, dann meldet sich `onFinished`.
    public func stop() {
        guard case .recording(let appName, _) = state else { return }
        maxDurationTimer?.invalidate()
        stopCapture()
        state = .finishing(appName: appName)
        meetingLog.notice("Mitschrift gestoppt nach \(Int(self.elapsed)) s, \(self.pendingChunks) Abschnitte offen")
        queue.async { [weak self] in
            guard let self else { return }
            if let rest = self.chunker.flush() { self.enqueue(rest) }
            DispatchQueue.main.async { self.finishIfDone() }
        }
    }

    // MARK: - Audio → Abschnitte

    private func ingest(_ samples: [Float]) {
        let level = AudioRecorder.level(of: samples)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        queue.async { [weak self] in
            guard let self else { return }
            for chunk in self.chunker.append(samples) { self.enqueue(chunk) }
        }
    }

    /// Auf `queue`.
    private func enqueue(_ chunk: [Float]) {
        let offset = Double(emittedSamples) / AudioRecorder.sampleRate
        emittedSamples += chunk.count
        let seconds = Double(chunk.count) / AudioRecorder.sampleRate
        guard SpeechDetector.containsSpeech(chunk) else {
            meetingLog.debug("Abschnitt bei \(Int(offset)) s (\(Int(seconds)) s) ohne Sprache übersprungen")
            return
        }
        meetingLog.debug("Abschnitt bei \(Int(offset)) s (\(Int(seconds)) s) → Transkription")
        DispatchQueue.main.async { [weak self] in self?.transcribe(chunk, offset: offset) }
    }

    private func transcribe(_ chunk: [Float], offset: TimeInterval) {
        guard isActive else { return }
        guard pendingChunks < maxPendingChunks else {
            droppedChunks = true
            return
        }
        pendingChunks += 1
        let processor = TextPostProcessor(removeFillers: settings.removeFillers, replacements: settings.replacements)
        transcriber.transcribe(samples: chunk, language: settings.language, prompt: settings.whisperPrompt) { [weak self] result in
            guard let self else { return }
            self.pendingChunks -= 1
            if case .success(let transcription) = result, let text = processor.process(transcription.text) {
                self.append(text, offset: offset, language: transcription.language)
            }
            self.finishIfDone()
        }
    }

    private func append(_ text: String, offset: TimeInterval, language: String?) {
        guard var item else { return }
        let paragraph = "[\(Self.clock(offset))] \(text)"
        item.text = item.text.isEmpty ? paragraph : item.text + "\n\n" + paragraph
        item.audioSeconds = elapsed
        if item.language == nil { item.language = language }
        self.item = item
        history.update(item)
    }

    private func finishIfDone() {
        guard case .finishing = state, pendingChunks == 0 else { return }
        var result: HistoryItem?
        if var finished = item {
            finished.inProgress = false
            finished.audioSeconds = elapsed
            if droppedChunks {
                finished.text += "\n\n[…] Teile des Meetings konnten nicht transkribiert werden – der Rechner kam nicht hinterher."
            }
            if finished.text.isEmpty {
                history.delete(finished)
            } else {
                history.update(finished)
                result = finished
            }
        }
        item = nil
        startedAt = nil
        source = nil
        state = .idle
        meetingLog.notice("Mitschrift abgeschlossen: \(result?.text.count ?? 0) Zeichen")
        onFinished?(result)
    }

    // MARK: - Aufnahmequellen

    private func stopCapture() {
        if #available(macOS 14.2, *), let capture = systemCapture as? SystemAudioCapture {
            capture.stop()
        }
        systemCapture = nil
        _ = microphone?.stop()
        microphone = nil
    }

    /// Nur-Mikrofon-Modus: Nach einem Gerätewechsel (AirPods) die Engine neu starten, statt stumm weiterzulaufen.
    private func restartMicrophone() {
        guard case .recording = state, let recorder = microphone else { return }
        _ = recorder.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, case .recording = self.state, self.microphone === recorder else { return }
            try? recorder.start(deviceUID: self.settings.inputDeviceUID)
        }
    }

    /// „12:34" bzw. „1:02:03".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
