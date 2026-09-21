import XCTest
import AVFoundation
@testable import RedeflussKit

/// Ende-zu-Ende gegen ein echtes whisper.cpp-Modell. Wird übersprungen, wenn keins da ist.
/// Modell wählen mit REDEFLUSS_TEST_MODEL=/pfad/zu/ggml-….bin
final class WhisperIntegrationTests: XCTestCase {
    private var modelPath: String? {
        if let env = ProcessInfo.processInfo.environment["REDEFLUSS_TEST_MODEL"] { return env }
        let fallback = NSHomeDirectory() + "/.cache/whisper-cpp/ggml-large-v3-turbo.bin"
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    func testTranscribesGermanSpeech() throws {
        guard let modelPath else { throw XCTSkip("Kein whisper-Modell gefunden") }
        let samples = try synthesize("Hallo, das ist ein Test der lokalen Diktierfunktion.", voice: "Anna")

        let transcriber = WhisperTranscriber()
        let loaded = expectation(description: "Modell geladen")
        let loadStart = Date()
        transcriber.load(modelPath: modelPath) { result in
            if case .failure(let error) = result { XCTFail("Laden fehlgeschlagen: \(error)") }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 120)
        print("⏱  Modell geladen in \(String(format: "%.2f", Date().timeIntervalSince(loadStart))) s")

        let done = expectation(description: "Transkription")
        var output: TranscriptionResult?
        transcriber.transcribe(samples: samples, language: "auto", prompt: "") { result in
            output = try? result.get()
            done.fulfill()
        }
        wait(for: [done], timeout: 60)

        let result = try XCTUnwrap(output)
        print("⏱  \(String(format: "%.2f", Double(samples.count) / 16_000)) s Audio → \(String(format: "%.2f", result.duration)) s Transkription [\(result.language ?? "?")]: \(result.text)")
        XCTAssertEqual(result.language, "de")
        let lowered = result.text.lowercased()
        XCTAssertTrue(lowered.contains("test"), result.text)
        XCTAssertTrue(lowered.contains("diktier"), result.text)

        let cleaned = TextPostProcessor().process(result.text)
        XCTAssertNotNil(cleaned)
    }

    /// Erzeugt Sprache mit der macOS-Stimme und liefert 16-kHz-Mono-Samples wie der Recorder.
    private func synthesize(_ text: String, voice: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("redefluss-test-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", url.path, text]
        try say.run()
        say.waitUntilExit()

        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: target))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
