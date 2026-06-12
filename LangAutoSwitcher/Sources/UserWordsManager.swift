import Foundation

/// Learned "always Latin" words. When the user reverts an auto-conversion
/// (⌥⌘Z), the original Latin word lands here and is never converted again —
/// abbreviations ("dpi"), brand names, slang. The detector consults this set
/// before dictionaries and autocorrect.
///
/// File location: `~/Library/Application Support/LangAutoSwitcher/learned_words.json`
/// Format: `{"latin_words": ["dpi", "json", ...]}` (stored lowercase)
enum UserWordsManager {

    private static let lock = NSLock()
    private static var cached: Set<String> = []
    private static var loaded = false

    static var fileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("LangAutoSwitcher", isDirectory: true)
        return appSupport.appendingPathComponent("learned_words.json")
    }

    /// All learned words (lowercase). Loads from disk on first call.
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
        let snapshot = cached
        lock.unlock()
        write(snapshot)
        NSLog("LangAutoSwitcher: learned word '%@' (now %d total)", w, snapshot.count)
    }

    /// Forget a learned word. No-op if not present.
    static func remove(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        ensureLoaded()
        lock.lock()
        cached.remove(w)
        let snapshot = cached
        lock.unlock()
        write(snapshot)
    }

    /// Forget all learned words.
    static func clear() {
        ensureLoaded()
        lock.lock()
        cached.removeAll()
        let snapshot = cached
        lock.unlock()
        write(snapshot)
        NSLog("LangAutoSwitcher: cleared all learned words")
    }

    /// Create the JSON file with the current set if it doesn't exist yet,
    /// so "edit learned words" always has something to open.
    static func ensureFileExists() {
        ensureLoaded()
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        lock.lock()
        let snapshot = cached
        lock.unlock()
        write(snapshot)
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
        if let data = try? Data(contentsOf: url),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = raw["latin_words"] as? [String] {
            loadedSet = Set(arr.map { $0.lowercased() })
        }

        lock.lock()
        cached = loadedSet
        loaded = true
        lock.unlock()
        NSLog("LangAutoSwitcher: loaded %d learned word(s)", loadedSet.count)
    }

    private static func write(_ set: Set<String>) {
        let payload: [String: Any] = [
            "_README": "Words listed here always stay Latin — LangAutoSwitcher " +
                       "will never convert them to Cyrillic. Add words by reverting " +
                       "a conversion with ⌥⌘Z, or by hand then choose Reload from " +
                       "the menu.",
            "latin_words": Array(set).sorted(),
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
