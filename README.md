# LangAutoSwitcher

> **Type English and Bulgarian on the same keyboard, without ever switching layouts.**
> Just type — LangAutoSwitcher figures out which language you meant and converts it to the right alphabet as you go.

Free, open source, native macOS Input Method. No accounts, no telemetry, no internet required.

```
You type:    napisah now kod and sent email to John
You see:     написах нов код and sent email to John
```

That's the whole idea. No `Cmd+Space`. No mistyped passwords. No half-Cyrillic, half-Latin Facebook posts.

---

## Who is this for?

Anyone who types in **both English and Bulgarian** every day and is tired of:

- Forgetting to switch the keyboard before typing a password
- Sending Facebook messages that start in one language and end in the other
- Constantly hitting `Cmd+Space` mid-sentence
- The standard БДС / Phonetic layout requiring you to *think* about which mode you're in

LangAutoSwitcher just watches what you type and picks the right alphabet for each word. Your existing Cyrillic and English keyboards stay exactly as they are — this is one more option you can switch to from the menu bar 🌐 icon.

---

## How it works

1. You type normally on a regular QWERTY keyboard.
2. Letters appear **underlined** while a word is being composed.
3. The moment you press **space**, the word is checked against:
   - a **234,000-word English dictionary**
   - a **234,000-word Bulgarian dictionary** (phonetically transliterated)
4. The winning language commits — either as-is (English) or converted to Cyrillic (Bulgarian).
5. If a word exists in both languages, it follows the language of the previous word, so your "flow" is preserved.

It auto-corrects common abbreviations too: `u` → `you`, `r` → `are`, plus edit-distance-1 spell correction for both languages.

### Examples

| You type | What appears | What happened |
|---|---|---|
| `towa e samo proba` | това е само проба | All Bulgarian words → Cyrillic |
| `hello how are you` | hello how are you | All English words → kept as-is |
| `napisah now kod and want to write` | написах нов код and want to write | Auto-switched mid-sentence |
| `how r u` | how are you | Abbreviation expanded |
| `kak si` | как си | Bulgarian via transliteration |
| `john@gmail.com` | john@gmail.com | Emails preserved |

---

## Install (60 seconds)

**1. Download** the latest release:
👉 [**Download LangAutoSwitcher-v2.6.0.zip**](https://github.com/bulgariamitko/lang-auto-switcher/releases/latest)

**2. Open Terminal** (⌘+Space → "Terminal") and paste:

```bash
cd ~/Downloads && unzip -o LangAutoSwitcher-v*.zip -d ~/Library/Input\ Methods/
```

**3. Log out and log back in.** (macOS only discovers new input methods at login — there is no way around this, sorry.)

**4. Add it to your input sources:**
- Open **System Settings → Keyboard → Input Sources → Edit…**
- Click **+** in the bottom-left → search for **"LangAutoSwitcher"** → **Add**

**5. Switch to it.** Click the 🌐 / flag icon in your menu bar and pick **LangAutoSwitcher**.

Now just type. 🎉

### Uninstall

```bash
rm -rf ~/Library/Input\ Methods/LangAutoSwitcher.app
```
Then log out / log back in.

---

## Transliteration mapping

Every Latin key maps to exactly one Cyrillic letter (no digraphs to remember):

| Key | → | Key | → | Key | → | Key | → |
|---|---|---|---|---|---|---|---|
| `a` | а | `i` | и | `q` | я | `y` | ъ |
| `b` | б | `j` | й | `r` | р | `z` | з |
| `c` | ц | `k` | к | `s` | с | `[` | ш |
| `d` | д | `l` | л | `t` | т | `]` | щ |
| `e` | е | `m` | м | `u` | у | `;` | ж |
| `f` | ф | `n` | н | `v` | ж | `` ` `` | ч |
| `g` | г | `o` | о | `w` | в | `\` | ю |
| `h` | х | `p` | п | `x` | ь | `'` | ь |

You almost never need to think about this table — most Bulgarian words are recognized by the dictionary directly from how you'd naturally spell them out (`zdravei`, `blagodarq`, `dobre`).

---

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

## Privacy

LangAutoSwitcher runs entirely on your Mac. It does **not**:

- send any text anywhere
- connect to the internet
- collect analytics or telemetry
- log your keystrokes to disk

The dictionaries ship bundled inside the app.

---

## Build from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project LangAutoSwitcher.xcodeproj -target LangAutoSwitcher -configuration Release build
bash install.sh
```

Then log out / log back in and add it from System Settings as above.

### Run tests

```bash
swift test_cases.swift
```

All 163 tests should pass.

---

## Adding your own language

The architecture supports any Latin ↔ non-Latin language pair. To add one:

1. Add mappings to `singleMap` in `LangAutoSwitcher/Sources/PhoneticMapper.swift`
2. Drop a word list (one word per line, in the target script) into `LangAutoSwitcher/Resources/`
3. Wire it up in `LangAutoSwitcher/Sources/LanguageDetector.swift`
4. Add test cases to `test_cases.swift`
5. Open a PR

Good candidates: **Russian**, **Ukrainian**, **Serbian** (other Cyrillic languages), **Greek**, **Georgian**, **Armenian**.

## Contributing

Pull requests welcome. For bug reports, please include:
- macOS version
- What you typed
- What you expected vs. what appeared

## License

MIT — do whatever you want with it, including for commercial use.

---

If LangAutoSwitcher saves you time, star ⭐ the repo and share it — that's how other Bulgarian Mac users find it.
