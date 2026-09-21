import XCTest
@testable import RedeflussKit

final class TextPostProcessorTests: XCTestCase {
    private let processor = TextPostProcessor()

    func testTrimsAndCapitalizes() {
        XCTAssertEqual(processor.process("  hallo welt. "), "Hallo welt.")
    }

    func testRemovesGermanAndEnglishFillers() {
        XCTAssertEqual(processor.process("Ähm, ich wollte, äh, kurz fragen."), "Ich wollte, kurz fragen.")
        XCTAssertEqual(processor.process("So umm, I think uh this works."), "So I think this works.")
    }

    func testKeepsGermanWordsThatLookLikeFillers() {
        XCTAssertEqual(processor.process("Wir treffen uns um acht Uhr, er kommt auch."), "Wir treffen uns um acht Uhr, er kommt auch.")
        XCTAssertEqual(processor.process("Der Ähnlichkeitswert und der Uhrmacher."), "Der Ähnlichkeitswert und der Uhrmacher.")
    }

    func testFillerRemovalCanBeDisabled() {
        let keep = TextPostProcessor(removeFillers: false)
        XCTAssertEqual(keep.process("Äh, ja."), "Äh, ja.")
    }

    func testStripsWhisperMarkers() {
        XCTAssertEqual(processor.process("[Musik] Hallo zusammen (lacht)"), "Hallo zusammen")
        XCTAssertNil(processor.process("[BLANK_AUDIO]"))
    }

    func testDropsKnownHallucinations() {
        XCTAssertNil(processor.process("Untertitel der Amara.org-Community"))
        XCTAssertNil(processor.process("Vielen Dank fürs Zuschauen!"))
        XCTAssertNil(processor.process("Thank you for watching."))
        XCTAssertNotNil(processor.process("Vielen Dank für die schnelle Antwort."))
    }

    func testReplacementsMatchWholeWordsCaseInsensitive() {
        let replacing = TextPostProcessor(replacements: [
            Replacement(from: "mfg", to: "Mit freundlichen Grüßen"),
            Replacement(from: "dream crm", to: "DreamCRM"),
        ])
        XCTAssertEqual(replacing.process("Danke, MFG"), "Danke, Mit freundlichen Grüßen")
        XCTAssertEqual(replacing.process("Öffne dream CRM bitte"), "Öffne DreamCRM bitte")
        XCTAssertEqual(replacing.process("Die mfgx bleibt"), "Die mfgx bleibt")
    }

    func testReplacementWithSpecialCharacters() {
        let replacing = TextPostProcessor(replacements: [Replacement(from: "dollar", to: "$1")])
        XCTAssertEqual(replacing.process("Das kostet zehn dollar"), "Das kostet zehn $1")
    }

    func testPunctuationSpacing() {
        XCTAssertEqual(processor.process("Hallo , wie geht es ?"), "Hallo, wie geht es?")
    }
}
