import AppKit
import SwiftUI
import Combine
import os.log

let flowBarLog = Logger(subsystem: "eu.dream-marketing.redefluss", category: "flowbar")

/// Zustand der schwebenden Leiste unten am Bildschirm.
public final class FlowBarModel: ObservableObject {
    public enum Mode: Equatable {
        case hidden
        case idle
        case recording
        case handsFree
        case transcribing
        /// Meeting wird mitgeschrieben; der Text ist der Name der Meeting-App.
        case meeting(String)
        /// Meeting beendet, die letzten Abschnitte werden noch transkribiert.
        case meetingFinishing
        case message(String, isError: Bool)
    }

    @Published public var mode: Mode = .idle
    @Published public var levels: [Float] = Array(repeating: 0, count: FlowBarModel.barCount)
    @Published public var hotkeyLabel = "Fn"
    /// Laufzeit des Meetings („12:34") – getrennt vom Modus, damit der Sekundentakt keine Animation auslöst.
    @Published public var meetingClock = ""

    public static let barCount = 14

    var onStartHandsFree: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMessageTap: (() -> Void)?
    var onStopMeeting: (() -> Void)?
    /// Rahmen der sichtbaren Kapsel in der Leisten-View (Ursprung oben links) – nur dort nimmt die Leiste Klicks an.
    var onPillFrameChange: ((CGRect) -> Void)?
    /// Verschieben der Leiste; nil (z. B. in Snapshots) = nicht verschiebbar.
    var drag: PillDragTracker?

    public init() {}

    public func push(level: Float) {
        var next = levels
        next.removeFirst()
        next.append(level)
        levels = next
    }

    public func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// Schiebt das Fenster mit der Maus, sobald die Zieh-Geste anspringt.
/// Rechnet in Bildschirmkoordinaten, weil das Fenster unter der Maus wegläuft – mit
/// View-Koordinaten würde die Leiste zittern.
final class PillDragTracker {
    var windowOrigin: () -> CGPoint = { .zero }
    var mouseLocation: () -> CGPoint = { NSEvent.mouseLocation }
    var moveWindow: (CGPoint) -> Void = { _ in }
    var didEndDrag: () -> Void = {}
    /// Ab so vielen Punkten Bewegung wird wirklich verschoben.
    var threshold: CGFloat = 4

    private var start: (origin: CGPoint, mouse: CGPoint)?
    private(set) var isDragging = false

