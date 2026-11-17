import Foundation

// INTERNAL ONLY. Compiled solely into the developer's private build
// (scripts/install_internal.sh sets INTERNAL_BUILD) and the unit tests.
// Release builds contain none of this.
#if INTERNAL_BUILD

/// A log of the app's *mistakes* only — never of ordinary typing.
///
/// A line is written when the user corrects us:
///   • REVERT  — ⌥⌘Z: we converted a word that should have stayed as typed.
///   • FORCE   — ⌥⌘B: we left a word Latin that should have converted.
///   • DELETED — the user erased a word we had just converted (or left as an
///               unknown Latin word) within a few seconds of committing it,
///               which is how most people fix a wrong word without hotkeys.
///   • RETYPED — what they typed in its place, logged on the next commit.
///
/// Each line carries the word, what we produced, a little text to its left and
/// the app it happened in — enough to replay the case as a unit test. The file
/// lives next to debug.log so it can be reviewed later and then cleared.
enum MistakeLog {

    static let enabledKey = "LangAutoSwitcher_MistakeLogEnabled"

    /// On by default — this file only exists in the internal build, whose
    /// whole point is collecting these. The menu can still pause it.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LangAutoSwitcher", isDirectory: true)
            .appendingPathComponent("mistakes.log")
    }

    /// How much left-hand context goes into an entry. Enough for the detector's
    /// neighbour logic (it looks one or two words back), not enough to turn the
    /// file into a transcript.
    static let contextLimit = 40

    /// Past this size the oldest half is dropped, so a forgotten log can't grow
    /// without bound.
    static let maxBytes = 1_000_000

    enum Kind: String {
        case revert = "REVERT"
        case force = "FORCE"
        case deleted = "DELETED"
        case retyped = "RETYPED"
    }

    // MARK: - Formatting (pure)

    /// Quote a value so a line always splits cleanly: no raw newlines, tabs or
    /// unescaped quotes from the user's text can break the format.
    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n", "\r": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    /// Keep only the tail of the text before the word: the current line, at
    /// most `contextLimit` characters, so neighbouring words come along but
    /// earlier paragraphs don't.
    static func trimContext(_ before: String) -> String {
        let lastLine = before.split(separator: "\n", omittingEmptySubsequences: false)
            .last.map(String.init) ?? ""
        return String(lastLine.suffix(contextLimit))
    }

    static func line(kind: Kind, typed: String, got: String, before: String?,
                     app: String?, version: String, at date: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        var parts = [stamp, kind.rawValue,
                     "typed=" + quote(typed),
                     "got=" + quote(got)]
        if let before { parts.append("before=" + quote(trimContext(before))) }
        parts.append("app=" + (app ?? "?"))
        parts.append("v=" + version)
        return parts.joined(separator: "  ")
    }

    // MARK: - Writing

    private static let queue = DispatchQueue(label: "LangAutoSwitcher.mistakelog")

    static func record(_ kind: Kind, typed: String, got: String, before: String?, app: String?) {
        guard isEnabled else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        let text = line(kind: kind, typed: typed, got: got, before: before,
                        app: app, version: version) + "\n"
        append(text, to: url)
    }

    /// Wait for queued writes to land (tests).
    static func flush() { queue.sync {} }

    static func append(_ text: String, to url: URL) {
        queue.async {
            guard let data = text.data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > UInt64(maxBytes) {
                    try? handle.close()
                    shrink(url)
                    if let h = try? FileHandle(forWritingTo: url) {
                        _ = try? h.seekToEnd()
                        try? h.write(contentsOf: data)
                        try? h.close()
                    }
                    return
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Drop the oldest half, cutting on a line boundary.
    private static func shrink(_ url: URL) {
        guard let all = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = all.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? kept.data(using: .utf8)?.write(to: url)
    }
}

/// Notices a just-committed word being erased with Backspace.
///
/// Armed on commit, fed every Backspace that reaches the document, and reports
/// once the deletions have covered the word. It expires after `window`
/// seconds, and on anything that means the user moved on (typing, arrows) —
/// so ordinary editing elsewhere in the text is not mistaken for a correction.
struct DeletionWatch: Equatable {
    let original: String
    let output: String
    let committedAt: Date
    private(set) var backspaces = 0
    private(set) var reported = false

    static let window: TimeInterval = 15

    init(original: String, output: String, committedAt: Date) {
        self.original = original
        self.output = output
        self.committedAt = committedAt
    }

    var isExpired: Bool { isExpired(at: Date()) }

    func isExpired(at now: Date) -> Bool {
        now.timeIntervalSince(committedAt) > Self.window
    }

    /// Feed one Backspace. `wholeWord` is ⌥⌫, which erases the word in one go.
    /// Returns true exactly once: when the word is gone.
    ///
    /// The threshold is the word's length: the space typed after it costs one
    /// press, so this fires with one letter left — the user is plainly
    /// replacing the word by then, and firing early beats missing the ones
    /// who delete the last letter by selecting it instead.
    mutating func backspace(wholeWord: Bool = false, at now: Date = Date()) -> Bool {
        guard !reported, !isExpired(at: now) else { return false }
        backspaces += wholeWord ? output.count + 1 : 1
        if backspaces >= output.count {
            reported = true
            return true
        }
        return false
    }

    /// Whether this word is worth watching at all: only commits where the
    /// language decision could have been wrong. A converted word, or one left
    /// Latin that isn't a known English word (a missed conversion).
    static func shouldWatch(original: String, output: String, isKnownBaseWord: Bool) -> Bool {
        if original.isEmpty || output.isEmpty { return false }
        if original != output { return true }
        return !isKnownBaseWord
    }
}

#endif
