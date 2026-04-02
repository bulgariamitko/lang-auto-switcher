import Cocoa
import InputMethodKit

/// The main input controller. Each text field the user focuses gets its own instance.
/// It intercepts keystrokes, buffers the current word, and on space/punctuation
/// decides whether to commit it as English (Latin) or Bulgarian (Cyrillic).
@objc(InputController)
class InputController: IMKInputController {

    // MARK: - State

    private let detector = LanguageDetector()

    /// Buffer of Latin characters for the word currently being composed.
    private var composingBuffer = ""

    /// Whether we are actively composing (have uncommitted text).
    private var isComposing: Bool { !composingBuffer.isEmpty }

    // MARK: - IMKInputController overrides

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else {
            return false
        }

        let client = sender as! IMKTextInput

        // Get the characters
        guard let chars = event.characters, !chars.isEmpty else {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Let through Cmd+key shortcuts (Cmd+C, Cmd+V, etc.)
        if modifiers.contains(.command) {
            commitComposingBuffer(client: client)
            return false
        }

        // Let through Ctrl+key
        if modifiers.contains(.control) {
            commitComposingBuffer(client: client)
            return false
        }

        let char = chars.first!

        // Handle special keys
        switch char {
        case "\r", "\n":
            // Return/Enter — commit and pass through
            commitComposingBuffer(client: client)
            return false

        case "\u{1B}":
            // Escape — cancel composition
            cancelComposition(client: client)
            return false

        case "\u{7F}":
            // Backspace
            return handleBackspace(client: client)

        case " ":
            // Space — commit the current word, then insert space
            commitComposingBuffer(client: client)
            return false  // Let the space pass through normally

        default:
            break
        }

        // Punctuation or non-letter: commit current word first, then pass through
        if !char.isLetter || !char.isASCII {
            commitComposingBuffer(client: client)
            return false  // Let the character pass through
        }

        // It's a Latin letter — add to our composing buffer
        let letter = String(char)
        composingBuffer += letter

        // Show the composing text (underlined, inline) so the user sees what they type
        updateMarkedText(client: client)

        return true  // We handled this event
    }

    // MARK: - Composition

    /// Show the current buffer as "marked" (composing) text.
    /// This appears inline with an underline, like how Chinese/Japanese input works.
    private func updateMarkedText(client: IMKTextInput) {
        // Show the Latin text while composing with an underline
        let attrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: NSColor.textColor,
        ]
        let marked = NSAttributedString(string: composingBuffer, attributes: attrs)

        client.setMarkedText(marked,
                             selectionRange: NSRange(location: composingBuffer.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Commit the composing buffer: detect language and insert final text.
    private func commitComposingBuffer(client: IMKTextInput) {
        guard isComposing else { return }

        let result = detector.processWord(composingBuffer)

        NSLog("LangAutoSwitcher: '%@' → '%@' [%@, %.2f]",
              composingBuffer, result.converted,
              result.language.rawValue, result.confidence)

        // Insert the final text (replaces the marked text)
        client.insertText(result.converted,
                          replacementRange: NSRange(location: NSNotFound, length: 0))

        composingBuffer = ""
    }

    /// Cancel composition without committing.
    private func cancelComposition(client: IMKTextInput) {
        if isComposing {
            // Remove the marked text
            client.insertText("",
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            composingBuffer = ""
        }
    }

    /// Handle backspace — remove last character from buffer.
    private func handleBackspace(client: IMKTextInput) -> Bool {
        if isComposing {
            composingBuffer.removeLast()
            if composingBuffer.isEmpty {
                // Nothing left — cancel the composition
                cancelComposition(client: client)
            } else {
                updateMarkedText(client: client)
            }
            return true  // We handled it
        }
        return false  // Not composing, let the app handle backspace
    }

    // MARK: - Session lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        detector.resetContext()
        composingBuffer = ""
        NSLog("LangAutoSwitcher: Activated")
    }

    override func deactivateServer(_ sender: Any!) {
        let client = sender as! IMKTextInput
        commitComposingBuffer(client: client)
        super.deactivateServer(sender)
        NSLog("LangAutoSwitcher: Deactivated")
    }
}
