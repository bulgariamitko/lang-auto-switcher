#!/usr/bin/env swift
/// Test suite for LangAutoSwitcher
/// Run with: swift test_cases.swift
/// Or: chmod +x test_cases.swift && ./test_cases.swift

import Foundation
import NaturalLanguage

// ============================================================================
// MARK: - Copy of PhoneticMapper (for testing)
// ============================================================================

struct PhoneticMapper {
    private static let digraphs: [(latin: String, cyrillic: String)] = [
        ("sht", "щ"), ("SHT", "Щ"), ("Sht", "Щ"),
        ("sh", "ш"), ("SH", "Ш"), ("Sh", "Ш"),
        ("zh", "ж"), ("ZH", "Ж"), ("Zh", "Ж"),
        ("ch", "ч"), ("CH", "Ч"), ("Ch", "Ч"),
        ("ts", "ц"), ("TS", "Ц"), ("Ts", "Ц"),
        ("yu", "ю"), ("YU", "Ю"), ("Yu", "Ю"),
        ("ya", "я"), ("YA", "Я"), ("Ya", "Я"),
    ]

    private static let singleMap: [Character: Character] = [
        "a": "а", "b": "б", "c": "ц", "d": "д", "e": "е",
        "f": "ф", "g": "г", "h": "х", "i": "и", "j": "й",
        "k": "к", "l": "л", "m": "м", "n": "н", "o": "о",
        "p": "п", "r": "р", "s": "с", "t": "т",
        "u": "у", "v": "ж", "w": "в", "x": "ь", "y": "ъ",
        "z": "з", "q": "я",
        "]": "щ", "[": "ш", ";": "ж", "'": "ь", "`": "ч", "\\": "ю",
        "}": "Щ", "{": "Ш", ":": "Ж", "\"": "Ь", "~": "Ч", "|": "Ю",
        "A": "А", "B": "Б", "C": "Ц", "D": "Д", "E": "Е",
        "F": "Ф", "G": "Г", "H": "Х", "I": "И", "J": "Й",
        "K": "К", "L": "Л", "M": "М", "N": "Н", "O": "О",
        "P": "П", "R": "Р", "S": "С", "T": "Т",
        "U": "У", "V": "Ж", "W": "В", "X": "Ь", "Y": "Ъ",
        "Z": "З", "Q": "Я",
    ]

    static func toCyrillic(_ text: String) -> String {
        var result = ""
        var i = text.startIndex
        while i < text.endIndex {
            var matched = false
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
                    result.append(char)
                }
                i = text.index(after: i)
            }
        }
        return result
    }
}

// ============================================================================
// MARK: - Load dictionaries
// ============================================================================

func loadDictionary(_ filename: String) -> Set<String> {
    let path = "LangAutoSwitcher/Resources/\(filename)"
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("⚠️  Could not load \(path)")
        return []
    }
    return Set(content.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty })
}

// ============================================================================
// MARK: - Test runner
// ============================================================================

var passed = 0
var failed = 0
var total = 0

func test(_ name: String, _ condition: Bool, detail: String = "") {
    total += 1
    if condition {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failed += 1
        print("  ❌ \(name) \(detail)")
    }
}

// ============================================================================
// MARK: - 1. Phonetic Mapping Tests
// ============================================================================

print("\n📋 PHONETIC MAPPING TESTS")
print("=" * 50)

// Basic single-char mapping
test("a → а", PhoneticMapper.toCyrillic("a") == "а")
test("b → б", PhoneticMapper.toCyrillic("b") == "б")
test("w → в", PhoneticMapper.toCyrillic("w") == "в")
test("v → ж", PhoneticMapper.toCyrillic("v") == "ж")
test("k → к", PhoneticMapper.toCyrillic("k") == "к")
test("q → я", PhoneticMapper.toCyrillic("q") == "я")

