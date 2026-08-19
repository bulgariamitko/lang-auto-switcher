import Foundation

/// Decides which languages are active and where their dictionaries live.
///
/// Both answers deliberately live OUTSIDE the app bundle — the enabled list in
/// user defaults, the dictionaries in Application Support — because Sparkle
/// replaces the whole bundle on update. Anything kept inside it would be lost
/// every time the app updates; anything kept outside survives forever. That is
/// the whole reason a user cannot lose a language they added.
enum LanguagePackStore {

    private static let enabledKey = "LangAutoSwitcher_EnabledLanguages"
    private static let migratedKey = "LangAutoSwitcher_DidMigrateLanguages"

    /// Root of the app's own storage. Overridable so tests can run against a
    /// scratch directory instead of the user's real Application Support —
    /// without it, simply exercising this type writes dictionaries into a
    /// live install.
    static var containerDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LangAutoSwitcher", isDirectory: true)

    /// Where dictionaries live between updates.
    static var dictionariesDirectory: URL {
        let base = containerDirectory.appendingPathComponent("dictionaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Marker the old, pre-multi-language version left behind. Overridable for
    /// the same reason as `containerDirectory`.
    static var legacyStateURL: URL = UserWordsManager.fileURL

    // MARK: - Which languages are active

    /// Language codes the app should run with, in order. The first is the
    /// Latin base and is always present.
    static func enabledCodes() -> [String] {
        if let stored = UserDefaults.standard.array(forKey: enabledKey) as? [String],
           !stored.isEmpty {
            return normalise(stored)
        }
        let discovered = firstRunCodes()
        setEnabledCodes(discovered)
        return discovered
    }

    static func setEnabledCodes(_ codes: [String]) {
        UserDefaults.standard.set(normalise(codes), forKey: enabledKey)
    }

    static func addLanguage(_ code: String) {
        var codes = enabledCodes()
        guard !codes.contains(code) else { return }
        codes.append(code)
        setEnabledCodes(codes)
    }

    static func removeLanguage(_ code: String) {
        // The Latin base is what unknown words fall back to; removing it would
        // leave nothing to fall back to.
        guard code != baseCode else { return }
        setEnabledCodes(enabledCodes().filter { $0 != code })
    }

    /// English first, then the rest in the order they were added, no repeats.
    private static func normalise(_ codes: [String]) -> [String] {
        var out = [baseCode]
        for c in codes where c != baseCode && !out.contains(c) {
            out.append(c)
        }
        return out
    }

    static let baseCode = "en"

    // MARK: - First run

    /// What to start with when there is no stored choice yet.
    ///
    /// An EXISTING install keeps what it already had. Until this release the
    /// app was English plus Bulgarian for everyone, so an upgrade must keep
    /// Bulgarian — a user who has been typing Bulgarian for months must not
    /// find it gone after an update they did not ask for.
    ///
    /// A FRESH install instead adopts whatever keyboard layouts the user has
    /// already enabled in System Settings, which is both zero-configuration
    /// and better information than a picker would collect.
    private static func firstRunCodes() -> [String] {
        if isUpgradeFromBeforeMultiLanguage() {
            UserDefaults.standard.set(true, forKey: migratedKey)
            NSLog("LangAutoSwitcher: upgrading an existing install — keeping English + Bulgarian")
            return ["en", "bg"]
        }
        let discovered = KeyboardLayoutReader.enabledLanguages().map { $0.languageCode }
        let codes = normalise(discovered)
        NSLog("LangAutoSwitcher: new install — adopting enabled input sources: %@",
              codes.joined(separator: ", "))
        return codes
    }

    /// Did this Mac run a version of the app that predates multi-language
    /// support? Evidence is any state the old version left behind.
    private static func isUpgradeFromBeforeMultiLanguage() -> Bool {
        if UserDefaults.standard.bool(forKey: migratedKey) { return true }
        let oldKeys = [
            "LangAutoSwitcher_DefaultLanguage",
            "LangAutoSwitcher_AutocorrectEnabled",
            "LangAutoSwitcher_TypoCorrectionEnabled",
        ]
        if oldKeys.contains(where: { UserDefaults.standard.object(forKey: $0) != nil }) {
            return true
        }
        // Learned words were stored next to the app's other support files.
        return FileManager.default.fileExists(atPath: legacyStateURL.path)
    }

    // MARK: - Dictionaries

    /// The word list for a language, or nil when it has not been installed.
    ///
    /// Application Support wins over the bundle so a downloaded or updated
    /// dictionary is not shadowed by a stale bundled copy. A bundled
    /// dictionary is copied out on first use, which is what carries an
    /// upgrading user's Bulgarian to safety before the bundle stops shipping
    /// it.
    static func dictionaryText(for code: String) -> String? {
        let installed = dictionariesDirectory.appendingPathComponent("\(code)-dictionary.txt")
        if let text = try? String(contentsOf: installed, encoding: .utf8), !text.isEmpty {
            return text
        }
        guard let bundled = Bundle.main.url(forResource: "\(code)-dictionary",
                                            withExtension: "txt"),
              let text = try? String(contentsOf: bundled, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        try? text.write(to: installed, atomically: true, encoding: .utf8)
        NSLog("LangAutoSwitcher: installed bundled '%@' dictionary into Application Support", code)
        return text
    }

    static func isInstalled(_ code: String) -> Bool {
        let installed = dictionariesDirectory.appendingPathComponent("\(code)-dictionary.txt")
        return FileManager.default.fileExists(atPath: installed.path)
            || Bundle.main.url(forResource: "\(code)-dictionary", withExtension: "txt") != nil
    }

    static func install(dictionaryText text: String, for code: String) throws {
        let url = dictionariesDirectory.appendingPathComponent("\(code)-dictionary.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
