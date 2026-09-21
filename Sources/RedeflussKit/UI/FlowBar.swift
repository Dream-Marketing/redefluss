import AppKit
import SwiftUI
import Combine

/// Zustand der schwebenden Leiste unten am Bildschirm.
public final class FlowBarModel: ObservableObject {
    public enum Mode: Equatable {
        case hidden
        case idle
        case recording
        case handsFree
        case transcribing
        case message(String, isError: Bool)
    }

    @Published public var mode: Mode = .idle
    @Published public var levels: [Float] = Array(repeating: 0, count: FlowBarModel.barCount)
    @Published public var hotkeyLabel = "Fn"

    public static let barCount = 14

    var onStartHandsFree: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMessageTap: (() -> Void)?

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

/// Randloses, nicht aktivierendes Panel: nimmt nie den Fokus, damit das Einfügen
/// in der App landet, in der der Nutzer gerade schreibt.
final class FlowBarPanel: NSPanel {
    static let size = NSSize(width: 360, height: 64)

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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: FlowBarView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Unten mittig auf dem Bildschirm, auf dem gerade die Maus ist – über dem Dock.
    func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 6)
        setFrameOrigin(origin)
    }
}

struct FlowBarView: View {
    @ObservedObject var model: FlowBarModel
    @State private var hovering = false

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            pill
                .padding(.bottom, 6)
        }
        .frame(width: FlowBarPanel.size.width, height: FlowBarPanel.size.height)
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
                .help("Diktat starten")

        case .recording:
            capsule {
                Waveform(levels: model.levels)
            }
            .frame(width: 104, height: 32)

        case .handsFree:
            capsule {
                HStack(spacing: 8) {
                    CircleButton(symbol: "xmark", tint: .white.opacity(0.18), help: "Verwerfen (Esc)") { model.onCancel?() }
                    Waveform(levels: model.levels)
                    CircleButton(symbol: "stop.fill", tint: Color(red: 0.95, green: 0.27, blue: 0.27), help: "Fertig (\(model.hotkeyLabel))") { model.onStop?() }
                }
                .padding(.horizontal, -8)
            }
            .frame(width: 150, height: 32)

        case .transcribing:
            capsule {
                ThinkingDots()
            }
            .frame(width: 64, height: 32)

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
        }
    }

    private func capsule<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(Color.black.opacity(0.88)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { index in
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
        let center = Double(levels.count - 1) / 2
        let distance = abs(Double(index) - center) / center
        let weight = 1 - distance * 0.45
        return max(3, CGFloat(levels[index]) * 20 * CGFloat(weight))
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

private struct CircleButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(tint))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Verwaltet Panel + Modell und blendet Hinweise nach kurzer Zeit wieder aus.
public final class FlowBarController {
    public let model = FlowBarModel()
    private lazy var panel = FlowBarPanel(model: model)
    private var messageTimer: Timer?
    public var showIdle = true { didSet { if model.mode == .idle || model.mode == .hidden { setIdle() } } }

    public init() {}

    public func show() {
        panel.reposition()
        panel.orderFrontRegardless()
    }

    public func setIdle() {
        messageTimer?.invalidate()
        model.resetLevels()
        model.mode = showIdle ? .idle : .hidden
        panel.ignoresMouseEvents = !showIdle
    }

    public func setRecording(handsFree: Bool) {
        messageTimer?.invalidate()
        panel.reposition()
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = !handsFree
        model.mode = handsFree ? .handsFree : .recording
    }

    public func setTranscribing() {
        panel.ignoresMouseEvents = true
        model.mode = .transcribing
    }

    public func showMessage(_ text: String, isError: Bool = false, duration: TimeInterval = 2.4) {
        messageTimer?.invalidate()
        panel.reposition()
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = false
        model.mode = .message(text, isError: isError)
        messageTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.setIdle()
        }
    }
}
