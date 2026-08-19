import Foundation

/// Manages the user-customizable Latin → Cyrillic key mapping.
///
/// File location: `~/Library/Application Support/LangAutoSwitcher/keymap.json`
/// Flat JSON: `{"a": "а", "b": "б", "[": "ш", ...}`.
///
/// At launch:
///   1. Load file (create with defaults if missing).
///   2. Diff against defaults — only push *changed* pairs into the Rust core
///      as overrides. Unchanged keys fall through to the built-in mapping.
///
/// Users can reload via the menu after editing without quitting the app.
enum KeymapManager {

    /// The built-in default map mirrors `default_map_char` in
    /// `langauto-core/src/phonetic.rs`. Keep in sync.
    static let defaults: [String: String] = [
        // lowercase letters
        "a": "а", "b": "б", "c": "ц", "d": "д", "e": "е",
        "f": "ф", "g": "г", "h": "х", "i": "и", "j": "й",
        "k": "к", "l": "л", "m": "м", "n": "н", "o": "о",
        "p": "п", "r": "р", "s": "с", "t": "т",
        "u": "у", "v": "ж", "w": "в", "x": "ь", "y": "ъ",
        "z": "з", "q": "я",
        // lowercase specials
        "]": "щ", "[": "ш", ";": "ж", "'": "ь", "`": "ч", "\\": "ю",
        // uppercase specials
        "}": "Щ", "{": "Ш", ":": "Ж", "\"": "Ь", "~": "Ч", "|": "Ю",
        // ISO Mac §/± key (top-left, left of 1) — alternate ч/Ч
        "§": "ч", "±": "Ч",
        // uppercase letters
        "A": "А", "B": "Б", "C": "Ц", "D": "Д", "E": "Е",
        "F": "Ф", "G": "Г", "H": "Х", "I": "И", "J": "Й",
        "K": "К", "L": "Л", "M": "М", "N": "Н", "O": "О",
        "P": "П", "R": "Р", "S": "С", "T": "Т",
        "U": "У", "V": "Ж", "W": "В", "X": "Ь", "Y": "Ъ",
        "Z": "З", "Q": "Я",
    ]

    static var fileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("LangAutoSwitcher", isDirectory: true)
        return appSupport.appendingPathComponent("keymap.json")
    }

    /// The user's keymap.json as written on disk, or nil when absent.
    /// Used to build language packs, which need the whole map rather than
    /// just the entries that differ from the defaults.
    static func userMap() -> [String: String]? {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return raw.filter { $0.key != "_README" }
    }

    /// Read keymap.json (creating with defaults if absent) and push the
    /// per-key *overrides* (entries that differ from the built-in defaults)
    /// into the Rust core.
    static func loadAndApply() {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            NSLog("LangAutoSwitcher: could not create keymap dir: \(error)")
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            writeDefaults(to: url)
        }
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            NSLog("LangAutoSwitcher: keymap.json unreadable; using built-in defaults")
            langauto_clear_char_overrides()
            return
        }
        langauto_clear_char_overrides()
        var overrideCount = 0
        for (latin, cyrillic) in raw {
            // Skip comment-style keys and entries that match the default.
            if latin.hasPrefix("_") { continue }
            if defaults[latin] == cyrillic { continue }
            guard let latinScalar = latin.unicodeScalars.first,
                  let cyrScalar = cyrillic.unicodeScalars.first else { continue }
            langauto_set_char_override(latinScalar.value, cyrScalar.value)
            overrideCount += 1
        }
        NSLog("LangAutoSwitcher: loaded keymap.json with \(overrideCount) override(s)")
    }

    /// Replace the on-disk file with a freshly serialized default map plus
    /// a help comment, then re-apply (i.e. drop all overrides).
    static func resetToDefaults() {
        writeDefaults(to: fileURL)
        loadAndApply()
    }

    private static func writeDefaults(to url: URL) {
        var dict: [String: String] = defaults
        dict["_README"] = "Customize the Latin → Cyrillic mapping. Save this file " +
                          "then choose 'Reload Keymap' from the LangAutoSwitcher input menu. " +
                          "Delete this file (or pick 'Reset Keymap to Defaults') to restore."
        if let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                NSLog("LangAutoSwitcher: could not write default keymap.json: \(error)")
            }
        }
    }
}
