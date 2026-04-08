import Foundation

/// Maps Latin text to Bulgarian Cyrillic using natural transliteration rules.
///
/// Supports digraphs (sh→ш, zh→ж, ch→ч, sht→щ, yu→ю, ya→я)
/// and single-character mappings (a→а, b→б, w→в, etc.).
struct PhoneticMapper {

    // MARK: - Transliteration rules

    /// Multi-character mappings (checked first, longest match wins).
    private static let digraphs: [(latin: String, cyrillic: String)] = [
        // Trigraphs first (longest match)
        ("sht", "щ"), ("SHT", "Щ"), ("Sht", "Щ"),
        // Digraphs
        ("sh", "ш"), ("SH", "Ш"), ("Sh", "Ш"),
        ("zh", "ж"), ("ZH", "Ж"), ("Zh", "Ж"),
        ("ch", "ч"), ("CH", "Ч"), ("Ch", "Ч"),
        ("ts", "ц"), ("TS", "Ц"), ("Ts", "Ц"),
        ("yu", "ю"), ("YU", "Ю"), ("Yu", "Ю"),
        ("ya", "я"), ("YA", "Я"), ("Ya", "Я"),
    ]

    /// Single character mappings.
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

    /// Convert Latin text to Cyrillic using transliteration.
    /// Processes digraphs/trigraphs first (longest match), then single chars.
    static func toCyrillic(_ text: String) -> String {
        var result = ""
        var i = text.startIndex

        while i < text.endIndex {
            var matched = false

            // Try digraphs/trigraphs (longest first — they're sorted by length desc)
            for (latin, cyrillic) in digraphs {
                let end = text.index(i, offsetBy: latin.count, limitedBy: text.endIndex)
                if let end = end {
                    let substring = String(text[i..<end])
                    if substring == latin {
                        result += cyrillic
                        i = end
                        matched = true
                        break
                    }
                }
            }

            if !matched {
                let char = text[i]
                if let mapped = singleMap[char] {
                    result.append(mapped)
                } else {
                    result.append(char) // spaces, punctuation, digits pass through
                }
                i = text.index(after: i)
            }
        }

        return result
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
