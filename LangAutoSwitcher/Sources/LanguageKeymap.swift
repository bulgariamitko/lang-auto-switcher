import Foundation

/// Builds the keymap a language actually types with.
///
/// Three layers, weakest first:
///
///   1. **The system layout.** macOS knows how every language is typed, which
///      is why adding one needs no hand-written table.
///   2. **This app's own keys.** macOS's Bulgarian layout has no §, ±, ;, :,
///      ' or ", but this app has always offered them — the ISO §/± key types
///      ч. Deriving purely from the system silently dropped every one, and
///      "ka§ila" stopped becoming "качила".
///   3. **The user's keymap.json.** An explicit choice outranks both.
///
/// Layer 2 is READ FROM the shipped defaults rather than retyped here, so the
/// map the app ships and the map it types with cannot drift apart. That is
/// the actual guarantee: not that someone remembered to copy §, but that
/// there is only one copy to begin with.
enum LanguageKeymap {

    /// Languages this app ships a complete keymap for. For these the shipped
    /// map is authoritative and the system layout only fills gaps, so a
    /// Bulgarian user gets exactly the layout they have always had whatever
    /// macOS happens to provide.
    static func shippedMap(for code: String) -> [String: String]? {
        switch code {
        case "bg": return ShippedKeymaps.bulgarian
        default:   return nil
        }
    }

    /// The effective map, as (key typed, letter produced) pairs.
    static func build(for code: String,
                      systemLayout: [(Character, Character)],
                      userOverrides: [String: String]? = nil) -> [(Character, Character)] {
        var map: [Character: Character] = [:]

        for (key, letter) in systemLayout {
            map[key] = letter
        }
        for (key, letter) in singleCharPairs(shippedMap(for: code)) {
            map[key] = letter
        }
        // keymap.json predates multi-language support and describes the
        // Bulgarian layout, so that is where it applies.
        if code == "bg" {
            for (key, letter) in singleCharPairs(userOverrides) {
                map[key] = letter
            }
        }
        return map.map { ($0.key, $0.value) }
    }

    private static func singleCharPairs(_ table: [String: String]?) -> [(Character, Character)] {
        guard let table = table else { return [] }
        return table.compactMap { key, value in
            guard key.count == 1, value.count == 1,
                  let k = key.first, let v = value.first else { return nil }
            return (k, v)
        }
    }
}
