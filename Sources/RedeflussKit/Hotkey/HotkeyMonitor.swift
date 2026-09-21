import Cocoa
import CoreGraphics

/// Was der Nutzer mit der Diktiertaste gerade getan hat.
public enum HotkeyEvent {
    /// Taste gedrückt → Aufnahme starten.
    case start
    /// Taste losgelassen (Push-to-talk) bzw. erneut gedrückt (Freihand) → transkribieren.
    case stop
    /// Esc, zu kurzer Tipper oder Tastenkombination (z. B. Fn+Pfeil) → verwerfen.
    case cancel
    /// Taste + Leertaste oder Doppeltipp → Aufnahme läuft ohne Halten weiter.
    case lockHandsFree
    /// ⌃⌘V → letztes Diktat erneut einfügen.
    case pasteLast
}

/// Globale Erkennung der Diktiertaste über einen CGEventTap.
///
/// Push-to-talk: Taste halten, sprechen, loslassen.
/// Freihand: Taste + Leertaste oder Doppeltipp; beenden mit erneutem Druck, Esc verwirft.
///
/// Der Tap ist aktiv (nicht nur lauschend), damit Esc/Leertaste während der Aufnahme
/// nicht in der fokussierten App landen. Das setzt die Bedienungshilfen-Berechtigung voraus.
public final class HotkeyMonitor {
    public var onEvent: ((HotkeyEvent) -> Void)?
    public var hotkey: HotkeyOption = .fn
    public var handsFreeEnabled = true
    /// Keycode der Taste, die im aktuellen Layout „v" schreibt.
    public var pasteKeyCode: Int64 = 9

    private enum State {
        case idle
        case holding(since: CFAbsoluteTime)
        case handsFree
        /// Aufnahme ist beendet/verworfen, die Taste ist aber noch unten.
        case awaitingRelease
    }

    private var state: State = .idle
    /// Uhr – in Tests austauschbar.
    var now: () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowedKeyDowns: Set<Int64> = []
    private var lastShortTap: CFAbsoluteTime = 0

    /// Kürzere Tipper gelten als Versehen (oder als erster Teil eines Doppeltipps).
    private let minimumHold: CFTimeInterval = 0.25
    private let doubleTapWindow: CFTimeInterval = 0.4

    private static let keyCodeSpace: Int64 = 49
    private static let keyCodeEscape: Int64 = 53

    public init() {}

    public var isRunning: Bool { tap != nil }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        state = .idle
    }

    /// Von außen zurücksetzen, z. B. wenn die Aufnahme nicht starten konnte
    /// oder per Klick auf die Leiste beendet wurde.
    public func reset() {
        switch state {
        case .holding: state = .awaitingRelease
        case .handsFree: state = .idle
        default: break
        }
    }

    /// Freihand von außen starten (Klick auf die Leiste).
    public func enterHandsFree() {
        state = .handsFree
    }

    // MARK: - Event-Verarbeitung

    /// Gibt `true` zurück, wenn das Event geschluckt werden soll.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .flagsChanged:
            handleFlagsChanged(event)
            return false
        case .keyDown:
            return handleKeyDown(event)
        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            return swallowedKeyDowns.remove(keyCode) != nil
        default:
            return false
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == hotkey.keyCode else {
            // Anderer Modifier während des Haltens (z. B. Fn+⌘ …) → kein Diktat.
            if case .holding = state {
                state = .awaitingRelease
                emit(.cancel)
            }
            return
        }
        let isDown = hotkey.isDown(in: event.flags)
        let now = self.now()

        switch state {
        case .idle:
            guard isDown else { return }
            if handsFreeEnabled && now - lastShortTap < doubleTapWindow {
                lastShortTap = 0
                state = .handsFree
                emit(.start)
                emit(.lockHandsFree)
            } else {
                state = .holding(since: now)
                emit(.start)
            }
        case .holding(let since):
            guard !isDown else { return }
            state = .idle
            if now - since < minimumHold {
                lastShortTap = now
                emit(.cancel)
            } else {
                emit(.stop)
            }
        case .handsFree:
            if isDown {
                state = .awaitingRelease
                emit(.stop)
            }
        case .awaitingRelease:
            if !isDown { state = .idle }
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch state {
        case .idle:
            let flags = event.flags
            if keyCode == pasteKeyCode,
               flags.contains(.maskCommand), flags.contains(.maskControl),
               !flags.contains(.maskAlternate), !flags.contains(.maskShift) {
                if !isRepeat { emit(.pasteLast) }
                return swallow(keyCode)
            }
            return false

        case .holding:
            if keyCode == Self.keyCodeEscape {
                state = .awaitingRelease
                emit(.cancel)
                return swallow(keyCode)
            }
            if keyCode == Self.keyCodeSpace && handsFreeEnabled {
                state = .handsFree
                emit(.lockHandsFree)
                return swallow(keyCode)
            }
            // Normale Kombination wie Fn+Pfeil oder ⌥+Buchstabe: durchlassen, Diktat verwerfen.
            state = .awaitingRelease
            emit(.cancel)
            return false

        case .handsFree:
            if keyCode == Self.keyCodeEscape {
                state = .idle
                emit(.cancel)
                return swallow(keyCode)
            }
            // Leertaste, die nach dem Sperren noch gehalten wird, wiederholt sich.
            if keyCode == Self.keyCodeSpace && isRepeat {
                return swallow(keyCode)
            }
            return false

        case .awaitingRelease:
            // Fn+Leertaste zum Beenden des Freihand-Modus darf kein Leerzeichen tippen.
            if keyCode == Self.keyCodeSpace || keyCode == Self.keyCodeEscape {
                return swallow(keyCode)
            }
            return false
        }
    }

    private func swallow(_ keyCode: Int64) -> Bool {
        swallowedKeyDowns.insert(keyCode)
        return true
    }

    private func emit(_ event: HotkeyEvent) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { self.onEvent?(event) }
        }
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow = monitor.handle(type: type, event: event)
    return swallow ? nil : Unmanaged.passUnretained(event)
}

extension HotkeyOption {
    /// Virtueller Keycode, den das flagsChanged-Event für diese Taste trägt.
    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }

    /// Geräteabhängige Masken (IOLLEvent.h), damit links/rechts unterscheidbar bleibt.
    func isDown(in flags: CGEventFlags) -> Bool {
        switch self {
        case .fn: return flags.contains(.maskSecondaryFn)
        case .rightOption: return flags.rawValue & 0x40 != 0
        case .rightCommand: return flags.rawValue & 0x10 != 0
        case .rightControl: return flags.rawValue & 0x2000 != 0
        }
    }
}
