import Foundation

/// Two persisted sets of user-taught words:
///
///  • **latin_words** — "always Latin". When the user reverts an auto-conversion
///    (⌥⌘Z), the original Latin word lands here and is never converted again —
///    abbreviations ("dpi"), brand names, slang.
///  • **bg_words** — "always Bulgarian". When the user forces a word with the
///    force-to-Bulgarian hotkey (⌥⌘B), the Latin spelling lands here and always
///    converts to Cyrillic afterwards — out-of-dictionary words ("клипчета",
///    "трейлъри") taught once instead of editing the dictionary file.
///
/// The detector consults both before dictionaries and autocorrect.
///
/// File location: `~/Library/Application Support/LangAutoSwitcher/learned_words.json`
/// Format: `{"latin_words": [...], "bg_words": [...]}` (stored lowercase)
enum UserWordsManager {

    private static let lock = NSLock()
    private static var cached: Set<String> = []
    private static var cachedBg: Set<String> = []
    private static var loaded = false

    static var fileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("LangAutoSwitcher", isDirectory: true)
        return appSupport.appendingPathComponent("learned_words.json")
    }

    // MARK: - Always-Latin words

    /// All learned ("always Latin") words (lowercase). Loads from disk on first call.
    static func all() -> Set<String> {
        ensureLoaded()
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Remember `word` as always-Latin (persisted). No-op if already known.
    static func add(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        guard !w.isEmpty else { return }
        ensureLoaded()
        lock.lock()
        cached.insert(w)
        // A word can't be both always-Latin and always-Bulgarian; the newest
        // wins, so drop any opposite entry.
        cachedBg.remove(w)
        let snapshot = (cached, cachedBg)
        lock.unlock()
        write(snapshot.0, snapshot.1)
        NSLog("LangAutoSwitcher: learned Latin word '%@' (now %d total)", w, snapshot.0.count)
    }

    /// Forget a learned ("always Latin") word. No-op if not present.
    static func remove(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        ensureLoaded()
        lock.lock()
        cached.remove(w)
        let snapshot = (cached, cachedBg)
        lock.unlock()
        write(snapshot.0, snapshot.1)
    }

    /// Forget all learned ("always Latin") words.
    static func clear() {
        ensureLoaded()
        lock.lock()
        cached.removeAll()
        let snapshot = (cached, cachedBg)
        lock.unlock()
        write(snapshot.0, snapshot.1)
        NSLog("LangAutoSwitcher: cleared all always-Latin words")
    }

    // MARK: - Always-Bulgarian words

    /// All forced ("always Bulgarian") words (lowercase Latin spelling).
    static func allBg() -> Set<String> {
        ensureLoaded()
        lock.lock(); defer { lock.unlock() }
        return cachedBg
    }

    /// Remember `word` as always-Bulgarian (persisted). No-op if already known.
    static func addBg(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        guard !w.isEmpty else { return }
        ensureLoaded()
        lock.lock()
        cachedBg.insert(w)
        cached.remove(w)   // newest wins (see add)
        let snapshot = (cached, cachedBg)
        lock.unlock()
        write(snapshot.0, snapshot.1)
        NSLog("LangAutoSwitcher: forced Bulgarian word '%@' (now %d total)", w, snapshot.1.count)
    }

    /// Forget a forced ("always Bulgarian") word. No-op if not present.
    static func removeBg(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        ensureLoaded()
        lock.lock()
        cachedBg.remove(w)
        let snapshot = (cached, cachedBg)
        lock.unlock()
        write(snapshot.0, snapshot.1)
    }

    /// Forget all forced ("always Bulgarian") words.
    static func clearBg() {
        ensureLoaded()
        lock.lock()
        cachedBg.removeAll()
        let snapshot = (cached, cachedBg)
        lock.unlock()
        write(snapshot.0, snapshot.1)
        NSLog("LangAutoSwitcher: cleared all always-Bulgarian words")
    }

    // MARK: - Shared

    /// Create the JSON file with the current sets if it doesn't exist yet,
    /// so "edit words" always has something to open.
    static func ensureFileExists() {
        ensureLoaded()
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        lock.lock()
        let snapshot = (cached, cachedBg)
        lock.unlock()
        write(snapshot.0, snapshot.1)
    }

    /// Reload from disk (e.g., after the user hand-edits the JSON).
    static func reload() {
        lock.lock()
        loaded = false
        lock.unlock()
        ensureLoaded()
    }

    // MARK: - private

    private static func ensureLoaded() {
        lock.lock()
        let needLoad = !loaded
        lock.unlock()
        guard needLoad else { return }

        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        var loadedSet: Set<String> = []
        var loadedBg: Set<String> = []
        if let data = try? Data(contentsOf: url),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let arr = raw["latin_words"] as? [String] {
                loadedSet = Set(arr.map { $0.lowercased() })
            }
            if let arr = raw["bg_words"] as? [String] {
                loadedBg = Set(arr.map { $0.lowercased() })
            }
        }

        lock.lock()
        cached = loadedSet
        cachedBg = loadedBg
        loaded = true
        lock.unlock()
        NSLog("LangAutoSwitcher: loaded %d always-Latin + %d always-Bulgarian word(s)",
              loadedSet.count, loadedBg.count)
    }

    private static func write(_ latin: Set<String>, _ bg: Set<String>) {
        let payload: [String: Any] = [
            "_README": "latin_words always stay Latin (never converted to Cyrillic); " +
                       "bg_words always convert to Cyrillic. Add Latin words by reverting " +
                       "a conversion with ⌥⌘Z, Bulgarian words by forcing one with ⌥⌘B, " +
                       "or by hand then choose Reload from the menu.",
            "latin_words": Array(latin).sorted(),
            "bg_words": Array(bg).sorted(),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("LangAutoSwitcher: failed to write learned_words.json: \(error)")
        }
    }
}
