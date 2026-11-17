import Foundation

/// The bookkeeping around a word that is *held back* waiting for its
/// right-hand neighbour.
///
/// The held word is shown as marked text with a trailing space, so the
/// composition — not the document — owns that space. Every rule below follows
/// from that single fact, and they have to agree: if the marked text ends in a
/// space but the space keypress also reaches the document, the user gets
/// "да  е" instead of "да е".
enum Composition {

    /// What the user sees while composing: the held word, then whatever is
    /// being typed now.
    ///
    /// The space between them is drawn only once there is something after it.
    /// A composition that *ends* in a space is drawn by Chromium apps (Viber,
    /// Slack) as an empty box, so a held word used to sit there with a box
    /// stuck to it until the next letter arrived. The space is not lost — it
    /// is re-emitted by `commit`.
    static func markedText(pending: String?, buffer: String) -> String {
        guard let pending, !pending.isEmpty else { return buffer }
        return buffer.isEmpty ? pending : pending + " " + buffer
    }

    /// Whether the space keypress should also reach the document.
    ///
    /// False while a word is held: that space is already drawn in the marked
    /// text and is re-emitted by `commit` when the word resolves.
    static func spacePassesThrough(pending: String?) -> Bool {
        pending == nil
    }

    /// The committed text for a held word plus the word that resolved it.
    static func commit(pending: String?, next: String, trailing: String = "") -> String {
        guard let pending, !pending.isEmpty else { return next + trailing }
        return pending + " " + next + trailing
    }

    /// Backspace while composing. Returns the new (pending, buffer).
    ///
    /// With an empty buffer the last thing on screen is the last held word
    /// (its space is not drawn — see `markedText`), so backspace takes THAT
    /// word off hold and deletes its last letter; any words held before it
    /// stay held. Moving the whole run into the buffer made "move li" one
    /// token with a space inside, which no dictionary contains, so the run
    /// committed as Latin.
    static func backspace(pending: String?, buffer: String) -> (pending: String?, buffer: String) {
        if !buffer.isEmpty {
            return (pending, String(buffer.dropLast()))
        }
        guard let pending else { return (nil, "") }
        if let space = pending.lastIndex(of: " ") {
            let earlier = String(pending[..<space])
            let last = String(pending[pending.index(after: space)...])
            return (earlier.isEmpty ? nil : earlier, String(last.dropLast()))
        }
        return (nil, String(pending.dropLast()))
    }

    /// How many held tokens are words. Numbers riding along in the run (see
    /// `holdsNumber`) don't count towards the word limit.
    static func heldWordCount(_ pending: String) -> Int {
        pending.split(separator: " ")
            .filter { !$0.allSatisfy({ $0.isASCII && $0.isNumber }) }
            .count
    }

    /// Whether a number may join the held run instead of ending it.
    ///
    /// A number has no language, so it cannot decide the held words — but it
    /// used to end the hold anyway, through the email/URL path, which wrote
    /// the held words out exactly as typed. "може да stane i to 10 часа": the
    /// three ambiguous words were waiting, "10" arrived, and they landed
    /// Latin, one word before "часа" would have settled them. Holding the
    /// number too lets the next real word decide the whole run; the detector
    /// passes numbers through unchanged.
    ///
    /// Only bare numbers, only with no punctuation stuck on (that ends the
    /// thought), and only while the run is short — it is visible marked text.
    static func holdsNumber(pending: String?, word: String, trailing: String,
                            maxTokens: Int) -> Bool {
        guard let pending, !pending.isEmpty, trailing.isEmpty, !word.isEmpty,
              word.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return false }
        return pending.split(separator: " ").count < maxTokens
    }
}
