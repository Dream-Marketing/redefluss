import AppKit
import CoreAudio

/// Ein fremdes Programm, das gerade das Mikrofon benutzt.
public struct MicrophoneUser: Equatable {
    public let pid: pid_t
    public let bundleID: String
    /// Anzeigename der App (bei Hilfsprozessen die Eltern-App), sonst die Bundle-ID.
    public let name: String
}

/// Entscheidet mit kurzer Verzögerung, ob ein Meeting läuft – ein Mikrofon-Zucker beim Gerätewechsel
/// soll das Meeting nicht beenden, ein Soundtest von einer Sekunde keins beginnen.
struct MeetingDetectionLogic {
    enum Event: Equatable { case started, ended }

    /// So lange muss das Mikrofon fremd belegt sein, bevor ein Meeting gilt …
    var startAfter: TimeInterval = 1
    /// … und so lange frei, bevor es als beendet gilt.
    var endAfter: TimeInterval = 2

    private(set) var isMeeting = false
    private var pendingSince: Date?
    private var pendingBusy = false

    mutating func observe(busy: Bool, at now: Date) -> Event? {
        if busy == isMeeting {
            pendingSince = nil
            return nil
        }
        guard let since = pendingSince, pendingBusy == busy else {
            pendingSince = now
            pendingBusy = busy
            return nil
        }
        guard now.timeIntervalSince(since) >= (busy ? startAfter : endAfter) else { return nil }
        isMeeting = busy
        pendingSince = nil
        return busy ? .started : .ended
    }

    /// Wann die nächste Abfrage den schwebenden Wechsel entscheiden würde – nil, wenn nichts schwebt.
    func pendingDeadline(now: Date) -> TimeInterval? {
        guard let since = pendingSince else { return nil }
        let needed = pendingBusy ? startAfter : endAfter
        return max(0, needed - now.timeIntervalSince(since))
    }

    mutating func reset() {
        isMeeting = false
        pendingSince = nil
    }
}

/// Erkennt Meetings daran, dass ein anderes Programm (Zoom, Teams, FaceTime, der Browser für Meet …)
/// das Mikrofon benutzt. Beobachtet dafür die Prozess-Objekte der Audio-HAL (macOS 14.2+): Änderungen
/// kommen per Listener sofort, eine Abfrage pro Sekunde ist nur das Sicherheitsnetz.
public final class MeetingDetector {
    /// Meeting hat begonnen (mit den beteiligten Apps) bzw. ist zu Ende.
    public var onStart: (([MicrophoneUser]) -> Void)?
    public var onEnd: (() -> Void)?
    /// Bei jeder Änderung: wer das Mikrofon gerade benutzt – für die Statusanzeige.
    public var onPoll: (([MicrophoneUser]) -> Void)?

    public static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// Mikrofon-Nutzer, die kein Meeting bedeuten: Siri, Diktat, Sprachmemos, andere Diktier-Apps.
    public var ignoredBundlePrefixes: [String] = [
        "com.apple.siri", "com.apple.assistant", "com.apple.corespeech", "com.apple.speech",
        "com.apple.Dictation", "com.apple.VoiceMemos", "com.apple.SoundRecorder", "com.apple.inputanalyticsd",
        "com.electron.wispr-flow", "com.superduper.superwhisper", "com.goodsnooze.MacWhisper",
    ]

