import Foundation
import NaturalLanguage

/// Detects whether Latin text typed on QWERTY is English or Bulgarian,
/// converts to the correct script, and applies autocorrect.
///
/// Strategy:
/// 1. Check abbreviation expansions first (u→you, r→are, etc.)
/// 2. Convert to Cyrillic and check both dictionaries
/// 3. If word exists in both → follow previous word's language
/// 4. If neither → follow previous word's language, then NLLanguageRecognizer
/// 5. After language detection, apply spell correction
final class LanguageDetector {

    // MARK: - Types

    enum DetectedLanguage: String {
        case english = "EN"
        case bulgarian = "BG"
        case uncertain = "??"
    }

    struct WordResult {
        let original: String
        let converted: String
        let language: DetectedLanguage
        let confidence: Double
    }

    // MARK: - Default language preference

    private static let defaultLangKey = "LangAutoSwitcher_DefaultLanguage"

    var defaultLanguage: DetectedLanguage {
        get {
            let stored = UserDefaults.standard.string(forKey: Self.defaultLangKey) ?? "EN"
            return DetectedLanguage(rawValue: stored) ?? .english
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultLangKey)
        }
    }

    // MARK: - State

    private var lastWordLanguage: DetectedLanguage = .uncertain
    private var recentLanguages: [DetectedLanguage] = []
    private let contextWindowSize = 6
    private let recognizer = NLLanguageRecognizer()
    private var recentLatinWords: [String] = []
    private let recentWordsMax = 8

    // MARK: - Dictionaries (loaded from bundled files)

    let bgDictionary: Set<String> = {
        guard let url = Bundle.main.url(forResource: "bg-dictionary", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("LangAutoSwitcher: ⚠️ Could not load bg-dictionary.txt!")
            return []
        }
        let words = Set(content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        NSLog("LangAutoSwitcher: Loaded %d Bulgarian words", words.count)
        return words
    }()

    let enDictionary: Set<String> = {
        guard let url = Bundle.main.url(forResource: "en-dictionary", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("LangAutoSwitcher: ⚠️ Could not load en-dictionary.txt!")
            return []
        }
        let words = Set(content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        NSLog("LangAutoSwitcher: Loaded %d English words", words.count)
        return words
    }()

    // MARK: - Autocorrect

    private let autoCorrector = AutoCorrector()

    /// True if no words have been processed yet (no context available).
    var isFirstWord: Bool {
        recentLanguages.isEmpty
    }

    // MARK: - Public

    func processWord(_ word: String) -> WordResult {
        guard PhoneticMapper.isLatinWord(word) else {
            return WordResult(original: word, converted: word,
                              language: .uncertain, confidence: 0)
        }

        let lower = word.lowercased()

        // 1. Check English abbreviation expansion first
        if let expanded = autoCorrector.expandEnglishAbbreviation(lower) {
            // But only expand if we're NOT in a Bulgarian flow
            if lastWordLanguage != .bulgarian {
                pushContext(.english)
                trackLatinWord(word)
                NSLog("LangAutoSwitcher: '%@' → '%@' [EN abbrev]", word, expanded)
                return WordResult(original: word, converted: expanded,
                                  language: .english, confidence: 1.0)
            }
        }

        // 2. Check Bulgarian abbreviation expansion
        if let bgExpanded = autoCorrector.expandBulgarianAbbreviation(lower) {
            if lastWordLanguage == .bulgarian {
                pushContext(.bulgarian)
                trackLatinWord(word)
                NSLog("LangAutoSwitcher: '%@' → '%@' [BG abbrev]", word, bgExpanded)
                return WordResult(original: word, converted: bgExpanded,
                                  language: .bulgarian, confidence: 1.0)
            }
        }

        // 3. Convert to Cyrillic and check both dictionaries
        let cyrillic = PhoneticMapper.toCyrillic(word)
        let cyrillicLower = cyrillic.lowercased()

        let isEnglish = enDictionary.contains(lower)
        let isBulgarian = bgDictionary.contains(cyrillicLower)

        var detected: DetectedLanguage
        var output: String
        var confidence: Double

        let bothLanguages = isBulgarian && isEnglish
        let streakLen = consecutiveStreakLength()

        // LANGUAGE SWITCHING LOGIC:
        // - If the word is in BOTH dictionaries → follow previous word's flow
        // - If the word is ONLY in one dictionary:
        //   - If we have a STRONG streak (3+ words) in the OTHER language,
        //     the exclusive match is likely a false positive (e.g., "pdf"→"пуф").
        //     Keep the current flow.
        //   - If the streak is weak (0-2 words), trust the dictionary match
        //     and allow language switching.

        if bothLanguages {
            // In BOTH dictionaries → follow previous word's language
            let result = resolveAmbiguous(word: word, cyrillic: cyrillic)
            detected = result.0
            output = result.1
            confidence = result.2
        } else if isBulgarian && !isEnglish {
            // Word is ONLY in BG dictionary.
            // But if we have a strong English streak AND the word is short,
            // it's likely a false match (e.g., "pdf"→"пуф").
            // Short words (≤3 chars) are much more likely to be false matches.
            // Longer words (4+) are intentional language switches.
            if lastWordLanguage == .english && streakLen >= 3 && lower.count <= 3 {
                detected = .english
                output = word
                confidence = 0.6
            } else {
                detected = .bulgarian
                output = cyrillic
                confidence = 1.0
            }
        } else if isEnglish && !isBulgarian {
            if lastWordLanguage == .bulgarian && streakLen >= 3 && lower.count <= 3 {
                detected = .bulgarian
                output = cyrillic
                confidence = 0.6
            } else {
                detected = .english
                output = word
                confidence = 1.0
            }
        } else {
            // In NEITHER dictionary — respect the current flow first.
            // Only try spell correction if it agrees with the flow.
            // This prevents "pdf"→"пдф"→spell correct→"пуф" when in English flow.

            if lastWordLanguage == .english && streakLen >= 2 {
                // In English flow — try English spell correction only
                let enSpellCorrection = autoCorrector.correctEnglish(word, dictionary: enDictionary)
                if let corrected = enSpellCorrection {
                    detected = .english
                    output = corrected
                    confidence = 0.8
                } else {
                    // No EN correction — keep as Latin (it's probably an acronym like "pdf")
                    detected = .english
                    output = word
                    confidence = 0.5
                }
            } else if lastWordLanguage == .bulgarian && streakLen >= 2 {
                // In Bulgarian flow — just transliterate directly.
                // Don't spell-correct: "пдф" should stay "пдф", not become "пуф".
                // The user typed exactly what they meant (acronym, foreign word, etc.)
                detected = .bulgarian
                output = cyrillic
                confidence = 0.5
            } else {
                // No clear flow — try both spell corrections
                let enSpellCorrection = autoCorrector.correctEnglish(word, dictionary: enDictionary)
                let bgSpellCorrection = autoCorrector.correctBulgarian(cyrillic, dictionary: bgDictionary)

                if bgSpellCorrection != nil && enSpellCorrection == nil {
                    detected = .bulgarian
                    output = bgSpellCorrection!
                    confidence = 0.8
                } else if enSpellCorrection != nil && bgSpellCorrection == nil {
                    detected = .english
                    output = enSpellCorrection!
                    confidence = 0.8
                } else if enSpellCorrection != nil && bgSpellCorrection != nil {
                    if lastWordLanguage == .bulgarian {
                        detected = .bulgarian
                        output = bgSpellCorrection!
                        confidence = 0.7
                    } else if lastWordLanguage == .english {
                        detected = .english
                        output = enSpellCorrection!
                        confidence = 0.7
                    } else {
                        let result = resolveUnknown(word: word, cyrillic: cyrillic)
                        detected = result.0
                        output = result.1
                        confidence = result.2
                    }
                } else {
                    let result = resolveUnknown(word: word, cyrillic: cyrillic)
                    detected = result.0
                    output = result.1
                    confidence = result.2
                }
            }
        }

        // 4. Apply spell correction AFTER language detection
        // Only for words that were found in a dictionary (not already spell-corrected above)
        if detected == .english && confidence >= 1.0 {
            if let corrected = autoCorrector.correctEnglish(output, dictionary: enDictionary) {
                NSLog("LangAutoSwitcher: spell EN '%@' → '%@'", output, corrected)
                output = corrected
            }
        } else if detected == .bulgarian && confidence >= 1.0 {
            if let corrected = autoCorrector.correctBulgarian(output, dictionary: bgDictionary) {
                NSLog("LangAutoSwitcher: spell BG '%@' → '%@'", output, corrected)
                output = corrected
            }
        }

        pushContext(detected, confidence: confidence)
        trackLatinWord(word)

        NSLog("LangAutoSwitcher: '%@' → '%@' [%@] (inBG=%d, inEN=%d, conf=%.2f)",
              word, output, detected.rawValue, isBulgarian, isEnglish, confidence)

        return WordResult(original: word, converted: output,
                          language: detected, confidence: confidence)
    }

    func resetContext() {
        recentLanguages.removeAll()
        recentLatinWords.removeAll()
        recentConfidences.removeAll()
        lastWordLanguage = .uncertain
    }

    // MARK: - Ambiguous resolution

    private func resolveAmbiguous(word: String, cyrillic: String) -> (DetectedLanguage, String, Double) {
        if lastWordLanguage == .bulgarian {
            return (.bulgarian, cyrillic, 0.9)
        } else if lastWordLanguage == .english {
            return (.english, word, 0.9)
        }

        let contextPhrase = (recentLatinWords + [word]).joined(separator: " ")
        let contextCyrillic = PhoneticMapper.toCyrillic(contextPhrase)
        let enScore = scoreEnglish(contextPhrase)
        let bgScore = scoreBulgarian(contextCyrillic)

        if bgScore > enScore + 0.1 {
            return (.bulgarian, cyrillic, bgScore)
        } else if enScore > bgScore + 0.1 {
            return (.english, word, enScore)
        }

        if defaultLanguage == .bulgarian {
            return (.bulgarian, cyrillic, 0.5)
        }
        return (.english, word, 0.5)
    }

    // MARK: - Unknown resolution

    private func resolveUnknown(word: String, cyrillic: String) -> (DetectedLanguage, String, Double) {
        if lastWordLanguage == .bulgarian {
            return (.bulgarian, cyrillic, 0.7)
        } else if lastWordLanguage == .english {
            return (.english, word, 0.7)
        }

        let enScore = scoreEnglish(word)
        let bgScore = scoreBulgarian(cyrillic)

        if recentLatinWords.count >= 2 {
            let contextPhrase = (recentLatinWords + [word]).joined(separator: " ")
            let contextCyrillic = PhoneticMapper.toCyrillic(contextPhrase)
            let enCtx = scoreEnglish(contextPhrase)
            let bgCtx = scoreBulgarian(contextCyrillic)

            let blendEn = enScore * 0.4 + enCtx * 0.6
            let blendBg = bgScore * 0.4 + bgCtx * 0.6

            if blendBg > 0.5 && blendBg > blendEn + 0.15 {
                return (.bulgarian, cyrillic, blendBg)
            } else if blendEn > 0.5 && blendEn > blendBg + 0.15 {
                return (.english, word, blendEn)
            }
        } else {
            if bgScore > 0.5 && bgScore > enScore + 0.15 {
                return (.bulgarian, cyrillic, bgScore)
            } else if enScore > 0.5 && enScore > bgScore + 0.15 {
                return (.english, word, enScore)
            }
        }

        if defaultLanguage == .bulgarian {
            return (.bulgarian, cyrillic, 0.3)
        }
        return (.english, word, 0.3)
    }

    // MARK: - Scoring

    private func scoreEnglish(_ text: String) -> Double {
        recognizer.reset()
        recognizer.languageConstraints = [.english, .bulgarian, .russian,
                                          .german, .french, .spanish, .italian]
        recognizer.processString(text)
        let hyp = recognizer.languageHypotheses(withMaximum: 10)
        return hyp[.english] ?? 0.0
    }

    private func scoreBulgarian(_ cyrillicText: String) -> Double {
        recognizer.reset()
        recognizer.languageConstraints = [.bulgarian, .russian, .ukrainian, .english]
        recognizer.processString(cyrillicText)
        let hyp = recognizer.languageHypotheses(withMaximum: 10)
        let bg = hyp[.bulgarian] ?? 0.0
        let ru = hyp[.russian] ?? 0.0
        return bg + ru * 0.4
    }

    // MARK: - Context

    /// Tracks confidence of each detection. Only high-confidence detections
    /// (exclusive dictionary matches) count toward streaks.
    private var recentConfidences: [Double] = []

    private func pushContext(_ lang: DetectedLanguage, confidence: Double = 1.0) {
        guard lang != .uncertain else { return }
        lastWordLanguage = lang
        recentLanguages.append(lang)
        recentConfidences.append(confidence)
        if recentLanguages.count > contextWindowSize {
            recentLanguages.removeFirst()
            recentConfidences.removeFirst()
        }
    }

    private func trackLatinWord(_ word: String) {
        recentLatinWords.append(word)
        if recentLatinWords.count > recentWordsMax {
            recentLatinWords.removeFirst()
        }
    }

    /// Count consecutive recent words that are the SAME language as lastWordLanguage
    /// AND were detected with high confidence (exclusive dictionary match).
    /// Ambiguous/unknown words don't count — they just followed the flow.
    private func consecutiveStreakLength() -> Int {
        guard lastWordLanguage != .uncertain else { return 0 }
        var count = 0
        for (idx, lang) in recentLanguages.enumerated().reversed() {
            if lang == lastWordLanguage && recentConfidences[idx] >= 0.9 {
                count += 1
            } else if lang == lastWordLanguage {
                // Same language but low confidence — don't count, but don't break streak
                continue
            } else {
                break
            }
        }
        return count
    }
}
