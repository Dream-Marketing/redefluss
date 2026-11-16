import AVFoundation
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

final class MeetingAudioTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("redefluss-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWriterProducesPlayableFileWithFullDuration() throws {
        let url = directory.appendingPathComponent("Aufnahmen/test.m4a")
        let writer = try MeetingAudioWriter(url: url)
        let rate = AudioRecorder.sampleRate
        let tone = (0..<Int(rate * 3)).map { Float(sin(Double($0) * 2 * .pi * 220 / rate) * 0.2) }
        // In Blöcken, wie die Aufnahme sie liefert.
        for start in stride(from: 0, to: tone.count, by: 1600) {
            try writer.append(Array(tone[start..<min(start + 1600, tone.count)]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Die .m4a entsteht erst am Ende")
        try writer.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.rawURL.path))

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 3, accuracy: 0.2)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThan(size, 40_000, "AAC statt unkomprimiert")
    }

    /// Absturz mitten im Gespräch: Der Writer wird nie abgeschlossen – beim nächsten Start ist die Aufnahme trotzdem da.
    func testRecordingSurvivesCrashAndIsRecoveredOnNextLaunch() throws {
        let recordings = directory.appendingPathComponent("Aufnahmen")
        let url = recordings.appendingPathComponent("Meeting abgestürzt.m4a")
        let rate = AudioRecorder.sampleRate
        let tone = (0..<Int(rate * 4)).map { Float(sin(Double($0) * 2 * .pi * 220 / rate) * 0.2) }
        var writer: MeetingAudioWriter? = try MeetingAudioWriter(url: url)
        try writer?.append(tone)
        try writer?.append([.nan, .infinity, 2, -2]) // darf nicht selbst zum Absturz führen
        let raw = try XCTUnwrap(writer?.rawURL)
        writer = nil // „Absturz": kein finish()

        // Ein halbes Sample am Ende, wie nach einem abgebrochenen Schreibvorgang.
        let handle = try FileHandle(forWritingTo: raw)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7f]))
        try handle.close()

        XCTAssertEqual(MeetingAudioWriter.recoverUnfinished(in: recordings).map(\.lastPathComponent), [url.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 4, accuracy: 0.2)
        XCTAssertEqual(MeetingAudioWriter.recoverUnfinished(in: recordings), [], "Zweiter Start findet nichts mehr")
    }

    func testEmptyRecordingLeavesNoFile() throws {
        let url = directory.appendingPathComponent("Aufnahmen/leer.m4a")
        let writer = try MeetingAudioWriter(url: url)
        try writer.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.rawURL.path))
    }

    func testFileNameHasNoPathSeparators() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let name = MeetingAudioWriter.fileName(date: date, appName: "../Zoom: Call/1")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasPrefix("Meeting 20"))
        XCTAssertTrue(name.hasSuffix("Zoom  Call 1.m4a"), name)
        XCTAssertEqual(MeetingAudioWriter.fileName(date: date, appName: "").components(separatedBy: " ").count, 3)
    }

    func testSavingAudioIsOffByDefault() {
        let name = "redefluss-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(AppSettings(defaults: defaults).meetingSaveAudio)
    }

    func testDeletingHistoryEntryDeletesItsRecording() throws {
        let store = HistoryStore(directory: directory)
        try FileManager.default.createDirectory(at: store.recordingsDirectory, withIntermediateDirectories: true)
        func meeting(_ file: String) throws -> HistoryItem {
            try Data([1, 2, 3]).write(to: store.recordingsDirectory.appendingPathComponent(file))
            let item = HistoryItem(date: Date(), text: "[00:00] Hallo", audioSeconds: 5, appName: "Zoom", language: "de", kind: .meeting, audioFile: file)
            store.add(item)
            return item
        }
        let first = try meeting("a.m4a")
        let second = try meeting("b.m4a")
        XCTAssertEqual(store.recordingCount, 2)
        XCTAssertNotNil(store.audioURL(for: first))

        // Auch die Rohdatei einer noch laufenden Aufnahme verschwindet mit dem Eintrag.
        let raw = store.recordingsDirectory.appendingPathComponent("a.m4a.pcm")
        try Data([1, 2]).write(to: raw)
        store.delete(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recordingsDirectory.appendingPathComponent("a.m4a").path))
        XCTAssertNotNil(store.audioURL(for: second))

        // Der Verweis übersteht einen Neustart; „Alles löschen" räumt auch die Dateien ab.
        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(reloaded.items.first?.audioFile, "b.m4a")
        reloaded.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recordingsDirectory.appendingPathComponent("b.m4a").path))
    }

    /// Ein manipulierter Verlauf darf keine Datei außerhalb des Aufnahmen-Ordners löschen.
    func testAudioReferenceCannotLeaveRecordingsDirectory() throws {
        let store = HistoryStore(directory: directory)
        let outside = directory.appendingPathComponent("wichtig.txt")
        try Data([1]).write(to: outside)
        let item = HistoryItem(date: Date(), text: "x", audioSeconds: 1, appName: nil, language: nil, kind: .meeting, audioFile: "../wichtig.txt")
        store.add(item)
        store.delete(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
