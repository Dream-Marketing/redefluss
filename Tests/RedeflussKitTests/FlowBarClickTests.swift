import XCTest
import AppKit
@testable import RedeflussKit

/// Schickt echte Maus-Events direkt an das Panel (ohne Cursor und Window-Server) und prüft,
/// dass Kapsel, Knöpfe und Anfasser sie bekommen. Das Panel wird nie Key-Fenster – genau das
/// hat SwiftUI-Buttons früher den Klick gekostet.
final class FlowBarClickTests: XCTestCase {
    private var controller: FlowBarController!
    private var panel: FlowBarPanel { controller.panel }

    override func setUp() {
        controller = FlowBarController()
        // Weit außerhalb jedes Bildschirms, damit beim Testen nichts aufblitzt.
        panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        panel.orderFrontRegardless()
        settle()
    }

    override func tearDown() {
        panel.orderOut(nil)
        controller = nil
    }

    func testClickOnIdlePillStartsHandsFree() {
        var started = 0
        controller.model.onStartHandsFree = { started += 1 }
        controller.setIdle()
        settle()
        click(at: NSPoint(x: 180, y: 10))   // Ruhe-Kapsel 38 × 8, unten mittig
        XCTAssertEqual(started, 1)
    }

    func testCancelAndStopButtonsInHandsFreeCapsule() {
        var cancelled = 0
        var stopped = 0
        controller.model.onCancel = { cancelled += 1 }
        controller.model.onStop = { stopped += 1 }
        controller.setRecording(handsFree: true)
        settle()
        // Kapsel 150 × 32 mittig unten: x 105…255, y 6…38. Knöpfe 22 pt, 6 pt vom Rand.
        click(at: NSPoint(x: 105 + 6 + 11, y: 22))
        XCTAssertEqual(cancelled, 1, "✕ muss die Aufnahme verwerfen")
        XCTAssertEqual(stopped, 0)
        click(at: NSPoint(x: 255 - 6 - 11, y: 22))
        XCTAssertEqual(stopped, 1, "■ muss die Aufnahme beenden")
    }

    func testStopButtonInMeetingCapsule() {
        var stopped = 0
        controller.model.onStopMeeting = { stopped += 1 }
        controller.meetingLabel = "Zoom"
        controller.model.meetingClock = "12:34"
        settle()
        let frame = controller.pillFrameForTests
        XCTAssertGreaterThan(frame.width, 100)
        // ■ ist das letzte Element, 6 pt vom rechten Rand (Koordinaten der View: Ursprung oben links).
        let x = frame.maxX - 6 - 11
        let y = FlowBarPanel.size.height - frame.midY
        click(at: NSPoint(x: x, y: y))
        XCTAssertEqual(stopped, 1)
    }

    func testDraggingTheWaveformMovesThePanel() {
        controller.setRecording(handsFree: true)
        settle()
        var mouse = NSPoint(x: -19_820, y: -19_978)
        controller.drag.mouseLocation = { mouse }
        let before = panel.frame.origin

        let start = NSPoint(x: 180, y: 22)   // Wellenform in der Mitte der Freihand-Kapsel
        send(.leftMouseDown, at: start)
        for step in 1...6 {
            mouse.y += 10
            send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y + CGFloat(step) * 10))
        }
        send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y + 60))
        settle()

        XCTAssertEqual(panel.frame.origin.y - before.y, 60, accuracy: 1)
        XCTAssertEqual(panel.frame.origin.x, before.x, accuracy: 1)
    }

    // MARK: - Helfer

    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func click(at point: NSPoint) {
        send(.leftMouseDown, at: point)
        send(.leftMouseUp, at: point)
        settle(0.3)
    }

    /// `point` in Fensterkoordinaten (Ursprung unten links).
    private func send(_ type: NSEvent.EventType, at point: NSPoint) {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        panel.sendEvent(event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
