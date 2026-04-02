import Foundation

/// Maps Latin characters (typed on QWERTY) to Bulgarian Cyrillic
/// using the standard Bulgarian Phonetic keyboard layout.
struct PhoneticMapper {

    // MARK: - Bulgarian Phonetic Layout (standard Apple)

    private static let latinToCyrillic: [Character: Character] = [
        // Lowercase
        "a": "а", "b": "б", "c": "ц", "d": "д", "e": "е",
        "f": "ф", "g": "г", "h": "х", "i": "и", "j": "й",
        "k": "к", "l": "л", "m": "м", "n": "н", "o": "о",
        "p": "п", "q": "я", "r": "р", "s": "с", "t": "т",
        "u": "у", "v": "в", "w": "ш", "x": "ь", "y": "ъ",
        "z": "з",
        // Uppercase
        "A": "А", "B": "Б", "C": "Ц", "D": "Д", "E": "Е",
        "F": "Ф", "G": "Г", "H": "Х", "I": "И", "J": "Й",
        "K": "К", "L": "Л", "M": "М", "N": "Н", "O": "О",
        "P": "П", "Q": "Я", "R": "Р", "S": "С", "T": "Т",
        "U": "У", "V": "В", "W": "Ш", "X": "Ь", "Y": "Ъ",
        "Z": "З",
        // Punctuation that maps differently on BG phonetic
        "[": "ш", "]": "щ", ";": "ж", "'": "ь",
    ]

    private static let cyrillicToLatin: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (latin, cyrillic) in latinToCyrillic {
            // Only map letter pairs (skip punctuation overrides)
            if latin.isLetter {
                map[cyrillic] = latin
            }
        }
        return map
    }()

    /// Convert a Latin string to Cyrillic using phonetic mapping.
    static func toCyrillic(_ text: String) -> String {
        String(text.map { latinToCyrillic[$0] ?? $0 })
    }

    /// Convert a Cyrillic string back to Latin.
    static func toLatin(_ text: String) -> String {
        String(text.map { cyrillicToLatin[$0] ?? $0 })
    }

    /// Check if a string is entirely ASCII Latin letters.
    static func isLatinWord(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isLetter && $0.isASCII }
    }

    /// Check if a string contains Cyrillic characters.
    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}
