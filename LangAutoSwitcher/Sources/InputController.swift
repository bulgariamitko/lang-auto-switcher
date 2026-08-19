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

    /// Shared across all controllers — IMK creates one controller per focused
    /// text field, and the detector owns ~468k dictionary entries.
    private let detector = LanguageDetector.shared

    /// Buffer of Latin characters for the word currently being composed.
    private var composingBuffer = ""

    /// Whether we are actively composing (have uncommitted text).
    private var isComposing: Bool { !composingBuffer.isEmpty || pendingWord != nil }

    /// A word that was ambiguous (in both dictionaries, no context).
    /// We hold it and wait for the next word to decide its language.
    private var pendingWord: String? = nil

    /// The last commit where conversion actually changed the text
    /// (original as typed, converted as inserted). ⌥⌘Z reverts it and
    /// remembers the word as always-Latin.
    private var lastConversion: (original: String, converted: String)? = nil

    /// The last committed word regardless of whether conversion changed it
    /// (original Latin as typed, output as inserted). ⌥⌘B forces it to
    /// Bulgarian and remembers it as always-Bulgarian — this needs the
    /// unchanged case too (a word that stayed Latin), which `lastConversion`
    /// deliberately drops.
    private var lastCommitted: (original: String, output: String)? = nil

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

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Backspace/Delete (keyCode 51) is handled by keyCode here — BEFORE the
        // `characters` guard below — so it is reliably consumed while composing.
        // Some apps/contexts deliver a Delete keyDown with an empty `characters`
        // payload; if that slips past the guard and returns false mid-word, the
        // app deletes an on-screen character while our composing buffer keeps
        // it. The two desync, so the word commits with a stray/dropped letter
        // ("neseru"+⌫+"iozno" → "neseruiozno") which isn't in the dictionary and
        // lands in Latin instead of converting to "несериозно". Plain Delete
        // only — let Cmd/Opt+Delete fall through to their existing handling.
        if TextHeuristics.isPlainBackspace(keyCode: event.keyCode,
                                           command: modifiers.contains(.command),
                                           option: modifiers.contains(.option)) {
            if isComposing {
                return handleBackspace(client: client)
            }
            return false  // not composing — let the app delete normally
        }

        // Get the characters
        guard let chars = event.characters, !chars.isEmpty else {
            return false
        }

        // ⌥⌘Z — revert the last auto-conversion and remember the word as
        // always-Latin, so it is never converted again.
        if modifiers.contains(.command), modifiers.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            revertLastConversion(client: client)
            return true
        }

        // ⌥⌘B — force the last committed word to Bulgarian and remember it as
        // always-Bulgarian, so an out-of-dictionary word ("клипчета") converts
        // from now on without editing the dictionary file.
        if modifiers.contains(.command), modifiers.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "b" {
            forceLastWordToBulgarian(client: client)
            return true
        }

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
            "}", "{", ":", "\"", "~", "|",
            // ISO Mac §/± key (top-left, left of 1) — alternate ч/Ч
            "§", "±"
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
            if TextHeuristics.isEmoticonPrefix(composingBuffer) && TextHeuristics.isEmoticonBody(char) {
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

        // Strip trailing punctuation (., , ! ?) before processing.
        // These get buffered for email/URL detection but shouldn't affect word detection.
        // Reattach after conversion.
        let (word, trailing) = TextHeuristics.splitTrailingPunctuation(rawBuffer)

        // If only punctuation, just commit as-is
        guard !word.isEmpty else {
            client.insertText(trailing,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }

        // Emoticon detection: :D, :P, :-D, xD, etc. should stay raw ASCII.
        if TextHeuristics.isEmoticon(word) {
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

        // Numbers stuck to a word ("2години", "години2", "2ри"): a digit
        // anywhere in a token otherwise makes isEmailOrUrl keep the whole
        // thing Latin. Peel edge digits and, if the letter core is a clear
        // Bulgarian word, convert just the core and reattach the digits.
        // Identifiers (mp3, covid19, v2) have a non-BG core and fall through.
        if pendingWord == nil {
            let (lead, core, trail) = TextHeuristics.splitEdgeDigits(word)
            if (!lead.isEmpty || !trail.isEmpty),
               !core.isEmpty,
               !core.contains(where: { $0.isNumber }),
               !TextHeuristics.isEmailOrUrl(core) {
                let coreCyrillic = PhoneticMapper.toCyrillic(core).lowercased()
                let coreIsBG = detector.bgDictionary.contains(coreCyrillic)
                let coreIsEN = detector.enDictionary.contains(core.lowercased())
                if coreIsBG && !coreIsEN {
                    let result = detector.processWord(core)
                    let converted = lead + result.converted + trail
                    client.insertText(converted + trailing,
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
                    recordConversion(original: word, converted: converted)
                    return
                }
            }
        }

        // Email/URL detection: if buffer contains @ or has URL-like patterns,
        // commit as raw Latin without conversion.
        if TextHeuristics.isEmailOrUrl(word) {
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
            let joined = converted.joined(separator: "-")
            let output = joined + trailing
            recordConversion(original: word, converted: joined)

            if let pending = pendingWord {
                let pendingCyrillic = PhoneticMapper.toCyrillic(pending)
                let firstResult = detector.processWord(String(parts.first ?? ""))
                let pendingOutput = firstResult.language.isBase ? pending : pendingCyrillic
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

        if let pending = pendingWord {
            // Decide the held word using BOTH neighbours, then the current
            // word with the held one in context. The core does the ordering.
            let resolved = detector.resolvePending(pending, next: word)
            let pendingOutput = resolved.pending.converted
            let secondResult = resolved.next

            NSLog("LangAutoSwitcher: pending '%@' → '%@' [%@] (resolved by '%@'→'%@' [%@])",
                  pending, pendingOutput, detector.code(for: resolved.pending.language),
                  word, secondResult.converted, detector.code(for: secondResult.language))

            let fullText = pendingOutput + " " + secondResult.converted + trailing
            client.insertText(fullText,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            // Prefer the most recent converted token for ⌥⌘Z.
            if secondResult.converted != word {
                recordConversion(original: word, converted: secondResult.converted)
            } else {
                recordConversion(original: pending, converted: pendingOutput)
            }
            pendingWord = nil

        } else if isAmbiguous && !detector.lastContextIsDecisive {
            // Ambiguous (a real word in both languages) AND the word on the
            // left didn't settle it — "laptop"/"лаптоп" is the canonical case.
            // Hold it and let the word on the right cast the deciding vote.
            //
            // Deliberately NOT held when the left neighbour was an exact
            // single-dictionary hit: that is already the strongest signal we
            // record, so waiting would add a visible delay and change nothing.
            // In practice this holds roughly 1 word in 20 rather than the
            // 1 in 5 that "hold every ambiguous word" would cost.
            pendingWord = word
            // If there's trailing punctuation, we can't hold — force commit
            if !trailing.isEmpty {
                let result = detector.processWord(word)
                client.insertText(result.converted + trailing,
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
                recordConversion(original: word, converted: result.converted)
                pendingWord = nil
            } else {
                NSLog("LangAutoSwitcher: holding ambiguous first word '%@'", word)
                updateMarkedText(client: client)
            }

        } else {
            let result = detector.processWord(word)

            NSLog("LangAutoSwitcher: '%@' → '%@' [%@, %.2f]",
                  word, result.converted,
                  detector.code(for: result.language), result.confidence)

            client.insertText(result.converted + trailing,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            recordConversion(original: word, converted: result.converted)
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
                recordConversion(original: pending, converted: result.converted)
            } else {
                // Pending + space + current word. The buffered word is the
                // right-hand neighbour we were waiting for, so resolve the
                // pair the same way the normal path does.
                let resolved = detector.resolvePending(pending, next: currentWord)
                let pendingOutput = resolved.pending.converted
                let secondResult = resolved.next
                let fullText = pendingOutput + " " + secondResult.converted
                client.insertText(fullText,
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
                if secondResult.converted != currentWord {
                    recordConversion(original: currentWord, converted: secondResult.converted)
                } else {
                    recordConversion(original: pending, converted: pendingOutput)
                }
            }

            pendingWord = nil
            composingBuffer = ""
        } else if !composingBuffer.isEmpty {
            let result = detector.processWord(composingBuffer)
            client.insertText(result.converted,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
            recordConversion(original: composingBuffer, converted: result.converted)
            composingBuffer = ""
        }
    }

    // MARK: - Revert + learn

    /// Revert the last auto-conversion: replace the converted text (still
    /// sitting right before the caret) with the original Latin word, and
    /// remember the word so it is never converted again.
    private func revertLastConversion(client: IMKTextInput) {
        guard let last = lastConversion, last.converted != last.original else {
            NSLog("LangAutoSwitcher: revert requested but nothing to revert")
            return
        }

        let sel = client.selectedRange()
        guard sel.location != NSNotFound, sel.location > 0 else { return }

        // Look back a small window before the caret (converted word plus a
        // few chars of punctuation/whitespace) and find the converted text.
        let convertedLen = (last.converted as NSString).length
        let lookback = min(sel.location, convertedLen + 8)
        let windowRange = NSRange(location: sel.location - lookback, length: lookback)
        guard let attr = client.attributedSubstring(from: windowRange) else {
            NSLog("LangAutoSwitcher: revert failed — client won't give us surrounding text")
            return
        }
        let window = attr.string as NSString
        let found = window.range(of: last.converted, options: .backwards)
        guard found.location != NSNotFound else {
            NSLog("LangAutoSwitcher: revert failed — '%@' not found near caret", last.converted)
            return
        }

        let absolute = NSRange(location: windowRange.location + found.location,
                               length: found.length)
        client.insertText(last.original, replacementRange: absolute)
        detector.learnLatinWord(last.original)
        lastConversion = nil
        NSLog("LangAutoSwitcher: reverted '%@' → '%@' and learned it",
              last.converted, last.original)
    }

    /// Force the last committed word to Bulgarian: replace the text sitting
    /// before the caret with its Cyrillic transliteration and remember the word
    /// as always-Bulgarian, so it converts automatically from now on. The
    /// mirror image of `revertLastConversion`.
    private func forceLastWordToBulgarian(client: IMKTextInput) {
        guard let last = lastCommitted else {
            NSLog("LangAutoSwitcher: force-to-BG requested but nothing committed yet")
            return
        }
        let cyrillic = PhoneticMapper.toCyrillic(last.original)
        // Always remember it so future occurrences convert on their own.
        detector.learnBulgarianWord(last.original)

        // If what we already inserted is identical to the Cyrillic form, there
        // is nothing on screen to replace — just learning it is enough.
        guard cyrillic != last.output else {
            NSLog("LangAutoSwitcher: '%@' already Bulgarian; learned it", last.original)
            lastCommitted = nil
            return
        }

        let sel = client.selectedRange()
        guard sel.location != NSNotFound, sel.location > 0 else { return }

        // Look back a small window before the caret and find the text we
        // inserted, so we can swap it for the Cyrillic form in place.
        let outputLen = (last.output as NSString).length
        let lookback = min(sel.location, outputLen + 8)
        let windowRange = NSRange(location: sel.location - lookback, length: lookback)
        guard let attr = client.attributedSubstring(from: windowRange) else {
            NSLog("LangAutoSwitcher: force-to-BG failed — client won't give us surrounding text")
            return
        }
        let window = attr.string as NSString
        let found = window.range(of: last.output, options: .backwards)
        guard found.location != NSNotFound else {
            NSLog("LangAutoSwitcher: force-to-BG failed — '%@' not found near caret", last.output)
            return
        }

        let absolute = NSRange(location: windowRange.location + found.location,
                               length: found.length)
        client.insertText(cyrillic, replacementRange: absolute)
        // The forward swap is itself revertible with ⌥⌘Z.
        lastConversion = (last.original, cyrillic)
        lastCommitted = (last.original, cyrillic)
        NSLog("LangAutoSwitcher: forced '%@' → '%@' and learned it as Bulgarian",
              last.output, cyrillic)
    }

    /// Record a commit so ⌥⌘Z can revert it (only when conversion changed the
    /// text) and ⌥⌘B can force it to Bulgarian (always, even unchanged).
    private func recordConversion(original: String, converted: String) {
        lastCommitted = (original, converted)
        if original != converted {
            lastConversion = (original, converted)
        }
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

        // Language management lives in dialogs rather than submenus.
        // IMK does not dispatch actions for items nested inside a submenu —
        // the menu renders and the click does nothing at all — and it also
        // hands actions an NSDictionary rather than the clicked NSMenuItem.
        // Both problems disappear if every menu action is a plain top-level
        // item that takes no arguments and asks its question in a dialog.
        let active = detector.activeLanguages
            .map { detector.languageName(for: $0) }
            .joined(separator: ", ")
        let header = NSMenuItem(title: MenuStrings.t(.languages) + ": " + active,
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let mainItem = NSMenuItem(title: MenuStrings.t(.leadLanguage) + "…",
                                  action: #selector(chooseLeadLanguage), keyEquivalent: "")
        mainItem.target = self
        menu.addItem(mainItem)

        let addItem = NSMenuItem(title: MenuStrings.t(.addLanguage),
                                 action: #selector(chooseLanguageToAdd), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)

        if detector.activeLanguages.count > 1 {
            let removeItem = NSMenuItem(title: MenuStrings.t(.removeLanguageMenu),
                                        action: #selector(chooseLanguageToRemove), keyEquivalent: "")
            removeItem.target = self
            menu.addItem(removeItem)
        }

        menu.addItem(NSMenuItem.separator())

        let autocorrectItem = NSMenuItem(title: MenuStrings.t(.autocorrect),
                                         action: #selector(toggleAutocorrect),
                                         keyEquivalent: "")
        autocorrectItem.target = self
        autocorrectItem.state = detector.autocorrectEnabled ? .on : .off
        menu.addItem(autocorrectItem)

        let typoFixItem = NSMenuItem(title: MenuStrings.t(.fixTypos),
                                     action: #selector(toggleTypoCorrection),
                                     keyEquivalent: "")
        typoFixItem.target = self
        typoFixItem.state = detector.typoCorrectionEnabled ? .on : .off
        menu.addItem(typoFixItem)

        menu.addItem(NSMenuItem.separator())

        // Per-app pass-through: lets the user disable interception in apps
        // that mishandle IMK composition (live-search fields, VNC password
        // boxes, Chromium omniboxes, etc.).
        if let bundle = currentBundleID {
            let excluded = AppExclusionManager.isExcluded(bundle)
            let title = excluded
                ? MenuStrings.t(.enableForApp, bundle)
                : MenuStrings.t(.disableForApp, bundle)
            let appToggle = NSMenuItem(title: title,
                                       action: #selector(toggleCurrentAppExclusion),
                                       keyEquivalent: "")
            appToggle.target = self
            appToggle.state = excluded ? .on : .off
            menu.addItem(appToggle)
        }

        let editExclusionsItem = NSMenuItem(title: MenuStrings.t(.editExclusions),
                                            action: #selector(editExcludedApps),
                                            keyEquivalent: "")
        editExclusionsItem.target = self
        menu.addItem(editExclusionsItem)

        let reloadExclusionsItem = NSMenuItem(title: MenuStrings.t(.reloadExclusions),
                                              action: #selector(reloadExcludedApps),
                                              keyEquivalent: "")
        reloadExclusionsItem.target = self
        menu.addItem(reloadExclusionsItem)

        menu.addItem(NSMenuItem.separator())

        let showKeyboardItem = NSMenuItem(title: MenuStrings.t(.showKeyboard),
                                          action: #selector(showKeyboardChart), keyEquivalent: "")
        showKeyboardItem.target = self
        menu.addItem(showKeyboardItem)

        let editKeymapItem = NSMenuItem(title: MenuStrings.t(.editKeymap),
                                        action: #selector(editKeymap),
                                        keyEquivalent: "")
        editKeymapItem.target = self
        menu.addItem(editKeymapItem)

        let reloadKeymapItem = NSMenuItem(title: MenuStrings.t(.reloadKeymap),
                                          action: #selector(reloadKeymap),
                                          keyEquivalent: "")
        reloadKeymapItem.target = self
        menu.addItem(reloadKeymapItem)

        let resetKeymapItem = NSMenuItem(title: MenuStrings.t(.resetKeymap),
                                         action: #selector(resetKeymap),
                                         keyEquivalent: "")
        resetKeymapItem.target = self
        menu.addItem(resetKeymapItem)

        menu.addItem(NSMenuItem.separator())

        // Learned ("always Latin") words — populated by ⌥⌘Z reverts.
        let revertItem = NSMenuItem(title: MenuStrings.t(.revertLastWord),
                                    action: #selector(revertFromMenu),
                                    keyEquivalent: "")
        revertItem.target = self
        revertItem.isEnabled = lastConversion != nil
        menu.addItem(revertItem)

        let editLearnedItem = NSMenuItem(title: MenuStrings.t(.learnedWords, "\(detector.learnedWordCount)"),
                                         action: #selector(editLearnedWords),
                                         keyEquivalent: "")
        editLearnedItem.target = self
        menu.addItem(editLearnedItem)

        let reloadLearnedItem = NSMenuItem(title: MenuStrings.t(.reloadLearned),
                                           action: #selector(reloadLearnedWordsAction),
                                           keyEquivalent: "")
        reloadLearnedItem.target = self
        menu.addItem(reloadLearnedItem)

        let clearLearnedItem = NSMenuItem(title: MenuStrings.t(.forgetLearned),
                                          action: #selector(clearLearnedWordsAction),
                                          keyEquivalent: "")
        clearLearnedItem.target = self
        menu.addItem(clearLearnedItem)

        menu.addItem(NSMenuItem.separator())

        // Forced ("always Bulgarian") words — populated by ⌥⌘B.
        let forceItem = NSMenuItem(title: MenuStrings.t(.forceToLanguage, detector.languageName(for: LanguagePackStore.leadCode)),
                                   action: #selector(forceBulgarianFromMenu),
                                   keyEquivalent: "")
        forceItem.target = self
        forceItem.isEnabled = lastCommitted != nil
        menu.addItem(forceItem)

        let clearForcedItem = NSMenuItem(
            title: MenuStrings.t(.forgetForcedWords, "\(detector.forcedBgWordCount)"),
            action: #selector(clearForcedBgWordsAction),
            keyEquivalent: "")
        clearForcedItem.target = self
        clearForcedItem.isEnabled = detector.forcedBgWordCount > 0
        menu.addItem(clearForcedItem)

        menu.addItem(NSMenuItem.separator())

        let diagnosticsItem = NSMenuItem(title: MenuStrings.t(.diagnostics),
                                         action: #selector(showDiagnostics),
                                         keyEquivalent: "")
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

        let updateItem = NSMenuItem(title: MenuStrings.t(.checkForUpdates),
                                    action: #selector(checkForUpdates),
                                    keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        return menu
    }

    @objc private func revertFromMenu() {
        guard let client = client() else { return }
        revertLastConversion(client: client)
    }

    @objc private func forceBulgarianFromMenu() {
        guard let client = client() else { return }
        forceLastWordToBulgarian(client: client)
    }

    @objc private func clearForcedBgWordsAction() {
        detector.clearForcedBgWords()
    }

    @objc private func editLearnedWords() {
        UserWordsManager.ensureFileExists()
        NSWorkspace.shared.open(UserWordsManager.fileURL)
    }

    @objc private func reloadLearnedWordsAction() {
        detector.reloadLearnedWords()
    }

    @objc private func clearLearnedWordsAction() {
        detector.clearLearnedWords()
    }

    @objc private func showDiagnostics() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        var buildDate = "unknown"
        if let exeURL = bundle.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: exeURL.path),
           let modified = attrs[.modificationDate] as? Date {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            buildDate = fmt.string(from: modified)
        }

        let counts = detector.dictionaryCounts
        let coreStatus = detector.isPassThrough
            ? "❌ FAILED — pass-through mode (no conversion)"
            : "OK"

        let lines = [
            "Version: \(version) (build \(build))",
            "Binary date: \(buildDate)",
            "Rust core: \(coreStatus)",
            "EN dictionary: \(counts.en) words",
            "BG dictionary: \(counts.bg) words",
            "Learned (always Latin) words: \(detector.learnedWordCount)",
            "Autocorrect: \(detector.autocorrectEnabled ? "on" : "off")",
            "Typo correction: \(detector.typoCorrectionEnabled ? "on" : "off")",
            "Default for unknown words: \(detector.code(for: detector.defaultLanguage))",
            "Current app: \(currentBundleID ?? "—") (passthrough: \(isTerminalApp ? "yes" : "no"))",
        ]

        let alert = NSAlert()
        alert.messageText = "LangAutoSwitcher Diagnostics"
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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

    /// Make a language the lead: it wins ambiguous words and the menu is
    /// written in it from now on.
    /// Run a block that puts something on screen.
    ///
    /// The app ships with LSBackgroundOnly, which pins the activation policy to
    /// `.prohibited` — a process in that state cannot display ANY window, so
    /// `runModal()` returns immediately having shown nothing. That is why the
    /// first attempts at a confirmation dialog appeared to do nothing at all.
    /// Switching to `.accessory` for the duration allows windows without
    /// putting the input method in the Dock, and the policy is restored after.
    private func withVisibleUI<T>(_ body: () -> T) -> T {
        let previous = NSApp.activationPolicy()
        if previous != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.activate(ignoringOtherApps: true)
        defer {
            if previous != .accessory {
                NSApp.setActivationPolicy(previous)
            }
        }
        return body()
    }

    /// Ask the user to pick from a list, returning the chosen index.
    ///
    /// A popup inside an alert rather than a menu of menus: this app owns no
    /// windows, and IMK will not deliver clicks from a submenu, so a dialog is
    /// the only place a choice can reliably be made.
    private func askToChoose(title: String, message: String, options: [String]) -> Int? {
        guard !options.isEmpty else {
            showMessage(title, MenuStrings.t(.nothingToChoose))
            return nil
        }
        return withVisibleUI {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: MenuStrings.t(.ok))
            alert.addButton(withTitle: MenuStrings.t(.cancel))

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26),
                                      pullsDown: false)
            popup.addItems(withTitles: options)
            alert.accessoryView = popup
            alert.window.level = .floating
            alert.window.makeKeyAndOrderFront(nil)

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return popup.indexOfSelectedItem
        }
    }

    @objc private func chooseLanguageToAdd() {
        DebugLog.write("chooseLanguageToAdd opened (policy=\(NSApp.activationPolicy().rawValue))")
        let active = Set(detector.activeLanguages)
        let candidates = KeyboardLayoutReader.availableLanguages()
            .filter { !active.contains($0.languageCode) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        guard let choice = askToChoose(title: MenuStrings.t(.addLanguage),
                                       message: MenuStrings.t(.addLanguagePrompt),
                                       options: candidates.map { $0.displayName }),
              choice < candidates.count else { return }

        let picked = candidates[choice]
        DebugLog.write("chose \(picked.languageCode) (\(picked.displayName))")

        if LanguagePackStore.isInstalled(picked.languageCode) {
            LanguagePackStore.addLanguage(picked.languageCode)
            notifyLanguageAdded(picked.displayName)
            return
        }
        showMessage(MenuStrings.t(.downloading, picked.displayName),
                    MenuStrings.t(.downloadingBody))
        DictionaryDownloader.install(picked.languageCode) { result in
            switch result {
            case .success(let n):
                DebugLog.write("download ok for \(picked.languageCode): \(n) words")
                LanguagePackStore.addLanguage(picked.languageCode)
                self.notifyLanguageAdded(picked.displayName)
            case .failure(let error):
                DebugLog.write("download FAILED for \(picked.languageCode): \(error.localizedDescription)")
                self.showMessage(MenuStrings.t(.noDictionary, picked.displayName),
                                 error.localizedDescription, style: .warning)
            }
        }
    }

    /// Show which key types which letter, for a language of the user's
    /// choosing. macOS's Keyboard Viewer cannot do this: it shows the selected
    /// input source, which while we are active is plain ABC.
    @objc private func showKeyboardChart() {
        DebugLog.write("showKeyboardChart opened")
        let codes = detector.activeLanguages
        let names = codes.map { detector.languageName(for: $0) }
        guard let choice = askToChoose(title: MenuStrings.t(.showKeyboard),
                                       message: MenuStrings.t(.showKeyboardPrompt),
                                       options: names),
              choice < codes.count else { return }

        let code = codes[choice]
        let chart = KeyboardChart.render(keymap: detector.keymapPairs(for: code),
                                         languageName: names[choice])
        withVisibleUI {
            let alert = NSAlert()
            alert.messageText = names[choice]
            alert.addButton(withTitle: MenuStrings.t(.ok))
            let text = NSTextField(labelWithString: chart)
            text.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            text.sizeToFit()
            alert.accessoryView = text
            alert.window.level = .floating
            alert.window.makeKeyAndOrderFront(nil)
            alert.runModal()
        }
    }

    @objc private func chooseLeadLanguage() {
        DebugLog.write("chooseLeadLanguage opened")
        let codes = detector.activeLanguages
        let names = codes.map { detector.languageName(for: $0) }
        guard let choice = askToChoose(title: MenuStrings.t(.leadLanguage),
                                       message: MenuStrings.t(.leadLanguagePrompt),
                                       options: names),
              choice < codes.count else { return }
        let code = codes[choice]
        LanguagePackStore.leadCode = code
        if let i = detector.index(of: code) {
            detector.defaultLanguage = .language(i)
        }
        DebugLog.write("main language is now \(code)")
        showMessage(MenuStrings.t(.leadLanguage), MenuStrings.t(.leadLanguageSet, names[choice]))
    }

    @objc private func chooseLanguageToRemove() {
        DebugLog.write("chooseLanguageToRemove opened")
        let codes = detector.activeLanguages.filter { $0 != LanguagePackStore.baseCode }
        let names = codes.map { detector.languageName(for: $0) }
        guard let choice = askToChoose(title: MenuStrings.t(.removeLanguageMenu),
                                       message: MenuStrings.t(.removeLanguagePrompt),
                                       options: names),
              choice < codes.count else { return }
        LanguagePackStore.removeLanguage(codes[choice])
        DebugLog.write("removed \(codes[choice])")
        notifyLanguageRemoved(names[choice])
    }

    /// Tell the user, visibly, what just happened.
    ///
    /// This app is LSBackgroundOnly/LSUIElement, so it owns no windows and is
    /// never the active app — an NSAlert shown without activating first can
    /// appear behind everything or not at all. Activating is what makes the
    /// confirmation actually reach the user.
    private func showMessage(_ title: String, _ detail: String, style: NSAlert.Style = .informational) {
        DispatchQueue.main.async {
            self.withVisibleUI {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = detail
                alert.alertStyle = style
                alert.addButton(withTitle: MenuStrings.t(.ok))
                alert.window.level = .floating
                alert.window.makeKeyAndOrderFront(nil)
                alert.runModal()
            }
        }
    }

    /// Confirmation that a language is now available. The detector builds its
    /// languages when it starts, so a newly added one needs a relaunch before
    /// it converts anything — say so plainly rather than leaving the user to
    /// wonder why typing has not changed.
    private func notifyLanguageAdded(_ name: String) {
        showMessage(
            MenuStrings.t(.languageAddedTitle, name),
            MenuStrings.t(.languageAddedBody, name))
    }

    private func notifyLanguageRemoved(_ name: String) {
        showMessage(
            MenuStrings.t(.languageRemovedTitle, name),
            MenuStrings.t(.restartNeeded))
    }

    @objc private func toggleAutocorrect() {
        detector.autocorrectEnabled.toggle()
        NSLog("LangAutoSwitcher: Autocorrect %@",
              detector.autocorrectEnabled ? "ON" : "OFF")
    }

    @objc private func toggleTypoCorrection() {
        detector.typoCorrectionEnabled.toggle()
        NSLog("LangAutoSwitcher: Typo correction %@",
              detector.typoCorrectionEnabled ? "ON" : "OFF")
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
        lastConversion = nil
        lastCommitted = nil

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
                  bundleID, isTerminalApp, detector.code(for: detector.defaultLanguage))
        }
    }

    override func deactivateServer(_ sender: Any!) {
        let client = sender as! IMKTextInput
        forceCommitAll(client: client)
        super.deactivateServer(sender)
        NSLog("LangAutoSwitcher: Deactivated")
    }
}
