//! Autocorrect: abbreviation expansion + edit-distance-1 dictionary matching.
//!
//! Ported from AutoCorrector.swift. NSSpellChecker is exposed as a callback
//! the platform shim installs; on Linux/Windows the callback is None and we
//! fall back to dictionary-only edit-distance.

use std::collections::HashSet;

/// Optional spell-check hook. Platform shim sets it; returns the suggested
/// correction (lowercase) or `None`.
pub type SpellCheckFn = fn(&str) -> Option<String>;

pub fn expand_english_abbreviation(word: &str) -> Option<&'static str> {
    Some(match word.to_lowercase().as_str() {
        "u" => "you",
        "r" => "are",
        "ur" => "your",
        "pls" => "please",
        "plz" => "please",
        "thx" => "thanks",
        "thnx" => "thanks",
        "ty" => "thank you",
        "yw" => "you're welcome",
        "np" => "no problem",
        "idk" => "I don't know",
        "imo" => "in my opinion",
        "imho" => "in my humble opinion",
        "btw" => "by the way",
        "fyi" => "for your information",
        "tbh" => "to be honest",
        "omg" => "oh my god",
        "brb" => "be right back",
        "gtg" => "got to go",
        "lmk" => "let me know",
        "nvm" => "never mind",
        "rn" => "right now",
        "bc" => "because",
        "w" => "with",
        "b4" => "before",
        "2day" => "today",
        "2morrow" => "tomorrow",
        "2nite" => "tonight",
        "msg" => "message",
        "ppl" => "people",
        "govt" => "government",
        "dept" => "department",
        "info" => "information",
        "pic" => "picture",
        "pics" => "pictures",
        "approx" => "approximately",
        "misc" => "miscellaneous",
        "temp" => "temporary",
        "diff" => "different",
        "convo" => "conversation",
        "prob" => "probably",
        "probs" => "probably",
        "def" => "definitely",
        "obv" => "obviously",
        "tbf" => "to be fair",
        "smth" => "something",
        "smb" => "somebody",
        "sth" => "something",
        "sb" => "somebody",
        "abt" => "about",
        "tho" => "though",
        "thru" => "through",
        "gonna" => "going to",
        "wanna" => "want to",
        "gotta" => "got to",
        "kinda" => "kind of",
        "sorta" => "sort of",
        "cuz" => "because",
        "coz" => "because",
        "dunno" => "don't know",
        "lemme" => "let me",
        "gimme" => "give me",
        _ => return None,
    })
}

pub fn expand_bulgarian_abbreviation(latin_word: &str) -> Option<&'static str> {
    Some(match latin_word.to_lowercase().as_str() {
        "mn" => "много",
        "nqm" => "нямам",
        "nqma" => "няма",
        "dr" => "добър",
        "zdr" => "здравей",
        "blgdr" => "благодаря",
        "msl" => "мисля",
        "spk" => "споко",
        _ => return None,
    })
}

pub fn is_english_abbreviation(word: &str) -> bool {
    expand_english_abbreviation(word).is_some()
}

const CYRILLIC_LETTERS: &[char] = &[
    'а', 'б', 'в', 'г', 'д', 'е', 'ж', 'з', 'и', 'й',
    'к', 'л', 'м', 'н', 'о', 'п', 'р', 'с', 'т', 'у',
    'ф', 'х', 'ц', 'ч', 'ш', 'щ', 'ъ', 'ь', 'ю', 'я',
];

/// Find a word in `dict` that is edit-distance 1 from `word`.
/// Tries substitution, deletion, insertion, transposition — in that order.
pub fn edit_distance_1_match(word: &str, dict: &HashSet<String>, alphabet: &[char]) -> Option<String> {
    let chars: Vec<char> = word.chars().collect();
    let len = chars.len();
    if len < 2 {
        return None;
    }

    // Substitution
    for i in 0..len {
        let original = chars[i];
        for &replacement in alphabet {
            if replacement == original {
                continue;
            }
            let mut candidate = chars.clone();
            candidate[i] = replacement;
            let s: String = candidate.into_iter().collect();
            if dict.contains(&s) {
                return Some(s);
            }
        }
    }

    // Deletion
    for i in 0..len {
        let mut candidate = chars.clone();
        candidate.remove(i);
        let s: String = candidate.into_iter().collect();
        if dict.contains(&s) {
            return Some(s);
        }
    }

    // Insertion
    for i in 0..=len {
        for &c in alphabet {
            let mut candidate = chars.clone();
            candidate.insert(i, c);
            let s: String = candidate.into_iter().collect();
            if dict.contains(&s) {
                return Some(s);
            }
        }
    }

    // Transposition
    for i in 0..(len - 1) {
        let mut candidate = chars.clone();
        candidate.swap(i, i + 1);
        let s: String = candidate.into_iter().collect();
        if dict.contains(&s) {
            return Some(s);
        }
    }

    None
}

pub fn edit_distance_1_cyrillic(word: &str, dict: &HashSet<String>) -> Option<String> {
    edit_distance_1_match(word, dict, CYRILLIC_LETTERS)
}