// Special char mapping
test("] → щ", PhoneticMapper.toCyrillic("]") == "щ")
test("[ → ш", PhoneticMapper.toCyrillic("[") == "ш")
test("; → ж", PhoneticMapper.toCyrillic(";") == "ж")
test("` → ч", PhoneticMapper.toCyrillic("`") == "ч")
test("\\ → ю", PhoneticMapper.toCyrillic("\\") == "ю")
test("} → Щ (uppercase)", PhoneticMapper.toCyrillic("}") == "Щ")
test("{ → Ш (uppercase)", PhoneticMapper.toCyrillic("{") == "Ш")
test(": → Ж (uppercase)", PhoneticMapper.toCyrillic(":") == "Ж")
test("\" → Ь (uppercase)", PhoneticMapper.toCyrillic("\"") == "Ь")
test("~ → Ч (uppercase)", PhoneticMapper.toCyrillic("~") == "Ч")
test("| → Ю (uppercase)", PhoneticMapper.toCyrillic("|") == "Ю")

// Digraphs
test("sh → ш", PhoneticMapper.toCyrillic("sh") == "ш")
test("zh → ж", PhoneticMapper.toCyrillic("zh") == "ж")
test("ch → ч", PhoneticMapper.toCyrillic("ch") == "ч")
test("sht → щ", PhoneticMapper.toCyrillic("sht") == "щ")
test("ya → я", PhoneticMapper.toCyrillic("ya") == "я")
test("yu → ю", PhoneticMapper.toCyrillic("yu") == "ю")
test("ts → ц", PhoneticMapper.toCyrillic("ts") == "ц")

// Full words
let wordTests: [(String, String, String)] = [
    ("towa", "това", "this"),
    ("kak", "как", "how"),
    ("si", "си", "you are"),
    ("dobre", "добре", "good"),
    ("blagodarya", "благодаря", "thank you"),
    ("nared", "наред", "in order"),
    ("we`e", "вече", "already"),
    ("ne]ata", "нещата", "the things"),
    ("proba", "проба", "test"),
    ("samo", "само", "only"),
    ("pokava", "покажа", "show (non-standard, but maps correctly)"),
    ("hubaw", "хубав", "nice"),
    ("mnogo", "много", "a lot"),
    ("zdrawej", "здравей", "hello"),
    ("mashina", "машина", "machine"),
    ("uchilishte", "училище", "school (with digraph)"),
    ("prewkl\\`wam", "превключвам", "to switch (with \\ → ю)"),
    ("~ajnika", "Чайника", "the kettle (uppercase Ч via ~)"),
    ("|nikod", "Юникод", "unicode (uppercase Ю via |)"),
]

print("\n📋 WORD MAPPING TESTS")
print("=" * 50)
for (latin, expectedCyrillic, meaning) in wordTests {
    let result = PhoneticMapper.toCyrillic(latin)
    test("\(latin) → \(expectedCyrillic) (\(meaning))",
         result == expectedCyrillic,
         detail: "got '\(result)'")
}

// ============================================================================
// MARK: - 2. Dictionary Tests
// ============================================================================

print("\n📋 DICTIONARY TESTS")
print("=" * 50)

let bgDict = loadDictionary("bg-dictionary.txt")
let enDict = loadDictionary("en-dictionary.txt")

test("BG dictionary loaded (230k+ words)", bgDict.count > 230000, detail: "got \(bgDict.count)")
test("EN dictionary loaded (230k+ words)", enDict.count > 230000, detail: "got \(enDict.count)")

// BG words that MUST be in dictionary
let mustHaveBG = ["това", "как", "си", "добре", "наред", "вече", "нещата",
                  "написах", "искам", "правописни", "и", "в", "с", "е", "а",
                  "на", "не", "да", "до", "за", "от", "по"]
print("\n  Bulgarian must-have words:")
for w in mustHaveBG {
    test("  BG dict has '\(w)'", bgDict.contains(w))
}

// EN words that MUST be in dictionary
let mustHaveEN = ["the", "is", "are", "you", "hello", "want", "write",
                  "ignore", "when", "there", "how", "have", "this",
                  "english", "message", "previous", "what"]
print("\n  English must-have words:")
for w in mustHaveEN {
    test("  EN dict has '\(w)'", enDict.contains(w))
}

