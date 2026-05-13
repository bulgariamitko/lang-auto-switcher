//! Phonetic Latin → Cyrillic mapping (strict 1-to-1, no digraphs).
//!
//! Ported from PhoneticMapper.swift. Behavior must match exactly.

/// Map a single Latin char (plus a few punctuation keys) to its Cyrillic counterpart.
/// Returns `None` if the char has no mapping — callers should keep the original char.
#[inline]
pub fn map_char(c: char) -> Option<char> {
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
    fn contains_cyrillic_detection() {
        assert!(contains_cyrillic("здравей"));
        assert!(contains_cyrillic("mixed text здравей"));
        assert!(!contains_cyrillic("hello world"));
        assert!(!contains_cyrillic(""));
        assert!(!contains_cyrillic("123 @# ."));
    }
}
