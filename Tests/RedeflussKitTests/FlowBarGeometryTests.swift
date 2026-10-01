import XCTest
@testable import RedeflussKit

/// Die Leiste darf nur dort Klicks schlucken, wo die Kapsel ist, und muss sich verschieben lassen –
/// mit einer gespeicherten Position, die auf jedem Bildschirm sinnvoll bleibt.
final class FlowBarGeometryTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let externalScreen = NSRect(x: 1440, y: 100, width: 2560, height: 1415)

    func testDefaultIsBottomCenterAboveDock() {
        let origin = FlowBarPanel.origin(for: nil, in: screen)
        XCTAssertEqual(origin.x + FlowBarPanel.size.width / 2, screen.midX)
        XCTAssertEqual(origin.y, screen.minY + FlowBarPanel.pillBottomPadding)
    }

    func testPositionNearDefaultSnapsBack() {
        let standard = FlowBarPanel.origin(for: nil, in: screen)
        let nudged = NSPoint(x: standard.x + 10, y: standard.y + 15)
        XCTAssertNil(FlowBarPanel.position(forOrigin: nudged, in: screen))
    }

    func testPositionRoundTripsOnSameScreen() throws {
        let dropped = NSPoint(x: 100, y: 600)
        let stored = try XCTUnwrap(FlowBarPanel.position(forOrigin: dropped, in: screen))
        let restored = FlowBarPanel.origin(for: stored, in: screen)
        XCTAssertEqual(restored.x, dropped.x, accuracy: 0.5)
        XCTAssertEqual(restored.y, dropped.y, accuracy: 0.5)
    }

    func testStoredPositionIsRelativeToScreen() throws {
        // Rechte obere Ecke des Laptops → auch auf dem großen Monitor rechts oben.
        let topRight = FlowBarPanel.clamp(NSPoint(x: 5000, y: 5000), in: screen)
        let stored = try XCTUnwrap(FlowBarPanel.position(forOrigin: topRight, in: screen))
        XCTAssertGreaterThan(stored.x, 0.8)
        XCTAssertGreaterThan(stored.y, 0.9)
        let onExternal = FlowBarPanel.origin(for: stored, in: externalScreen)
        XCTAssertGreaterThan(onExternal.x, externalScreen.midX)
        XCTAssertGreaterThan(onExternal.y, externalScreen.midY)
        XCTAssertTrue(externalScreen.contains(pillRect(forOrigin: onExternal)), "Kapsel muss auf dem Bildschirm bleiben")
    }

    func testClampKeepsPillOnScreenButLetsItReachTheEdge() {
        let farLeft = FlowBarPanel.clamp(NSPoint(x: -1000, y: -1000), in: screen)
        let pill = pillRect(forOrigin: farLeft)
        XCTAssertEqual(pill.minX, screen.minX, accuracy: 0.5, "Kapsel darf bis an den Rand – das unsichtbare Panel ragt darüber hinaus")
        XCTAssertEqual(farLeft.y, screen.minY)

        let farUp = FlowBarPanel.clamp(NSPoint(x: 0, y: 5000), in: screen)
        XCTAssertEqual(pillRect(forOrigin: farUp).maxY, screen.maxY, accuracy: 0.5)
    }

    // MARK: - Klick oder Ziehen

    func testTinyMovementDoesNotMoveTheBar() {
        let tracker = PillDragTracker()
        var mouse = CGPoint(x: 700, y: 20)
        tracker.mouseLocation = { mouse }
        tracker.windowOrigin = { CGPoint(x: 540, y: 6) }
        var moves: [CGPoint] = []
        tracker.moveWindow = { moves.append($0) }
        var dragEnded = false
        tracker.didEndDrag = { dragEnded = true }

        tracker.changed()
        mouse.x += 1
        tracker.changed()
        tracker.ended()

        XCTAssertFalse(dragEnded)
        XCTAssertTrue(moves.isEmpty, "Ein Wackler von einem Punkt darf die Leiste nicht verschieben")
    }

    func testDragMovesWindowBySameDeltaAsMouse() {
        let tracker = PillDragTracker()
        var mouse = CGPoint(x: 700, y: 20)
        tracker.mouseLocation = { mouse }
        tracker.windowOrigin = { CGPoint(x: 540, y: 6) }
        var moves: [CGPoint] = []
        tracker.moveWindow = { moves.append($0) }
        var dragEnded = false
        tracker.didEndDrag = { dragEnded = true }

        tracker.changed()                      // Druck
        mouse = CGPoint(x: 730, y: 220)        // weit ziehen
        tracker.changed()
        mouse = CGPoint(x: 740, y: 230)
        tracker.changed()
        XCTAssertTrue(tracker.isDragging)
        tracker.ended()

        XCTAssertEqual(moves, [CGPoint(x: 570, y: 206), CGPoint(x: 580, y: 216)])
        XCTAssertTrue(dragEnded)
        XCTAssertFalse(tracker.isDragging)
    }

    func testAlreadyMovedDistanceIsAppliedImmediately() {
        // SwiftUI meldet die Geste erst nach 4 pt Weg – diesen Weg soll die Leiste sofort nachholen.
        let tracker = PillDragTracker()
        tracker.mouseLocation = { CGPoint(x: 705, y: 24) }
        tracker.windowOrigin = { CGPoint(x: 540, y: 6) }
        var moves: [CGPoint] = []
        tracker.moveWindow = { moves.append($0) }

        tracker.changed(alreadyMoved: CGSize(width: 5, height: 4))
        XCTAssertEqual(moves, [CGPoint(x: 545, y: 10)])
        XCTAssertTrue(tracker.isDragging)
    }

    private func pillRect(forOrigin origin: NSPoint) -> NSRect {
        NSRect(
            x: origin.x + FlowBarPanel.size.width / 2 - FlowBarPanel.pillBox.width / 2,
            y: origin.y + FlowBarPanel.pillBottomPadding,
            width: FlowBarPanel.pillBox.width,
            height: FlowBarPanel.pillBox.height
        )
    }
}