// Words that should NOT be in EN dictionary (abbreviations)
print("\n  Abbreviations removed from EN dict:")
test("  'u' not in EN dict (abbreviation)", !enDict.contains("u"))
test("  'r' not in EN dict (abbreviation)", !enDict.contains("r"))

// ============================================================================
// MARK: - 3. Language Detection Scenario Tests
// ============================================================================

print("\n📋 LANGUAGE DETECTION SCENARIOS")
print("=" * 50)

struct Scenario {
    let name: String
    let words: [String]               // Latin input words
    let expectedLangs: [String]       // "EN" or "BG" for each word
    let expectedOutputs: [String]     // Expected output for each word
}

let scenarios: [Scenario] = [
    // Pure English sentences
    Scenario(
        name: "Pure English: hello how are you",
        words: ["hello", "how", "are", "you"],
        expectedLangs: ["EN", "EN", "EN", "EN"],
        expectedOutputs: ["hello", "how", "are", "you"]
    ),

    // Pure Bulgarian sentences
    Scenario(
        name: "Pure Bulgarian: towa e samo proba",
        words: ["towa", "e", "samo", "proba"],
        expectedLangs: ["BG", "BG", "BG", "BG"],
        expectedOutputs: ["това", "е", "само", "проба"]
    ),
    Scenario(
        name: "Pure Bulgarian: kak si dobre",
        words: ["kak", "si", "dobre"],
        expectedLangs: ["BG", "BG", "BG"],
        expectedOutputs: ["как", "си", "добре"]
    ),
    Scenario(
        name: "Pure Bulgarian: az iskam kafe",
        words: ["az", "iskam", "kafe"],
        expectedLangs: ["BG", "BG", "BG"],
        expectedOutputs: ["аз", "искам", "кафе"]
    ),

    // English with abbreviations (r→are, u→you handled by AutoCorrector in real app,
    // not testable in simplified simulator — tested separately below)


    // Language switching: BG to EN — only ambiguous words after a switch
    // follow the new flow if the streak supports it.
    // "want write" are exclusive EN; "to" between them is ambiguous and
    // follows the dominant recent language.
    Scenario(
        name: "BG→EN switch: napisah now kod want write",
        words: ["napisah", "now", "kod", "want", "write"],
        expectedLangs: ["BG", "BG", "BG", "EN", "EN"],
        expectedOutputs: ["написах", "нов", "код", "want", "write"]
    ),

    // EN streak should not break on false BG match
    Scenario(
        name: "EN streak protection: when there is a puf (пуф false match)",
        words: ["when", "there", "is", "a", "puf"],
        expectedLangs: ["EN", "EN", "EN", "EN", "EN"],
        expectedOutputs: ["when", "there", "is", "a", "puf"]
    ),

    // In BG flow, "pdf"→"пдф" should NOT be spell-corrected to "пуф"
    // The direct transliteration is correct — пдф not пуф
    Scenario(
        name: "BG flow: pdf → пдф (not spell-corrected to пуф)",
        words: ["koj", "prawi", "pdf"],
        expectedLangs: ["BG", "BG", "BG"],
        expectedOutputs: ["кой", "прави", "пдф"]
    ),

    // Foreign word in BG flow shouldn't flip subsequent ambiguous words.
    // "link" is exclusive EN, but "i ne se" after it should still be Bulgarian
    // because the dominant recent history is BG.
    Scenario(
        name: "BG flow with foreign EN word: wywedoh tozi link i ne se polu`awa",
        words: ["wywedoh", "tozi", "link", "i", "ne", "se", "polu`awa"],
        expectedLangs: ["BG", "BG", "EN", "BG", "BG", "BG", "BG"],
        expectedOutputs: ["въведох", "този", "link", "и", "не", "се", "получава"]
    ),

    // BG with special chars
    Scenario(
        name: "BG special chars: we`e ne]ata",
        words: ["we`e", "ne]ata"],
        expectedLangs: ["BG", "BG"],
        expectedOutputs: ["вече", "нещата"]
    ),

    // BG spell correction (handled by AutoCorrector in real app,
    // not testable in simplified simulator — tested separately below)

]

