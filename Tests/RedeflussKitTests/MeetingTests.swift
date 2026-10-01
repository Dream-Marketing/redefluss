import XCTest
@testable import RedeflussKit

final class MeetingDetectionLogicTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testShortMicrophoneUseIsIgnored() {
        var logic = MeetingDetectionLogic()
        XCTAssertNil(logic.observe(busy: true, at: t0))
        XCTAssertNil(logic.observe(busy: true, at: t0 + 0.5))
        XCTAssertNil(logic.observe(busy: false, at: t0 + 0.8))   // kurzer Soundtest
        XCTAssertFalse(logic.isMeeting)
    }

    func testDefaultsReactWithinSeconds() {
        var logic = MeetingDetectionLogic()
        XCTAssertNil(logic.observe(busy: true, at: t0))
        XCTAssertEqual(logic.pendingDeadline(now: t0 + 0.25)!, 0.75, accuracy: 0.001)
        XCTAssertEqual(logic.observe(busy: true, at: t0 + 1.05), .started)
        XCTAssertNil(logic.pendingDeadline(now: t0 + 1.05))
        XCTAssertNil(logic.observe(busy: false, at: t0 + 30))     // aufgelegt
        XCTAssertEqual(logic.observe(busy: false, at: t0 + 32.05), .ended)
    }

    func testSustainedUseStartsMeetingAndLongPauseEndsIt() {
        var logic = MeetingDetectionLogic()
        logic.startAfter = 4
        logic.endAfter = 10
        XCTAssertNil(logic.observe(busy: true, at: t0))
        XCTAssertEqual(logic.observe(busy: true, at: t0 + 4.5), .started)
        XCTAssertTrue(logic.isMeeting)
        XCTAssertNil(logic.observe(busy: true, at: t0 + 60))

        // Kurzer Aussetzer (Gerätewechsel) beendet nichts …
        XCTAssertNil(logic.observe(busy: false, at: t0 + 61))
        XCTAssertNil(logic.observe(busy: false, at: t0 + 65))
        XCTAssertNil(logic.observe(busy: true, at: t0 + 66))
        XCTAssertTrue(logic.isMeeting)

        // … erst eine lange Pause.
        XCTAssertNil(logic.observe(busy: false, at: t0 + 100))
        XCTAssertNil(logic.observe(busy: false, at: t0 + 105))
        XCTAssertEqual(logic.observe(busy: false, at: t0 + 110.5), .ended)
        XCTAssertFalse(logic.isMeeting)
    }

    func testOwnProcessIsNeverAMeeting() {
        let detector = MeetingDetector()
        XCTAssertFalse(detector.currentUsers().contains { $0.pid == getpid() })
    }

    func testClockFormatting() {
        XCTAssertEqual(MeetingRecorder.clock(0), "00:00")
        XCTAssertEqual(MeetingRecorder.clock(754.9), "12:34")
        XCTAssertEqual(MeetingRecorder.clock(3723), "1:02:03")
    }
}

final class TranscriptChunkerTests: XCTestCase {
    private let rate = 16_000.0

    private func tone(seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(sin(Double($0) * 2 * .pi * 220 / rate) * 0.2) }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(rate * seconds))
    }

    func testCutsAtFirstPauseAfterTarget() {
        var chunker = TranscriptChunker()
        chunker.targetSeconds = 10
        chunker.maxSeconds = 20
        var chunks: [[Float]] = []
        // 12 s Sprache, 1 s Pause, 5 s Sprache – in Blöcken, wie das Mikrofon sie liefert.
        let stream = tone(seconds: 12) + silence(seconds: 1) + tone(seconds: 5)
        for start in stride(from: 0, to: stream.count, by: 1024) {
            chunks += chunker.append(Array(stream[start..<min(start + 1024, stream.count)]))
        }
        XCTAssertEqual(chunks.count, 1)
        let cutSeconds = Double(chunks[0].count) / rate
        XCTAssertGreaterThan(cutSeconds, 12, "Schnitt muss in der Pause liegen, nicht im Wort")
        XCTAssertLessThan(cutSeconds, 13)
        XCTAssertEqual(chunker.bufferedSeconds, 18 - cutSeconds, accuracy: 0.1)
    }

    func testCutsAtMaximumWithoutPause() {
        var chunker = TranscriptChunker()
        chunker.targetSeconds = 10
        chunker.maxSeconds = 20
        let chunks = chunker.append(tone(seconds: 45))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(Double(chunks[0].count) / rate, 20, accuracy: 0.05)
        XCTAssertEqual(Double(chunks[1].count) / rate, 20, accuracy: 0.05)
        XCTAssertEqual(chunker.bufferedSeconds, 5, accuracy: 0.05)
    }

    func testFlushReturnsRestAndResets() {
        var chunker = TranscriptChunker()
        _ = chunker.append(tone(seconds: 3))
        XCTAssertEqual(chunker.flush()?.count, Int(rate * 3))
        XCTAssertNil(chunker.flush())
        XCTAssertEqual(chunker.bufferedSeconds, 0)
    }
}

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("redefluss-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Einträge älterer Versionen haben weder `kind` noch `inProgress` – sie dürfen nicht verloren gehen.
    func testDecodesLegacyEntriesWithoutKind() throws {
        let legacy = """
        [{"id":"5C34939B-48F9-4452-8003-652A7CDF49DE","date":"2026-09-30T16:13:57Z","audioSeconds":40.3,"text":"Hallo Welt","language":"de","appName":"Notizen"}]
        """
        try legacy.data(using: .utf8)!.write(to: directory.appendingPathComponent("history.json"))
        let store = HistoryStore(directory: directory)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].text, "Hallo Welt")
        XCTAssertFalse(store.items[0].isMeeting)
    }

    func testUpdateReplacesGrowingMeetingAndUnfinishedMeetingIsClosedOnNextLaunch() {
        let store = HistoryStore(directory: directory)
        var meeting = HistoryItem(date: Date(), text: "", audioSeconds: 0, appName: "Zoom", language: nil, kind: .meeting, inProgress: true)
        store.add(meeting)
        store.add(HistoryItem(date: Date(), text: "Ein Diktat nebenbei", audioSeconds: 2, appName: "Mail", language: "de", kind: .dictation))

        meeting.text = "[00:00] Guten Morgen zusammen."
        meeting.audioSeconds = 31
        store.update(meeting)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first { $0.id == meeting.id }?.text, "[00:00] Guten Morgen zusammen.")

        // App „stürzt ab" – beim nächsten Start ist das Meeting nicht mehr „läuft noch".
        let reloaded = HistoryStore(directory: directory)
        let restored = reloaded.items.first { $0.id == meeting.id }
        XCTAssertEqual(restored?.inProgress, false)
        XCTAssertTrue(restored?.isMeeting ?? false)
    }
}
