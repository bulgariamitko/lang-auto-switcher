//! LangAutoSwitcher — Windows shim (SKELETON)
//!
//! Status: project structure is in place and the Rust core is wired up.
//! Real input integration (TSF text service or low-level keyboard hook) is
//! TODO — see README.md for the contributor guide and architectural options.
//!
//! This binary currently:
//!   1. Loads dictionaries (or falls back to a tiny inline set)
//!   2. Constructs the cross-platform LanguageDetector from `langauto_core`
//!   3. Runs a demo conversion to prove the core builds on Windows
//!   4. Prints a TODO message

use langauto_core::LanguageDetector;
use std::collections::HashSet;

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
    println!("=== LangAutoSwitcher (Windows skeleton) ===");
    println!();

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

    let test_phrases = ["napisah", "now", "kod", "hello", "world", "kak", "si"];
    for word in test_phrases {
        let r = detector.process_word(word);
        println!(
            "  {:>10}  ->  {:<15}  [{}, conf={:.2}]",
            r.original, r.converted, r.language.as_str(), r.confidence
        );
    }

    println!();
    println!("OK: langauto_core works on Windows.");
    println!();
    println!("TODO: wire to TSF or keyboard hook.");
    println!("See https://github.com/bulgariamitko/lang-auto-switcher/blob/main/langauto-windows/README.md");
    println!("for the contributor guide.");
}
