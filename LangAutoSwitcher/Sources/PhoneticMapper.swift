import Foundation

/// Maps Latin text to Bulgarian Cyrillic using natural transliteration rules.
///
/// Supports digraphs (sh→ш, zh→ж, ch→ч, sht→щ, yu→ю, ya→я)
/// and single-character mappings (a→а, b→б, w→в, etc.).
struct PhoneticMapper {

    // MARK: - Character mapping (strict 1-to-1)

    /// Single character mappings. Every Latin key maps to exactly one Cyrillic character.
    private static let singleMap: [Character: Character] = [
        // Lowercase
        "a": "а", "b": "б", "c": "ц", "d": "д", "e": "е",
        "f": "ф", "g": "г", "h": "х", "i": "и", "j": "й",
        "k": "к", "l": "л", "m": "м", "n": "н", "o": "о",
        "p": "п", "r": "р", "s": "с", "t": "т",
        "u": "у", "v": "ж", "w": "в", "x": "ь", "y": "ъ",
        "z": "з", "q": "я",
        "]": "щ", "[": "ш", ";": "ж", "'": "ь", "`": "ч", "\\": "ю",
        "}": "Щ", "{": "Ш", ":": "Ж", "\"": "Ь", "~": "Ч", "|": "Ю",
        // Uppercase
        "A": "А", "B": "Б", "C": "Ц", "D": "Д", "E": "Е",
        "F": "Ф", "G": "Г", "H": "Х", "I": "И", "J": "Й",
        "K": "К", "L": "Л", "M": "М", "N": "Н", "O": "О",
        "P": "П", "R": "Р", "S": "С", "T": "Т",
        "U": "У", "V": "Ж", "W": "В", "X": "Ь", "Y": "Ъ",
        "Z": "З", "Q": "Я",
    ]

    /// Convert Latin text to Cyrillic. Strict 1-to-1 character mapping.
    static func toCyrillic(_ text: String) -> String {
        String(text.map { singleMap[$0] ?? $0 })
    }

    /// Characters that are part of typing (letters + special mapped chars).
    private static let mappableSpecials: Set<Character> = [
        "]", "[", ";", "'", "`", "\\",
        "}", "{", ":", "\"", "~", "|"
    ]

    /// Check if a string is entirely typeable characters (ASCII letters + mapped specials).
    static func isLatinWord(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { ($0.isLetter && $0.isASCII) || mappableSpecials.contains($0) }
    }

    /// Check if a string contains Cyrillic characters.
    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}
