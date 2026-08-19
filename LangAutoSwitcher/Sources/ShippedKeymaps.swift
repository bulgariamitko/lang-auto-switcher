import Foundation

/// The keyboard layouts this app ships itself.
///
/// Kept apart from KeymapManager (which talks to the Rust core) so the layering
/// logic and its tests can use it without pulling in the whole app. There is
/// exactly ONE copy of this table: KeymapManager and LanguageKeymap both read
/// it from here. Retyping it into a second place is how § quietly stopped
/// typing ч — the check that should have caught it was comparing against a
/// hand-copied duplicate.
enum ShippedKeymaps {

    /// Bulgarian phonetic, as this app has always defined it. Mirrors
    /// `default_map_char` in langauto-core/src/phonetic.rs.
    ///
    /// Note the entries macOS's own Bulgarian layout does NOT have: the ISO
    /// §/± key typing ч, and ; : ' " as alternates for ж and ь. Those are the
    /// reason this table has to win over the system layout.
    static let bulgarian: [String: String] = [
        // lowercase letters
        "a": "а", "b": "б", "c": "ц", "d": "д", "e": "е",
        "f": "ф", "g": "г", "h": "х", "i": "и", "j": "й",
        "k": "к", "l": "л", "m": "м", "n": "н", "o": "о",
        "p": "п", "r": "р", "s": "с", "t": "т",
        "u": "у", "v": "ж", "w": "в", "x": "ь", "y": "ъ",
        "z": "з", "q": "я",
        // lowercase specials
        "]": "щ", "[": "ш", ";": "ж", "'": "ь", "`": "ч", "\\": "ю",
        // uppercase specials
        "}": "Щ", "{": "Ш", ":": "Ж", "\"": "Ь", "~": "Ч", "|": "Ю",
        // ISO Mac §/± key (top-left, left of 1) — alternate ч/Ч
        "§": "ч", "±": "Ч",
        // uppercase letters
        "A": "А", "B": "Б", "C": "Ц", "D": "Д", "E": "Е",
        "F": "Ф", "G": "Г", "H": "Х", "I": "И", "J": "Й",
        "K": "К", "L": "Л", "M": "М", "N": "Н", "O": "О",
        "P": "П", "R": "Р", "S": "С", "T": "Т",
        "U": "У", "V": "Ж", "W": "В", "X": "Ь", "Y": "Ъ",
        "Z": "З", "Q": "Я",
    ]

}
