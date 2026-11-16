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
/// Software-Tipp: Kommen Drücken und Loslassen im selben Augenblick (Logi Options+ postet für
/// „Diktat" nur ein sofortiges keyDown/keyUp), kann niemand halten – dann schaltet jeder Tipp den
/// Dauer-Modus um: einmal an, nochmal aus.
///
/// Die Diktiertaste ist entweder ein Modifier (Fn, rechte ⌘ … – kommt als flagsChanged) oder eine
/// normale Taste (F5, F18, Ziffernblock … – kommt als keyDown/keyUp, beim Halten mit Autorepeat),
/// siehe `HotkeyOption.Kind`. Eine normale Diktiertaste wird immer geschluckt, damit sie nicht
/// nebenbei in der fokussierten App tippt – und bei F5, damit macOS-Diktat (Mikrofontaste tippen)
/// und Siri (Mikrofontaste halten) sie nie zu sehen bekommen.
///
/// Der Tap ist aktiv (nicht nur lauschend), damit Esc/Leertaste während der Aufnahme
/// nicht in der fokussierten App landen. Das setzt die Bedienungshilfen-Berechtigung voraus.
public final class HotkeyMonitor {
    public var onEvent: ((HotkeyEvent) -> Void)?
    public var hotkey: HotkeyOption = .fn
    public var handsFreeEnabled = true
    /// Keycode der Taste, die im aktuellen Layout „v" schreibt.
    public var pasteKeyCode: Int64 = 9
    /// Solange eine neue Diktiertaste aufgenommen wird, reicht der Tap alles unverändert durch –
    /// sonst würde die bisherige Taste beim Aufnehmen ein Diktat starten.
    public var isSuspended = false

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
    /// Noch kürzer schafft kein Finger: Drücken und Loslassen kamen aus Software (Logi Options+
    /// braucht unter 1 ms) – so ein Tipp schaltet den Dauer-Modus ein statt zu verwerfen.
    private let instantTap: CFTimeInterval = 0.02

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
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard !isSuspended else { return false }
        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
            return false
        case .keyDown:
            return handleKeyDown(event)
        case .keyUp:
            return handleKeyUp(event)
        default:
            return false
        }
    }

    private func isHotkey(_ keyCode: Int64, kind: HotkeyOption.Kind) -> Bool {
        hotkey.matches(keyCode: keyCode, kind: kind)
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard isHotkey(keyCode, kind: .modifier) else {
            // Anderer Modifier während des Haltens (z. B. Fn+⌘ …) → kein Diktat.
            if case .holding = state {
                state = .awaitingRelease
                emit(.cancel)
            }
            return
        }
        hotkeyChanged(isDown: hotkey.isDown(in: event.flags))
    }

    /// Die Diktiertaste wurde gedrückt oder losgelassen – egal ob Modifier oder normale Taste.
    private func hotkeyChanged(isDown: Bool) {
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
            let held = now - since
            if held < instantTap && handsFreeEnabled {
                state = .handsFree
                emit(.lockHandsFree)
            } else if held < minimumHold {
                state = .idle
                lastShortTap = now
                emit(.cancel)
            } else {
                state = .idle
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

        if isHotkey(keyCode, kind: .key) {
            // Autorepeat beim Halten ist kein neuer Druck; die Taste selbst landet nie in der App.
            if !isRepeat { hotkeyChanged(isDown: true) }
            return true
        }

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

    private func handleKeyUp(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if isHotkey(keyCode, kind: .key) {
            swallowedKeyDowns.remove(keyCode)
            hotkeyChanged(isDown: false)
            return true
        }
        return swallowedKeyDowns.remove(keyCode) != nil
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
    /// Geräteabhängige Masken (IOLLEvent.h), damit links/rechts unterscheidbar bleibt.
    public static func modifierMask(forKeyCode keyCode: Int64) -> CGEventFlags? {
        switch keyCode {
        case 63: return .maskSecondaryFn
        case 54: return CGEventFlags(rawValue: 0x10)   // rechte ⌘
        case 55: return CGEventFlags(rawValue: 0x08)   // linke ⌘
        case 56: return CGEventFlags(rawValue: 0x02)   // linke ⇧
        case 60: return CGEventFlags(rawValue: 0x04)   // rechte ⇧
        case 58: return CGEventFlags(rawValue: 0x20)   // linke ⌥
        case 61: return CGEventFlags(rawValue: 0x40)   // rechte ⌥
        case 59: return CGEventFlags(rawValue: 0x01)   // linke ⌃
        case 62: return CGEventFlags(rawValue: 0x2000) // rechte ⌃
        default: return nil
        }
    }

    /// Ist diese Modifier-Taste laut den Flags eines flagsChanged-Events gerade unten?
    func isDown(in flags: CGEventFlags) -> Bool {
        guard kind == .modifier, let mask = Self.modifierMask(forKeyCode: keyCode) else { return false }
        return flags.rawValue & mask.rawValue != 0
    }
}
