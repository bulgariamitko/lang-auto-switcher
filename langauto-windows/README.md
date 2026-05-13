# langauto-windows

Windows input shim for LangAutoSwitcher.

> **Status: SKELETON.** The Rust core is wired up and the demo binary runs. Real input integration is not implemented yet. **Contributions welcome.**

## What works today

```cmd
cargo build -p langauto-windows
cargo run -p langauto-windows
```

Produces:

```
=== LangAutoSwitcher (Windows skeleton) ===

    napisah  ->  написах          [BG, conf=1.00]
        now  ->  нов              [BG, conf=0.90]
        kod  ->  код              [BG, conf=1.00]
      hello  ->  hello            [EN, conf=1.00]
      world  ->  world            [EN, conf=1.00]
        kak  ->  как              [BG, conf=1.00]
         si  ->  си               [BG, conf=1.00]

OK: langauto_core works on Windows.
```

This proves the cross-platform Rust core compiles and runs correctly on Windows.

## What's TODO

There are two reasonable architectures for the actual input integration. **Pick one** — they're not compatible.

### Option A: Text Services Framework (TSF) — the "proper" way

- Integrates with Windows' language picker (you can switch to it via Win+Space)
- Works correctly with every text field, including elevated windows
- Implemented as an in-process COM DLL
- **Complexity: HIGH** — ~30 COM interfaces, ~2000–3000 lines of boilerplate

Useful crates:
- `windows` (official Microsoft crate with TSF bindings): https://crates.io/crates/windows
- Reference: https://learn.microsoft.com/en-us/windows/win32/tsf/text-services-framework

### Option B: Low-level keyboard hook — the "pragmatic" way

- Doesn't appear in Windows' language picker
- Runs as a background process / system tray app
- Uses `SetWindowsHookEx(WH_KEYBOARD_LL, ...)` to intercept all keystrokes
- **Complexity: LOW–MEDIUM** — a few hundred lines
- Caveats:
  - May trigger antivirus heuristics
  - Doesn't work in some elevated apps without UAC
  - User can't switch via Win+Space (must toggle via tray icon)

Useful crate:
- `windows` with `Win32::UI::WindowsAndMessaging` features

### Recommended: start with Option B

It's the fastest path to a working v1 that real users can install. Option A can come later as a v2 once we know there's demand.

## Build dependencies

The `windows` crate downloads its own Windows SDK metadata, so no manual SDK install is needed in most setups. Cargo handles everything:

```cmd
cargo build --release -p langauto-windows
```

## How to test once implemented

For Option B (keyboard hook):
```cmd
target\release\langauto-windows.exe
# (runs in tray; right-click icon to toggle / exit)
```

For Option A (TSF):
```cmd
regsvr32 target\release\langauto_windows.dll
# (now appears in Settings → Time & Language → Language → Input)
```

## Reference implementations

Existing TSF input methods to study:

- **Microsoft Pinyin TSF** (closed source but documented behavior)
- **chewing-windows-tsf** (open source, traditional Chinese): https://github.com/chewing/windows-chewing-tsf
- **Google Japanese Input TSF** (in mozc): https://github.com/google/mozc

Open an issue or PR to claim this work. The core logic is already done; you only need the OS plumbing.
