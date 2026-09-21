import XCTest
@testable import RedeflussKit

final class SpeechDetectorTests: XCTestCase {
    func testSilenceIsNotSpeech() {
        let silence = [Float](repeating: 0, count: 16_000)
        XCTAssertFalse(SpeechDetector.containsSpeech(silence))
    }

    func testLowNoiseIsNotSpeech() {
        let noise = (0..<16_000).map { _ in Float.random(in: -0.003...0.003) }
        XCTAssertFalse(SpeechDetector.containsSpeech(noise))
    }

    func testToneIsSpeechLike() {
        let tone = (0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 220 / 16_000) * 0.1) }
        XCTAssertTrue(SpeechDetector.containsSpeech(tone))
    }

    func testVeryShortBlipIsIgnored() {
        var samples = [Float](repeating: 0, count: 16_000)
        for i in 0..<800 { samples[i] = Float(sin(Double(i) * 0.3) * 0.2) }   // 50 ms Klick
        XCTAssertFalse(SpeechDetector.containsSpeech(samples))
    }
}
