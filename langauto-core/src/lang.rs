//! Language packs — everything the detector needs to know about ONE language.
//!
//! Before this existed, "Bulgarian" was spread across the codebase as a
//! hardcoded keymap, a hardcoded alphabet, a hardcoded vowel set, a hardcoded
//! table of confusable letters and a second dictionary field. Adding a third
//! language meant touching all of it. A pack gathers those decisions in one
//! place so the detector can hold N of them and stay language-agnostic.
//!
//! A pack answers three questions about a word the user typed on a Latin
//! keyboard:
//!   1. What would this word look like in my script?      (`transliterate`)
//!   2. Is that a word I recognise?                       (`contains`)
//!   3. Did the user press a key that only I use?         (`has_exclusive_key`)

use std::collections::{HashMap, HashSet};

/// One language the detector can recognise and convert into.
pub struct LanguagePack {
    /// Stable short id used in settings and on the FFI boundary: "en", "bg".
    pub id: String,
    /// Human-readable name for menus.
    pub display_name: String,

    /// Latin keystroke → the letter it produces in this language. Empty for a
    /// language already written in Latin, where typing is its own output.
    keymap: HashMap<char, char>,
    /// keymap reversed: letter → the Latin key that types it. Used for
    /// keyboard-distance judgements in typo repair. When several keys produce
    /// the same letter the first one registered wins, which matches how the
    /// old hardcoded reverse lookup behaved.
    reverse: HashMap<char, char>,

    /// Keys that exist ONLY to type this language's script — `[`, `]`, backtick
    /// and friends for Bulgarian. Nobody puts them mid-word in English, so one
    /// of them is strong evidence the user meant this language.
    exclusive_keys: HashSet<char>,

    /// Every letter of the alphabet, used to enumerate typo candidates.
    pub letters: Vec<char>,
    /// Vowels. Inflection changes the final vowel in Slavic languages, so a
    /// final-vowel swap is a grammatical form rather than a typing slip.
    vowels: HashSet<char>,
    /// Letter pairs users confuse because the transliteration convention
    /// disagrees with the physical layout, NOT because the keys are close.
    confusables: HashSet<(char, char)>,

    /// Recognised words, lowercase.
    pub dict: HashSet<String>,
    /// Short forms this language expands when autocorrect is on.
    pub abbreviations: HashMap<String, String>,

    /// True for the pack whose script IS the Latin the user types. Unknown
    /// words fall back to it, because "we don't recognise this" should leave
    /// the text alone rather than guess a transliteration.
    pub is_latin_base: bool,
}

impl LanguagePack {
    /// A language written in the Latin alphabet, where most keys type
    /// themselves. `extra_keys` covers letters absent from a US keyboard —
    /// Swedish å/ä/ö, say — mapped to the key that produces them on that
    /// language's own physical layout.
    pub fn latin(
        id: &str,
        display_name: &str,
        dict: HashSet<String>,
        extra_keys: &[(char, char)],
    ) -> Self {
        let mut pack = Self::blank(id, display_name, dict);
        pack.is_latin_base = true;
        for &(key, letter) in extra_keys {
            pack.keymap.insert(key, letter);
            pack.reverse.entry(letter).or_insert(key);
            // A key that types å is not a key English ever needs mid-word.
            if !key.is_ascii_alphabetic() {
                pack.exclusive_keys.insert(key);
            }
        }
        pack.letters = ('a'..='z').chain(extra_keys.iter().map(|&(_, l)| l)).collect();
        pack.vowels = "aeiouy".chars().chain(extra_keys.iter().map(|&(_, l)| l)).collect();
        pack
    }

    /// A language written in another script, reached by transliterating each
    /// Latin keystroke. `keymap` is the full Latin-key → letter table.
    pub fn transliterated(
        id: &str,
        display_name: &str,
        dict: HashSet<String>,
        keymap: &[(char, char)],
        vowels: &str,
        confusables: &[(char, char)],
    ) -> Self {
        let mut pack = Self::blank(id, display_name, dict);
        for &(key, letter) in keymap {
            pack.keymap.insert(key, letter);
            pack.reverse.entry(letter).or_insert(key);
            // Non-alphabetic keys only exist here to reach this script.
            if !key.is_ascii_alphanumeric() {
                pack.exclusive_keys.insert(key);
            }
        }
        // Letters, lowercase, de-duplicated, in a stable order so typo
        // candidate generation is deterministic.
        let mut seen = HashSet::new();
        pack.letters = keymap
            .iter()
            .map(|&(_, l)| l)
            .filter(|l| l.is_lowercase() && seen.insert(*l))
            .collect();
        pack.vowels = vowels.chars().collect();
        for &(a, b) in confusables {
            pack.confusables.insert((a, b));
            pack.confusables.insert((b, a));
        }
        pack
    }

    fn blank(id: &str, display_name: &str, dict: HashSet<String>) -> Self {
        Self {
            id: id.to_string(),
            display_name: display_name.to_string(),
            keymap: HashMap::new(),
            reverse: HashMap::new(),
            exclusive_keys: HashSet::new(),
            letters: Vec::new(),
            vowels: HashSet::new(),
            confusables: HashSet::new(),
            dict,
            abbreviations: HashMap::new(),
            is_latin_base: false,
        }
    }

    pub fn with_abbreviations(mut self, pairs: &[(&str, &str)]) -> Self {
        for &(k, v) in pairs {
            self.abbreviations.insert(k.to_string(), v.to_string());
        }
        self
    }

    /// What the typed keystrokes look like in this language's script.
    /// Characters with no mapping pass through unchanged, so digits and
    /// punctuation survive.
    pub fn transliterate(&self, text: &str) -> String {
        if self.keymap.is_empty() {
            return text.to_string();
        }
        text.chars()
            .map(|c| self.map_char(c).unwrap_or(c))
            .collect()
    }

    fn map_char(&self, c: char) -> Option<char> {
        if let Some(&m) = self.keymap.get(&c) {
            return Some(m);
        }
        // Uppercase is derived from the lowercase mapping so every pack gets
        // capitals for free instead of listing both cases.
        if c.is_uppercase() {
            let lower = c.to_lowercase().next()?;
            let mapped = *self.keymap.get(&lower)?;
            return mapped.to_uppercase().next();
        }
        None
    }

    pub fn contains(&self, word: &str) -> bool {
        self.dict.contains(&word.to_lowercase())
    }

    /// Did the user press a key that only this language needs? Evidence strong
    /// enough to override an established streak in another language.
    pub fn has_exclusive_key(&self, typed: &str) -> bool {
        typed.chars().any(|c| self.exclusive_keys.contains(&c))
    }

    pub fn is_vowel(&self, c: char) -> bool {
        self.vowels.contains(&c)
    }

    pub fn is_confusable(&self, a: char, b: char) -> bool {
        self.confusables.contains(&(a, b))
    }

    /// The Latin key that types `letter`, for keyboard-distance checks.
    pub fn key_for(&self, letter: char) -> Option<char> {
        self.reverse.get(&letter).copied()
    }
}
