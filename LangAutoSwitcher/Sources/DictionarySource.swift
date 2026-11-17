import Foundation

/// Which copy of a language's word list to use: the one inside the app bundle
/// or the one installed in Application Support.
///
/// A language that ships with the app (Bulgarian, English) is copied into
/// Application Support on first use — and for a long time that copy then won
/// forever. Every dictionary fix shipped after that (the л-participles of
/// "разплатя", the clitic "й", words removed as harmful like "гоогле") was in
/// the bundle and never reached anyone who already had the app, so a word
/// fixed in a release kept failing on their Mac.
///
/// For a bundled language the installed file is only a cache of the bundle,
/// so the bundle is the truth: when the two differ, the bundle replaces it.
/// Languages downloaded from the menu have no bundled copy and keep theirs.
enum DictionarySource {

    struct Choice: Equatable {
        /// The word list to load.
        let text: String
        /// Whether to (re)write the installed copy with `text`.
        let writeInstalled: Bool
    }

    static func choose(installed: String?, bundled: String?) -> Choice? {
        let installed = installed.flatMap { $0.isEmpty ? nil : $0 }
        let bundled = bundled.flatMap { $0.isEmpty ? nil : $0 }
        if let bundled {
            return Choice(text: bundled, writeInstalled: installed != bundled)
        }
        if let installed {
            return Choice(text: installed, writeInstalled: false)
        }
        return nil
    }
}
