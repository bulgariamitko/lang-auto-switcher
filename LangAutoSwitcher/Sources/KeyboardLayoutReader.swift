import Carbon
import Foundation

/// Reads keyboard layouts out of macOS instead of hardcoding them.
///
/// macOS already knows how every language is typed, and the user has already
/// told it which languages they use. Both facts are available through Text
/// Input Services, so the app can derive its language packs rather than ship
/// a hand-written table per language.
///
/// Verified against the layout we had hand-built: macOS's "Bulgarian – QWERTY"
/// is identical to the app's original Bulgarian map across all 30 keys.
enum KeyboardLayoutReader {

    /// A language macOS can type, and the layout that types it.
    struct Layout {
        /// BCP-47 code from macOS: "bg", "ru", "sv".
        let languageCode: String
        /// Input source id, e.g. com.apple.keylayout.Bulgarian-Phonetic.
        let sourceID: String
        /// Localized name for menus.
        let displayName: String
        /// True when this layout types the Latin alphabet, so text needs no
        /// transliteration — it is already what the user typed.
        let isLatin: Bool
        /// Which letter each Latin key produces. Captured up front rather than
        /// looked up later: a TISInputSource must not outlive the array it
        /// came from, and fetching it lazily read freed memory — which showed
        /// up as unrelated languages ("Ainu", "Hiragana") appearing in the
        /// enabled list after an unrelated call.
        let keymap: [(Character, Character)]
    }

    /// Our own input method, which must never be treated as a language.
    private static let ownBundleID = Bundle.main.bundleIdentifier
        ?? "com.dklaturov.inputmethod.LangAutoSwitcher"

    // MARK: - Discovery

    /// Languages the user has ALREADY enabled in System Settings. This is what
    /// the app adopts on first launch: no picker, no questions — if you type
    /// Bulgarian and English, that is what you get.
    static func enabledLanguages() -> [Layout] {
        collect(includeAllInstalled: false)
    }

    /// Every language macOS has a keyboard layout for, for the "add a
    /// language" menu — so a user can add Swedish without first enabling a
    /// Swedish input source.
    static func availableLanguages() -> [Layout] {
        collect(includeAllInstalled: true)
    }

    private static func collect(includeAllInstalled: Bool) -> [Layout] {
        guard let list = TISCreateInputSourceList(nil, includeAllInstalled)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }

