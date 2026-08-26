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
    /// With an empty buffer the last thing on screen is the held word itself
    /// (its space is not drawn — see `markedText`), so backspace takes the
    /// word off hold and deletes its last letter. Every keypress removes
    /// exactly one visible character, which is the whole point.
    static func backspace(pending: String?, buffer: String) -> (pending: String?, buffer: String) {
        if !buffer.isEmpty {
            return (pending, String(buffer.dropLast()))
        }
        if let pending {
            return (nil, String(pending.dropLast()))
        }
        return (nil, "")
    }
}
