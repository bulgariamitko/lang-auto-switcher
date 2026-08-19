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
    // size must leave room for at least the null terminator; size <= 0 would
    // underflow the copy-length math below.
    guard let buf = buf, !s.isEmpty, size > 1 else { return 0 }
    let bytes = Array(s.utf8)
    var copyLen = min(bytes.count, size - 1)
    // Never truncate mid-UTF-8-sequence: back off past continuation bytes
    // (0b10xxxxxx) so the receiver always gets valid UTF-8.
    while copyLen > 0 && copyLen < bytes.count && (bytes[copyLen] & 0b1100_0000) == 0b1000_0000 {
        copyLen -= 1
    }
    guard copyLen > 0 else { return 0 }
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
        fileprivate let detector: OpaquePointer?
        fileprivate let language: DictionaryLanguage

        enum DictionaryLanguage { case en, bg }

        func contains(_ word: String) -> Bool {
            guard let detector = detector else { return false }
            return word.withCString { cstr in
                switch language {
                case .en: return langauto_detector_word_in_en_dict(detector, cstr) == 1
                case .bg: return langauto_detector_word_in_bg_dict(detector, cstr) == 1
                }
            }
        }
    }

    // MARK: state

    /// One detector per process. Dictionaries hold ~468k entries; IMK creates
    /// an InputController per focused text field, so a per-controller detector
    /// would re-parse and re-allocate everything on every focus change.
    static let shared = LanguageDetector()

    /// Nil when the Rust core couldn't be created (corrupt/missing
    /// dictionaries). The detector then degrades to pass-through: every word
    /// goes out exactly as typed.
    private let ptr: OpaquePointer?
    private static let defaultLangKey = "LangAutoSwitcher_DefaultLanguage"
    private static let autocorrectKey = "LangAutoSwitcher_AutocorrectEnabled"
    private static let typoCorrectionKey = "LangAutoSwitcher_TypoCorrectionEnabled"

    var defaultLanguage: DetectedLanguage {
        get {
            guard let ptr = ptr else { return .english }
            return DetectedLanguage.fromInt(langauto_detector_get_default_language(ptr))
        }
        set {
            if let ptr = ptr {
                langauto_detector_set_default_language(ptr, newValue.asInt)
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultLangKey)
        }
    }

    /// Toggle for abbreviation expansion (w→with), spell-check suggestions,
    /// and edit-distance-1 matching. Off by default — users explicitly asked
    /// for raw transliteration without "helpful" rewrites.
    var autocorrectEnabled: Bool {
        get {
            guard let ptr = ptr else { return false }
            return langauto_detector_get_autocorrect_enabled(ptr) == 1
        }
        set {
            if let ptr = ptr {
                langauto_detector_set_autocorrect_enabled(ptr, newValue ? 1 : 0)
            }
            UserDefaults.standard.set(newValue, forKey: Self.autocorrectKey)
        }
    }

    /// Bulgarian typo rescue ("изтриеп" → "изтриеш", "можешда" → "можеш да").
    /// On by default; independent of the aggressive `autocorrectEnabled`.
    var typoCorrectionEnabled: Bool {
        get {
            guard let ptr = ptr else { return false }
            return langauto_detector_get_typo_correction_enabled(ptr) == 1
        }
        set {
            if let ptr = ptr {
                langauto_detector_set_typo_correction_enabled(ptr, newValue ? 1 : 0)
            }
            UserDefaults.standard.set(newValue, forKey: Self.typoCorrectionKey)
        }
    }

    var isFirstWord: Bool {
        guard let ptr = ptr else { return true }
        return langauto_detector_is_first_word(ptr) == 1
    }

    /// True when the word to the left was pinned by an exact hit in exactly
    /// one dictionary. `InputController` uses this to decide whether an
    /// ambiguous word needs to wait for the word on its right: when the left
    /// side is already this decisive, waiting would only add a visible delay.
    var lastContextIsDecisive: Bool {
        guard let ptr = ptr else { return false }
        return langauto_detector_last_context_is_decisive(ptr) == 1
    }

    /// (english, bulgarian) dictionary entry counts — shown in Diagnostics.
    var dictionaryCounts: (en: Int, bg: Int) {
        guard let ptr = ptr else { return (0, 0) }
        var en: size_t = 0
        var bg: size_t = 0
        langauto_detector_dict_counts(ptr, &en, &bg)
        return (Int(en), Int(bg))
    }

    /// Number of learned ("always Latin") words currently active in the core.
    var learnedWordCount: Int {
        guard let ptr = ptr else { return 0 }
        return Int(langauto_detector_user_latin_word_count(ptr))
    }

    /// Number of forced ("always Bulgarian") words currently active in the core.
    var forcedBgWordCount: Int {
        guard let ptr = ptr else { return 0 }
        return Int(langauto_detector_user_bg_word_count(ptr))
    }

    /// True when the Rust core failed to initialize and we pass keystrokes
    /// through unconverted.
    var isPassThrough: Bool { ptr == nil }

    // MARK: learned words

    /// Remember `word` as always-Latin: persists it and updates the live core.
    func learnLatinWord(_ word: String) {
        UserWordsManager.add(word)
        if let ptr = ptr {
            word.withCString { langauto_detector_add_user_latin_word(ptr, $0) }
        }
    }

    /// Forget all learned words (persisted + live core).
    func clearLearnedWords() {
        UserWordsManager.clear()
        if let ptr = ptr {
            langauto_detector_clear_user_latin_words(ptr)
        }
    }

    /// Remember `word` as always-Bulgarian: persists it and updates the live
    /// core. `word` is the Latin spelling the user typed.
    func learnBulgarianWord(_ word: String) {
        UserWordsManager.addBg(word)
        guard let ptr = ptr else { return }
        // Newest wins: drop any opposite always-Latin entry from the live core
        // (UserWordsManager already did so on disk).
        word.withCString {
            _ = langauto_detector_remove_user_latin_word(ptr, $0)
            langauto_detector_add_user_bg_word(ptr, $0)
        }
    }

    /// Forget all forced ("always Bulgarian") words (persisted + live core).
    func clearForcedBgWords() {
        UserWordsManager.clearBg()
        if let ptr = ptr {
            langauto_detector_clear_user_bg_words(ptr)
        }
    }

    /// Re-read learned_words.json (e.g., after a hand edit) into the live core.
    /// Refreshes BOTH the always-Latin and always-Bulgarian sets.
    func reloadLearnedWords() {
        UserWordsManager.reload()
        guard let ptr = ptr else { return }
        langauto_detector_clear_user_latin_words(ptr)
        langauto_detector_clear_user_bg_words(ptr)
        for word in UserWordsManager.all() {
            word.withCString { langauto_detector_add_user_latin_word(ptr, $0) }
        }
        for word in UserWordsManager.allBg() {
            word.withCString { langauto_detector_add_user_bg_word(ptr, $0) }
        }
        NSLog("LangAutoSwitcher: reloaded %d always-Latin + %d always-Bulgarian word(s) into core",
              learnedWordCount, forcedBgWordCount)
    }

    var enDictionary: DictionaryProxy { DictionaryProxy(detector: ptr, language: .en) }
    var bgDictionary: DictionaryProxy { DictionaryProxy(detector: ptr, language: .bg) }

    /// Languages the detector was built with, in pack order. Index 0 is the
    /// Latin base.
    private(set) var activeLanguages: [String] = []

    /// Display names for the menu, keyed by language code.
    private(set) var languageNames: [String: String] = [:]

    /// Vowels, which a keyboard layout cannot tell us. Needed for the guard
    /// that refuses to "correct" a word by swapping its final vowel, since in
    /// inflected languages that is a different grammatical form rather than a
    /// typo. A language we have no list for simply loses that guard.
    private static func vowels(for code: String) -> String {
        switch code {
        case "bg": return "аеиоуъюяь"
        case "ru", "uk", "sr", "mk", "be": return "аеиоуыэюяёіїєь"
        case "el":  return "αειουηω"
        default:    return "aeiouyåäöéèü"
        }
    }

    /// Letters people mix up because the layout disagrees with how they would
    /// romanise the language — not because the keys are close together. Only
    /// pairs we have evidence for are listed.
    private static func confusablePairs(for code: String) -> [(UInt32, UInt32)] {
        let pairs: [(Character, Character)]
        switch code {
        case "bg":
            // 'v' types ж where people mean в, 'y' types ъ where they mean й,
            // 'x' types ь where they mean х. All three are real reports.
            pairs = [("ж", "в"), ("ъ", "й"), ("ь", "х")]
        default:
            pairs = []
        }
        return pairs.compactMap { a, b in
            guard let x = a.unicodeScalars.first, let y = b.unicodeScalars.first else { return nil }
            return (x.value, y.value)
        }
    }

    private init() {
        // Which languages, and how each is typed, both come from the system
        // rather than from hardcoded tables: the enabled list from the user's
        // own input-source preference, the keymaps from macOS's own layouts.
        let codes = LanguagePackStore.enabledCodes()
        let layouts = Dictionary(
            KeyboardLayoutReader.availableLanguages().map { ($0.languageCode, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let handle = langauto_detector_new_empty()
        self.ptr = handle
        guard let handle = handle else {
            NSLog("LangAutoSwitcher: ERROR — failed to create Rust detector; running in pass-through mode")
            return
        }

        for code in codes {
            guard let dict = LanguagePackStore.dictionaryText(for: code) else {
                NSLog("LangAutoSwitcher: no dictionary installed for '%@' — skipping", code)
                continue
            }
            let layout = layouts[code]
            let isBase = (code == LanguagePackStore.baseCode)
            // A Latin-script language needs only the letters a US keyboard
            // lacks (Swedish å/ä/ö); everything else keeps its full keymap.
            let pairs = layout?.keymap ?? []
            let name = layout?.displayName ?? code

            var keys: [UInt32] = []
            var letters: [UInt32] = []
            for (k, l) in pairs {
                guard let ks = k.unicodeScalars.first, let ls = l.unicodeScalars.first,
                      k.unicodeScalars.count == 1, l.unicodeScalars.count == 1 else { continue }
                keys.append(ks.value)
                letters.append(ls.value)
            }
            let vowels = Self.vowels(for: code)
            let confusables = Self.confusablePairs(for: code)
            var ca = confusables.map { $0.0 }
            var cb = confusables.map { $0.1 }

            let index = code.withCString { idC in
                name.withCString { nameC in
                    dict.withCString { dictC in
                        vowels.withCString { vowelC in
                            keys.withUnsafeBufferPointer { kBuf in
                                letters.withUnsafeBufferPointer { lBuf in
                                    ca.withUnsafeMutableBufferPointer { aBuf in
                                        cb.withUnsafeMutableBufferPointer { bBuf in
                                            langauto_detector_add_pack(
                                                handle, idC, nameC, dictC,
                                                kBuf.baseAddress, lBuf.baseAddress, kBuf.count,
                                                vowelC,
                                                aBuf.baseAddress, bBuf.baseAddress, aBuf.count,
                                                isBase ? 1 : 0)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if index >= 0 {
                activeLanguages.append(code)
                languageNames[code] = name
                NSLog("LangAutoSwitcher: language '%@' (%@) ready — %d keys, %d words",
                      code, name, keys.count, dict.split(separator: "\n").count)
            }
        }

        if activeLanguages.isEmpty {
            NSLog("LangAutoSwitcher: WARNING — no languages available; running in pass-through mode")
        }

        let ptr = handle

        // Install platform callbacks
        langauto_detector_set_en_spell_check(ptr, enSpellCheckCallback)
        langauto_detector_set_bg_spell_check(ptr, bgSpellCheckCallback)
        langauto_detector_set_en_score(ptr, englishScoreCallback)
        langauto_detector_set_bg_score(ptr, bulgarianScoreCallback)

        // Restore persisted default language preference
        if let stored = UserDefaults.standard.string(forKey: Self.defaultLangKey),
           let lang = DetectedLanguage(rawValue: stored) {
            langauto_detector_set_default_language(ptr, lang.asInt)
        }

        // Restore persisted autocorrect preference (default: off).
        // We only flip it on if the user explicitly enabled it before.
        if UserDefaults.standard.object(forKey: Self.autocorrectKey) != nil {
            let on = UserDefaults.standard.bool(forKey: Self.autocorrectKey)
            langauto_detector_set_autocorrect_enabled(ptr, on ? 1 : 0)
        }

        // Restore persisted typo-correction preference (default: on).
        if UserDefaults.standard.object(forKey: Self.typoCorrectionKey) != nil {
            let on = UserDefaults.standard.bool(forKey: Self.typoCorrectionKey)
            langauto_detector_set_typo_correction_enabled(ptr, on ? 1 : 0)
        }

        // Push learned ("always Latin") words into the core.
        for word in UserWordsManager.all() {
            word.withCString { langauto_detector_add_user_latin_word(ptr, $0) }
        }
        // Push forced ("always Bulgarian") words into the core.
        for word in UserWordsManager.allBg() {
            word.withCString { langauto_detector_add_user_bg_word(ptr, $0) }
        }

        NSLog("LangAutoSwitcher: initialized Rust core")
    }

    deinit {
        if let ptr = ptr {
            langauto_detector_free(ptr)
        }
    }

    func processWord(_ word: String) -> WordResult {
        guard let ptr = ptr else {
            // Pass-through mode: the core never came up, keep the word as typed.
            return WordResult(original: word, converted: word, language: .uncertain, confidence: 0)
        }
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

    /// Decide a held-back word using the words on both sides of it, then
    /// decide the word that followed. Returns both in insertion order.
    ///
    /// Falls back to plain sequential processing in pass-through mode or if
    /// the core hands back a null string.
    func resolvePending(_ pending: String, next: String) -> (pending: WordResult, next: WordResult) {
        guard let ptr = ptr else {
            return (WordResult(original: pending, converted: pending, language: .uncertain, confidence: 0),
                    WordResult(original: next, converted: next, language: .uncertain, confidence: 0))
        }

        var pendingLang: Int32 = LANGAUTO_LANG_UNCERTAIN
        var nextOut: UnsafeMutablePointer<CChar>? = nil
        var nextLang: Int32 = LANGAUTO_LANG_UNCERTAIN
        var nextConf: Double = 0

        let pendingConverted: String? = pending.withCString { pStr in
            next.withCString { nStr in
                guard let out = langauto_detector_resolve_pending(
                    ptr, pStr, nStr, &pendingLang, &nextOut, &nextLang, &nextConf
                ) else { return nil }
                defer { langauto_string_free(out) }
                return String(cString: out)
            }
        }

        guard let pendingConverted = pendingConverted else {
            // Core declined — keep the old sequential behaviour rather than
            // dropping either word.
            return (processWord(pending), processWord(next))
        }

        let nextConverted: String
        if let nextOut = nextOut {
            nextConverted = String(cString: nextOut)
            langauto_string_free(nextOut)
        } else {
            nextConverted = next
        }

        return (
            WordResult(original: pending, converted: pendingConverted,
                       language: DetectedLanguage.fromInt(pendingLang), confidence: 0),
            WordResult(original: next, converted: nextConverted,
                       language: DetectedLanguage.fromInt(nextLang), confidence: nextConf)
        )
    }

    func resetContext() {
        if let ptr = ptr {
            langauto_detector_reset_context(ptr)
        }
    }
}