        var seen = Set<String>()
        var out: [Layout] = []
        for source in list {
            // Keyboards only. Emoji pickers, Dictation and PressAndHold are
            // "palette" sources and are not languages.
            guard string(source, kTISPropertyInputSourceCategory)
                    == (kTISCategoryKeyboardInputSource as String) else { continue }

            let sourceID = string(source, kTISPropertyInputSourceID) ?? ""
            guard sourceID != ownBundleID else { continue }

            // Filter against the user's own preference rather than trusting
            // Text Input Services. Enumerating all installed sources makes
            // macOS start reporting bundled input methods as enabled — after
            // one such call the "enabled only" list grew from 6 entries to 9,
            // with Ainu and Japanese both claiming isEnabled = true. The
            // preference does not move.
            if !includeAllInstalled, !userEnabledIDs.contains(sourceID) { continue }

            // The languages array lists EVERY language a layout can type —
            // ABC claims 95 of them. Only the first is the one it is for.
            guard let code = languages(source).first, !code.isEmpty else { continue }

            // Keep one layout per language: the phonetic/QWERTY variant when
            // there is one, since our users type on a Latin keyboard.
            let existing = out.firstIndex { $0.languageCode == code }
            let candidate = Layout(
                languageCode: code,
                sourceID: sourceID,
                displayName: string(source, kTISPropertyLocalizedName) ?? code,
                isLatin: isLatinScript(source),
                keymap: readKeymap(source)
            )
            if let i = existing {
                if preferenceScore(sourceID) > preferenceScore(out[i].sourceID) {
                    out[i] = candidate
                }
            } else if seen.insert(code).inserted {
                out.append(candidate)
            }
        }
        return out
    }

    /// Is this layout's script the Latin alphabet? Decided from what the keys
    /// actually produce rather than from the language code, because a Latin
    /// language is not always English: Swedish types a-z as themselves and
    /// only adds å/ä/ö on the punctuation keys, so it must still count as
    /// Latin or its words would be pointlessly "transliterated".
    private static func isLatinScript(_ source: TISInputSource) -> Bool {
        guard let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return true }
        let layoutData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
        // Probe a few letter keys. If they produce non-Latin letters the
        // script is something else; if they produce themselves, it is Latin.
        for (_, code) in virtualKeys.prefix(6) {
            guard let produced = translate(keyCode: code, layoutData: layoutData, shift: false),
                  let ch = produced.unicodeScalars.first else { continue }
            if ch.value > 0x24F { return false }   // past Latin Extended-B
        }
        return true
    }

    /// Prefer a layout that maps Latin keys to their nearest-sounding letter.
    /// Someone using this app types Latin and expects transliteration, so
    /// "Russian – QWERTY" is right even for a user whose enabled layout is the
    /// positional ЙЦУКЕН one.
    private static func preferenceScore(_ sourceID: String) -> Int {
        // Plain ABC is the reference Latin layout; "Dvorak – QWERTY" also
        // contains "QWERTY" but rearranges the letters, so match it first.
        if sourceID.hasSuffix(".ABC") { return 3 }
        if sourceID.contains("Dvorak") || sourceID.contains("Colemak") { return 0 }
        if sourceID.contains("Phonetic") || sourceID.contains("QWERTY") { return 2 }
        return 1
    }

    // MARK: - The mapping itself

    /// Which letter each Latin key produces in this layout.
    static func keymap(for layout: Layout) -> [(Character, Character)] {
        layout.keymap
    }

    private static func readKeymap(_ source: TISInputSource) -> [(Character, Character)] {
        guard let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return [] }
        let layoutData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data

        var pairs: [(Character, Character)] = []
        for (key, code) in Self.virtualKeys {
            guard let produced = translate(keyCode: code, layoutData: layoutData, shift: false),
                  let ch = produced.first, produced.count == 1
            else { continue }
            // A key that types itself carries no information.
            if ch == key { continue }
            pairs.append((key, ch))
            // The shifted form of a punctuation key is not derivable from the
            // lowercase one ('}' is not the uppercase of ']'), so record it.
            if !key.isLetter,
               let shifted = translate(keyCode: code, layoutData: layoutData, shift: true),
               let sch = shifted.first, shifted.count == 1, sch != ch,
               let shiftedKey = Self.shiftedPunctuation[key] {
                pairs.append((shiftedKey, sch))
            }
        }
        return pairs
    }

    private static func translate(keyCode: UInt16, layoutData: Data, shift: Bool) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) : 0

        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            let keyboard = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(keyboard,
                                  keyCode,
                                  UInt16(kUCKeyActionDisplay),
                                  modifiers,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState,
                                  chars.count,
                                  &length,
                                  &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }


    // MARK: - Property helpers

    private static func string(_ source: TISInputSource, _ key: CFString!) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    /// Input-source ids the user actually turned on, read from the same
    /// preference System Settings writes. Falls back to an empty set, which
    /// the caller treats as "preference unreadable, trust the TIS list".
    private static var userEnabledIDs: Set<String> = {
        guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox"),
              let entries = defaults.array(forKey: "AppleEnabledInputSources")
                as? [[String: Any]]
        else { return [] }
        var ids = Set<String>()
        for entry in entries {
            // Keyboard layouts are named, not bundle-identified. The id is the
            // name with spaces removed: "Bulgarian - Phonetic" becomes
            // com.apple.keylayout.Bulgarian-Phonetic.
            if let name = entry["KeyboardLayout Name"] as? String {
                ids.insert("com.apple.keylayout." + name.replacingOccurrences(of: " ", with: ""))
            }
            if let bundle = entry["Bundle ID"] as? String {
                ids.insert(bundle)
            }
        }
        return ids
    }()

    private static func languages(_ source: TISInputSource) -> [String] {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]) ?? []
    }

    /// US-keyboard virtual key codes for every key that can carry a letter.
    private static let virtualKeys: [(Character, UInt16)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6),
        ("x", 7), ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14),
        ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34),
        ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ("[", 33), ("]", 30), (";", 41), ("'", 39), ("`", 50), ("\\", 42),
        ("-", 27), ("=", 24), (",", 43), (".", 47), ("/", 44),
    ]

    /// What each punctuation key produces with Shift held on a US keyboard.
    private static let shiftedPunctuation: [Character: Character] = [
        "[": "{", "]": "}", ";": ":", "'": "\"", "`": "~", "\\": "|",
        "-": "_", "=": "+", ",": "<", ".": ">", "/": "?",
    ]
}
