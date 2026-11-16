import XCTest
import CoreGraphics
@testable import RedeflussKit

/// Prüft das Wispr-Verhalten der Diktiertaste mit synthetischen Tastatur-Events:
/// halten = aufnehmen, loslassen = einfügen, Doppeltipp = Dauer-Modus bis zum nächsten Druck.
final class HotkeyMonitorTests: XCTestCase {
    private var monitor: HotkeyMonitor!
    private var events: [HotkeyEvent] = []
    private var clock: CFAbsoluteTime = 1000

    override func setUp() {
        monitor = HotkeyMonitor()
        monitor.hotkey = .fn
        monitor.now = { [unowned self] in self.clock }
        monitor.onEvent = { [unowned self] in self.events.append($0) }
        events = []
    }

    // MARK: - Push-to-talk

    func testHoldAndReleaseRecordsAndStops() {
        fn(down: true)
        XCTAssertEqual(events, [.start])
        advance(1.5)
        fn(down: false)
        XCTAssertEqual(events, [.start, .stop])
    }

    func testAccidentalShortTapIsDiscarded() {
        fn(down: true)
        advance(0.1)
        fn(down: false)
        XCTAssertEqual(events, [.start, .cancel])
    }

    // MARK: - Doppeltipp → Dauer-Modus

    func testDoubleTapStartsHandsFreeUntilNextPress() {
        fn(down: true); advance(0.08); fn(down: false)        // 1. Tipp
        advance(0.15)
        fn(down: true); advance(0.08); fn(down: false)        // 2. Tipp
        XCTAssertEqual(events, [.start, .cancel, .start, .lockHandsFree])

        advance(20)                                            // freihändig sprechen
        XCTAssertEqual(events.count, 4, "Loslassen darf im Dauer-Modus nichts beenden")

        fn(down: true)                                         // einmal drücken → fertig
        XCTAssertEqual(events.last, .stop)
        advance(0.1)
        fn(down: false)
        XCTAssertEqual(events.count, 5)

        // Danach ist wieder normales Halten möglich.
        advance(1)
        fn(down: true); advance(1); fn(down: false)
        XCTAssertEqual(Array(events.suffix(2)), [.start, .stop])
    }

    func testTwoTapsTooFarApartAreNotADoubleTap() {
        fn(down: true); advance(0.08); fn(down: false)
        advance(0.8)
        fn(down: true)
        XCTAssertEqual(events, [.start, .cancel, .start])
        advance(1); fn(down: false)
        XCTAssertEqual(events.last, .stop)
    }

    func testDoubleTapDisabledWhenHandsFreeOff() {
        monitor.handsFreeEnabled = false
        fn(down: true); advance(0.08); fn(down: false)
        advance(0.15)
        fn(down: true); advance(1); fn(down: false)
        XCTAssertEqual(events, [.start, .cancel, .start, .stop])
    }

    // MARK: - Fn + Leertaste, Esc, Kombinationen

    func testFnSpaceLocksHandsFreeAndSwallowsSpace() {
        fn(down: true)
        XCTAssertTrue(key(49, down: true), "Leertaste darf nicht in der App landen")
        XCTAssertTrue(key(49, down: false))
        fn(down: false)
        XCTAssertEqual(events, [.start, .lockHandsFree])
    }

    func testEscapeCancelsWhileHolding() {
        fn(down: true)
        XCTAssertTrue(key(53, down: true))
        XCTAssertTrue(key(53, down: false))
        advance(1)
        fn(down: false)
        XCTAssertEqual(events, [.start, .cancel])
    }

    func testEscapeCancelsHandsFree() {
        doubleTap()
        advance(3)
        XCTAssertTrue(key(53, down: true))
        XCTAssertEqual(events.last, .cancel)
    }

    func testFnArrowIsPassedThroughAndCancels() {
        fn(down: true)
        XCTAssertFalse(key(123, down: true), "Fn+Pfeil muss als Pos1 bei der App ankommen")
        XCTAssertEqual(events, [.start, .cancel])
        fn(down: false)
        XCTAssertEqual(events.count, 2)
    }

    func testNormalTypingIsNeverSwallowed() {
        XCTAssertFalse(key(0, down: true))
        XCTAssertFalse(key(0, down: false))
        XCTAssertFalse(key(49, down: true))
        XCTAssertTrue(events.isEmpty)
    }

