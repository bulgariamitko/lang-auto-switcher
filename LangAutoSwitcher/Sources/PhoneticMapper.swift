import Foundation

/// Maps Latin text to Bulgarian Cyrillic using natural transliteration rules.
///
/// Thin Swift wrapper around the Rust core (`langauto-core`). All logic lives
/// in Rust now — same mapping table on every platform that links the core.
struct PhoneticMapper {

    static func toCyrillic(_ text: String) -> String {
        text.withCString { cstr in
            guard let out = langauto_to_cyrillic(cstr) else { return "" }
            defer { langauto_string_free(out) }
            return String(cString: out)
        }
    }

    static func isLatinWord(_ word: String) -> Bool {
        word.withCString { langauto_is_latin_word($0) == 1 }
    }

    static func containsCyrillic(_ text: String) -> Bool {
        text.withCString { langauto_contains_cyrillic($0) == 1 }
    }
}
