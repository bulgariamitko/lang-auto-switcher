//! The language packs that ship with the app.
//!
//! Each entry is the whole definition of a language: how its letters are
//! typed on a US keyboard, which letters are vowels, and which letter pairs
//! people confuse. Adding a language means adding a function here and a
//! dictionary — no changes to the detector.

use std::collections::HashSet;

use crate::lang::LanguagePack;

/// English — the Latin base. What you type is what you get, so it has no
/// keymap; it exists so the detector can weigh "this is already English"
/// against the transliterating packs on equal terms.
pub fn english(dict: HashSet<String>) -> LanguagePack {
    LanguagePack::latin("en", "English", dict, &[]).with_abbreviations(&[
        ("u", "you"), ("r", "are"), ("w", "with"), ("y", "why"),
        ("pls", "please"), ("thx", "thanks"), ("bc", "because"),
    ])
}

/// Bulgarian phonetic, exactly the layout the app has always shipped.
///
/// Note the two deliberate departures from romanisation, which are also why
/// `confusables` lists them: `v` types ж (в is on `w`) and `y` types ъ (й is
/// on `j`). `x` types ь where people reach for х. Those three mismatches are
/// the ones users actually trip over, so typo repair knows about them.
pub fn bulgarian(dict: HashSet<String>) -> LanguagePack {
    LanguagePack::transliterated(
        "bg",
        "Български",
        dict,
        &[
            ('a', 'а'), ('b', 'б'), ('c', 'ц'), ('d', 'д'), ('e', 'е'),
            ('f', 'ф'), ('g', 'г'), ('h', 'х'), ('i', 'и'), ('j', 'й'),
            ('k', 'к'), ('l', 'л'), ('m', 'м'), ('n', 'н'), ('o', 'о'),
            ('p', 'п'), ('q', 'я'), ('r', 'р'), ('s', 'с'), ('t', 'т'),
            ('u', 'у'), ('v', 'ж'), ('w', 'в'), ('x', 'ь'), ('y', 'ъ'),
            ('z', 'з'),
            // Keys that exist only to reach Cyrillic.
            (']', 'щ'), ('[', 'ш'), (';', 'ж'), ('\'', 'ь'),
            ('`', 'ч'), ('\\', 'ю'),
            // Shifted forms of those keys — not derivable from the lowercase
            // entry, because '}' is not the uppercase of ']'.
            ('}', 'Щ'), ('{', 'Ш'), (':', 'Ж'), ('"', 'Ь'),
            ('~', 'Ч'), ('|', 'Ю'),
            // ISO Mac §/± key (top-left, left of 1) — another way to type ч.
            ('§', 'ч'), ('±', 'Ч'),
        ],
        "аеиоуъюяь",
        &[('ж', 'в'), ('ъ', 'й'), ('ь', 'х')],
    )
    .with_abbreviations(&[
        ("mn", "много"), ("zdr", "здравей"), ("bl", "благодаря"),
        ("sq", "сега"), ("kv", "какво"),
    ])
}
