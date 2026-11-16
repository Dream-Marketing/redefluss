import XCTest
@testable import RedeflussKit

/// Speichern/Laden der Diktiertaste (inkl. Umzug vom alten Textwert) und die Tastennamen.
final class HotkeyOptionTests: XCTestCase {
    private let suite = "redefluss.tests.hotkeyoption"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultIsFn() {
        XCTAssertEqual(AppSettings(defaults: defaults).hotkey, .fn)
    }

    func testLegacyStringSettingIsMigrated() {
        defaults.set("rightCommand", forKey: "hotkey")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.hotkey, .rightCommand)
        XCTAssertEqual(settings.hotkey.label, "Rechte ⌘ Command")
    }

    func testCustomKeyRoundTrip() {
        let settings = AppSettings(defaults: defaults)
        settings.hotkey = HotkeyOption(kind: .key, keyCode: 79, name: "F18")

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.hotkey.kind, .key)
        XCTAssertEqual(reloaded.hotkey.keyCode, 79)
        XCTAssertEqual(reloaded.hotkey.name, "F18")
        XCTAssertFalse(reloaded.hotkey.isPreset)
        XCTAssertEqual(reloaded.hotkey.label, "F18")
        XCTAssertEqual(reloaded.hotkey.shortLabel, "F18")
    }

    func testRecordedPresetBecomesThePreset() {
        let recorded = HotkeyOption(kind: .modifier, keyCode: 61, name: "Rechte ⌥").canonical
        XCTAssertTrue(recorded.isPreset)
        XCTAssertEqual(recorded.label, "Rechte ⌥ Option")
        XCTAssertEqual(recorded.shortLabel, "⌥")
        // Gleicher Keycode, andere Art → andere Taste.
        XCTAssertNotEqual(HotkeyOption(kind: .key, keyCode: 61, name: "x"), HotkeyOption.rightOption)
    }

    func testKeyNames() {
        XCTAssertEqual(KeyNames.name(forKeyCode: 79, kind: .key), "F18")
        XCTAssertEqual(KeyNames.name(forKeyCode: 81, kind: .key), "Num =")
        XCTAssertEqual(KeyNames.name(forKeyCode: 115, kind: .key), "Pos1")
        XCTAssertEqual(KeyNames.name(forKeyCode: 63, kind: .modifier), "Fn")
        XCTAssertEqual(KeyNames.name(forKeyCode: 56, kind: .modifier), "Linke ⇧")
        XCTAssertEqual(KeyNames.name(forKeyCode: 999, kind: .modifier), "Taste 999")
        // Buchstaben kommen aus dem aktuellen Layout (Keycode 0 = „a" auf QWERTZ und QWERTY).
        XCTAssertEqual(KeyNames.name(forKeyCode: 0, kind: .key), "A")
    }

    func testFunctionKeysAreRecognised() {
        XCTAssertTrue(HotkeyOption(kind: .key, keyCode: 97, name: "F6").isFunctionKey)
        XCTAssertTrue(HotkeyOption(kind: .key, keyCode: 111, name: "F12").isFunctionKey)
        XCTAssertFalse(HotkeyOption(kind: .key, keyCode: 96, name: "F5").isFunctionKey, "F5 kommt als Mikrofontaste auch ohne die Einstellung an")
        XCTAssertFalse(HotkeyOption(kind: .key, keyCode: 105, name: "F13").isFunctionKey, "F13+ gibt es auf der Mac-Tastatur nicht, also kein Konflikt")
        XCTAssertFalse(HotkeyOption.fn.isFunctionKey)
    }

    func testF5PresetCoversPlainF5AndTheMicrophoneKey() {
        XCTAssertTrue(HotkeyOption.f5.isPreset)
        XCTAssertEqual(HotkeyOption.f5.label, "F5 / 🎤 Mikrofontaste")
        XCTAssertEqual(HotkeyOption.f5.shortLabel, "F5")
        XCTAssertTrue(HotkeyOption.f5.matches(keyCode: 96, kind: .key), "F5 mit Fn oder auf Fremdtastaturen")
        XCTAssertTrue(HotkeyOption.f5.matches(keyCode: 176, kind: .key), "Mikrofontaste der Apple-Tastatur")
        XCTAssertFalse(HotkeyOption.f5.matches(keyCode: 105, kind: .key), "F13 ist eine eigene Taste")
        XCTAssertFalse(HotkeyOption.f5.matches(keyCode: 96, kind: .modifier))
        XCTAssertFalse(HotkeyOption.f5.isFunctionKey, "Braucht keine „Standardfunktionstasten“")
        XCTAssertFalse(HotkeyOption(kind: .key, keyCode: 79, name: "F18").matches(keyCode: 176, kind: .key))
        // Aufgenommen kommt die Mikrofontaste als Keycode 176 an – daraus wird die Voreinstellung F5.
        let recorded = HotkeyOption(kind: .key, keyCode: 176, name: KeyNames.name(forKeyCode: 176, kind: .key)).canonical
        XCTAssertEqual(recorded, .f5)
        XCTAssertEqual(recorded.keyCode, 96)
    }

    func testStoredMicrophoneKeyCodeLoadsAsF5Preset() throws {
        defaults.set(try JSONEncoder().encode(HotkeyOption(kind: .key, keyCode: 176, name: "F5")), forKey: "hotkey")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.hotkey, .f5)
        XCTAssertTrue(settings.hotkey.isPreset)
    }

    func testEveryModifierPresetHasAMask() {
        for preset in HotkeyOption.presets where preset.kind == .modifier {
            XCTAssertNotNil(HotkeyOption.modifierMask(forKeyCode: preset.keyCode), preset.name)
        }
        XCTAssertNil(HotkeyOption.modifierMask(forKeyCode: 57), "Caps Lock ist ein Schalter, keine Haltetaste")
    }
}
