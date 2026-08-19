import Foundation

/// Renders "which key types which letter" for one language.
///
/// macOS's own Keyboard Viewer shows the layout of the SELECTED input source,
/// which while this app is active is plain ABC — so it can never show what
/// our Bulgarian or Swedish layouts do. Without this there is no way to
/// discover that Swedish types å on `[`, or that ч is on the § key.
enum KeyboardChart {

    /// US-keyboard rows, in physical order, as the user sees them.
    private static let rows: [[Character]] = [
        ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="],
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'"],
        ["z", "x", "c", "v", "b", "n", "m", ",", ".", "/"],
    ]

    /// Extra keys that are not on the main block but that a layout may use —
    /// the ISO §/± key this app puts ч on, for one.
    private static let extras: [Character] = ["§", "±"]

    /// A keyboard-shaped chart: each key with the letter it produces beneath
    /// it. A key that types itself shows itself rather than a placeholder —
    /// a dot there would read as "this key does nothing", which is wrong and
    /// matters most for a Latin language like Swedish where most keys are
    /// unchanged and only a few carry å, ä and ö.
    static func render(keymap: [(Character, Character)], languageName: String) -> String {
        var map: [Character: Character] = [:]
        for (key, letter) in keymap { map[key] = letter }

        // A language typed exactly as the keys print needs no diagram —
        // English drew a full identity keyboard that said nothing and pushed
        // the layouts that DO differ off the bottom of the window.
        let drawnKeys = Set(rows.flatMap { $0 }).union(extras)
        let differing = drawnKeys.filter { key in map[key].map { $0 != key } ?? false }
        if differing.isEmpty {
            return "types exactly what the keys print"
        }

        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            let indent = String(repeating: " ", count: index * 2)
            var keyLine = indent
            var letterLine = indent
            for key in row {
                let produced = map[key]
                keyLine += " \(key) "
                letterLine += " \(produced.map(String.init) ?? String(key)) "
            }
            lines.append(keyLine)
            lines.append(letterLine)
            lines.append("")
        }

        let present = extras.filter { map[$0] != nil }
        if !present.isEmpty {
            let pairs = present.map { "\($0) → \(map[$0]!)" }.joined(separator: "    ")
            lines.append(pairs)
        }

        lines.append("")
        lines.append("\(differing.count) keys type something different.")
        return lines.joined(separator: "\n")
    }
}
