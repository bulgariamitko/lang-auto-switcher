//! Autocorrect: abbreviation expansion + edit-distance-1 dictionary matching.
//!
//! Ported from AutoCorrector.swift. NSSpellChecker is exposed as a callback
//! the platform shim installs; on Linux/Windows the callback is None and we
//! fall back to dictionary-only edit-distance.

use std::collections::HashSet;

use crate::lang::LanguagePack;

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
/// Are these two letters typed on neighbouring keys of the given language?
pub fn keys_adjacent_in(pack: &LanguagePack, a: char, b: char) -> bool {
    match (pack.key_for(a), pack.key_for(b)) {
        (Some(ka), Some(kb)) => qwerty_neighbors(ka).contains(kb),
        _ => false,
    }
}

/// The four rows of a US keyboard, used to tell a sideways roll of the
/// fingers from a merely nearby key.
const KEYBOARD_ROWS: [&str; 4] = [
    "`1234567890-=",
    "qwertyuiop[]\\",
    "asdfghjkl;'",
    "zxcvbnm,./",
];

/// Are these two letters typed on keys that sit side by side in the SAME row?
///
/// Stricter than `keys_adjacent_in`, which also counts the rows above and
/// below. A finger rolling sideways brushes the key next to its target
/// ("pos" typed "pods": d and s are neighbours on the home row); reaching a
/// row away is a different motion, and treating it as one triples the number
/// of correct words that get rewritten.
pub fn keys_rolled_in(pack: &LanguagePack, a: char, b: char) -> bool {
    let (ka, kb) = match (pack.key_for(a), pack.key_for(b)) {
        (Some(ka), Some(kb)) => (ka, kb),
        _ => return false,
    };
    KEYBOARD_ROWS.iter().any(|row| {
        let keys: Vec<char> = row.chars().collect();
        keys.windows(2)
            .any(|w| (w[0] == ka && w[1] == kb) || (w[0] == kb && w[1] == ka))
    })
}