    /// Bei jedem Maus-Event mit gedrückter Taste. `alreadyMoved`: Weg seit dem Druck in Bildschirmrichtung
    /// (SwiftUI meldet ihn erst, wenn die Geste anspringt – ohne Übernahme bliebe eine Totzone).
    func changed(alreadyMoved: CGSize = .zero) {
        guard let start else {
            let mouse = mouseLocation()
            start = (windowOrigin(), CGPoint(x: mouse.x - alreadyMoved.width, y: mouse.y - alreadyMoved.height))
            if alreadyMoved != .zero { changed() }
            return
        }
        let mouse = mouseLocation()
        let dx = mouse.x - start.mouse.x
        let dy = mouse.y - start.mouse.y
        if !isDragging && abs(dx) < threshold && abs(dy) < threshold { return }
        if !isDragging { flowBarLog.debug("Ziehen beginnt bei \(mouse.x, format: .fixed(precision: 0)),\(mouse.y, format: .fixed(precision: 0))") }
        isDragging = true
        moveWindow(CGPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    /// Beim Loslassen.
    func ended() {
        let dragged = isDragging
        start = nil
        isDragging = false
        flowBarLog.debug("\(dragged ? "Ziehen beendet" : "Loslassen ohne Zug", privacy: .public)")
        if dragged { didEndDrag() }
    }
}

/// Randloses, nicht aktivierendes Panel: nimmt nie den Fokus, damit das Einfügen
/// in der App landet, in der der Nutzer gerade schreibt.
final class FlowBarPanel: NSPanel {
    static let size = NSSize(width: 360, height: 64)
    /// Typische Kapselgröße unten mittig im Panel – hält die Kapsel beim Verschieben auf dem Bildschirm.
    static let pillBox = NSSize(width: 150, height: 32)
    static let pillBottomPadding: CGFloat = 6

    init(model: FlowBarModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: FlowBarView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var placedOnce = false

    /// Unten mittig über dem Dock oder an die gespeicherte Stelle – auf dem gespeicherten Bildschirm,
    /// sonst auf dem, wo die Leiste gerade ist. Nur beim allerersten Mal zählt die Maus: Die Leiste soll
    /// nicht bei jedem Hinweis zwischen den Bildschirmen springen.
    func reposition(_ position: FlowBarPosition?) {
        let screen = Self.screen(withDisplayID: position?.displayID)
            ?? (placedOnce ? currentScreen : nil)
            ?? Self.screenUnderMouse
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        placedOnce = true
        setFrameOrigin(Self.origin(for: position, in: visible))
    }

    /// Bildschirm, auf dem das Panel gerade liegt.
    var currentScreen: NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
    }

    /// Sichtbarer Bereich des Bildschirms, auf dem das Panel gerade liegt.
    var currentVisibleFrame: NSRect? { (currentScreen ?? NSScreen.main)?.visibleFrame }

    static var screenUnderMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    static func screen(withDisplayID displayID: UInt32?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { $0.displayID == displayID }
    }

    /// Fensterursprung für eine gespeicherte Position (nil = unten mittig).
    static func origin(for position: FlowBarPosition?, in visible: NSRect) -> NSPoint {
        guard let position else {
            return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + pillBottomPadding)
        }
        let center = NSPoint(
            x: visible.minX + CGFloat(position.x) * visible.width,
            y: visible.minY + CGFloat(position.y) * visible.height
        )
        return clamp(NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), in: visible)
    }

    /// Gespeicherte Position für einen Fensterursprung. Nahe der Standardlage rastet sie ein (nil).
    static func position(forOrigin origin: NSPoint, in visible: NSRect) -> FlowBarPosition? {
        guard visible.width > 0, visible.height > 0 else { return nil }
        let standard = self.origin(for: nil, in: visible)
        if abs(origin.x - standard.x) < 24, abs(origin.y - standard.y) < 24 { return nil }
        let clamped = clamp(origin, in: visible)
        let center = NSPoint(x: clamped.x + size.width / 2, y: clamped.y + size.height / 2)
        return FlowBarPosition(
            x: Double((center.x - visible.minX) / visible.width),
            y: Double((center.y - visible.minY) / visible.height)
        )
    }

    /// Hält die Kapsel (nicht das unsichtbare Panel) im sichtbaren Bereich – so kann sie bis an den Rand.
    static func clamp(_ origin: NSPoint, in visible: NSRect) -> NSPoint {
        let minX = visible.minX + pillBox.width / 2 - size.width / 2
        let maxX = visible.maxX - pillBox.width / 2 - size.width / 2
        let minY = visible.minY
        let maxY = visible.maxY - pillBottomPadding - pillBox.height
        return NSPoint(
            x: min(max(origin.x, minX), max(minX, maxX)),
            y: min(max(origin.y, minY), max(minY, maxY))
        )
    }
}

/// Meldet den Rahmen der Kapsel nach oben, damit nur dort Klicks angenommen werden.
private struct PillFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private extension View {
    /// Rahmen der Kapsel melden – nur dort nimmt das Panel Klicks an.
    func reportPillFrame() -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: PillFrameKey.self, value: geometry.frame(in: .named(FlowBarView.space)))
        })
    }

    /// Hier lässt sich die Leiste anfassen und verschieben. Nicht an Elternelemente von Knöpfen hängen:
    /// Eine DragGesture am Elternelement nimmt SwiftUI-Buttons auf macOS den Klick weg.
    func pillDragHandle(_ model: FlowBarModel) -> some View {
        gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    // SwiftUI zählt y nach unten, der Bildschirm nach oben.
                    model.drag?.changed(alreadyMoved: CGSize(width: value.translation.width, height: -value.translation.height))
                }
                .onEnded { _ in model.drag?.ended() }
        )
    }
}