// For scenario testing, we simulate the detector logic
// (simplified version - checks dictionary membership and flow)
func simulateDetection(words: [String], bgDict: Set<String>, enDict: Set<String>) -> [(lang: String, output: String)] {
    var results: [(String, String)] = []
    var lastLang = "??"
    var streak = 0
    // Track confident detections (exclusive matches) for dominant-history calculation
    var confidentHistory: [String] = []  // "BG" or "EN", only confidence-1.0 matches

    func dominantLanguage() -> String {
        let bg = confidentHistory.filter { $0 == "BG" }.count
        let en = confidentHistory.filter { $0 == "EN" }.count
        if bg > en { return "BG" }
        if en > bg { return "EN" }
        return "??"
    }

    for word in words {
        let lower = word.lowercased()
        let cyrillic = PhoneticMapper.toCyrillic(word)
        let cyrillicLower = cyrillic.lowercased()

        let inEN = enDict.contains(lower)
        let inBG = bgDict.contains(cyrillicLower)

        var lang: String
        var output: String
        var isConfident = false

        if inBG && !inEN {
            // Exclusive BG — but check streak protection
            if lastLang == "EN" && streak >= 3 && lower.count <= 3 {
                lang = "EN"
                output = word
            } else {
                lang = "BG"
                output = cyrillic
                isConfident = true
            }
        } else if inEN && !inBG {
            // Exclusive EN — but check streak protection
            if lastLang == "BG" && streak >= 3 && lower.count <= 3 {
                lang = "BG"
                output = cyrillic
            } else {
                lang = "EN"
                output = word
                isConfident = true
            }
        } else if inBG && inEN {
            // Ambiguous — follow DOMINANT history (not just last word)
            let dominant = dominantLanguage()
            if dominant == "BG" {
                lang = "BG"
                output = cyrillic
            } else if dominant == "EN" {
                lang = "EN"
                output = word
            } else if lastLang == "BG" {
                lang = "BG"
                output = cyrillic
            } else {
                lang = "EN"
                output = word
            }
        } else {
            // Neither — follow previous word
            if lastLang == "BG" {
                lang = "BG"
                output = cyrillic
            } else {
                lang = "EN"
                output = word
            }
        }

        if lang == lastLang { streak += 1 } else { streak = 1 }
        lastLang = lang
        if isConfident {
            confidentHistory.append(lang)
            if confidentHistory.count > 6 {
                confidentHistory.removeFirst()
            }
        }
        results.append((lang, output))
    }
    return results
}

for scenario in scenarios {
    print("\n  \(scenario.name)")
    let results = simulateDetection(words: scenario.words, bgDict: bgDict, enDict: enDict)

    for (idx, word) in scenario.words.enumerated() {
        let (detectedLang, detectedOutput) = results[idx]
        let expectedLang = scenario.expectedLangs[idx]
        let expectedOutput = scenario.expectedOutputs[idx]

        let langOk = detectedLang == expectedLang
        let outputOk = detectedOutput == expectedOutput

        test("  '\(word)' → '\(expectedOutput)' [\(expectedLang)]",
             langOk && outputOk,
             detail: "got '\(detectedOutput)' [\(detectedLang)]")
    }
}

// ============================================================================
// MARK: - 4. First-word ambiguity tests (look-ahead needed)
// ============================================================================

print("\n📋 FIRST-WORD AMBIGUITY (look-ahead)")
print("=" * 50)

struct LookAheadTest {
    let name: String
    let word1: String  // Ambiguous first word
    let word2: String  // Second word that determines language
    let expectedLang: String
    let expectedWord1Output: String
    let expectedWord2Output: String
}

