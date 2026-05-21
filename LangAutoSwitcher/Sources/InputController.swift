import Cocoa
import InputMethodKit
import Sparkle

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

    /// Whether the current app is a terminal — if so, pass all keys through directly.
    private var isTerminalApp = false

    /// Bundle ID of the currently focused app — needed by the menu so the
    /// "Disable for [app]" item knows which bundle to flip.
    private var currentBundleID: String? = nil

    /// Bundle IDs of known terminal/CLI apps where we should not intercept input.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "co.zeit.hyper",
        "com.qvacua.VimR",
        "org.vim.MacVim",
    ]

    /// Bundle ID prefixes that indicate terminal-like apps.
    private static let terminalPrefixes: [String] = [
        "com.microsoft.VSCode",   // VS Code (has integrated terminal)
        "com.jetbrains.",         // JetBrains IDEs (have integrated terminals)
    ]

    // MARK: - IMKInputController overrides

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        // In terminal apps, pass everything through — don't intercept
        if isTerminalApp {
            return false
        }

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

        // Arrow keys — user is navigating, not typing.
        // Commit raw Latin (like Enter) and let the arrow pass through.
        // Converting on navigation destroys the text the user is trying to edit.
        switch event.keyCode {
        case 123, 124, 125, 126:  // Left, Right, Down, Up
            commitRawLatin(client: client)
            return false
        default:
            break
        }

        let char = chars.first!

        // Handle special keys
        switch char {
        case "\r", "\n":
            // Return/Enter — commit raw Latin text WITHOUT conversion.
            // Space = convert, Enter = submit as-is.
            // This prevents Chrome address bar from getting Bulgarian text
            // when user wants to navigate to a URL or accept autocomplete.
            commitRawLatin(client: client)
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

        // Characters that map to Cyrillic should be buffered
        let mappableChars: Set<Character> = [
            "]", "[", ";", "'", "`", "\\",
            "}", "{", ":", "\"", "~", "|"
        ]
        // Email/URL/path chars — buffer them so we can detect emails/URLs and keep them Latin
        let emailUrlChars: Set<Character> = [".", "@", "-", "_", "/", "+"]
        let isLetter = char.isLetter && char.isASCII
        let isDigit = char.isNumber && char.isASCII
        let isMappable = isLetter || mappableChars.contains(char)
        let isEmailUrl = emailUrlChars.contains(char) || isDigit

        // Non-mappable, non-email chars: commit current word, pass through
        if !isMappable && !isEmailUrl {
            // Emoticon detection: buffer like ":", ";", "=", ":-", ":'" followed by
            // ")", "(", "*", "|" etc. should stay raw ASCII (e.g., ":)", ":-(", ":*").
            if Self.isEmoticonPrefix(composingBuffer) && Self.isEmoticonBody(char) {
                commitBufferRaw(client: client)
                return false  // Let the body char pass through to form the emoticon
            }
            forceCommitAll(client: client)
            return false  // Let the character pass through
        }

        // Email/URL/digit chars: only buffer if we're already composing
        // (otherwise let them pass through normally)
        if !isMappable && isEmailUrl && composingBuffer.isEmpty && pendingWord == nil {
            return false  // Let it pass through
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

        let rawBuffer = composingBuffer
        composingBuffer = ""

        // Strip trailing punctuation (., , ! ? : ;) before processing.
        // These get buffered for email/URL detection but shouldn't affect word detection.
        // Reattach after conversion.
        let trailingPunct: Set<Character> = [".", ",", "!", "?"]
        var word = rawBuffer
        var trailing = ""
        while let last = word.last, trailingPunct.contains(last) {
            trailing = String(last) + trailing
            word.removeLast()
        }

        // If only punctuation, just commit as-is
        guard !word.isEmpty else {
            client.insertText(trailing,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }

        // Emoticon detection: :D, :P, :-D, xD, etc. should stay raw ASCII.
        if Self.isEmoticon(word) {
            var fullText = ""
            if let pending = pendingWord {
                let result = detector.processWord(pending)
                fullText = result.converted + " "
                pendingWord = nil
            }
            fullText += word + trailing
            client.insertText(fullText,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }

        // Email/URL detection: if buffer contains @ or has URL-like patterns,
        // commit as raw Latin without conversion.
        if isEmailOrUrl(word) {
            // Commit pending word too if any (also as raw, since it's likely the local-part)
            var fullText = ""
            if let pending = pendingWord {
                fullText = pending
            }
            fullText += word + trailing
            client.insertText(fullText,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            pendingWord = nil
            return
        }

        // Hyphenated words: split on hyphen, process each part, rejoin.
        if word.contains("-") {
            let parts = word.split(separator: "-", omittingEmptySubsequences: false)
            let converted = parts.map { part -> String in
                let partStr = String(part)
                if partStr.isEmpty { return "" }
                let result = detector.processWord(partStr)
                return result.converted
            }
            let output = converted.joined(separator: "-") + trailing

            if let pending = pendingWord {
                let pendingCyrillic = PhoneticMapper.toCyrillic(pending)
                let firstResult = detector.processWord(String(parts.first ?? ""))
                let pendingOutput = firstResult.language == .bulgarian ? pendingCyrillic : pending
                client.insertText(pendingOutput + " " + output,
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
                pendingWord = nil
            } else {
                client.insertText(output,
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            return
        }

        // Check if this word is ambiguous (in both dictionaries)
        let lower = word.lowercased()
        let cyrillic = PhoneticMapper.toCyrillic(word)
        let cyrillicLower = cyrillic.lowercased()
        let isEnglish = detector.enDictionary.contains(lower)
        let isBulgarian = detector.bgDictionary.contains(cyrillicLower)
        let isAmbiguous = isEnglish && isBulgarian

        if pendingWord != nil {
            let secondResult = detector.processWord(word)
            let pendingCyrillic = PhoneticMapper.toCyrillic(pendingWord!)
            let pendingOutput: String
            if secondResult.language == .bulgarian {
                pendingOutput = pendingCyrillic
            } else {
                pendingOutput = pendingWord!
            }

            NSLog("LangAutoSwitcher: pending '%@' → '%@' (resolved by '%@'→'%@' [%@])",
                  pendingWord!, pendingOutput, word, secondResult.converted, secondResult.language.rawValue)

            let fullText = pendingOutput + " " + secondResult.converted + trailing
            client.insertText(fullText,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            pendingWord = nil

        } else if isAmbiguous && detector.isFirstWord {
            // First word, ambiguous — hold it. Reattach trailing to buffer for later.
            pendingWord = word
            // If there's trailing punctuation, we can't hold — force commit
            if !trailing.isEmpty {
                let result = detector.processWord(word)
                client.insertText(result.converted + trailing,
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
                pendingWord = nil
            } else {
                NSLog("LangAutoSwitcher: holding ambiguous first word '%@'", word)
                updateMarkedText(client: client)
            }

        } else {
            let result = detector.processWord(word)

            NSLog("LangAutoSwitcher: '%@' → '%@' [%@, %.2f]",
                  word, result.converted,
                  result.language.rawValue, result.confidence)

            client.insertText(result.converted + trailing,
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

    /// Detect if a word is an email, URL, file path, or similar Latin-only construct.
    private func isEmailOrUrl(_ word: String) -> Bool {
        // Contains @ → email
        if word.contains("@") { return true }
        // Contains / → URL or path
        if word.contains("/") { return true }
        // Contains a digit → likely identifier/code/version
        if word.contains(where: { $0.isNumber }) { return true }
        // Contains . with letters around it → domain (e.g., gmail.com, foo.bar)
        if word.contains(".") {
            let parts = word.split(separator: ".")
            if parts.count >= 2 && parts.allSatisfy({ !$0.isEmpty }) {
                return true
            }
        }
        return false
    }

    // MARK: - Emoticon detection

    /// Buffer contents that, followed by an emoticon body char, form an emoticon.
    /// (Used before force-commit when next char is non-mappable punctuation like ")")
    private static let emoticonPrefixes: Set<String> = [
        ":", ";", "=", ":-", ";-", "=-", ":'", ";'",
    ]

    /// Non-mappable, non-email chars that indicate an emoticon body
    /// when they follow an emoticon prefix (e.g., ")" in ":)", "*" in ":*").
    private static let emoticonBodyChars: Set<Character> = [
        ")", "(", "*", "|",
    ]

    /// Complete emoticons that may end up fully buffered and committed via space/punct.
    /// These typically have letter bodies (D, P, O) or digit bodies (3) that stay in buffer.
    private static let knownEmoticons: Set<String> = [
        ":D", ":P", ":p", ":O", ":o", ":3", ":X", ":x",
        ";D", ";P", ";p",
        "=D", "=P", "=p",
        ":-D", ":-P", ":-p", ":-O", ":-o", ":-3",
        ";-D", ";-P", ";-p",
        ":'D",
        "xD", "XD", "xP", "XP",
    ]

    private static func isEmoticonPrefix(_ buffer: String) -> Bool {
        emoticonPrefixes.contains(buffer)
    }

    private static func isEmoticonBody(_ char: Character) -> Bool {
        emoticonBodyChars.contains(char)
    }

    static func isEmoticon(_ word: String) -> Bool {
        knownEmoticons.contains(word)
    }

    /// Commit pending word (converted normally) + composing buffer (raw ASCII).
    /// Used when buffer is an emoticon prefix and the upcoming char completes it.
    private func commitBufferRaw(client: IMKTextInput) {
        var output = ""
        if let pending = pendingWord {
            let result = detector.processWord(pending)
            output = result.converted + " "
            pendingWord = nil
        }
        output += composingBuffer
        composingBuffer = ""
        if !output.isEmpty {
            client.insertText(output,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// Commit raw Latin text without any conversion.
    /// Used on Enter — the user wants to submit/accept what they see, not convert.
    private func commitRawLatin(client: IMKTextInput) {
        var raw = ""
        if let pending = pendingWord {
            raw += pending + " "
        }
        if !composingBuffer.isEmpty {
            raw += composingBuffer
        }
        if !raw.isEmpty {
            client.insertText(raw,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        composingBuffer = ""
        pendingWord = nil
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

        menu.addItem(NSMenuItem.separator())

        let autocorrectItem = NSMenuItem(title: "Автокорекция (w → with)",
                                         action: #selector(toggleAutocorrect),
                                         keyEquivalent: "")
        autocorrectItem.target = self
        autocorrectItem.state = detector.autocorrectEnabled ? .on : .off
        menu.addItem(autocorrectItem)

        menu.addItem(NSMenuItem.separator())

        // Per-app pass-through: lets the user disable interception in apps
        // that mishandle IMK composition (live-search fields, VNC password
        // boxes, Chromium omniboxes, etc.).
        if let bundle = currentBundleID {
            let excluded = AppExclusionManager.isExcluded(bundle)
            let title = excluded
                ? "Включи отново за: \(bundle)"
                : "Изключи за: \(bundle)"
            let appToggle = NSMenuItem(title: title,
                                       action: #selector(toggleCurrentAppExclusion),
                                       keyEquivalent: "")
            appToggle.target = self
            appToggle.state = excluded ? .on : .off
            menu.addItem(appToggle)
        }

        let editExclusionsItem = NSMenuItem(title: "Редактирай списъка с изключения…",
                                            action: #selector(editExcludedApps),
                                            keyEquivalent: "")
        editExclusionsItem.target = self
        menu.addItem(editExclusionsItem)

        let reloadExclusionsItem = NSMenuItem(title: "Презареди списъка с изключения",
                                              action: #selector(reloadExcludedApps),
                                              keyEquivalent: "")
        reloadExclusionsItem.target = self
        menu.addItem(reloadExclusionsItem)

        menu.addItem(NSMenuItem.separator())

        let editKeymapItem = NSMenuItem(title: "Edit Keymap…",
                                        action: #selector(editKeymap),
                                        keyEquivalent: "")
        editKeymapItem.target = self
        menu.addItem(editKeymapItem)

        let reloadKeymapItem = NSMenuItem(title: "Reload Keymap",
                                          action: #selector(reloadKeymap),
                                          keyEquivalent: "")
        reloadKeymapItem.target = self
        menu.addItem(reloadKeymapItem)

        let resetKeymapItem = NSMenuItem(title: "Reset Keymap to Defaults",
                                         action: #selector(resetKeymap),
                                         keyEquivalent: "")
        resetKeymapItem.target = self
        menu.addItem(resetKeymapItem)

        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(title: "Check for Updates…",
                                    action: #selector(checkForUpdates),
                                    keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        return menu
    }

    @objc private func editKeymap() {
        // Open the JSON file in the user's default JSON handler (usually TextEdit).
        NSWorkspace.shared.open(KeymapManager.fileURL)
    }

    @objc private func reloadKeymap() {
        KeymapManager.loadAndApply()
    }

    @objc private func resetKeymap() {
        KeymapManager.resetToDefaults()
    }

    @objc private func setDefaultEnglish() {
        detector.defaultLanguage = .english
        NSLog("LangAutoSwitcher: Default set to English (Latin)")
    }

    @objc private func setDefaultBulgarian() {
        detector.defaultLanguage = .bulgarian
        NSLog("LangAutoSwitcher: Default set to Bulgarian (Cyrillic)")
    }

    @objc private func toggleAutocorrect() {
        detector.autocorrectEnabled.toggle()
        NSLog("LangAutoSwitcher: Autocorrect %@",
              detector.autocorrectEnabled ? "ON" : "OFF")
    }

    @objc private func toggleCurrentAppExclusion() {
        guard let bundle = currentBundleID else { return }
        if AppExclusionManager.isExcluded(bundle) {
            AppExclusionManager.include(bundle)
            isTerminalApp = Self.terminalBundleIDs.contains(bundle)
                || Self.terminalPrefixes.contains(where: { bundle.hasPrefix($0) })
        } else {
            AppExclusionManager.exclude(bundle)
            isTerminalApp = true
            // If we were mid-composition, drop it cleanly; nothing more we
            // can do for this session since we won't intercept any more keys.
            composingBuffer = ""
            pendingWord = nil
        }
    }

    @objc private func editExcludedApps() {
        NSWorkspace.shared.open(AppExclusionManager.fileURL)
    }

    @objc private func reloadExcludedApps() {
        AppExclusionManager.reload()
        // Re-evaluate the current app's status against the freshly loaded list.
        if let bundle = currentBundleID {
            let wasExcluded = isTerminalApp
            let nowExcluded = Self.terminalBundleIDs.contains(bundle)
                || AppExclusionManager.isExcluded(bundle)
                || Self.terminalPrefixes.contains(where: { bundle.hasPrefix($0) })
            isTerminalApp = nowExcluded
            if wasExcluded != nowExcluded {
                NSLog("LangAutoSwitcher: passthrough for '%@' is now %@",
                      bundle, nowExcluded ? "ON" : "OFF")
            }
        }
    }

    @objc private func checkForUpdates() {
        // `updaterController` is the SPUStandardUpdaterController declared at
        // top level in main.swift; visible to other files in the same module.
        updaterController.checkForUpdates(nil)
    }

    // MARK: - Session lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        detector.resetContext()
        composingBuffer = ""
        pendingWord = nil

        // Detect if we're in a terminal app or a user-excluded app
        isTerminalApp = false
        currentBundleID = nil
        if let client = sender as? IMKTextInput,
           let bundleID = client.bundleIdentifier() {
            currentBundleID = bundleID
            if Self.terminalBundleIDs.contains(bundleID) {
                isTerminalApp = true
            } else if AppExclusionManager.isExcluded(bundleID) {
                isTerminalApp = true
            } else {
                for prefix in Self.terminalPrefixes {
                    if bundleID.hasPrefix(prefix) {
                        isTerminalApp = true
                        break
                    }
                }
            }
            NSLog("LangAutoSwitcher: Activated for '%@' (passthrough=%d, default=%@)",
                  bundleID, isTerminalApp, detector.defaultLanguage.rawValue)
        }
    }

    override func deactivateServer(_ sender: Any!) {
        let client = sender as! IMKTextInput
        forceCommitAll(client: client)
        super.deactivateServer(sender)
        NSLog("LangAutoSwitcher: Deactivated")
    }
}