    func testPasteLastShortcut() {
        XCTAssertTrue(key(9, down: true, flags: [.maskCommand, .maskControl]))
        XCTAssertEqual(events, [.pasteLast])
        XCTAssertFalse(key(9, down: true, flags: [.maskCommand]), "Normales ⌘V bleibt unberührt")
    }

    func testRightOptionAsAlternativeHotkey() {
        monitor.hotkey = .rightOption
        send(flagsChanged: 61, flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40))
        advance(1)
        send(flagsChanged: 61, flags: [])
        XCTAssertEqual(events, [.start, .stop])
        // Linke Option (Keycode 58) löst nichts aus.
        send(flagsChanged: 58, flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20))
        XCTAssertEqual(events.count, 2)
    }

    // MARK: - Eigene Taste: normale Taste statt Modifier (z. B. F18 auf einer Fremdtastatur)

    private let f18 = HotkeyOption(kind: .key, keyCode: 79, name: "F18")

    func testCustomKeyHoldAndReleaseIsSwallowedIncludingAutorepeat() {
        monitor.hotkey = f18
        XCTAssertTrue(key(79, down: true), "Die Diktiertaste selbst darf nie in der App landen")
        XCTAssertTrue(key(79, down: true, autorepeat: true), "Autorepeat beim Halten wird geschluckt")
        XCTAssertTrue(key(79, down: true, autorepeat: true))
        advance(1)
        XCTAssertTrue(key(79, down: false))
        XCTAssertEqual(events, [.start, .stop], "Autorepeat darf kein zweites Diktat starten")
    }

    func testCustomKeyShortTapAndDoubleTap() {
        monitor.hotkey = f18
        key(79, down: true); advance(0.08); key(79, down: false)
        XCTAssertEqual(events, [.start, .cancel])
        advance(0.15)
        key(79, down: true); advance(0.08); key(79, down: false)
        XCTAssertEqual(events, [.start, .cancel, .start, .lockHandsFree])

        advance(5)
        XCTAssertTrue(key(79, down: true))                     // einmal drücken → fertig
        XCTAssertEqual(events.last, .stop)
        XCTAssertTrue(key(79, down: true, autorepeat: true))
        XCTAssertTrue(key(79, down: false))
        XCTAssertEqual(events.count, 5)
    }

    func testCustomKeyWithSpaceLocksHandsFreeAndEscapeCancels() {
        monitor.hotkey = f18
        key(79, down: true)
        XCTAssertTrue(key(49, down: true))
        XCTAssertTrue(key(49, down: false))
        key(79, down: false)
        XCTAssertEqual(events, [.start, .lockHandsFree])
        XCTAssertTrue(key(53, down: true))
        XCTAssertEqual(events.last, .cancel)
    }

    func testCustomKeyPlusOtherKeyIsPassedThroughAndCancels() {
        monitor.hotkey = f18
        key(79, down: true)
        XCTAssertFalse(key(0, down: true), "F18+A muss als A bei der App ankommen")
        XCTAssertEqual(events, [.start, .cancel])
        XCTAssertTrue(key(79, down: false), "Loslassen der Diktiertaste bleibt geschluckt")
        XCTAssertEqual(events.count, 2)
    }

    func testCustomKeyIgnoresFnAndFnIgnoresCustomKey() {
        monitor.hotkey = f18
        fn(down: true); advance(1); fn(down: false)
        XCTAssertTrue(events.isEmpty)

        monitor.hotkey = .fn
        XCTAssertFalse(key(79, down: true))
        XCTAssertFalse(key(79, down: false))
        XCTAssertTrue(events.isEmpty)
    }

    func testF5PresetTakesMicrophoneKeyAndPlainF5ButNotF13() {
        monitor.hotkey = .f5
        // Apple-Tastatur ohne Fn: Mikrofontaste, Keycode 176, haltbar mit Autorepeat.
        XCTAssertTrue(key(176, down: true), "Geschluckt – sonst startet macOS-Diktat bzw. beim Halten Siri")
        XCTAssertTrue(key(176, down: true, autorepeat: true))
        advance(1)
        XCTAssertTrue(key(176, down: false))
        XCTAssertEqual(events, [.start, .stop])

        // Fn+F5 oder Fremdtastatur: normales F5.
        events = []
        XCTAssertTrue(key(96, down: true))
        advance(1)
        XCTAssertTrue(key(96, down: false))
        XCTAssertEqual(events, [.start, .stop])

        // F13 bleibt eine fremde Taste.
        events = []
        XCTAssertFalse(key(105, down: true))
        XCTAssertFalse(key(105, down: false))
        XCTAssertTrue(events.isEmpty)
    }

    func testInstantMicrophoneTapsFromLogiOptionsToggleHandsFree() {
        monitor.hotkey = .f5
        // Logi Options+ schickt für „Diktat“ nur ein sofortiges keyDown/keyUp – Halten ist damit
        // unmöglich, also schaltet ein Tipp den Dauer-Modus ein …
        XCTAssertTrue(key(176, down: true)); XCTAssertTrue(key(176, down: false))
        XCTAssertEqual(events, [.start, .lockHandsFree])
        advance(5)
        // … und der nächste Tipp wieder aus.
        key(176, down: true); key(176, down: false)
        XCTAssertEqual(events, [.start, .lockHandsFree, .stop])
        // Danach ist normales Halten (Fn+F5 bzw. Tastenkombination F5 aus Options+) wieder möglich.
        advance(1)
        key(96, down: true); advance(1); key(96, down: false)
        XCTAssertEqual(Array(events.suffix(2)), [.start, .stop])
    }

    func testInstantTapWithoutHandsFreeIsDiscarded() {
        monitor.hotkey = .f5
        monitor.handsFreeEnabled = false
        key(176, down: true); key(176, down: false)
        XCTAssertEqual(events, [.start, .cancel])
    }

    func testHumanShortTapOnTheMicrophoneKeyStillCancels() {
        monitor.hotkey = .f5
        // Ein echter Tipp auf der Mac-Tastatur dauert immer deutlich länger als ein Software-Tipp.
        key(176, down: true); advance(0.04); key(176, down: false)
        XCTAssertEqual(events, [.start, .cancel])
        advance(0.15)
        key(176, down: true); advance(0.04); key(176, down: false)
        XCTAssertEqual(events, [.start, .cancel, .start, .lockHandsFree], "Doppeltipp bleibt der Weg in den Dauer-Modus")
    }

    func testAnyModifierCanBeTheHotkey() {
        monitor.hotkey = HotkeyOption(kind: .modifier, keyCode: 56, name: "Linke ⇧")
        send(flagsChanged: 56, flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x02))
        advance(1)
        send(flagsChanged: 56, flags: [])
        XCTAssertEqual(events, [.start, .stop])
        // Rechte Shift (Keycode 60) löst nichts aus.
        send(flagsChanged: 60, flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x04))
        XCTAssertEqual(events.count, 2)
    }

    func testSuspendedMonitorPassesEverythingThrough() {
        monitor.isSuspended = true
        fn(down: true); advance(1); fn(down: false)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(key(9, down: true, flags: [.maskCommand, .maskControl]), "Auch ⌃⌘V bleibt unberührt")
        XCTAssertFalse(key(53, down: true))

        monitor.isSuspended = false
        fn(down: true); advance(1); fn(down: false)
        XCTAssertEqual(events, [.start, .stop])
    }

    // MARK: - Helfer

    private func doubleTap() {
        fn(down: true); advance(0.08); fn(down: false)
        advance(0.15)
        fn(down: true); advance(0.08); fn(down: false)
    }

    private func advance(_ seconds: CFTimeInterval) { clock += seconds }

    private func fn(down: Bool) {
        send(flagsChanged: 63, flags: down ? .maskSecondaryFn : [])
    }

    private func send(flagsChanged keyCode: CGKeyCode, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.type = .flagsChanged
        event.flags = flags
        _ = monitor.handle(type: .flagsChanged, event: event)
    }

    @discardableResult
    private func key(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags = [], autorepeat: Bool = false) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
        event.flags = flags
        if autorepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return monitor.handle(type: down ? .keyDown : .keyUp, event: event)
    }
}

extension HotkeyEvent: Equatable {}