fn match_case(original: &str, corrected: &str) -> String {
    let first_upper = original.chars().next().map(|c| c.is_uppercase()).unwrap_or(false);
    if !first_upper {
        return corrected.to_string();
    }
    let mut chars = corrected.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().chain(chars).collect(),
        None => corrected.to_string(),
    }
}

pub fn correct_english(
    word: &str,
    dict: &HashSet<String>,
    spell_check: Option<SpellCheckFn>,
) -> Option<String> {
    let lower = word.to_lowercase();

    if let Some(expanded) = expand_english_abbreviation(&lower) {
        return Some(match_case(word, expanded));
    }

    if dict.contains(&lower) {
        return None;
    }

    if let Some(cb) = spell_check {
        if let Some(correction) = cb(word) {
            let lc = correction.to_lowercase();
            if dict.contains(&lc) {
                return Some(match_case(word, &correction));
            }
        }
    }

    None
}

pub fn correct_bulgarian(
    cyrillic_word: &str,
    dict: &HashSet<String>,
    spell_check: Option<SpellCheckFn>,
) -> Option<String> {
    let lower = cyrillic_word.to_lowercase();
    if dict.contains(&lower) {
        return None;
    }

    if let Some(cb) = spell_check {
        if let Some(correction) = cb(cyrillic_word) {
            let lc = correction.to_lowercase();
            if dict.contains(&lc) {
                return Some(match_case(cyrillic_word, &correction));
            }
        }
    }

    if let Some(correction) = edit_distance_1_cyrillic(&lower, dict) {
        return Some(match_case(cyrillic_word, &correction));
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build_dict(words: &[&str]) -> HashSet<String> {
        words.iter().map(|w| w.to_string()).collect()
    }

    #[test]
    fn english_abbreviations_expand() {
        assert_eq!(expand_english_abbreviation("u"), Some("you"));
        assert_eq!(expand_english_abbreviation("U"), Some("you"));
        assert_eq!(expand_english_abbreviation("r"), Some("are"));
        assert_eq!(expand_english_abbreviation("idk"), Some("I don't know"));
        assert_eq!(expand_english_abbreviation("foo"), None);
    }

    #[test]
    fn bulgarian_abbreviations_expand() {
        assert_eq!(expand_bulgarian_abbreviation("mn"), Some("много"));
        assert_eq!(expand_bulgarian_abbreviation("zdr"), Some("здравей"));
        assert_eq!(expand_bulgarian_abbreviation("xyz"), None);
    }

    #[test]
    fn edit_distance_substitution() {
        let dict = build_dict(&["правописни"]);
        assert_eq!(
            edit_distance_1_cyrillic("пръвописни", &dict),
            Some("правописни".to_string())
        );
    }

    #[test]
    fn edit_distance_deletion() {
        let dict = build_dict(&["много"]);
        assert_eq!(edit_distance_1_cyrillic("мнгого", &dict), Some("много".to_string()));
    }

    #[test]
    fn edit_distance_insertion() {
        let dict = build_dict(&["много"]);
        assert_eq!(edit_distance_1_cyrillic("мног", &dict), Some("много".to_string()));
    }

    #[test]
    fn edit_distance_transposition() {
        let dict = build_dict(&["абвгд"]);
        assert_eq!(edit_distance_1_cyrillic("бавгд", &dict), Some("абвгд".to_string()));
    }

    #[test]
    fn edit_distance_no_match() {
        let dict = build_dict(&["много"]);
        assert_eq!(edit_distance_1_cyrillic("здравей", &dict), None);
    }

    #[test]
    fn correct_english_expands_abbrev() {
        let dict = build_dict(&["you", "are"]);
        assert_eq!(correct_english("u", &dict, None), Some("you".to_string()));
        assert_eq!(correct_english("U", &dict, None), Some("You".to_string()));
    }

    #[test]
    fn correct_english_skips_known_words() {
        let dict = build_dict(&["hello"]);
        assert_eq!(correct_english("hello", &dict, None), None);
    }

    #[test]
    fn correct_english_uses_spell_callback() {
        let dict = build_dict(&["hello"]);
        fn cb(w: &str) -> Option<String> {
            if w == "helo" { Some("hello".to_string()) } else { None }
        }
        assert_eq!(correct_english("helo", &dict, Some(cb)), Some("hello".to_string()));
    }

    #[test]
    fn correct_bulgarian_skips_known_words() {
        let dict = build_dict(&["добре"]);
        assert_eq!(correct_bulgarian("добре", &dict, None), None);
    }

    #[test]
    fn correct_bulgarian_falls_back_to_edit_distance() {
        let dict = build_dict(&["добре"]);
        assert_eq!(correct_bulgarian("дъбре", &dict, None), Some("добре".to_string()));
    }

    #[test]
    fn match_case_preserves_capitalization() {
        assert_eq!(match_case("Hello", "world"), "World");
        assert_eq!(match_case("hello", "world"), "world");
        assert_eq!(match_case("", "world"), "world");
    }
}
