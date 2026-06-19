//! Autocorrect: abbreviation expansion + edit-distance-1 dictionary matching.
//!
//! Ported from AutoCorrector.swift. NSSpellChecker is exposed as a callback
//! the platform shim installs; on Linux/Windows the callback is None and we
//! fall back to dictionary-only edit-distance.

use std::collections::HashSet;

use crate::phonetic::latin_key_for_cyrillic;

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

/// QWERTY physical neighbors for each key in the phonetic layout.
fn qwerty_neighbors(key: char) -> &'static str {
    match key {
        'q' => "wa",      'w' => "qeas",   'e' => "wrsd",   'r' => "etdf",
        't' => "ryfg",    'y' => "tugh",   'u' => "yihj",   'i' => "uojk",
        'o' => "ipkl",    'p' => "o[l;",   '[' => "p];'",   ']' => "['\\",
        'a' => "qwsz",    's' => "awedxz", 'd' => "serfcx", 'f' => "drtgvc",
        'g' => "ftyhbv",  'h' => "gyujnb", 'j' => "huikmn", 'k' => "jiolm",
        'l' => "kop;",    ';' => "lp['",   '\'' => ";[]",   '\\' => "]",
        'z' => "asx",     'x' => "zsdc",   'c' => "xdfv",   'v' => "cfgb",
        'b' => "vghn",    'n' => "bhjm",   'm' => "njk",
        _ => "",
    }
}

/// True when the QWERTY keys that type these two Cyrillic letters are
/// physically adjacent — the signature of a fat-finger substitution
/// ("изтриеп": п is typed 'p', ш is typed '[', and p/[ are neighbors).
pub fn keys_adjacent(a: char, b: char) -> bool {
    match (latin_key_for_cyrillic(a), latin_key_for_cyrillic(b)) {
        (Some(ka), Some(kb)) => qwerty_neighbors(ka).contains(kb),
        _ => false,
    }
}

/// Ranked edit-distance-1 correction for Bulgarian typos. Unlike
/// `edit_distance_1_cyrillic` (first match wins), this prefers the fix that
/// best matches how typos actually happen:
///   1. adjacent-key substitution (pressed the key next to the right one)
///   2. transposition (two letters swapped)
///   3. any other substitution
///   4. deletion (one extra key pressed)
///   5. insertion (one key missed)
/// With a fully inflected dictionary a typo often has several distance-1
/// neighbors ("изтриеп" → изтрием/изтриеш/изтрие); ranking picks the right one.
pub fn best_bulgarian_typo_fix(word: &str, dict: &HashSet<String>) -> Option<String> {
    let chars: Vec<char> = word.chars().collect();
    let len = chars.len();
    if len < 2 {
        return None;
    }

    // Substitution — track the adjacent-key match separately from the rest.
    let mut adjacent_sub: Option<String> = None;
    let mut other_sub: Option<String> = None;
    for i in 0..len {
        let original = chars[i];
        for &replacement in CYRILLIC_LETTERS {
            if replacement == original {
                continue;
            }
            let mut candidate = chars.clone();
            candidate[i] = replacement;
            let s: String = candidate.into_iter().collect();
            if dict.contains(&s) {
                if keys_adjacent(original, replacement) {
                    if adjacent_sub.is_none() {
                        adjacent_sub = Some(s);
                    }
                } else if other_sub.is_none() {
                    other_sub = Some(s);
                }
            }
        }
    }
    if adjacent_sub.is_some() {
        return adjacent_sub;
    }

    // Transposition — "letters shifted".
    for i in 0..(len - 1) {
        if chars[i] == chars[i + 1] {
            continue;
        }
        let mut candidate = chars.clone();
        candidate.swap(i, i + 1);
        let s: String = candidate.into_iter().collect();
        if dict.contains(&s) {
            return Some(s);
        }
    }

    if other_sub.is_some() {
        return other_sub;
    }

    // Deletion — an extra key was pressed.
    for i in 0..len {
        let mut candidate = chars.clone();
        candidate.remove(i);
        let s: String = candidate.into_iter().collect();
        if dict.contains(&s) {
            return Some(s);
        }
    }

    // Insertion — a key was missed.
    for i in 0..=len {
        for &c in CYRILLIC_LETTERS {
            let mut candidate = chars.clone();
            candidate.insert(i, c);
            let s: String = candidate.into_iter().collect();
            if dict.contains(&s) {
                return Some(s);
            }
        }
    }

    None
}

