import Foundation

/// Per-app pass-through list. When the focused app's bundle identifier is in
/// this set, the input controller does not intercept keystrokes — they go
/// straight to the app like a normal English keyboard would.
///
/// Why: some apps don't honor IMK marked-text composition (Chromium-style
/// search bars, live-search-per-keystroke custom apps, password fields in
/// VNC clients, …). In those cases our marked text leaks into the field as
/// committed text and you get "lalanlangllangulanglanguaglanguage" instead
/// of "language". Excluding the app fully sidesteps the issue — the user
/// just types Latin and accepts that they can't write Bulgarian there.
///
/// File location: `~/Library/Application Support/LangAutoSwitcher/excluded_apps.json`
/// Format: `{"bundles": ["com.example.app", ...]}`
enum AppExclusionManager {

    private static let lock = NSLock()
    private static var cached: Set<String> = []
    private static var loaded = false

    static var fileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("LangAutoSwitcher", isDirectory: true)
        return appSupport.appendingPathComponent("excluded_apps.json")
    }

    /// Whether the given bundle is excluded. Loads from disk on first call.
    static func isExcluded(_ bundleID: String) -> Bool {
        ensureLoaded()
        lock.lock(); defer { lock.unlock() }
        return cached.contains(bundleID)
    }

    /// Add `bundleID` to the exclusion list (persisted to disk). No-op if
    /// already excluded.
    static func exclude(_ bundleID: String) {
        ensureLoaded()
        lock.lock()
        cached.insert(bundleID)
        let snapshot = cached
        lock.unlock()
        write(snapshot)
        NSLog("LangAutoSwitcher: excluded '%@' (now %d total)",
              bundleID, snapshot.count)
    }

    /// Remove `bundleID` from the exclusion list. No-op if not present.
    static func include(_ bundleID: String) {
        ensureLoaded()
        lock.lock()
        cached.remove(bundleID)
        let snapshot = cached
        lock.unlock()
        write(snapshot)
        NSLog("LangAutoSwitcher: re-enabled '%@' (now %d total)",
              bundleID, snapshot.count)
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
           let arr = raw["bundles"] as? [String] {
            loadedSet = Set(arr)
        }

        lock.lock()
        cached = loadedSet
        loaded = true
        lock.unlock()
        NSLog("LangAutoSwitcher: loaded %d excluded app(s)", loadedSet.count)
    }

    private static func write(_ set: Set<String>) {
        let payload: [String: Any] = [
            "_README": "Bundle IDs listed here will receive raw keystrokes — " +
                       "LangAutoSwitcher will not intercept input. Edit via the " +
                       "menu (Disable for current app), or by hand then choose " +
                       "Reload Excluded Apps.",
            "bundles": Array(set).sorted(),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("LangAutoSwitcher: failed to write excluded_apps.json: \(error)")
        }
    }
}