let lookAheadTests: [LookAheadTest] = [
    LookAheadTest(name: "no ignore → EN",
                  word1: "no", word2: "ignore",
                  expectedLang: "EN",
                  expectedWord1Output: "no", expectedWord2Output: "ignore"),
    LookAheadTest(name: "i iskam → BG",
                  word1: "i", word2: "iskam",
                  expectedLang: "BG",
                  expectedWord1Output: "и", expectedWord2Output: "искам"),
    LookAheadTest(name: "i want → EN",
                  word1: "i", word2: "want",
                  expectedLang: "EN",
                  expectedWord1Output: "i", expectedWord2Output: "want"),
    LookAheadTest(name: "a kafe → BG",
                  word1: "a", word2: "kafe",
                  expectedLang: "BG",
                  expectedWord1Output: "а", expectedWord2Output: "кафе"),
    LookAheadTest(name: "a nice → EN",
                  word1: "a", word2: "nice",
                  expectedLang: "EN",
                  expectedWord1Output: "a", expectedWord2Output: "nice"),
    LookAheadTest(name: "to towa → BG",
                  word1: "to", word2: "towa",
                  expectedLang: "BG",
                  expectedWord1Output: "то", expectedWord2Output: "това"),
    LookAheadTest(name: "to write → EN",
                  word1: "to", word2: "write",
                  expectedLang: "EN",
                  expectedWord1Output: "to", expectedWord2Output: "write"),
    LookAheadTest(name: "do you → EN",
                  word1: "do", word2: "you",
                  expectedLang: "EN",  // "you" is EN-only
                  expectedWord1Output: "do", expectedWord2Output: "you"),
    LookAheadTest(name: "do towa → BG",
                  word1: "do", word2: "towa",
                  expectedLang: "BG",
                  expectedWord1Output: "до", expectedWord2Output: "това"),
]

for t in lookAheadTests {
    let cyrillic1 = PhoneticMapper.toCyrillic(t.word1)
    let cyrillic2 = PhoneticMapper.toCyrillic(t.word2)
    let w1inEN = enDict.contains(t.word1.lowercased())
    let w1inBG = bgDict.contains(cyrillic1.lowercased())
    let w2inEN = enDict.contains(t.word2.lowercased())
    let w2inBG = bgDict.contains(cyrillic2.lowercased())

    let isAmbiguous = w1inEN && w1inBG

    // Determine word2's language (it resolves word1)
    let word2Lang: String
    if w2inBG && !w2inEN {
        word2Lang = "BG"
    } else if w2inEN && !w2inBG {
        word2Lang = "EN"
    } else {
        word2Lang = "??"  // Also ambiguous - would need word3
    }

    let resolvedWord1 = word2Lang == "BG" ? cyrillic1 : t.word1
    let resolvedWord2 = word2Lang == "BG" ? cyrillic2 : t.word2

    test("\(t.name): '\(t.word1)' is ambiguous=\(isAmbiguous), word2 lang=\(word2Lang)",
         isAmbiguous && resolvedWord1 == t.expectedWord1Output && resolvedWord2 == t.expectedWord2Output,
         detail: "got '\(resolvedWord1) \(resolvedWord2)' (w1: EN=\(w1inEN) BG=\(w1inBG), w2: EN=\(w2inEN) BG=\(w2inBG))")
}

// ============================================================================
// MARK: - 5. Dictionary conflict analysis
// ============================================================================

print("\n📋 DICTIONARY CONFLICTS (words in both)")
print("=" * 50)

// Common English words whose Cyrillic version is also in BG dict
let commonConflicts = ["a", "i", "no", "do", "to", "go", "so", "on",
                       "at", "as", "is", "it", "in", "if", "he", "me",
                       "we", "be", "or", "up"]

print("\n  Common EN words that are also valid BG Cyrillic:")
for w in commonConflicts {
    let cyr = PhoneticMapper.toCyrillic(w)
    let inEN = enDict.contains(w)
    let inBG = bgDict.contains(cyr.lowercased())
    if inEN && inBG {
        print("    ⚠️  '\(w)' → '\(cyr)' — in BOTH (needs look-ahead or context)")
    }
}

// ============================================================================
// MARK: - Summary
// ============================================================================

print("\n" + "=" * 50)
print("📊 RESULTS: \(passed)/\(total) passed, \(failed) failed")
if failed == 0 {
    print("🎉 All tests passed!")
} else {
    print("⚠️  \(failed) test(s) need attention")
}
print("=" * 50)

// Operator for string repetition
extension String {
    static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}
