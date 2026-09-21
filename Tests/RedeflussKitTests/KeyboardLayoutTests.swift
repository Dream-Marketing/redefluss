import XCTest
@testable import RedeflussKit

final class KeyboardLayoutTests: XCTestCase {
    /// Auf QWERTZ/QWERTY liegt „v" auf Keycode 9 – sonst würde ⌘V eine andere Taste drücken.
    func testFindsPasteKeyInCurrentLayout() throws {
        let keyCode = try XCTUnwrap(KeyboardLayout.keyCode(for: "v"))
        print("⌨️  „v“ liegt im aktuellen Layout auf Keycode \(keyCode)")
        XCTAssertLessThan(keyCode, 128)
    }
}
