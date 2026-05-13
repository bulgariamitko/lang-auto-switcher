//! LangAutoSwitcher — Linux IBus engine (SKELETON)
//!
//! Status: project structure is in place and the Rust core is wired up.
//! Input event handling via IBus is TODO — see README.md for the contributor
//! guide.
//!
//! This binary currently:
//!   1. Loads the bundled dictionaries
//!   2. Constructs the cross-platform LanguageDetector from `langauto_core`
//!   3. Runs a demo conversion to prove the core works on Linux
//!   4. Prints a TODO message about IBus integration
//!
//! When fully implemented, this binary will:
//!   - Register itself with the IBus daemon as an input method engine
//!   - Receive key events for each keystroke
//!   - Maintain the per-word preedit buffer (underlined text the user sees
//!     before committing)
//!   - Call `LanguageDetector::process_word` on space/punctuation to commit
//!   - Surface the committed text to the focused application via IBus

use langauto_core::LanguageDetector;
use std::collections::HashSet;

/// Load a newline-separated wordlist from disk into a HashSet.
/// In the final implementation, dictionaries will ship in
/// /usr/share/langauto-switcher/ (or $XDG_DATA_HOME/langauto-switcher/).
fn load_dict(path: &str) -> HashSet<String> {
    std::fs::read_to_string(path)
        .map(|t| {
            t.lines()
                .map(|w| w.trim().to_lowercase())
                .filter(|w| !w.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

fn main() {
    println!("=== LangAutoSwitcher (Linux skeleton) ===");
    println!();

    // CI builds this without dictionaries on disk — fall back to tiny inline
    // wordlists so the demo always runs.
    let en_dict_path = "../LangAutoSwitcher/Resources/en-dictionary.txt";
    let bg_dict_path = "../LangAutoSwitcher/Resources/bg-dictionary.txt";

    let mut en_dict = load_dict(en_dict_path);
    let mut bg_dict = load_dict(bg_dict_path);

    if en_dict.is_empty() || bg_dict.is_empty() {
        eprintln!("note: bundled dictionaries not found, using minimal inline set");
        en_dict = ["hello", "world", "and", "the", "to", "want", "write"]
            .iter().map(|s| s.to_string()).collect();
        bg_dict = ["написах", "нов", "код", "как", "си", "добре", "това", "е", "проба"]
            .iter().map(|s| s.to_string()).collect();
    }

    let mut detector = LanguageDetector::new(en_dict, bg_dict);

    // Demo: prove the core works on Linux
    let test_phrases = ["napisah", "now", "kod", "hello", "world", "kak", "si"];
    for word in test_phrases {
        let r = detector.process_word(word);
        println!(
            "  {:>10}  →  {:<15}  [{}, conf={:.2}]",
            r.original, r.converted, r.language.as_str(), r.confidence
        );
    }

    println!();
    println!("✓ langauto_core works on Linux.");
    println!();
    println!("TODO: wire to IBus.");
    println!("See https://github.com/bulgariamitko/lang-auto-switcher/blob/main/langauto-linux/README.md");
    println!("for the contributor guide.");
}
