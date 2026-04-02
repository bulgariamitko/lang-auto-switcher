import Foundation
import NaturalLanguage

/// Detects whether Latin text typed on QWERTY is English or Bulgarian
/// (typed using the phonetic keyboard mental model).
///
/// Uses Apple's NLLanguageRecognizer on the Cyrillic-converted text,
/// plus contextual hints from previously committed words.
final class LanguageDetector {

    // MARK: - Types

    enum DetectedLanguage: String {
        case english = "EN"
        case bulgarian = "BG"
        case uncertain = "??"
    }

    struct WordResult {
        let original: String           // What the user typed (Latin)
        let converted: String          // Output: Latin or Cyrillic
        let language: DetectedLanguage
        let confidence: Double         // 0.0–1.0
    }

    // MARK: - State

    /// Rolling context of recent detected languages.
    private var recentLanguages: [DetectedLanguage] = []
    private let contextWindowSize = 6

    private let recognizer = NLLanguageRecognizer()

    // MARK: - Public

    /// Process a single Latin word and decide if it's EN or BG.
    func processWord(_ word: String) -> WordResult {
        guard PhoneticMapper.isLatinWord(word) else {
            return WordResult(original: word, converted: word,
                              language: .uncertain, confidence: 0)
        }

        let cyrillic = PhoneticMapper.toCyrillic(word)

        // Get raw scores from NLLanguageRecognizer
        let enScore = scoreEnglish(word)
        let bgScore = scoreBulgarian(cyrillic)

        // Context bias
        let bias = contextBias()
        let adjEn = enScore + (bias == .english ? 0.12 : 0.0)
        let adjBg = bgScore + (bias == .bulgarian ? 0.12 : 0.0)

        let detected: DetectedLanguage
        let output: String
        let confidence: Double

        if adjBg > adjEn && bgScore > 0.25 {
            detected = .bulgarian
            output = cyrillic
            confidence = bgScore
        } else if adjEn >= adjBg && enScore > 0.2 {
            detected = .english
            output = word
            confidence = enScore
        } else {
            // Truly ambiguous — use context, default English
            if bias == .bulgarian && bgScore > 0.15 {
                detected = .bulgarian
                output = cyrillic
                confidence = bgScore
            } else {
                detected = .english
                output = word
                confidence = max(enScore, 0.1)
            }
        }

        pushContext(detected)
        return WordResult(original: word, converted: output,
                          language: detected, confidence: confidence)
    }

    /// Process a multi-word buffer at once (more context = better detection).
    func processBuffer(_ text: String) -> WordResult {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return WordResult(original: text, converted: text,
                              language: .uncertain, confidence: 0)
        }

        let cyrillic = PhoneticMapper.toCyrillic(trimmed)
        let enScore = scoreEnglish(trimmed)
        let bgScore = scoreBulgarian(cyrillic)

        if bgScore > enScore && bgScore > 0.25 {
            pushContext(.bulgarian)
            return WordResult(original: trimmed, converted: cyrillic,
                              language: .bulgarian, confidence: bgScore)
        } else {
            pushContext(.english)
            return WordResult(original: trimmed, converted: trimmed,
                              language: .english, confidence: enScore)
        }
    }

    /// Clear context (e.g., user switched apps or text fields).
    func resetContext() {
        recentLanguages.removeAll()
    }

    // MARK: - Scoring

    private func scoreEnglish(_ text: String) -> Double {
        recognizer.reset()
        recognizer.languageConstraints = [.english, .bulgarian, .russian,
                                          .german, .french, .spanish]
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
        // Russian is close enough to Bulgarian in Cyrillic — count it partially
        return bg + ru * 0.4
    }

    // MARK: - Context

    private func pushContext(_ lang: DetectedLanguage) {
        guard lang != .uncertain else { return }
        recentLanguages.append(lang)
        if recentLanguages.count > contextWindowSize {
            recentLanguages.removeFirst()
        }
    }

    private func contextBias() -> DetectedLanguage {
        guard recentLanguages.count >= 2 else { return .uncertain }
        let bg = recentLanguages.filter { $0 == .bulgarian }.count
        let en = recentLanguages.filter { $0 == .english }.count
        if bg > en { return .bulgarian }
        if en > bg { return .english }
        return .uncertain
    }
}