struct FlowBarView: View {
    static let space = "flowbar"

    @ObservedObject var model: FlowBarModel
    @State private var hovering = false

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            pill
                .padding(.bottom, FlowBarPanel.pillBottomPadding)
        }
        .frame(width: FlowBarPanel.size.width, height: FlowBarPanel.size.height)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(PillFrameKey.self) { frame in model.onPillFrameChange?(frame) }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: model.mode)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder
    private var pill: some View {
        switch model.mode {
        case .hidden:
            EmptyView()

        case .idle:
            Capsule()
                .fill(Color.black.opacity(hovering ? 0.82 : 0.55))
                .overlay(Capsule().strokeBorder(Color.white.opacity(hovering ? 0.3 : 0.18), lineWidth: 1))
                .overlay {
                    if hovering {
                        Text("\(model.hotkeyLabel) halten oder klicken")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize()
                    }
                }
                .frame(width: hovering ? 170 : 38, height: hovering ? 24 : 8)
                .contentShape(Capsule().inset(by: -8))
                .onHover { hovering = $0 }
                .onTapGesture { model.onStartHandsFree?() }
                .pillDragHandle(model)
                .reportPillFrame()
                .help("Diktat starten – ziehen verschiebt die Leiste")

        case .recording:
            capsule {
                Waveform(levels: model.levels)
            }
            .frame(width: 104, height: 32)
            .reportPillFrame()

        case .handsFree:
            capsule(inset: 6) {
                HStack(spacing: 8) {
                    CircleButton(symbol: "xmark", tint: .white.opacity(0.18), help: "Verwerfen (Esc)") { model.onCancel?() }
                    Waveform(levels: model.levels)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .pillDragHandle(model)
                    CircleButton(symbol: "stop.fill", tint: Color(red: 0.95, green: 0.27, blue: 0.27), help: "Fertig (\(model.hotkeyLabel))") { model.onStop?() }
                }
            }
            .frame(width: 150, height: 32)
            .reportPillFrame()

        case .transcribing:
            capsule {
                ThinkingDots()
            }
            .frame(width: 64, height: 32)
            .reportPillFrame()

        case .meeting(let appName):
            capsule(inset: 6) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Spacer().frame(width: 2)
                        RecordingDot()
                        Text(appName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .frame(maxWidth: 110)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(model.meetingClock)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                        Waveform(levels: model.levels, bars: 8)
                    }
                    .contentShape(Rectangle())
                    .pillDragHandle(model)
                    .help("Meeting wird mitgeschrieben – ziehen verschiebt die Leiste")
                    CircleButton(symbol: "stop.fill", tint: Color(red: 0.95, green: 0.27, blue: 0.27), help: "Meeting-Mitschrift beenden") { model.onStopMeeting?() }
                }
            }
            .frame(height: 32)
            .fixedSize(horizontal: true, vertical: false)
            .reportPillFrame()

        case .meetingFinishing:
            capsule {
                HStack(spacing: 8) {
                    ThinkingDots()
                    Text("Meeting wird gespeichert …")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize()
                }
            }
            .frame(height: 32)
            .fixedSize(horizontal: true, vertical: false)
            .pillDragHandle(model)
            .reportPillFrame()

        case .message(let text, let isError):
            capsule {
                HStack(spacing: 6) {
                    if isError {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.3))
                    }
                    Text(text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(height: 32)
            .fixedSize(horizontal: true, vertical: false)
            .onTapGesture { model.onMessageTap?() }
            .pillDragHandle(model)
            .reportPillFrame()
        }
    }

    /// - Parameter inset: Innenabstand links/rechts – kleiner, wenn außen Knöpfe sitzen.
    private func capsule<Content: View>(inset: CGFloat = 14, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Rahmen und Hintergrund dürfen Klicks auf Knöpfe und Anfasser darin nicht abfangen.
            .background(Capsule().fill(Color.black.opacity(0.88)).allowsHitTesting(false))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

private struct Waveform: View {
    let levels: [Float]
    var bars: Int = FlowBarModel.barCount

    private var shown: [Float] { Array(levels.suffix(bars)) }

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(shown.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 2.5, height: height(for: index))
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.08), value: levels)
    }

    private func height(for index: Int) -> CGFloat {
        // Mitte etwas höher gewichten – wirkt wie eine Stimme statt eines Balkendiagramms.
        let values = shown
        let center = Double(values.count - 1) / 2
        let distance = center > 0 ? abs(Double(index) - center) / center : 0
        let weight = 1 - distance * 0.45
        return max(3, CGFloat(values[index]) * 20 * CGFloat(weight))
    }
}

