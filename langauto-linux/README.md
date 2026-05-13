# langauto-linux

Linux IBus input method engine for LangAutoSwitcher.

> **Status: SKELETON.** The Rust core is wired up and the demo binary runs. IBus integration is not implemented yet. **Contributions welcome.**

## What works today

```bash
cargo build -p langauto-linux
cargo run -p langauto-linux
```

Produces:

```
=== LangAutoSwitcher (Linux skeleton) ===

    napisah  →  написах          [BG, conf=1.00]
        now  →  нов              [BG, conf=0.90]
        kod  →  код              [BG, conf=1.00]
      hello  →  hello            [EN, conf=1.00]
      world  →  world            [EN, conf=1.00]
        kak  →  как              [BG, conf=1.00]
         si  →  си               [BG, conf=1.00]

✓ langauto_core works on Linux.

TODO: wire to IBus.
```

This proves the cross-platform Rust core compiles and runs correctly on Linux.

## What's TODO

The hard work — turning this demo into an actual input method:

### 1. Register as an IBus engine

Create an IBus component XML file at `/usr/share/ibus/component/langauto.xml`:

```xml
<component>
    <name>org.freedesktop.IBus.LangAutoSwitcher</name>
    <description>Auto-switching EN/BG input method</description>
    <exec>/usr/bin/langauto-linux --ibus</exec>
    <version>0.1.0</version>
    <engines>
        <engine>
            <name>langauto</name>
            <longname>LangAutoSwitcher</longname>
            <language>bg</language>
            <symbol>Аб</symbol>
        </engine>
    </engines>
</component>
```

### 2. Connect to the IBus daemon

Use one of these approaches (pick one):

- **Direct C bindings**: `bindgen` against `/usr/include/ibus-1.0/ibus.h`
- **D-Bus**: `zbus` crate to speak the IBus protocol directly
- **GLib wrapping**: `glib` + `gio` crates

The IBus protocol is documented at https://github.com/ibus/ibus/wiki

### 3. Handle key events

Implement the `process_key_event` callback:

```rust
fn process_key_event(&mut self, keyval: u32, keycode: u32, modifiers: u32) -> bool {
    // Translate keyval to char
    // Append to current word buffer
    // On space/punctuation/Enter: call detector.process_word()
    //   then commit_text() the result back to IBus
    // Return true if we consumed the event
}
```

### 4. Display the preedit (underlined composing text)

Call `update_preedit_text()` on each keystroke so the user sees the Latin
characters underlined before they commit (matches the macOS UX).

## Build dependencies

On Ubuntu/Debian:

```bash
sudo apt install libibus-1.0-dev
```

On Fedora:

```bash
sudo dnf install ibus-devel
```

## How to test once implemented

```bash
cargo build --release -p langauto-linux
sudo cp target/release/langauto-linux /usr/bin/
sudo cp langauto-linux/langauto.xml /usr/share/ibus/component/
ibus restart
ibus engine langauto
```

## Reference implementations

These IBus engines have similar shapes and are good models:

- **ibus-typing-booster** (Python): https://github.com/mike-fabian/ibus-typing-booster
- **ibus-rime** (C): https://github.com/rime/ibus-rime
- **fcitx5-rime** (C++): https://github.com/fcitx/fcitx5-rime

Want to help? Open an issue or PR. The core logic is already done — you only need to write the OS plumbing.
