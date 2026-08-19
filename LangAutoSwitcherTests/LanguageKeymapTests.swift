import XCTest

/// Guards the keys this app provides on top of the system keyboard layout.
///
/// These exist because deriving Bulgarian purely from macOS dropped every one
/// of them and silently undid the §-types-ч feature. The bug reached a user,
/// so the guarantee is enforced here rather than trusted.
final class LanguageKeymapTests: XCTestCase {

    /// Keys macOS's Bulgarian layout does NOT provide, which this app must.
    /// A Bulgarian user has to get these whatever the system offers.
    private let appProvidedKeys: [(String, String)] = [
        ("§", "ч"), ("±", "Ч"),      // ISO Mac top-left key
        (";", "ж"), (":", "Ж"),      // alternates for ж
        ("'", "ь"), ("\"", "Ь"),     // alternates for ь
    ]

    func testAppProvidedKeysSurviveAnEmptySystemLayout() {
        // The worst case: macOS tells us nothing at all. Bulgarian must still
        // be fully typable, because the shipped map is authoritative.
        let pairs = LanguageKeymap.build(for: "bg", systemLayout: [], userOverrides: nil)
        let map = Dictionary(pairs.map { (String($0.0), String($0.1)) },
                             uniquingKeysWith: { first, _ in first })
        for (key, expected) in appProvidedKeys {
            XCTAssertEqual(map[key], expected,
                           "key \(key) must type \(expected) even with no system layout")
        }
    }

    func testEveryShippedDefaultIsTypable() {
        // Not a sample: every single entry the app ships must survive the
        // layering. Checking a hand-copied subset is what let § slip through.
        let pairs = LanguageKeymap.build(for: "bg", systemLayout: [], userOverrides: nil)
        let map = Dictionary(pairs.map { (String($0.0), String($0.1)) },
                             uniquingKeysWith: { first, _ in first })
        for (key, expected) in ShippedKeymaps.bulgarian where key.count == 1 {
            XCTAssertEqual(map[key], expected, "shipped key \(key) must type \(expected)")
        }
    }

    func testSystemLayoutCannotOverrideAShippedKey() {
        // If macOS ever maps § to something else, the app's meaning wins.
        let pairs = LanguageKeymap.build(for: "bg",
                                         systemLayout: [("§", "x"), ("a", "z")],
                                         userOverrides: nil)
        let map = Dictionary(pairs.map { (String($0.0), String($0.1)) },
                             uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(map["§"], "ч")
        XCTAssertEqual(map["a"], "а")
    }

    func testUserOverridesWinOverEverything() {
        let pairs = LanguageKeymap.build(for: "bg",
                                         systemLayout: [],
                                         userOverrides: ["§": "ш"])
        let map = Dictionary(pairs.map { (String($0.0), String($0.1)) },
                             uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(map["§"], "ш", "an explicit user choice outranks the shipped map")
    }

    func testAPartialUserFileDoesNotRemoveOtherKeys() {
        // A user editing one key must not lose the rest of the alphabet.
        let pairs = LanguageKeymap.build(for: "bg",
                                         systemLayout: [],
                                         userOverrides: ["`": "ч"])
        let map = Dictionary(pairs.map { (String($0.0), String($0.1)) },
                             uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(map["§"], "ч", "unrelated keys must survive a partial keymap.json")
        XCTAssertEqual(map["a"], "а")
    }

    func testALanguageWeShipNoMapForUsesTheSystemLayout() {
        let pairs = LanguageKeymap.build(for: "ru",
                                         systemLayout: [("y", "ы"), ("w", "ш")],
                                         userOverrides: nil)
        let map = Dictionary(pairs.map { (String($0.0), String($0.1)) },
                             uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(map["y"], "ы")
        XCTAssertEqual(map["w"], "ш")
        XCTAssertNil(map["§"], "Bulgarian's extra keys must not leak into other languages")
    }
}