/// Short Bulgarian function words (clitics, prepositions, conjunctions,
/// particles). These are the words a missed spacebar actually glues onto a
/// neighbour — "можешда", "натова", "иеми". A split is only trusted when one
/// of its halves is one of these; otherwise a perfectly good single word that
/// merely happens to decompose into two content words ("клипчета" → клип+чета,
/// "вертикално" → вер+тикално) gets wrongly torn apart.
const FUNCTION_WORDS: &[&str] = &[
    "да", "е", "и", "а", "но", "или", "не", "ще", "се", "си", "съм", "са",
    "го", "я", "ги", "ме", "те", "ни", "ви", "ми", "ти", "му", "им",
    "ли", "че", "то", "за", "на", "от", "до", "по", "в", "с", "във", "със",
    "бе", "ето", "ама",
];

fn is_function_word(w: &str) -> bool {
    FUNCTION_WORDS.contains(&w)
}

/// Missing-space rescue: "можешда" → "можеш да" when both halves are
/// dictionary words AND at least one half is a short function word — the only
/// kind a slipped spacebar realistically glues. Without that guard the split
/// fires on ordinary single words that decompose into two dictionary words
/// (the diminutive "клипчета" = клип + чета), which is the bug this prevents.
/// Returns None when no trusted split point works.
pub fn split_into_two_words(word: &str, dict: &HashSet<String>) -> Option<String> {
    let chars: Vec<char> = word.chars().collect();
    let len = chars.len();
    if len < 3 {
        return None;
    }
    for i in 1..len {
        let left: String = chars[..i].iter().collect();
        let right: String = chars[i..].iter().collect();
        if dict.contains(&left)
            && dict.contains(&right)
            && (is_function_word(&left) || is_function_word(&right))
        {
            return Some(format!("{left} {right}"));
        }
    }
    None
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
    fn keys_adjacent_uses_qwerty_layout() {
        // п is typed 'p', ш is typed '[' — physically adjacent.
        assert!(keys_adjacent('п', 'ш'));
        // п ('p') and м ('m') are far apart.
        assert!(!keys_adjacent('п', 'м'));
        // в is typed 'w', е is typed 'e' — adjacent.
        assert!(keys_adjacent('в', 'е'));
    }

    #[test]
    fn best_typo_fix_prefers_adjacent_key_substitution() {
        // "изтриеп" has three distance-1 dictionary neighbors; only
        // п→ш is an adjacent-key substitution, so it must win over the
        // alphabetically earlier "изтрием" and the deletion "изтрие".
        let dict = build_dict(&["изтрие", "изтрием", "изтриеш"]);
        assert_eq!(
            best_bulgarian_typo_fix("изтриеп", &dict),
            Some("изтриеш".to_string())
        );
    }

    #[test]
    fn best_typo_fix_prefers_transposition_over_far_substitution() {
        // "нгео" → transposition gives "него"; no adjacent-key sub exists.
        let dict = build_dict(&["него"]);
        assert_eq!(
            best_bulgarian_typo_fix("нгео", &dict),
            Some("него".to_string())
        );
    }

    #[test]
    fn best_typo_fix_falls_back_to_deletion_and_insertion() {
        let dict = build_dict(&["много"]);
        // Extra letter pressed → deletion.
        assert_eq!(best_bulgarian_typo_fix("мнного", &dict), Some("много".to_string()));
        // Letter missed → insertion.
        assert_eq!(best_bulgarian_typo_fix("мноо", &dict), Some("много".to_string()));
        // Nothing within distance 1 → None.
        assert_eq!(best_bulgarian_typo_fix("здравей", &dict), None);
    }

    #[test]
    fn split_into_two_words_finds_missing_space() {
        let dict = build_dict(&["можеш", "да", "това", "е"]);
        assert_eq!(
            split_into_two_words("можешда", &dict),
            Some("можеш да".to_string())
        );
        assert_eq!(
            split_into_two_words("товае", &dict),
            Some("това е".to_string())
        );
        assert_eq!(split_into_two_words("здравейте", &dict), None);
    }

    #[test]
    fn split_requires_a_function_word_half() {
        // Regression: a real single word that happens to decompose into two
        // content words must NOT be split. "клипчета" (a diminutive) splits
        // into "клип" + "чета", both real words — but neither is a function
        // word, so the split must be refused.
        let dict = build_dict(&["клип", "чета", "клипчета"]);
        assert_eq!(split_into_two_words("клипчета", &dict), None,
            "two content words must not be split apart");

        // But a genuine missed space onto a function word still splits.
        let dict2 = build_dict(&["клип", "е", "на", "представлението"]);
        assert_eq!(
            split_into_two_words("клипе", &dict2),
            Some("клип е".to_string()),
            "missed space before the clitic 'е' must still split");
        assert_eq!(
            split_into_two_words("напредставлението", &dict2),
            Some("на представлението".to_string()),
            "missed space after the preposition 'на' must still split");
    }

    #[test]
    fn match_case_preserves_capitalization() {
        assert_eq!(match_case("Hello", "world"), "World");
        assert_eq!(match_case("hello", "world"), "world");
        assert_eq!(match_case("", "world"), "world");
    }
}
