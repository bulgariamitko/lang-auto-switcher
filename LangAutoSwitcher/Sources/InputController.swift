import Cocoa
import InputMethodKit

/// The main input controller. Each text field the user focuses gets its own instance.
/// It intercepts keystrokes, buffers the current word, and on space/punctuation
/// decides whether to commit it as English (Latin) or Bulgarian (Cyrillic).
///
/// When the first word is ambiguous (exists in both languages and no prior context),
/// it buffers that word and waits for the second word to determine the language,
/// then commits both.
@objc(InputController)
class InputController: IMKInputController {

    // MARK: - State

    private let detector = LanguageDetector()

    /// Buffer of Latin characters for the word currently being composed.
    private var composingBuffer = ""

    /// Whether we are actively composing (have uncommitted text).
    private var isComposing: Bool { !composingBuffer.isEmpty || pendingWord != nil }

    /// A word that was ambiguous (in both dictionaries, no context).
    /// We hold it and wait for the next word to decide its language.
    private var pendingWord: String? = nil

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
            forceCommitAll(client: client)
            return false
        }

        // Let through Ctrl+key
        if modifiers.contains(.control) {
            forceCommitAll(client: client)
            return false
        }

        let char = chars.first!

        // Handle special keys
        switch char {
        case "\r", "\n":
            // Return/Enter — commit everything and pass through
            forceCommitAll(client: client)
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

        // Characters that map to Cyrillic (] [ ; ' `) should be buffered too
        let mappableChars: Set<Character> = ["]", "[", ";", "'", "`"]
        let isMappable = (char.isLetter && char.isASCII) || mappableChars.contains(char)

        // Non-mappable punctuation/symbols: commit current word, pass through
        if !isMappable {
            forceCommitAll(client: client)
            return false  // Let the character pass through
        }

        // It's a mappable character — add to our composing buffer
        let letter = String(char)
        composingBuffer += letter

        // Show the composing text (underlined, inline)
        updateMarkedText(client: client)

        return true  // We handled this event
    }

    // MARK: - Composition

    /// Show the current buffer as "marked" (composing) text.
    private func updateMarkedText(client: IMKTextInput) {
        // Show pending word + current buffer together as marked text
        var display = ""
        if let pending = pendingWord {
            display = pending + " "
        }
        display += composingBuffer

        let attrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: NSColor.textColor,
        ]
        let marked = NSAttributedString(string: display, attributes: attrs)

        client.setMarkedText(marked,
                             selectionRange: NSRange(location: display.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Commit the composing buffer: detect language and insert final text.
    /// If the word is ambiguous and there's no context, hold it as pending.
    private func commitComposingBuffer(client: IMKTextInput) {
        guard !composingBuffer.isEmpty else {
            // No current word, but if there's a pending word, force commit it
            if pendingWord != nil {
                forceCommitAll(client: client)
            }
            return
        }

        let word = composingBuffer
        composingBuffer = ""

        // Check if this word is ambiguous (in both dictionaries)
        let lower = word.lowercased()
        let cyrillic = PhoneticMapper.toCyrillic(word)
        let cyrillicLower = cyrillic.lowercased()
        let isEnglish = detector.enDictionary.contains(lower)
        let isBulgarian = detector.bgDictionary.contains(cyrillicLower)
        let isAmbiguous = isEnglish && isBulgarian

        if pendingWord != nil {
            // We have a pending ambiguous word — now we can resolve both.
            // Process the SECOND word first to establish context.
            let secondResult = detector.processWord(word)

            // Now re-process the pending word — context from the second word will guide it
            // Reset context first, then process pending, then second again
            // Actually, the second word already set the context. Let's use that context
            // to determine what the pending word should have been.
            let pendingCyrillic = PhoneticMapper.toCyrillic(pendingWord!)
            let pendingOutput: String
            if secondResult.language == .bulgarian {
                pendingOutput = pendingCyrillic
            } else {
                pendingOutput = pendingWord!
            }

            NSLog("LangAutoSwitcher: pending '%@' → '%@' (resolved by '%@'→'%@' [%@])",
                  pendingWord!, pendingOutput, word, secondResult.converted, secondResult.language.rawValue)

            // Commit: pending word + space + second word
            let fullText = pendingOutput + " " + secondResult.converted
            client.insertText(fullText,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            pendingWord = nil

        } else if isAmbiguous && detector.isFirstWord {
            // First word with no context AND ambiguous — hold it
            pendingWord = word
            NSLog("LangAutoSwitcher: holding ambiguous first word '%@'", word)
            // Keep it as marked text (underlined) — don't commit yet
            // The space will be inserted when we resolve it
            updateMarkedText(client: client)

        } else {
            // Normal case — process and commit immediately
            let result = detector.processWord(word)

            NSLog("LangAutoSwitcher: '%@' → '%@' [%@, %.2f]",
                  word, result.converted,
                  result.language.rawValue, result.confidence)

            client.insertText(result.converted,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// Force-commit everything (pending word + composing buffer).
    /// Used when we can't wait any longer (Enter, Cmd+key, punctuation, etc.)
    private func forceCommitAll(client: IMKTextInput) {
        if let pending = pendingWord {
            // No second word to help — commit pending with default language
            let result = detector.processWord(pending)
            let currentWord = composingBuffer.isEmpty ? "" : composingBuffer

            if currentWord.isEmpty {
                // Just the pending word
                client.insertText(result.converted,
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                // Pending + space + current word
                let secondResult = detector.processWord(currentWord)
                let pendingCyrillic = PhoneticMapper.toCyrillic(pending)
                let pendingOutput = secondResult.language == .bulgarian ? pendingCyrillic : pending
                let fullText = pendingOutput + " " + secondResult.converted
                client.insertText(fullText,
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
            }

            pendingWord = nil
            composingBuffer = ""
        } else if !composingBuffer.isEmpty {
            let result = detector.processWord(composingBuffer)
            client.insertText(result.converted,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            composingBuffer = ""
        }
    }

    /// Cancel composition without committing.
    private func cancelComposition(client: IMKTextInput) {
        if isComposing {
            client.insertText("",
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            composingBuffer = ""
            pendingWord = nil
        }
    }

    /// Handle backspace — remove last character from buffer.
    private func handleBackspace(client: IMKTextInput) -> Bool {
        if !composingBuffer.isEmpty {
            composingBuffer.removeLast()
            if composingBuffer.isEmpty && pendingWord == nil {
                cancelComposition(client: client)
            } else {
                updateMarkedText(client: client)
            }
            return true
        } else if pendingWord != nil {
            // Backspace into the pending word
            pendingWord!.removeLast()
            if pendingWord!.isEmpty {
                pendingWord = nil
                cancelComposition(client: client)
            } else {
                updateMarkedText(client: client)
            }
            return true
        }
        return false  // Not composing, let the app handle backspace
    }

    // MARK: - Menu

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "LangAutoSwitcher")

        let currentDefault = detector.defaultLanguage
        let headerItem = NSMenuItem(title: "Default for unknown words:", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        let latinItem = NSMenuItem(title: "Keep Latin (EN)", action: #selector(setDefaultEnglish), keyEquivalent: "")
        latinItem.target = self
        latinItem.state = (currentDefault == .english) ? .on : .off
        menu.addItem(latinItem)

        let cyrillicItem = NSMenuItem(title: "Convert to Cyrillic (BG)", action: #selector(setDefaultBulgarian), keyEquivalent: "")
        cyrillicItem.target = self
        cyrillicItem.state = (currentDefault == .bulgarian) ? .on : .off
        menu.addItem(cyrillicItem)

        return menu
    }

    @objc private func setDefaultEnglish() {
        detector.defaultLanguage = .english
        NSLog("LangAutoSwitcher: Default set to English (Latin)")
    }

    @objc private func setDefaultBulgarian() {
        detector.defaultLanguage = .bulgarian
        NSLog("LangAutoSwitcher: Default set to Bulgarian (Cyrillic)")
    }

    // MARK: - Session lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        detector.resetContext()
        composingBuffer = ""
        pendingWord = nil
        NSLog("LangAutoSwitcher: Activated (default=%@)", detector.defaultLanguage.rawValue)
    }

    override func deactivateServer(_ sender: Any!) {
        let client = sender as! IMKTextInput
        forceCommitAll(client: client)
        super.deactivateServer(sender)
        NSLog("LangAutoSwitcher: Deactivated")
    }
}
