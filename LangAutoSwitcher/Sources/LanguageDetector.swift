import Foundation
import AppKit
import NaturalLanguage

// MARK: - Top-level C callbacks (installed into the Rust core at init time)
//
// These have to be top-level @convention(c) closures because Rust function
// pointers cannot capture Swift environment. NSSpellChecker / NLLanguageRecognizer
// are singletons so the callbacks just use the shared instances.

private let sharedSpellChecker = NSSpellChecker.shared
private let sharedRecognizer = NLLanguageRecognizer()

private func writeStringToBuffer(_ s: String, _ buf: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int32 {
    guard let buf = buf, !s.isEmpty else { return 0 }
    let bytes = Array(s.utf8)
    let copyLen = min(bytes.count, size - 1)
    bytes.withUnsafeBufferPointer { src in
        if let base = src.baseAddress {
            base.withMemoryRebound(to: CChar.self, capacity: copyLen) { srcChar in
                buf.update(from: srcChar, count: copyLen)
            }
        }
    }
    buf[copyLen] = 0
    return 1
}

private func runSpellCheck(_ word: String, language: String) -> String? {
    let range = NSRange(location: 0, length: word.utf16.count)
    return sharedSpellChecker.correction(
        forWordRange: range,
        in: word,
        language: language,
        inSpellDocumentWithTag: 0
    )
}

private let enSpellCheckCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int32 = { wordPtr, outBuf, size in
    guard let wordPtr = wordPtr else { return 0 }
    let word = String(cString: wordPtr)
    guard let correction = runSpellCheck(word, language: "en") else { return 0 }
    return writeStringToBuffer(correction, outBuf, size)
}

private let bgSpellCheckCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int32 = { wordPtr, outBuf, size in
    guard let wordPtr = wordPtr else { return 0 }
    let word = String(cString: wordPtr)
    guard let correction = runSpellCheck(word, language: "bg") else { return 0 }
    return writeStringToBuffer(correction, outBuf, size)
}

private let englishScoreCallback: @convention(c) (UnsafePointer<CChar>?) -> Double = { textPtr in
    guard let textPtr = textPtr else { return 0 }
    let text = String(cString: textPtr)
    sharedRecognizer.reset()
    sharedRecognizer.languageConstraints = [.english, .bulgarian, .russian,
                                            .german, .french, .spanish, .italian]
    sharedRecognizer.processString(text)
    let hyp = sharedRecognizer.languageHypotheses(withMaximum: 10)
    return hyp[.english] ?? 0.0
}

private let bulgarianScoreCallback: @convention(c) (UnsafePointer<CChar>?) -> Double = { textPtr in
    guard let textPtr = textPtr else { return 0 }
    let text = String(cString: textPtr)
    sharedRecognizer.reset()
    sharedRecognizer.languageConstraints = [.bulgarian, .russian, .ukrainian, .english]
    sharedRecognizer.processString(text)
    let hyp = sharedRecognizer.languageHypotheses(withMaximum: 10)
    let bg = hyp[.bulgarian] ?? 0.0
    let ru = hyp[.russian] ?? 0.0
    return bg + ru * 0.4
}

// MARK: - LanguageDetector (Swift facade over the Rust core)

final class LanguageDetector {

    enum DetectedLanguage: String {
        case english = "EN"
        case bulgarian = "BG"
        case uncertain = "??"

        fileprivate var asInt: Int32 {
            switch self {
            case .english:   return LANGAUTO_LANG_ENGLISH
            case .bulgarian: return LANGAUTO_LANG_BULGARIAN
            case .uncertain: return LANGAUTO_LANG_UNCERTAIN
            }
        }

        fileprivate static func fromInt(_ i: Int32) -> DetectedLanguage {
            switch i {
            case LANGAUTO_LANG_BULGARIAN: return .bulgarian
            case LANGAUTO_LANG_UNCERTAIN: return .uncertain
            default: return .english
            }
        }
    }

    struct WordResult {
        let original: String
        let converted: String
        let language: DetectedLanguage
        let confidence: Double
    }

    /// Dictionary façade — exposes `.contains(_:)` so InputController doesn't need to change.
    struct DictionaryProxy {
        fileprivate let detector: OpaquePointer
        fileprivate let language: DictionaryLanguage

        enum DictionaryLanguage { case en, bg }

        func contains(_ word: String) -> Bool {
            word.withCString { cstr in
                switch language {
                case .en: return langauto_detector_word_in_en_dict(detector, cstr) == 1
                case .bg: return langauto_detector_word_in_bg_dict(detector, cstr) == 1
                }
            }
        }
    }

    // MARK: state

    private let ptr: OpaquePointer
    private static let defaultLangKey = "LangAutoSwitcher_DefaultLanguage"
    private static let autocorrectKey = "LangAutoSwitcher_AutocorrectEnabled"

    var defaultLanguage: DetectedLanguage {
        get {
            DetectedLanguage.fromInt(langauto_detector_get_default_language(ptr))
        }
        set {
            langauto_detector_set_default_language(ptr, newValue.asInt)
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultLangKey)
        }
    }

    /// Toggle for abbreviation expansion (w→with), spell-check suggestions,
    /// and edit-distance-1 matching. Off by default — users explicitly asked
    /// for raw transliteration without "helpful" rewrites.
    var autocorrectEnabled: Bool {
        get {
            langauto_detector_get_autocorrect_enabled(ptr) == 1
        }
        set {
            langauto_detector_set_autocorrect_enabled(ptr, newValue ? 1 : 0)
            UserDefaults.standard.set(newValue, forKey: Self.autocorrectKey)
        }
    }

    var isFirstWord: Bool {
        langauto_detector_is_first_word(ptr) == 1
    }

    var enDictionary: DictionaryProxy { DictionaryProxy(detector: ptr, language: .en) }
    var bgDictionary: DictionaryProxy { DictionaryProxy(detector: ptr, language: .bg) }

    init() {
        let enURL = Bundle.main.url(forResource: "en-dictionary", withExtension: "txt")
        let bgURL = Bundle.main.url(forResource: "bg-dictionary", withExtension: "txt")
        let enText = (try? enURL.flatMap { try String(contentsOf: $0, encoding: .utf8) }) ?? ""
        let bgText = (try? bgURL.flatMap { try String(contentsOf: $0, encoding: .utf8) }) ?? ""

        let handle: OpaquePointer? = enText.withCString { enCStr in
            bgText.withCString { bgCStr in
                langauto_detector_new(enCStr, bgCStr)
            }
        }
        guard let handle = handle else {
            fatalError("LangAutoSwitcher: failed to create Rust detector — dictionaries missing?")
        }
        self.ptr = handle

        // Install platform callbacks
        langauto_detector_set_en_spell_check(self.ptr, enSpellCheckCallback)
        langauto_detector_set_bg_spell_check(self.ptr, bgSpellCheckCallback)
        langauto_detector_set_en_score(self.ptr, englishScoreCallback)
        langauto_detector_set_bg_score(self.ptr, bulgarianScoreCallback)

        // Restore persisted default language preference
        if let stored = UserDefaults.standard.string(forKey: Self.defaultLangKey),
           let lang = DetectedLanguage(rawValue: stored) {
            langauto_detector_set_default_language(self.ptr, lang.asInt)
        }

        // Restore persisted autocorrect preference (default: off).
        // We only flip it on if the user explicitly enabled it before.
        if UserDefaults.standard.object(forKey: Self.autocorrectKey) != nil {
            let on = UserDefaults.standard.bool(forKey: Self.autocorrectKey)
            langauto_detector_set_autocorrect_enabled(self.ptr, on ? 1 : 0)
        }

        NSLog("LangAutoSwitcher: initialized Rust core")
    }

    deinit {
        langauto_detector_free(ptr)
    }

    func processWord(_ word: String) -> WordResult {
        var outLang: Int32 = LANGAUTO_LANG_UNCERTAIN
        var outConf: Double = 0
        let converted: String = word.withCString { cstr in
            guard let out = langauto_detector_process_word(ptr, cstr, &outLang, &outConf) else { return word }
            defer { langauto_string_free(out) }
            return String(cString: out)
        }
        return WordResult(
            original: word,
            converted: converted,
            language: DetectedLanguage.fromInt(outLang),
            confidence: outConf
        )
    }

    func resetContext() {
        langauto_detector_reset_context(ptr)
    }
}
