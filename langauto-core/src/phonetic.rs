//! Phonetic Latin → Cyrillic mapping (strict 1-to-1, no digraphs).
//!
//! Ported from PhoneticMapper.swift. Behavior must match exactly.
//!
//! User overrides:
//!   The host platform can install a per-char override map via
//!   `set_char_override`. When set, `map_char` consults it first before
//!   falling through to the built-in default.

use std::collections::HashMap;
use std::sync::Mutex;

// Single, process-wide override map. Empty = use built-in defaults only.
// Mutex::new is const since Rust 1.63, no need for OnceCell/lazy_static.
static OVERRIDES: Mutex<Option<HashMap<char, char>>> = Mutex::new(None);

/// Replace the per-char override map. Pass an empty map to clear overrides.
pub fn set_char_overrides(map: HashMap<char, char>) {
    if let Ok(mut g) = OVERRIDES.lock() {
        *g = if map.is_empty() { None } else { Some(map) };
    }
}

/// Add or replace a single override entry. Lighter-weight than building a
/// full HashMap on the caller side when streaming pairs across FFI.
pub fn set_char_override(latin: char, cyrillic: char) {
    if let Ok(mut g) = OVERRIDES.lock() {
        g.get_or_insert_with(HashMap::new).insert(latin, cyrillic);
    }
}

/// Drop all overrides — `map_char` returns to the built-in mapping.
pub fn clear_char_overrides() {
    if let Ok(mut g) = OVERRIDES.lock() { *g = None; }
}

/// Map a single Latin char (plus a few punctuation keys) to its Cyrillic counterpart.
/// Returns `None` if the char has no mapping — callers should keep the original char.
#[inline]
pub fn map_char(c: char) -> Option<char> {
    if let Ok(g) = OVERRIDES.lock() {
        if let Some(map) = g.as_ref() {
            if let Some(&out) = map.get(&c) { return Some(out); }
        }
    }
    default_map_char(c)
}

#[inline]
fn default_map_char(c: char) -> Option<char> {
    let mapped = match c {
        // lowercase letters
        'a' => 'а', 'b' => 'б', 'c' => 'ц', 'd' => 'д', 'e' => 'е',
        'f' => 'ф', 'g' => 'г', 'h' => 'х', 'i' => 'и', 'j' => 'й',
        'k' => 'к', 'l' => 'л', 'm' => 'м', 'n' => 'н', 'o' => 'о',
        'p' => 'п', 'r' => 'р', 's' => 'с', 't' => 'т',
        'u' => 'у', 'v' => 'ж', 'w' => 'в', 'x' => 'ь', 'y' => 'ъ',
        'z' => 'з', 'q' => 'я',
        // lowercase specials
        ']' => 'щ', '[' => 'ш', ';' => 'ж', '\'' => 'ь', '`' => 'ч', '\\' => 'ю',
        // uppercase specials
        '}' => 'Щ', '{' => 'Ш', ':' => 'Ж', '"' => 'Ь', '~' => 'Ч', '|' => 'Ю',
        // uppercase letters
        'A' => 'А', 'B' => 'Б', 'C' => 'Ц', 'D' => 'Д', 'E' => 'Е',
        'F' => 'Ф', 'G' => 'Г', 'H' => 'Х', 'I' => 'И', 'J' => 'Й',
        'K' => 'К', 'L' => 'Л', 'M' => 'М', 'N' => 'Н', 'O' => 'О',
        'P' => 'П', 'R' => 'Р', 'S' => 'С', 'T' => 'Т',
        'U' => 'У', 'V' => 'Ж', 'W' => 'В', 'X' => 'Ь', 'Y' => 'Ъ',
        'Z' => 'З', 'Q' => 'Я',
        _ => return None,
    };
    Some(mapped)
}

/// Convert a whole Latin string to Cyrillic. Unmapped chars pass through unchanged.
pub fn to_cyrillic(text: &str) -> String {
    text.chars().map(|c| map_char(c).unwrap_or(c)).collect()
}

#[inline]
fn is_mappable_special(c: char) -> bool {
    matches!(c,
        ']' | '[' | ';' | '\'' | '`' | '\\' |
        '}' | '{' | ':' | '"' | '~' | '|'
    )
}