/// Best single-edit repair for a word no language recognised, or None to
/// leave it exactly as typed.
///
/// Every edit is a silent guess about what the user MEANT, so the bar is
/// deliberately high: a wrong guess rewrites a correctly-typed word into a
/// different real word and the user may never notice. Declining to fix is the
/// cheap failure — the word stays as typed, which is obvious on screen.
///
/// Dictionaries are never complete (ours was missing every л-participle of
/// "разплатя"), so words reaching this function are frequently CORRECT rather
/// than mistyped. Measured against the shipped Bulgarian dictionary, the old
/// rules rewrote 77% of correct-but-missing words into some other word; these
/// cut that to 14% while still fixing every real typo on record. Removed:
///
/// * Substitution between keys that are NOT neighbours — the biggest source
///   of damage (41% of cases): in an inflected language almost every letter
///   swap lands on another real word, and reaching a far key is not a slip.
/// * Substituting the final vowel, even between neighbours — that is
///   inflection, not typing.
/// * Deleting an arbitrary letter (now only a doubled one — a bounced key —
///   or a consonant rolled over its same-row neighbour, which costs 0.6%).
/// * Inserting a letter: 30 letters at any position reaches a real word far
///   too easily to trust.
pub fn best_typo_fix(word: &str, pack: &LanguagePack) -> Option<String> {
    let chars: Vec<char> = word.chars().collect();
    let len = chars.len();
    if len < 2 {
        return None;
    }

    // Substitution, strongest evidence first: a neighbouring key beats a
    // known layout confusion. Neither may touch a final vowel.
    let mut confusable_sub: Option<String> = None;
    for i in 0..len {
        let original = chars[i];
        let final_vowel = i == len - 1 && pack.is_vowel(original);
        for &replacement in &pack.letters {
            if replacement == original {
                continue;
            }
            if final_vowel && pack.is_vowel(replacement) {
                continue;
            }
            let adjacent = keys_adjacent_in(pack, original, replacement);
            if !adjacent && !pack.is_confusable(original, replacement) {
                continue;
            }
            let mut candidate = chars.clone();
            candidate[i] = replacement;
            let s: String = candidate.into_iter().collect();
            if pack.dict.contains(&s) {
                if adjacent {
                    return Some(s);
                }
                if confusable_sub.is_none() {
                    confusable_sub = Some(s);
                }
            }
        }
    }
    if confusable_sub.is_some() {
        return confusable_sub;
    }

    // Transposition — "letters shifted".
    for i in 0..(len - 1) {
        if chars[i] == chars[i + 1] {
            continue;
        }
        let mut candidate = chars.clone();
        candidate.swap(i, i + 1);
        let s: String = candidate.into_iter().collect();
        if pack.dict.contains(&s) {
            return Some(s);
        }
    }

    // Deletion of ONE letter the finger added on its way past. Dropping an
    // arbitrary letter turns "агора" into "гора", which is word substitution
    // rather than typo repair, so only two motions qualify:
    //
    // * a doubled letter — the key bounced and typed twice;
    // * a consonant sitting next to a consonant it shares a keyboard row
    //   with — the finger rolled sideways over its neighbour ("постановките"
    //   typed "подстановките": д and с are typed d and s, side by side on the
    //   home row). Vowels are excluded because Bulgarian inflects through
    //   them, and rows above/below are excluded because reaching them is a
    //   deliberate motion, not a roll.
    for i in 0..len {
        let doubled = (i > 0 && chars[i] == chars[i - 1])
            || (i + 1 < len && chars[i] == chars[i + 1]);
        let rolled = !pack.is_vowel(chars[i])
            && ((i > 0 && !pack.is_vowel(chars[i - 1]) && keys_rolled_in(pack, chars[i], chars[i - 1]))
                || (i + 1 < len
                    && !pack.is_vowel(chars[i + 1])
                    && keys_rolled_in(pack, chars[i], chars[i + 1])));
        if !doubled && !rolled {
            continue;
        }
        let mut candidate = chars.clone();
        candidate.remove(i);
        let s: String = candidate.into_iter().collect();
        if pack.dict.contains(&s) {
            return Some(s);
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

    /// Wrap a word list in the real Bulgarian pack, so typo tests exercise
    /// the actual alphabet, vowels, confusables and key positions.
    fn bg_pack(words: &[&str]) -> crate::lang::LanguagePack {
        crate::packs::bulgarian(build_dict(words))
    }

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
        let p = bg_pack(&[]);
        assert!(keys_adjacent_in(&p, 'п', 'ш'));
        // п ('p') and м ('m') are far apart.
        assert!(!keys_adjacent_in(&p, 'п', 'м'));
        // в is typed 'w', е is typed 'e' — adjacent.
        assert!(keys_adjacent_in(&p, 'в', 'е'));
    }

    #[test]
    fn best_typo_fix_prefers_adjacent_key_substitution() {
        // "изтриеп" has three distance-1 dictionary neighbors; only
        // п→ш is an adjacent-key substitution, so it must win over the
        // alphabetically earlier "изтрием" and the deletion "изтрие".
        let pack = bg_pack(&["изтрие", "изтрием", "изтриеш"]);
        assert_eq!(
            best_typo_fix("изтриеп", &pack),
            Some("изтриеш".to_string())
        );
    }

    #[test]
    fn best_typo_fix_prefers_transposition_over_far_substitution() {
        // "нгео" → transposition gives "него"; no adjacent-key sub exists.
        let pack = bg_pack(&["него"]);
        assert_eq!(
            best_typo_fix("нгео", &pack),
            Some("него".to_string())
        );
    }

    #[test]
    fn best_typo_fix_deletes_only_a_doubled_letter() {
        let pack = bg_pack(&["много"]);
        // A bounced key typed the same letter twice → drop the duplicate.
        assert_eq!(best_typo_fix("мнного", &pack), Some("много".to_string()));
        // A MISSED key is no longer repaired: inserting one of 30 letters at any
        // position lands on a real word far too easily to do silently. The word
        // stays as typed — visibly wrong on screen, and trivial to retype.
        assert_eq!(best_typo_fix("мноо", &pack), None);
        // Nothing within one trusted edit → None.
        assert_eq!(best_typo_fix("здравей", &pack), None);
    }

    #[test]
    fn correct_word_missing_from_dictionary_is_left_alone() {
        // Real user report: "не си го разплатила" typed as "ne si go razplatila"
        // came out "не си го разклатила". "разплатила" is correct Bulgarian but
        // absent from the dictionary, and "разклатила" sits one substitution
        // away — so the word was silently replaced with a different one.
        //
        // п is typed 'p' and к is typed 'k': opposite ends of the keyboard.
        // Nobody hits 'k' reaching for 'p', so this was never a plausible typo.
        let pack = bg_pack(&["разклатила", "разклатил", "разклати"]);
        assert_eq!(best_typo_fix("разплатила", &pack), None,
            "a correct word must not be rewritten into a different one");
    }

    #[test]
    fn final_vowel_is_never_substituted() {
        // Bulgarian inflects by changing the final vowel, so "разплатила" vs
        // "разплатили" is a different grammatical form — not a typing slip —
        // even though и and а sit near each other.
        let pack = bg_pack(&["разплатили", "колата", "колите"]);
        assert_eq!(best_typo_fix("разплатила", &pack), None);
        assert_eq!(best_typo_fix("колата", &pack), None,
            "an exact dictionary word is not this function's business");
        // A final CONSONANT swap between neighbouring keys is still a typo and
        // must still be repaired — this is the "изтриеп" → "изтриеш" case.
        let pack2 = bg_pack(&["изтриеш"]);
        assert_eq!(best_typo_fix("изтриеп", &pack2), Some("изтриеш".to_string()));
    }

    #[test]
    fn a_letter_rolled_over_its_row_neighbour_is_deleted() {
        // Real user report: "постановките" typed "podstanowkite" — the finger
        // rolled across d on its way to s, and both are consonants side by
        // side on the home row.
        let pack = bg_pack(&["постановките"]);
        assert_eq!(
            best_typo_fix("подстановките", &pack),
            Some("постановките".to_string())
        );
    }

    #[test]
    fn a_roll_must_be_two_consonants_in_the_same_row() {
        // в is typed 'w' and с is typed 's' — near each other, but a row
        // apart. "боядисва" is a correct word one such deletion away from
        // "боядиса", and the -св- cluster runs through hundreds of verbs, so
        // counting a diagonal as a roll would rewrite all of them.
        let pack = bg_pack(&["боядиса"]);
        assert_eq!(best_typo_fix("боядисва", &pack), None);
        // Neither may the letter dropped be a vowel: Bulgarian inflects
        // through its vowels, so that is grammar, not a slip. о and и are
        // typed 'o' and 'i', side by side.
        let pack2 = bg_pack(&["бра"]);
        assert_eq!(best_typo_fix("биоа", &pack2), None);
    }

    #[test]
    fn arbitrary_letters_are_not_deleted() {
        // Dropping any letter to reach a dictionary word turns "агора" into
        // "гора" and "абсурдни" into "абсурди" — substitution of one word for
        // another, not typo repair. Only a doubled letter may be dropped.
        let pack = bg_pack(&["гора", "абсурди"]);
        assert_eq!(best_typo_fix("агора", &pack), None);
        assert_eq!(best_typo_fix("абсурдни", &pack), None);
    }

    #[test]
    fn layout_confusions_are_still_repaired() {
        // Three keys produce a different letter than romanization suggests, and
        // none of the pairs are keyboard neighbours — so they need the explicit
        // table rather than key distance.
        // 'v' types ж but was meant as в: "видеа" typed "videa" → "жидеа".
        let pack = bg_pack(&["видеа"]);
        assert_eq!(best_typo_fix("жидеа", &pack), Some("видеа".to_string()));
        // 'y' types ъ but was meant as й: "трейлъри" typed "treylyri" → "треълъри".
        let pack2 = bg_pack(&["трейлъри"]);
        assert_eq!(best_typo_fix("треълъри", &pack2), Some("трейлъри".to_string()));
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