    private var timer: Timer?
    private var deadlineTimer: Timer?
    private var logic = MeetingDetectionLogic()
    private let interval: TimeInterval = 1
    private var lastUsers: [MicrophoneUser] = []
    private var watchedProcesses: Set<AudioObjectID> = []
    private var listeningToProcessList = false
    private lazy var changeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.poll() }

    public init() {}

    public var isRunning: Bool { timer != nil }

    public func start() {
        guard timer == nil, Self.isSupported else { return }
        logic.reset()
        addListener(to: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
        listeningToProcessList = true
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        if listeningToProcessList {
            removeListener(from: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
            listeningToProcessList = false
        }
        for object in watchedProcesses { removeListener(from: object, selector: kAudioProcessPropertyIsRunningInput) }
        watchedProcesses = []
        logic.reset()
        lastUsers = []
    }

    private func poll() {
        guard timer != nil else { return }
        watchProcesses(AudioProcesses.allProcessObjects())

        let users = currentUsers()
        if users != lastUsers {
            lastUsers = users
            onPoll?(users)
        }
        let now = Date()
        switch logic.observe(busy: !users.isEmpty, at: now) {
        case .started:
            meetingLog.notice("Meeting erkannt: \(users.map { "\($0.name) [\($0.bundleID)]" }.joined(separator: ", "), privacy: .public)")
            onStart?(users)
        case .ended:
            meetingLog.notice("Meeting zu Ende – Mikrofon ist wieder frei")
            onEnd?()
        case nil:
            break
        }

        // Schwebenden Wechsel genau dann entscheiden, wenn die Schwelle erreicht ist – nicht erst bei der nächsten Abfrage.
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        if let remaining = logic.pendingDeadline(now: now) {
            deadlineTimer = Timer.scheduledTimer(withTimeInterval: remaining + 0.05, repeats: false) { [weak self] _ in self?.poll() }
        }
    }

    /// Jedes Prozess-Objekt meldet per Listener, wenn es einen Eingabestrom öffnet oder schließt.
    private func watchProcesses(_ objects: [AudioObjectID]) {
        let current = Set(objects)
        for object in current.subtracting(watchedProcesses) {
            addListener(to: object, selector: kAudioProcessPropertyIsRunningInput)
        }
        // Verschwundene Prozesse: Objekt ist weg, der Listener damit auch.
        watchedProcesses = current
    }

    private func addListener(to object: AudioObjectID, selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(object, &address, .main, changeListener)
    }

    private func removeListener(from object: AudioObjectID, selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, changeListener)
    }

    /// Fremde Prozesse mit aktivem Eingabestrom, ohne die eigene App und ohne Ausnahmen.
    func currentUsers() -> [MicrophoneUser] {
        let ownBundle = Bundle.main.bundleIdentifier
        return AudioProcesses.processesRunningInput()
            .filter { $0.pid != getpid() }
            .filter { $0.bundleID.isEmpty || $0.bundleID != ownBundle }
            .filter { user in !ignoredBundlePrefixes.contains { user.bundleID.hasPrefix($0) } }
            .map { MicrophoneUser(pid: $0.pid, bundleID: $0.bundleID, name: Self.displayName(pid: $0.pid, bundleID: $0.bundleID)) }
    }

    /// Hilfsprozesse (Chrome Helper, Teams-Renderer) haben keinen Namen – dann den der Eltern-App nehmen.
    static func displayName(pid: pid_t, bundleID: String) -> String {
        var current = pid
        for _ in 0..<4 {
            if let app = NSRunningApplication(processIdentifier: current), let name = app.localizedName {
                return name
            }
            guard let parent = parentProcessID(of: current), parent > 1 else { break }
            current = parent
        }
        // Kommandozeilen-Werkzeuge haben weder Bundle noch Eltern-App – dann neutral beschriften.
        return bundleID.isEmpty ? "Meeting" : bundleID
    }

    private static func parentProcessID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

/// Prozess-Objekte der Audio-HAL (macOS 14.2+): welche Programme haben gerade einen Eingabestrom offen?
enum AudioProcesses {
    struct Entry: Equatable {
        let pid: pid_t
        let bundleID: String
    }

    static func allProcessObjects() -> [AudioObjectID] {
        CoreAudioProperty.readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) ?? []
    }

    static func processesRunningInput() -> [Entry] {
        allProcessObjects().compactMap { object in
            guard let running: UInt32 = CoreAudioProperty.read(object, kAudioProcessPropertyIsRunningInput), running != 0,
                  let pid: pid_t = CoreAudioProperty.read(object, kAudioProcessPropertyPID) else { return nil }
            return Entry(pid: pid, bundleID: CoreAudioProperty.readString(object, kAudioProcessPropertyBundleID) ?? "")
        }
    }
}
