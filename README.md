# LangAutoSwitcher

A macOS Input Method that **automatically detects** which language you're typing and converts to the correct alphabet on the fly. No more forgetting to switch keyboards!

Currently supports **English ↔ Bulgarian (Cyrillic)**, but designed to be extensible — you can add your own language pairs.

## How it works

1. You type on a single QWERTY keyboard
2. As you type, letters appear underlined (composing state)
3. When you press **space**, the word is analyzed:
   - Checked against **234K English** and **234K Bulgarian** word dictionaries
   - If ambiguous (exists in both), follows the previous word's language
   - If the first word is ambiguous, waits for the second word to decide
4. **Autocorrect**: `u` → `you`, `r` → `are`, plus spell correction for both languages
5. Your native keyboards remain untouched — this is just one more input option

### Examples

| You type | Output | Why |
|---|---|---|
| `towa e samo proba` | това е само проба | Bulgarian words detected |
| `hello how are you` | hello how are you | English words detected |
| `napisah now kod want to write` | написах нов код want to write | Auto-switches at "want" |
| `how r u` | how are you | English abbreviation expansion |
| `kak si dobre` | как си добре | Bulgarian via transliteration |

### Transliteration mapping

| Key | Cyrillic | Key | Cyrillic | Key | Cyrillic |
|-----|----------|-----|----------|-----|----------|
| `a` | а | `k` | к | `u` | у |
| `b` | б | `l` | л | `v` | ж |
| `c` | ц | `m` | м | `w` | в |
| `d` | д | `n` | н | `x` | ь |
| `e` | е | `o` | о | `y` | ъ |
| `f` | ф | `p` | п | `z` | з |
| `g` | г | `q` | я | `]` | щ |
| `h` | х | `r` | р | `[` | ш |
| `i` | и | `s` | с | `;` | ж |
| `j` | й | `t` | т | `` ` `` | ч |

**Digraphs:** `sh`→ш, `zh`→ж, `ch`→ч, `sht`→щ, `ts`→ц, `ya`→я, `yu`→ю

## Install (pre-built)

1. Download `LangAutoSwitcher.zip` from [Releases](../../releases/latest)
2. Unzip and move to Input Methods:
   ```bash
   unzip LangAutoSwitcher.zip -d ~/Library/Input\ Methods/
   ```
3. Register the input method:
   ```bash
   swift -e 'import Carbon; TISRegisterInputSource(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Input Methods/LangAutoSwitcher.app") as CFURL)'
   ```
4. **Log out and back in** (macOS needs this to discover new input methods)
5. **System Settings → Keyboard → Input Sources → Edit...** → click **+** → find **LangAutoSwitcher**
6. Switch to it from the input menu in your menu bar

## Build from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project LangAutoSwitcher.xcodeproj -target LangAutoSwitcher -configuration Release build
```

### Install after building

```bash
bash install.sh
# Then log out/in and add in System Settings → Keyboard → Input Sources
```

### Run tests

```bash
swift test_cases.swift
```

## Adding your own language

The architecture is designed to support any Latin ↔ non-Latin language pair. To add a new language:

### 1. Create a character mapping

Edit `LangAutoSwitcher/Sources/PhoneticMapper.swift`:

- Add your mappings to `singleMap` (single character → character)
- Add digraphs to the `digraphs` array if your language has multi-character mappings (e.g., `sh` → `ш`)

### 2. Add a word dictionary

Create a text file with one word per line (in the target script, e.g., Cyrillic, Greek, etc.):

```bash
# Example: adding Greek
# Create LangAutoSwitcher/Resources/el-dictionary.txt with Greek words
```

### 3. Update the detector

In `LangAutoSwitcher/Sources/LanguageDetector.swift`:

- Load your dictionary alongside the existing ones
- Add dictionary checks in `processWord()`

### 4. Add test cases

Add scenarios to `test_cases.swift` to verify your language works correctly.

### Example: languages that could be added

- **Russian** (Cyrillic) — similar to Bulgarian, different phonetic mapping
- **Greek** — Latin ↔ Greek alphabet
- **Ukrainian** (Cyrillic) — similar to Bulgarian/Russian
- **Serbian** (Cyrillic) — similar to Bulgarian
- **Georgian** — Latin ↔ Georgian alphabet
- **Armenian** — Latin ↔ Armenian alphabet

## How detection works

1. **Dictionary lookup** — the typed Latin word and its converted version are checked against 234K-word dictionaries for each language
2. **Exclusive match** — if a word only exists in one language's dictionary, that language is used
3. **Ambiguous match** — if a word exists in both, the previous word's language is followed (flow continuity)
4. **First-word look-ahead** — if the first word is ambiguous, it waits for the second word to decide
5. **Streak protection** — a strong streak (3+ confident words) in one language prevents short false matches from the other language from breaking the flow
6. **Autocorrect** — abbreviation expansion and edit-distance-1 spell correction for both languages
7. **Default preference** — configurable via the menu bar menu (click the input method icon)

## Uninstall

```bash
rm -rf ~/Library/Input\ Methods/LangAutoSwitcher.app
# Then log out/in or restart
```

## Requirements

- macOS 14.0+ (Sonoma or later)
- Apple Silicon or Intel Mac

## Contributing

1. Fork the repo
2. Add your language or fix a bug
3. Add test cases to `test_cases.swift`
4. Run `swift test_cases.swift` — all tests must pass
5. Open a PR

## License

MIT
