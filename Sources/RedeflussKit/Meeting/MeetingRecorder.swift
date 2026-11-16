import AVFoundation
import Combine
import os.log

let meetingLog = Logger(subsystem: "eu.dream-marketing.redefluss", category: "meeting")

/// Zeichnet ein Meeting auf: Systemaudio + Mikrofon (oder nur Mikrofon), schneidet den Strom in
/// Abschnitte, transkribiert sie nacheinander und schreibt den Text fortlaufend in den Verlauf.
/// Gespeichert wird nur der Text – außer `meetingSaveAudio` ist eingeschaltet, dann zusätzlich eine .m4a-Datei.
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
    /// Die Audiodatei ließ sich zuletzt nicht anlegen oder schreiben – für die Einstellungen.
    @Published public private(set) var audioFileProblem: String?
    /// Läuft gerade eine Aufnahme, die auch als Audiodatei gespeichert wird?
    @Published public private(set) var isSavingAudio = false

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
    private var mixer = MeetingMixer(maxLag: Int(AudioRecorder.sampleRate / 2))
    private var emittedSamples = 0
    private var audioWriter: MeetingAudioWriter?

    // Nur auf dem Main-Thread:
    private var systemCapture: AnyObject?
    private var microphone: AudioRecorder?
    private var item: HistoryItem?
    private var pendingChunks = 0
    private var droppedChunks = false
    private var startedAt: Date?
    private var maxDurationTimer: Timer?
    /// Nach dem Stopp: Rest-Abschnitt und Audiodatei sind noch nicht fertig – so lange nicht abschließen.
    private var flushing = false

    /// Mehr Abschnitte warten nicht – sonst frisst ein zu langsamer Rechner den Speicher.
    private let maxPendingChunks = 6
    /// Sicherheitsgrenze pro Meeting.
    private let maxDuration: TimeInterval = 4 * 60 * 60

    init(transcriber: WhisperTranscriber, history: HistoryStore, settings: AppSettings) {
        self.transcriber = transcriber
        self.history = history
        self.settings = settings
        // Aufnahmen, die ein Absturz oder Stromausfall unfertig hinterlassen hat, jetzt fertigstellen.
        let recordings = history.recordingsDirectory
        queue.async { MeetingAudioWriter.recoverUnfinished(in: recordings) }
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
        let started = Date()

        // Vor den Aufnahmequellen einrichten, damit schon die ersten Samples in der Datei landen.
        var writer: MeetingAudioWriter?
        audioFileProblem = nil
        if settings.meetingSaveAudio {
            let url = history.recordingsDirectory.appendingPathComponent(MeetingAudioWriter.fileName(date: started, appName: appName))
            do {
                writer = try MeetingAudioWriter(url: url)
            } catch {
                audioFileProblem = error.localizedDescription
                meetingLog.error("Audiodatei nicht angelegt, nur Text: \(error.localizedDescription, privacy: .public)")
            }
        }
        queue.sync {
            chunker = TranscriptChunker()
            mixer = MeetingMixer(maxLag: Int(AudioRecorder.sampleRate / 2))
            emittedSamples = 0
            audioWriter = writer
        }

        if settings.meetingSystemAudio, #available(macOS 14.2, *) {
            let capture = SystemAudioCapture()
            capture.onSamples = { [weak self] samples in self?.receive(samples, from: .system) }
            do {
                try capture.start()
                systemCapture = capture
                source = .systemAndMicrophone
            } catch {
                systemAudioProblem = error.localizedDescription
                meetingLog.error("Systemaudio nicht verfügbar, nur Mikrofon: \(error.localizedDescription, privacy: .public)")
            }
        }

        let recorder = AudioRecorder()
        recorder.accumulates = false
        recorder.usesVoiceProcessing = true
        let mixesSystemAudio = source == .systemAndMicrophone
        recorder.onSamples = { [weak self] samples in
            if mixesSystemAudio {
                self?.receive(samples, from: .microphone)
            } else {
                self?.ingest(samples)
            }
        }
        recorder.onInterruption = { [weak self] in self?.restartMicrophone() }
        do {
            try recorder.start(deviceUID: microphoneUID)
        } catch {
            stopCapture()
            discardAudioFile()
            throw StartError.capture(error.localizedDescription)
        }
        microphone = recorder

        pendingChunks = 0
        droppedChunks = false
        isSavingAudio = writer != nil

        let entry = HistoryItem(
            date: started, text: "", audioSeconds: 0, appName: appName, language: nil, kind: .meeting, inProgress: true,
            audioFile: writer?.url.lastPathComponent
        )
        history.add(entry)
        item = entry
        startedAt = started
        self.source = source
        state = .recording(appName: appName, started: started)
        meetingLog.notice("Mitschrift gestartet (\(appName, privacy: .public), Quelle: \(String(describing: source), privacy: .public), Audiodatei: \(writer != nil))")

        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in self?.stop() }
    }

    /// Beendet die Aufnahme; der Rest wird noch transkribiert, dann meldet sich `onFinished`.
    public func stop() {
        guard case .recording(let appName, _) = state else { return }
        maxDurationTimer?.invalidate()
        stopCapture()
        flushing = true
        state = .finishing(appName: appName)
        meetingLog.notice("Mitschrift gestoppt nach \(Int(self.elapsed)) s, \(self.pendingChunks) Abschnitte offen")
        queue.async { [weak self] in
            guard let self else { return }
            let mixedRest = self.mixer.flush()
            if !mixedRest.isEmpty { self.consume(mixedRest) }
            if let rest = self.chunker.flush() { self.enqueue(rest) }
            self.finishAudioFile()
            DispatchQueue.main.async {
                self.flushing = false
                self.finishIfDone()
            }
        }
    }

    /// Beim Beenden der App: Aufnahme anhalten und die Audiodatei abschließen – sonst ist sie nicht abspielbar.
    public func finalizeAudioFile() {
        guard isSavingAudio else { return }
        stopCapture()
        // Alles bis hierher Aufgenommene ist schon geschrieben (`ingest` läuft über dieselbe Queue).
        // Reicht die Zeit nicht, bleibt die Rohdatei liegen und wird beim nächsten Start gewandelt.
        queue.sync { finishAudioFile() }
    }

    /// Auf `queue`: Rohdatei in die .m4a wandeln.
    private func finishAudioFile() {
        guard let writer = audioWriter else { return }
        audioWriter = nil
        do {
            try writer.finish()
        } catch {
            let message = error.localizedDescription
            meetingLog.error("Audiodatei nicht fertiggestellt: \(message, privacy: .public)")
            DispatchQueue.main.async { [weak self] in self?.audioFileProblem = message }
        }
    }

    /// Start fehlgeschlagen: die leere Datei wieder entfernen.
    private func discardAudioFile() {
        queue.sync {
            guard let writer = audioWriter else { return }
            writer.discard()
            audioWriter = nil
        }
    }

    // MARK: - Audio → Abschnitte

    private func ingest(_ samples: [Float]) {
        queue.async { [weak self] in self?.consume(samples) }
    }

    private func receive(_ samples: [Float], from source: MeetingMixer.Source) {
        queue.async { [weak self] in
            guard let self else { return }
            let mixed = self.mixer.append(samples, from: source)
            if !mixed.isEmpty { self.consume(mixed) }
        }
    }

    private func consume(_ samples: [Float]) {
        let level = AudioRecorder.level(of: samples)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        write(samples)
        for chunk in chunker.append(samples) { enqueue(chunk) }
    }

    /// Auf `queue`. Ein Schreibfehler (Platte voll) beendet nur die Audiodatei, nicht die Mitschrift;
    /// was bis dahin aufgenommen wurde, bleibt erhalten.
    private func write(_ samples: [Float]) {
        guard let writer = audioWriter else { return }
        do {
            try writer.append(samples)
        } catch {
            audioWriter = nil
            try? writer.finish()
            let message = error.localizedDescription
            meetingLog.error("Audiodatei abgebrochen: \(message, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.audioFileProblem = message
                self?.isSavingAudio = false
            }
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
        guard case .finishing = state, pendingChunks == 0, !flushing else { return }
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
        isSavingAudio = false
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

    /// Nach einem Gerätewechsel (AirPods) die Engine neu starten, statt stumm weiterzulaufen.
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
