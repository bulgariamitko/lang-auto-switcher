import Foundation

/// Pure text heuristics used by InputController, split out so they can be
/// unit-tested without InputMethodKit, Sparkle, or the Rust core.
enum TextHeuristics {

    // MARK: - Emoticons

    /// Buffer contents that, followed by an emoticon body char, form an emoticon.
    /// (Used before force-commit when next char is non-mappable punctuation like ")")
    static let emoticonPrefixes: Set<String> = [
        ":", ";", "=", ":-", ";-", "=-", ":'", ";'",
    ]

    /// Non-mappable, non-email chars that indicate an emoticon body
    /// when they follow an emoticon prefix (e.g., ")" in ":)", "*" in ":*").
    static let emoticonBodyChars: Set<Character> = [
        ")", "(", "*", "|",
    ]

    /// Complete emoticons that may end up fully buffered and committed via space/punct.
    /// These typically have letter bodies (D, P, O) or digit bodies (3) that stay in buffer.
    static let knownEmoticons: Set<String> = [
        ":D", ":P", ":p", ":O", ":o", ":3", ":X", ":x",
        ";D", ";P", ";p",
        "=D", "=P", "=p",
        ":-D", ":-P", ":-p", ":-O", ":-o", ":-3",
        ";-D", ";-P", ";-p",
        ":'D",
        "xD", "XD", "xP", "XP",
    ]

    static func isEmoticonPrefix(_ buffer: String) -> Bool {
        emoticonPrefixes.contains(buffer)
    }

    static func isEmoticonBody(_ char: Character) -> Bool {
        emoticonBodyChars.contains(char)
    }

    static func isEmoticon(_ word: String) -> Bool {
        knownEmoticons.contains(word)
    }

    // MARK: - Email / URL / identifier detection

    /// Detect if a word is an email, URL, file path, or similar Latin-only construct.
    static func isEmailOrUrl(_ word: String) -> Bool {
        // Contains @ → email
        if word.contains("@") { return true }
        // Contains / → URL or path
        if word.contains("/") { return true }
        // Contains a digit → likely identifier/code/version
        if word.contains(where: { $0.isNumber }) { return true }
        // Contains . with letters around it → domain (e.g., gmail.com, foo.bar)
        if word.contains(".") {
            let parts = word.split(separator: ".")
            if parts.count >= 2 && parts.allSatisfy({ !$0.isEmpty }) {
                return true
            }
        }
        return false
    }

    // MARK: - Trailing punctuation

    /// Punctuation that gets buffered for email/URL detection but shouldn't
    /// affect word detection. Stripped before processing, reattached after.
    static let trailingPunctuation: Set<Character> = [".", ",", "!", "?"]

    /// Split "word?!" into ("word", "?!"). Either part may be empty.
    static func splitTrailingPunctuation(_ raw: String) -> (word: String, trailing: String) {
        var word = raw
        var trailing = ""
        while let last = word.last, trailingPunctuation.contains(last) {
            trailing = String(last) + trailing
            word.removeLast()
        }
        return (word, trailing)
    }
}