private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = sin((t * 5) - Double(i) * 0.7)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * max(0, phase))
                        .offset(y: -2.5 * max(0, phase))
                }
            }
        }
    }
}

/// Pulsierender roter Punkt – „es wird aufgenommen".
private struct RecordingDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2.4))
            Circle()
                .fill(Color(red: 0.95, green: 0.27, blue: 0.27))
                .frame(width: 8, height: 8)
                .opacity(pulse)
        }
    }
}

/// Runder Knopf in der Kapsel. Bewusst kein SwiftUI-`Button`: Das Panel wird nie Key-Fenster, und
/// Buttons schlucken dort den „ersten Klick" zum Aktivieren – eine Tap-Geste reagiert sofort.
private struct CircleButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(tint))
            .overlay(Circle().fill(Color.white.opacity(hovering ? 0.18 : 0)))
            .contentShape(Circle().inset(by: -4))
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(help)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(help)
    }
}

/// Verwaltet Panel + Modell, blendet Hinweise nach kurzer Zeit wieder aus und sorgt dafür,
/// dass das unsichtbare Panel nur dort Klicks schluckt, wo wirklich die Kapsel ist.
public final class FlowBarController {
    public let model = FlowBarModel()
    lazy var panel = FlowBarPanel(model: model)   // intern für Tests
    private var messageTimer: Timer?
    private var messageTap: (() -> Void)?
    private var monitors: [Any] = []
    let drag = PillDragTracker()
    /// Rahmen der Kapsel in der Leisten-View (Ursprung oben links).
    private var pillFrame: CGRect = .zero
    /// Nimmt der aktuelle Zustand überhaupt Klicks an (Ruhepunkt, Freihand, Meeting, Hinweis)?
    private var interactive = false

    public var showIdle = true { didSet { if isResting { setIdle() } } }
    /// Vom Nutzer verschobene Lage; nil = unten mittig.
    public var position: FlowBarPosition? {
        didSet { if position != oldValue { panel.reposition(position) } }
    }
    public var onPositionChange: ((FlowBarPosition?) -> Void)?
    /// Name der Meeting-App, solange ein Meeting mitgeschrieben wird – ersetzt im Ruhezustand den Punkt.
    public var meetingLabel: String? { didSet { if isResting { setIdle() } } }
    public var meetingFinishing = false { didSet { if isResting { setIdle() } } }

    public init() {
        model.drag = drag
        model.onPillFrameChange = { [weak self] frame in
            self?.pillFrame = frame
            self?.updateMouseTransparency()
        }
        model.onMessageTap = { [weak self] in self?.messageTap?() }
        drag.windowOrigin = { [weak self] in self?.panel.frame.origin ?? .zero }
        drag.moveWindow = { [weak self] origin in self?.panel.setFrameOrigin(origin) }
        drag.didEndDrag = { [weak self] in self?.storePosition() }
        installMouseMonitors()
    }

