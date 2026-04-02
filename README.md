# LangAutoSwitcher

A macOS Input Method that automatically detects whether you're typing in English or Bulgarian and converts Bulgarian words to Cyrillic on the fly. No more forgetting to switch keyboards!

## How it works

1. You type on a single QWERTY keyboard
2. As you type, letters appear underlined (composing state)
3. When you press **space**, Apple's `NLLanguageRecognizer` detects the language:
   - `kak si` → commits **как си** (Bulgarian detected)
   - `hello` → commits **hello** (English detected)
4. Previous word context helps with ambiguous words — if you've been typing Bulgarian, ambiguous words lean Bulgarian

Uses the **Bulgarian Phonetic keyboard mapping** (the standard Apple layout where `a→а`, `k→к`, `s→с`, etc.).

## Install (pre-built)

1. Download `LangAutoSwitcher-v1.0.0.zip` from [Releases](../../releases)
2. Unzip and move `LangAutoSwitcher.app` to `~/Library/Input Methods/`
   ```bash
   unzip LangAutoSwitcher-v1.0.0.zip -d ~/Library/Input\ Methods/
   ```
3. **Log out and back in** (macOS needs this to discover new input methods)
4. Go to **System Settings → Keyboard → Input Sources → Edit...**
5. Click **+**, find **LangAutoSwitcher** and add it
6. Switch to it from the input menu in your menu bar

Your native English and Bulgarian keyboards remain untouched — this is just one more option.

## Build from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
bash install.sh
```

Then log out/in and add the keyboard in System Settings.

## Uninstall

```bash
rm -rf ~/Library/Input\ Methods/LangAutoSwitcher.app
```

Then log out/in or restart.

## Requirements

- macOS 14.0+
- Apple Silicon or Intel Mac

## How detection works

The app uses a two-layer approach:

1. **Phonetic mapping** — each Latin character is converted to its Cyrillic equivalent using the Bulgarian Phonetic layout
2. **NLLanguageRecognizer** — Apple's built-in NLP framework scores the Latin text as English and the Cyrillic text as Bulgarian
3. **Context bias** — the last few detected languages bias ambiguous words toward the current "flow"

## License

MIT
