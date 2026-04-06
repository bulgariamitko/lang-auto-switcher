import Foundation
import AppKit

/// Handles autocorrect for both English and Bulgarian:
/// 1. Abbreviation expansion (u → you, r → are, pls → please, etc.)
/// 2. Spell correction via NSSpellChecker for typos
final class AutoCorrector {

    // MARK: - English abbreviation expansions

    private let englishAbbreviations: [String: String] = [
        // Common texting abbreviations
        "u": "you",
        "r": "are",
        "ur": "your",
        "pls": "please",
        "plz": "please",
        "thx": "thanks",
        "thnx": "thanks",
        "ty": "thank you",
        "yw": "you're welcome",
        "np": "no problem",
        "idk": "I don't know",
        "imo": "in my opinion",
        "imho": "in my humble opinion",
        "btw": "by the way",
        "fyi": "for your information",
        "tbh": "to be honest",
        "omg": "oh my god",
        "brb": "be right back",
        "gtg": "got to go",
        "lmk": "let me know",
        "nvm": "never mind",
        "rn": "right now",
        "bc": "because",
        "w": "with",
        "b4": "before",
        "2day": "today",
        "2morrow": "tomorrow",
        "2nite": "tonight",
        "msg": "message",
        "ppl": "people",
        "govt": "government",
        "dept": "department",
        "info": "information",
        "pic": "picture",
        "pics": "pictures",
        "approx": "approximately",
        "misc": "miscellaneous",
        "temp": "temporary",
        "diff": "different",
        "convo": "conversation",
        "prob": "probably",
        "probs": "probably",
        "def": "definitely",
        "obv": "obviously",
        "tbf": "to be fair",
        "smth": "something",
        "smb": "somebody",
        "sth": "something",
        "sb": "somebody",
        "abt": "about",
        "tho": "though",
        "thru": "through",
        "gonna": "going to",
        "wanna": "want to",
        "gotta": "got to",
        "kinda": "kind of",
        "sorta": "sort of",
        "cuz": "because",
        "coz": "because",
        "dunno": "don't know",
        "lemme": "let me",
        "gimme": "give me",
    ]

    // MARK: - Bulgarian abbreviation expansions (transliterated)
    // These are typed on Latin keyboard, so they use the user's mapping

    private let bulgarianAbbreviations: [String: String] = [
        // Common BG abbreviations (Cyrillic output)
        "mn": "много",
        "nqm": "нямам",
        "nqma": "няма",
        "dr": "добър",
        "zdr": "здравей",
        "blgdr": "благодаря",
        "msl": "мисля",
        "spk": "споко",
    ]

    /// The spell checker instance (reused).
    private let spellChecker = NSSpellChecker.shared

    // MARK: - Public API

    /// Expand an English abbreviation directly. Returns nil if not an abbreviation.
    func expandEnglishAbbreviation(_ word: String) -> String? {
        return englishAbbreviations[word.lowercased()]
    }

    /// Try to autocorrect an English word.
    /// Returns the corrected word, or nil if no correction needed/found.
    func correctEnglish(_ word: String, dictionary: Set<String>) -> String? {
        let lower = word.lowercased()

        // 1. Abbreviation expansion
        if let expanded = englishAbbreviations[lower] {
            // Preserve capitalization of first letter
            if word.first?.isUppercase == true {
                return expanded.prefix(1).uppercased() + expanded.dropFirst()
            }
            return expanded
        }

        // 2. If word is already in dictionary, no correction needed
        if dictionary.contains(lower) {
            return nil
        }

        // 3. Try NSSpellChecker for typo correction
        let range = NSRange(location: 0, length: word.utf16.count)
        if let correction = spellChecker.correction(forWordRange: range,
                                                      in: word,
                                                      language: "en",
                                                      inSpellDocumentWithTag: 0) {
            // Only accept if the correction is actually in our dictionary
            if dictionary.contains(correction.lowercased()) {
                // Preserve original capitalization pattern
                if word.first?.isUppercase == true {
                    return correction.prefix(1).uppercased() + correction.dropFirst()
                }
                return correction
            }
        }

        return nil
    }