    deinit {
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    private var isResting: Bool {
        switch model.mode {
        case .idle, .hidden, .meeting, .meetingFinishing: return true
        default: return false
        }
    }

    public func show() {
        panel.reposition(position)
        panel.orderFrontRegardless()
        updateMouseTransparency()
    }

    public func setIdle() {
        messageTimer?.invalidate()
        messageTap = nil
        model.resetLevels()
        if meetingFinishing {
            model.mode = .meetingFinishing
            interactive = true
        } else if let meetingLabel {
            model.mode = .meeting(meetingLabel)
            interactive = true
        } else {
            model.mode = showIdle ? .idle : .hidden
            interactive = showIdle
        }
        updateMouseTransparency()
    }

    public func setRecording(handsFree: Bool) {
        messageTimer?.invalidate()
        panel.reposition(position)
        panel.orderFrontRegardless()
        interactive = handsFree
        model.mode = handsFree ? .handsFree : .recording
        updateMouseTransparency()
    }

    public func setTranscribing() {
        interactive = false
        model.mode = .transcribing
        updateMouseTransparency()
    }

    /// - Parameter onTap: Klick auf den Hinweis (z. B. Einstellungen öffnen).
    public func showMessage(_ text: String, isError: Bool = false, duration: TimeInterval = 2.4, onTap: (() -> Void)? = nil) {
        messageTimer?.invalidate()
        messageTap = onTap
        panel.reposition(position)
        panel.orderFrontRegardless()
        interactive = true
        model.mode = .message(text, isError: isError)
        updateMouseTransparency()
        messageTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.setIdle()
        }
    }

    // MARK: - Maus-Durchlässigkeit

    /// Das Panel ist 360 × 64 Punkte groß, die Kapsel viel kleiner. Ein Fenster mit Core-Animation-Inhalt
    /// schluckt aber Klicks auf seiner ganzen Fläche – auch auf durchsichtigen Stellen. Deshalb wird
    /// `ignoresMouseEvents` je nach Mausposition umgeschaltet: nur über der Kapsel nimmt das Panel Events an.
    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.updateMouseTransparency()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.updateMouseTransparency()
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Zuletzt gemeldeter Kapselrahmen in View-Koordinaten (Ursprung oben links) – für Tests.
    var pillFrameForTests: CGRect { pillFrame }

    /// Kapselrahmen in Bildschirmkoordinaten, etwas großzügiger als die Kapsel selbst.
    func hitRegionOnScreen() -> NSRect {
        guard interactive, pillFrame != .zero, let host = panel.contentView else { return .zero }
        let inWindow = host.convert(pillFrame.insetBy(dx: -12, dy: -12), to: nil)
        return panel.convertToScreen(inWindow)
    }

    private func updateMouseTransparency() {
        let mouse = NSEvent.mouseLocation
        let region = hitRegionOnScreen()
        let accept = interactive && (drag.isDragging || region.contains(mouse))
        if panel.ignoresMouseEvents != !accept {
            panel.ignoresMouseEvents = !accept
            flowBarLog.debug("Kapsel nimmt Klicks an: \(accept) – Maus \(mouse.x, format: .fixed(precision: 0)),\(mouse.y, format: .fixed(precision: 0)) Region \(region.minX, format: .fixed(precision: 0))…\(region.maxX, format: .fixed(precision: 0)) × \(region.minY, format: .fixed(precision: 0))…\(region.maxY, format: .fixed(precision: 0))")
        }
    }

    // MARK: - Verschieben

    private func storePosition() {
        guard let screen = panel.currentScreen ?? NSScreen.main else { return }
        var stored = FlowBarPanel.position(forOrigin: panel.frame.origin, in: screen.visibleFrame)
        stored?.displayID = screen.displayID
        position = stored
        panel.reposition(stored)   // einrasten bzw. in den sichtbaren Bereich holen
        onPositionChange?(stored)
    }
}

extension NSScreen {
    /// CGDirectDisplayID – bleibt für einen Monitor über Neustarts stabil.
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
