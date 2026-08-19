//! Manual sanity check of typo correction against the real shipped
//! dictionaries. Run with:
//!   cargo run -p langauto_core --example typo_check
use std::collections::HashSet;
use std::fs;

use langauto_core::detector::LanguageDetector;

fn load(path: &str) -> HashSet<String> {
    fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("cannot read {path}: {e}"))
        .lines()
        .map(|w| w.trim().to_lowercase())
        .filter(|w| !w.is_empty())
        .collect()
}

fn main() {
    let en = load("LangAutoSwitcher/Resources/en-dictionary.txt");
    let bg = load("LangAutoSwitcher/Resources/bg-dictionary.txt");
    println!("dicts: en={} bg={}", en.len(), bg.len());
    let mut d = LanguageDetector::new(en, bg);

    // The user's sentence: "ок можеш да ги изтриеп от при нас вече"
    // typed phonetically. ж='v', ш='[', в='w', я='q', ч='`'.
    let sentence = ["ok", "move[", "da", "gi", "iztriep", "ot", "pri", "nas", "we`e"];
    let mut out = Vec::new();
    for w in sentence {
        let r = d.process_word(w);
        out.push(format!("{} [{}]", r.converted, format!("{:?}", r.language)));
    }
    println!("sentence: {}", out.join(" | "));

    // Guards: these must all stay Latin even mid-BG-flow.
    d.reset_context();
    d.process_word("towa");
    d.process_word("mnogo");
    for w in ["dpi", "Windows", "css", "json", "iphone", "bitcoin", "photoshop", "google"] {
        let r = d.process_word(w);
        println!("guard: {:10} -> {} [{}]", w, r.converted, format!("{:?}", r.language));
    }
}