    /// Try to autocorrect a Bulgarian word (already in Cyrillic).
    /// Returns the corrected Cyrillic word, or nil if no correction needed/found.
    func correctBulgarian(_ cyrillicWord: String, dictionary: Set<String>) -> String? {
        let lower = cyrillicWord.lowercased()

        // 1. If word is already in dictionary, no correction needed
        if dictionary.contains(lower) {
            return nil
        }

        // 2. Try NSSpellChecker first
        let range = NSRange(location: 0, length: cyrillicWord.utf16.count)
        if let correction = spellChecker.correction(forWordRange: range,
                                                      in: cyrillicWord,
                                                      language: "bg",
                                                      inSpellDocumentWithTag: 0) {
            if dictionary.contains(correction.lowercased()) {
                if cyrillicWord.first?.isUppercase == true {
                    return correction.prefix(1).uppercased() + correction.dropFirst()
                }
                return correction
            }
        }

        // 3. Dictionary-based edit-distance-1 correction
        //    Finds words that differ by exactly one character substitution.
        //    This catches common typos like пръвописни → правописни
        if let correction = findEditDistance1Match(for: lower, in: dictionary) {
            if cyrillicWord.first?.isUppercase == true {
                return correction.prefix(1).uppercased() + correction.dropFirst()
            }
            return correction
        }

        return nil
    }

    /// Check if a Latin word is a known English abbreviation.
    func isEnglishAbbreviation(_ word: String) -> Bool {
        englishAbbreviations[word.lowercased()] != nil
    }

    /// Expand a Bulgarian abbreviation (typed in Latin).
    /// Returns Cyrillic expansion or nil.
    func expandBulgarianAbbreviation(_ latinWord: String) -> String? {
        bulgarianAbbreviations[latinWord.lowercased()]
    }

    // MARK: - Edit distance spell correction

    /// Find a word in the dictionary that is edit-distance-1 from the input.
    /// Checks: substitution, deletion (extra char), insertion (missing char), transposition (swapped chars).
    private func findEditDistance1Match(for word: String, in dictionary: Set<String>) -> String? {
        let chars = Array(word)
        let len = chars.count

        guard len >= 2 else { return nil }  // Too short to correct

        // All unique characters that appear in the word + common nearby chars
        // For Cyrillic, we generate candidates by trying all Cyrillic letters
        let cyrillicLetters: [Character] = Array("абвгдежзийклмнопрстуфхцчшщъьюя")

        // 1. Substitution: replace one character
        for i in 0..<len {
            let original = chars[i]
            for replacement in cyrillicLetters {
                if replacement == original { continue }
                var candidate = chars
                candidate[i] = replacement
                let candidateStr = String(candidate)
                if dictionary.contains(candidateStr) {
                    return candidateStr
                }
            }
        }

        // 2. Deletion: remove one character (word has an extra char)
        for i in 0..<len {
            var candidate = chars
            candidate.remove(at: i)
            let candidateStr = String(candidate)
            if dictionary.contains(candidateStr) {
                return candidateStr
            }
        }

        // 3. Insertion: add one character (word is missing a char)
        for i in 0...len {
            for c in cyrillicLetters {
                var candidate = chars
                candidate.insert(c, at: i)
                let candidateStr = String(candidate)
                if dictionary.contains(candidateStr) {
                    return candidateStr
                }
            }
        }

        // 4. Transposition: swap two adjacent characters
        for i in 0..<(len - 1) {
            var candidate = chars
            candidate.swapAt(i, i + 1)
            let candidateStr = String(candidate)
            if dictionary.contains(candidateStr) {
                return candidateStr
            }
        }

        return nil
    }
}
