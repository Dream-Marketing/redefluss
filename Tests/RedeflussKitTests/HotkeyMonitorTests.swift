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
    private func key(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags = []) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
        event.flags = flags
        return monitor.handle(type: down ? .keyDown : .keyUp, event: event)
    }
}

extension HotkeyEvent: Equatable {}