/// True when every char is an ASCII letter or a mapped special (and the word isn't empty).
pub fn is_latin_word(word: &str) -> bool {
    !word.is_empty() && word.chars().all(|c| c.is_ascii_alphabetic() || is_mappable_special(c))
}

/// The QWERTY key that produces this Cyrillic char in the default phonetic
/// map (lowercase). Used by typo ranking to detect adjacent-key mistakes.
/// Ignores user keymap overrides — adjacency is a heuristic, not a contract.
pub fn latin_key_for_cyrillic(c: char) -> Option<char> {
    Some(match c {
        'а' => 'a', 'б' => 'b', 'ц' => 'c', 'д' => 'd', 'е' => 'e',
        'ф' => 'f', 'г' => 'g', 'х' => 'h', 'и' => 'i', 'й' => 'j',
        'к' => 'k', 'л' => 'l', 'м' => 'm', 'н' => 'n', 'о' => 'o',
        'п' => 'p', 'р' => 'r', 'с' => 's', 'т' => 't', 'у' => 'u',
        'ж' => 'v', 'в' => 'w', 'ь' => 'x', 'ъ' => 'y', 'з' => 'z',
        'я' => 'q', 'щ' => ']', 'ш' => '[', 'ч' => '`', 'ю' => '\\',
        _ => return None,
    })
}

/// True if any char is in the Cyrillic Unicode block U+0400..=U+04FF.
pub fn contains_cyrillic(text: &str) -> bool {
    text.chars().any(|c| {
        let v = c as u32;
        (0x0400..=0x04FF).contains(&v)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lowercase_letters_map() {
        // Note: phonetic mapping uses 'w' → 'в', NOT 'v' → 'в'.
        // 'v' maps to 'ж' (QWERTY-position based, not sound-based).
        assert_eq!(to_cyrillic("zdrawei"), "здравеи");
        assert_eq!(to_cyrillic("dobre"), "добре");
        assert_eq!(to_cyrillic("blagodarq"), "благодаря");
    }

    #[test]
    fn special_chars_map() {
        assert_eq!(map_char(']'), Some('щ'));
        assert_eq!(map_char('['), Some('ш'));
        assert_eq!(map_char('`'), Some('ч'));
        assert_eq!(map_char('\\'), Some('ю'));
    }

    #[test]
    fn uppercase_letters_map() {
        assert_eq!(to_cyrillic("ABC"), "АБЦ");
        assert_eq!(map_char('Q'), Some('Я'));
    }

    #[test]
    fn unmapped_passthrough() {
        // 'l' → 'л', 'o' → 'о', so "hello 123!" → "хелло 123!"
        assert_eq!(to_cyrillic("hello 123!"), "хелло 123!");
        assert_eq!(map_char('0'), None);
        assert_eq!(map_char(' '), None);
        assert_eq!(map_char('.'), None);
    }

    #[test]
    fn is_latin_word_basics() {
        assert!(is_latin_word("hello"));
        assert!(is_latin_word("HELLO"));
        assert!(is_latin_word("Mixed"));
        assert!(is_latin_word("po[ata"));
        assert!(!is_latin_word(""));
        assert!(!is_latin_word("hello1"));
        assert!(!is_latin_word("здравей"));
        assert!(!is_latin_word("hello world"));
    }

    #[test]
    fn user_override_replaces_default_mapping() {
        // Default: 'v' → 'ж'. Override to 'в' (phonetic-sound mapping).
        // After clearing, the default returns.
        clear_char_overrides();
        assert_eq!(to_cyrillic("v"), "ж");

        set_char_override('v', 'в');
        assert_eq!(to_cyrillic("v"), "в");
        // Other chars still use default.
        assert_eq!(to_cyrillic("a"), "а");

        clear_char_overrides();
        assert_eq!(to_cyrillic("v"), "ж");
    }

    #[test]
    fn contains_cyrillic_detection() {
        assert!(contains_cyrillic("здравей"));
        assert!(contains_cyrillic("mixed text здравей"));
        assert!(!contains_cyrillic("hello world"));
        assert!(!contains_cyrillic(""));
        assert!(!contains_cyrillic("123 @# ."));
    }
}
