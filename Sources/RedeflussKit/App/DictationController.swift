import AppKit
import Carbon.HIToolbox
import Combine

/// Herzstück: verbindet Taste → Aufnahme → whisper.cpp → Nachbearbeitung → Einfügen.
/// Dazu die Meeting-Mitschrift: erkennt fremde Mikrofon-Nutzung und schreibt automatisch mit.
public final class DictationController: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case recording(handsFree: Bool)
        case transcribing
    }

    public enum ModelState: Equatable {
        case none
        case loading(String)
        case ready(String)
        case failed(String)

        public var isUsable: Bool {
            switch self {
            case .ready, .loading: return true
            default: return false
            }
        }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var modelState: ModelState = .none
    @Published public private(set) var hotkeyActive = false
    @Published public private(set) var lastTranscript: String?
    /// Apps, die gerade das Mikrofon benutzen (für die Statusanzeige in den Einstellungen).
    @Published public private(set) var microphoneUsers: [MicrophoneUser] = []

    public let settings: AppSettings
    public let models: ModelManager
    public let history: HistoryStore
    public let flowBar = FlowBarController()
    public let meeting: MeetingRecorder

    /// Wird aufgerufen, wenn der Nutzer die Einstellungen sehen sollte (z. B. kein Modell).
    public var onNeedsAttention: ((SettingsTab) -> Void)?

    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = WhisperTranscriber()
    private let inserter = TextInserter()
    private let sounds = SoundPlayer()
    private let detector = MeetingDetector()

    private var recordingStarted: Date?
    private var lastStartSound: Date = .distantPast
    private var pendingIdle: DispatchWorkItem?
    private var targetApp: NSRunningApplication?
    private var maxDurationTimer: Timer?
    private var permissionTimer: Timer?
    private var meetingClockTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Obergrenze pro Diktat – danach wird automatisch transkribiert.
    private let maxRecordingSeconds: TimeInterval = 10 * 60

    public init(settings: AppSettings = .shared, models: ModelManager = .shared, history: HistoryStore = .shared) {
        self.settings = settings
        self.models = models
        self.history = history
        self.meeting = MeetingRecorder(transcriber: transcriber, history: history, settings: settings)
    }

    // MARK: - Start

    public func start() {
        hotkey.onEvent = { [weak self] event in self?.handle(event) }
        recorder.onLevel = { [weak self] level in self?.flowBar.model.push(level: level) }
        recorder.onInterruption = { [weak self] in self?.recordingInterrupted() }

        flowBar.model.onStartHandsFree = { [weak self] in self?.startFromBar() }
        flowBar.model.onStop = { [weak self] in self?.finishRecording() }
        flowBar.model.onCancel = { [weak self] in self?.cancelRecording(settle: false) }
        flowBar.model.onStopMeeting = { [weak self] in self?.meeting.stop() }
        flowBar.onPositionChange = { [weak self] position in self?.settings.flowBarPosition = position }

        settings.$hotkey
            .sink { [weak self] key in
                self?.hotkey.hotkey = key
                self?.flowBar.model.hotkeyLabel = key.shortLabel
            }
            .store(in: &cancellables)
        settings.$handsFreeEnabled
            .sink { [weak self] enabled in self?.hotkey.handsFreeEnabled = enabled }
            .store(in: &cancellables)
        settings.$showIdlePill
            .sink { [weak self] show in self?.flowBar.showIdle = show }
            .store(in: &cancellables)
        settings.$flowBarPosition
            .sink { [weak self] position in self?.flowBar.position = position }
            .store(in: &cancellables)
        settings.$modelPath
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] path in self?.loadModel(path: path) }
            .store(in: &cancellables)

        // Tastaturlayout kann sich ändern (z. B. Wechsel auf Dvorak).
        DistributedNotificationCenter.default().publisher(for: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))
            .sink { [weak self] _ in self?.updatePasteKeyCode() }
            .store(in: &cancellables)
        updatePasteKeyCode()

        flowBar.showIdle = settings.showIdlePill
        flowBar.setIdle()
        flowBar.show()

        // Leiste folgt dem aktiven Bildschirm.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.flowBar.show() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in if self?.phase == .idle { self?.flowBar.show() } }
            .store(in: &cancellables)

        setUpMeetings()
        startHotkeyWhenTrusted()
        loadInitialModel()
    }

    private func updatePasteKeyCode() {
        hotkey.pasteKeyCode = Int64(KeyboardLayout.keyCode(for: "v") ?? 9)
    }

    /// Der Tap braucht die Bedienungshilfen-Berechtigung. Solange sie fehlt, regelmäßig nachsehen.
    public func startHotkeyWhenTrusted() {
        permissionTimer?.invalidate()
        if Permissions.accessibilityGranted, hotkey.start() {
            hotkeyActive = true
            return
        }
        hotkeyActive = false
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if Permissions.accessibilityGranted, self.hotkey.start() {
                self.hotkeyActive = true
                timer.invalidate()
            }
        }
    }

    // MARK: - Modell

    private func loadInitialModel() {
        models.refresh()
        // refresh() veröffentlicht asynchron auf dem Main-Thread.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let path = self.settings.modelPath
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                self.loadModel(path: path)
            } else if let best = self.models.bestInstalled() {
                self.settings.modelPath = best.path   // löst loadModel über den Publisher aus
            } else {
                self.modelState = .none
            }
        }
    }

    public func loadModel(path: String) {
        guard !path.isEmpty else {
            modelState = .none
            transcriber.unload()
            return
        }
        let name = InstalledModel(path: path, sizeBytes: 0, isExternal: false).displayName
        modelState = .loading(name)
        transcriber.load(modelPath: path) { [weak self] result in
            guard let self, self.settings.modelPath == path else { return }
            switch result {
            case .success: self.modelState = .ready(name)
            case .failure(let error): self.modelState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Ablauf

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .start: beginRecording(handsFree: false)
        case .lockHandsFree:
            guard case .recording = phase else { return }
            phase = .recording(handsFree: true)
            flowBar.setRecording(handsFree: true)
        case .stop: finishRecording()
        case .cancel: cancelRecording(settle: true)
        case .pasteLast: pasteLast()
        }
    }

    private func startFromBar() {
        guard phase == .idle else { return }
        hotkey.enterHandsFree()
        beginRecording(handsFree: true)
        if phase != .recording(handsFree: true) { hotkey.reset() }
    }

    private func beginRecording(handsFree: Bool) {
        // Während noch transkribiert wird, keine neue Aufnahme – und die Taste nicht im Freihand-Zustand hängen lassen.
        guard phase == .idle else {
            if phase == .transcribing { hotkey.reset() }
            return
        }

        guard modelState.isUsable else {
            hotkey.reset()
            sounds.play(.error)
            flowBar.showMessage("Kein Sprachmodell – hier klicken", isError: true, duration: 3.5) { [weak self] in
                self?.onNeedsAttention?(.model)
            }
            return
        }

        switch Permissions.microphoneStatus {
        case .authorized:
            break
        case .notDetermined:
            hotkey.reset()
            Permissions.requestMicrophone { _ in }
            return
        default:
            hotkey.reset()
            sounds.play(.error)
            flowBar.showMessage("Kein Mikrofonzugriff – Systemeinstellungen prüfen", isError: true, duration: 3.5) {
                Permissions.openMicrophoneSettings()
            }
            return
        }

        do {
            try recorder.start(deviceUID: settings.inputDeviceUID)
        } catch {
            hotkey.reset()
            sounds.play(.error)
            flowBar.showMessage(error.localizedDescription, isError: true)
            return
        }

        pendingIdle?.cancel()
        targetApp = NSWorkspace.shared.frontmostApplication
        recordingStarted = Date()
        phase = .recording(handsFree: handsFree)
        flowBar.setRecording(handsFree: handsFree)
        // Beim Doppeltipp nicht zweimal hintereinander piepen.
        if settings.playSounds && Date().timeIntervalSince(lastStartSound) > 0.6 {
            sounds.play(.start)
            lastStartSound = Date()
        }

        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingSeconds, repeats: false) { [weak self] _ in
            self?.hotkey.reset()
            self?.finishRecording()
        }
    }

    /// Das Mikrofon ist während des Diktats weggefallen oder gewechselt (AirPods, Headset) –
    /// die Engine liefert dann nichts mehr. Also beenden und das bis dahin Gesagte verwenden.
    private func recordingInterrupted() {
        guard case .recording = phase else { return }
        hotkey.reset()
        finishRecording()
    }

    /// - Parameter settle: Leiste kurz stehen lassen – nach einem kurzen Tipp kommt oft
    ///   gleich der zweite (Doppeltipp → Freihand), dann soll nichts flackern.
    private func cancelRecording(settle: Bool) {
        guard case .recording = phase else { return }
        maxDurationTimer?.invalidate()
        _ = recorder.stop()
        hotkey.reset()
        phase = .idle
        pendingIdle?.cancel()
        guard settle else {
            flowBar.setIdle()
            return
        }
        flowBar.model.resetLevels()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .idle else { return }
            self.flowBar.setIdle()
        }
        pendingIdle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func finishRecording() {
        guard case .recording = phase else { return }
        maxDurationTimer?.invalidate()
        hotkey.reset()
        let samples = recorder.stop()
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        if settings.playSounds { sounds.play(.stop) }

        guard SpeechDetector.containsSpeech(samples) else {
            phase = .idle
            flowBar.showMessage("Nichts gehört", duration: 1.4)
            return
        }

        phase = .transcribing
        flowBar.setTranscribing()

        let processor = TextPostProcessor(removeFillers: settings.removeFillers, replacements: settings.replacements)
        let targetApp = self.targetApp
        transcriber.transcribe(samples: samples, language: settings.language, prompt: settings.whisperPrompt) { [weak self] result in
            guard let self else { return }
            self.phase = .idle
            switch result {
            case .failure(let error):
                self.sounds.play(.error)
                self.flowBar.showMessage(error.localizedDescription, isError: true)
            case .success(let transcription):
                guard let cleaned = processor.process(transcription.text) else {
                    self.flowBar.showMessage("Nichts erkannt", duration: 1.4)
                    return
                }
                let text = self.settings.appendTrailingSpace ? cleaned + " " : cleaned
                self.lastTranscript = text
                self.deliver(text, to: targetApp)
                if self.settings.saveHistory {
                    self.history.add(HistoryItem(
                        date: Date(),
                        text: cleaned,
                        audioSeconds: seconds,
                        appName: targetApp?.localizedName,
                        language: transcription.language,
                        kind: .dictation
                    ))
                }
            }
        }
    }

    private func deliver(_ text: String, to app: NSRunningApplication?) {
        // Falls der Fokus zwischendurch gewechselt ist (z. B. Klick auf die Leiste), zurück zur Ziel-App.
        if let app, NSWorkspace.shared.frontmostApplication != app, !app.isTerminated,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.paste(text) }
        } else {
            paste(text)
        }
    }

    private func paste(_ text: String) {
        switch inserter.insert(text, restoreClipboard: settings.restoreClipboard) {
        case .pasted:
            flowBar.setIdle()
        case .copiedOnly:
            flowBar.showMessage("In die Zwischenablage kopiert (⌘V)", duration: 2.6)
        }
    }

    public func pasteLast() {
        guard let lastTranscript, phase == .idle else { return }
        paste(lastTranscript)
    }

    public func copyLast() {
        guard let lastTranscript else { return }
        inserter.copyToClipboard(lastTranscript.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Meetings

    private func setUpMeetings() {
        detector.onPoll = { [weak self] users in self?.microphoneUsers = users }
        detector.onStart = { [weak self] users in self?.meetingDetected(users) }
        detector.onEnd = { [weak self] in
            // Die Meeting-App hat das Mikrofon freigegeben → Mitschrift abschließen.
            if case .recording = self?.meeting.state { self?.meeting.stop() }
        }
        settings.$meetingAutoRecord
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.detector.start() } else { self.detector.stop(); self.microphoneUsers = [] }
            }
            .store(in: &cancellables)

        meeting.onLevel = { [weak self] level in
            guard let self, case .meeting = self.flowBar.model.mode else { return }
            self.flowBar.model.push(level: level)
        }
        meeting.onFinished = { [weak self] item in
            guard let self else { return }
            if item == nil {
                self.flowBar.showMessage("Meeting ohne Sprache – nichts gespeichert", duration: 3)
            } else {
                self.flowBar.showMessage("Meeting-Mitschrift im Verlauf gespeichert", duration: 4) { [weak self] in
                    self?.onNeedsAttention?(.history)
                }
            }
        }
        meeting.$state
            .sink { [weak self] state in self?.meetingStateChanged(state) }
            .store(in: &cancellables)
    }

    private func meetingDetected(_ users: [MicrophoneUser]) {
        guard settings.meetingAutoRecord, !meeting.isActive else { return }
        guard modelState.isUsable else {
            flowBar.showMessage("Meeting erkannt – kein Sprachmodell zum Mitschreiben", isError: true, duration: 4) { [weak self] in
                self?.onNeedsAttention?(.model)
            }
            return
        }
        let names = Array(Set(users.map(\.name))).sorted()
        startMeeting(appName: names.first ?? "Meeting")
    }

    /// Mitschrift von Hand starten (Menü) – z. B. für ein Gespräch ohne Meeting-App.
    public func startMeetingManually() {
        guard modelState.isUsable else {
            onNeedsAttention?(.model)
            return
        }
        let names = microphoneUsers.map(\.name)
        startMeeting(appName: names.first ?? "Meeting")
    }

    private func startMeeting(appName: String) {
        do {
            try meeting.start(appName: appName)
        } catch {
            sounds.play(.error)
            flowBar.showMessage(error.localizedDescription, isError: true, duration: 4)
        }
    }

    public func stopMeeting() {
        meeting.stop()
    }

    private func meetingStateChanged(_ state: MeetingRecorder.State) {
        meetingClockTimer?.invalidate()
        meetingClockTimer = nil
        switch state {
        case .idle:
            flowBar.meetingFinishing = false
            flowBar.meetingLabel = nil
        case .recording(let appName, _):
            flowBar.meetingFinishing = false
            flowBar.model.meetingClock = MeetingRecorder.clock(0)
            flowBar.meetingLabel = appName
            meetingClockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.flowBar.model.meetingClock = MeetingRecorder.clock(self.meeting.elapsed)
            }
        case .finishing:
            flowBar.meetingLabel = nil
            flowBar.meetingFinishing = true
        }
    }
}
