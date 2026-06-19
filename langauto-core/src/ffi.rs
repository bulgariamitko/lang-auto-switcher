//! C ABI for Swift / C++ / Python callers.
//!
//! Memory rules:
//! - Strings returned via `*mut c_char` must be freed by the caller with
//!   `langauto_string_free`.
//! - The `LangAutoDetector*` handle is heap-allocated by `langauto_detector_new`
//!   and must be released with `langauto_detector_free`.
//!
//! Callbacks (spell-check, language score) are set by the platform shim. They
//! receive a null-terminated UTF-8 string and either return a score (f64) or
//! write a correction into a caller-provided fixed-size output buffer.

use std::collections::HashSet;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::ptr;
use std::sync::Mutex;

use crate::detector::{DetectedLanguage, LanguageDetector};
use crate::phonetic;

// ---------- string utilities ----------

/// Free a string returned by this library. Safe to call with null.
///
/// # Safety
/// `s` must have been returned by one of this library's functions and not
/// previously freed.
#[no_mangle]
pub unsafe extern "C" fn langauto_string_free(s: *mut c_char) {
    if !s.is_null() {
        let _ = CString::from_raw(s);
    }
}

fn rust_to_c_string(s: &str) -> *mut c_char {
    match CString::new(s) {
        Ok(cs) => cs.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

unsafe fn c_to_rust_str<'a>(s: *const c_char) -> Option<&'a str> {
    if s.is_null() {
        None
    } else {
        CStr::from_ptr(s).to_str().ok()
    }
}

// ---------- phonetic free functions ----------

/// Convert Latin text to Cyrillic. Returned string must be freed with
/// `langauto_string_free`. Returns null on invalid UTF-8 input.
///
/// # Safety
/// `text` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn langauto_to_cyrillic(text: *const c_char) -> *mut c_char {
    let Some(s) = c_to_rust_str(text) else { return ptr::null_mut() };
    rust_to_c_string(&phonetic::to_cyrillic(s))
}

/// 1 if every char in `text` is an ASCII letter or a mapped special, else 0.
///
/// # Safety
/// `text` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn langauto_is_latin_word(text: *const c_char) -> c_int {
    let Some(s) = c_to_rust_str(text) else { return 0 };
    if phonetic::is_latin_word(s) { 1 } else { 0 }
}

/// 1 if `text` contains any Cyrillic codepoint (U+0400..U+04FF).
///
/// # Safety
/// `text` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn langauto_contains_cyrillic(text: *const c_char) -> c_int {
    let Some(s) = c_to_rust_str(text) else { return 0 };
    if phonetic::contains_cyrillic(s) { 1 } else { 0 }
}

// ---------- detector handle + lifecycle ----------

/// Opaque handle to a LanguageDetector instance.
/// Install / clear a single Latin → Cyrillic override pair.
///
/// `latin` and `cyrillic` are unicode scalar values (UTF-32 code points).
/// Pass scalar 0 (or anything outside the BMP without an override entry) only
/// if you mean it. If `cyrillic` is 0 this is a no-op (we don't store NUL).
#[no_mangle]
pub extern "C" fn langauto_set_char_override(latin: u32, cyrillic: u32) {
    if let (Some(l), Some(c)) = (char::from_u32(latin), char::from_u32(cyrillic)) {
        if c != '\0' { phonetic::set_char_override(l, c); }
    }
}

/// Drop all character overrides — `map_char` returns to the built-in mapping.
#[no_mangle]
pub extern "C" fn langauto_clear_char_overrides() {
    phonetic::clear_char_overrides();
}

pub struct LangAutoDetector {
    inner: LanguageDetector,
}

fn parse_dict(text: &str) -> HashSet<String> {
    text.lines()
        .map(|w| w.trim().to_lowercase())
        .filter(|w| !w.is_empty())
        .collect()
}

/// Create a new detector. Both dictionaries are passed as newline-separated
/// UTF-8 text. The detector takes ownership of the parsed words.
///
/// # Safety
/// `en_dict_text` and `bg_dict_text` must be valid null-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_new(
    en_dict_text: *const c_char,
    bg_dict_text: *const c_char,
) -> *mut LangAutoDetector {
    let en_text = match c_to_rust_str(en_dict_text) {
        Some(s) => s,
        None => return ptr::null_mut(),
    };
    let bg_text = match c_to_rust_str(bg_dict_text) {
        Some(s) => s,
        None => return ptr::null_mut(),
    };
    let detector = LanguageDetector::new(parse_dict(en_text), parse_dict(bg_text));
    Box::into_raw(Box::new(LangAutoDetector { inner: detector }))
}

/// Free a detector. Safe to call with null.
///
/// # Safety
/// `d` must have been returned by `langauto_detector_new` and not previously freed.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_free(d: *mut LangAutoDetector) {
    if !d.is_null() {
        let _ = Box::from_raw(d);
    }
}

// ---------- language enum mirror ----------

pub const LANGAUTO_LANG_ENGLISH: c_int = 0;
pub const LANGAUTO_LANG_BULGARIAN: c_int = 1;
pub const LANGAUTO_LANG_UNCERTAIN: c_int = 2;

fn lang_to_int(l: DetectedLanguage) -> c_int {
    match l {
        DetectedLanguage::English => LANGAUTO_LANG_ENGLISH,
        DetectedLanguage::Bulgarian => LANGAUTO_LANG_BULGARIAN,
        DetectedLanguage::Uncertain => LANGAUTO_LANG_UNCERTAIN,
    }
}

fn int_to_lang(i: c_int) -> DetectedLanguage {
    match i {
        LANGAUTO_LANG_BULGARIAN => DetectedLanguage::Bulgarian,
        LANGAUTO_LANG_UNCERTAIN => DetectedLanguage::Uncertain,
        _ => DetectedLanguage::English,
    }
}

// ---------- detector operations ----------

/// Process a word. Returns the converted string (caller must free with
/// `langauto_string_free`). Writes detected language and confidence to the
/// output pointers if non-null.
///
/// # Safety
/// `d` and `word` must be valid. `out_lang` and `out_conf` may be null.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_process_word(
    d: *mut LangAutoDetector,
    word: *const c_char,
    out_lang: *mut c_int,
    out_conf: *mut f64,
) -> *mut c_char {
    if d.is_null() {
        return ptr::null_mut();
    }
    let detector = &mut (*d).inner;
    let w = match c_to_rust_str(word) {
        Some(s) => s,
        None => return ptr::null_mut(),
    };
    let result = detector.process_word(w);
    if !out_lang.is_null() {
        *out_lang = lang_to_int(result.language);
    }
    if !out_conf.is_null() {
        *out_conf = result.confidence;
    }
    rust_to_c_string(&result.converted)
}

/// Reset all context (no recent words, no streak). Use at sentence boundaries
/// or when the user moves the cursor far away.
///
/// # Safety
/// `d` must be a valid detector pointer.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_reset_context(d: *mut LangAutoDetector) {
    if d.is_null() {
        return;
    }
    (*d).inner.reset_context();
}

/// 1 if the detector has processed no words yet (no context).
///
/// # Safety
/// `d` must be a valid detector pointer.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_is_first_word(d: *mut LangAutoDetector) -> c_int {
    if d.is_null() {
        return 1;
    }
    if (*d).inner.is_first_word() { 1 } else { 0 }
}

/// 1 if `word` (lowercase) is in the English dictionary.
///
/// # Safety
/// `d` and `word` must be valid.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_word_in_en_dict(
    d: *mut LangAutoDetector,
    word: *const c_char,
) -> c_int {
    if d.is_null() {
        return 0;
    }
    let Some(w) = c_to_rust_str(word) else { return 0 };
    if (*d).inner.en_dict.contains(&w.to_lowercase()) { 1 } else { 0 }
}

/// 1 if `cyrillic_word` (lowercase) is in the Bulgarian dictionary.
///
/// # Safety
/// `d` and `cyrillic_word` must be valid.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_word_in_bg_dict(
    d: *mut LangAutoDetector,
    cyrillic_word: *const c_char,
) -> c_int {
    if d.is_null() {
        return 0;
    }
    let Some(w) = c_to_rust_str(cyrillic_word) else { return 0 };
    if (*d).inner.bg_dict.contains(&w.to_lowercase()) { 1 } else { 0 }
}

/// Set the default language preference (used to break ties).
///
/// # Safety
/// `d` must be a valid detector pointer. `lang` should be LANGAUTO_LANG_*.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_set_default_language(
    d: *mut LangAutoDetector,
    lang: c_int,
) {
    if d.is_null() {
        return;
    }
    (*d).inner.default_language = int_to_lang(lang);
}

/// Get the current default language preference.
///
/// # Safety
/// `d` must be a valid detector pointer.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_get_default_language(
    d: *mut LangAutoDetector,
) -> c_int {
    if d.is_null() {
        return LANGAUTO_LANG_ENGLISH;
    }
    lang_to_int((*d).inner.default_language)
}

/// Enable or disable all autocorrect behavior (abbreviation expansion, spell
/// suggestions, edit-distance-1 matching). Off by default.
///
/// # Safety
/// `d` must be a valid detector pointer.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_set_autocorrect_enabled(
    d: *mut LangAutoDetector,
    enabled: c_int,
) {
    if d.is_null() {
        return;
    }
    (*d).inner.autocorrect_enabled = enabled != 0;
}

/// 1 if autocorrect is currently enabled, 0 otherwise.
///
/// # Safety
/// `d` must be a valid detector pointer.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_get_autocorrect_enabled(
    d: *mut LangAutoDetector,
) -> c_int {
    if d.is_null() {
        return 0;
    }
    if (*d).inner.autocorrect_enabled { 1 } else { 0 }
}

/// Enable or disable Bulgarian typo rescue (adjacent-key/edit-distance-1
/// correction + missing-space split for unknown words mid-BG-flow).
/// On by default.
///
/// # Safety
/// `d` must be a valid detector pointer.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_set_typo_correction_enabled(
    d: *mut LangAutoDetector,
    enabled: c_int,
) {
    if d.is_null() {
        return;
    }
    (*d).inner.typo_correction_enabled = enabled != 0;
}

/// 1 if typo correction is currently enabled, 0 otherwise.
///
/// # Safety
/// `d` must be a valid detector pointer.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_get_typo_correction_enabled(
    d: *mut LangAutoDetector,
) -> c_int {
    if d.is_null() {
        return 0;
    }
    if (*d).inner.typo_correction_enabled { 1 } else { 0 }
}

/// Write the number of entries in the English / Bulgarian dictionaries to the
/// output pointers (each may be null). Used by the diagnostics UI.
///
/// # Safety
/// `d` must be a valid detector pointer; out pointers may be null.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_dict_counts(
    d: *mut LangAutoDetector,
    out_en: *mut usize,
    out_bg: *mut usize,
) {
    let (en, bg) = if d.is_null() {
        (0, 0)
    } else {
        ((*d).inner.en_dict.len(), (*d).inner.bg_dict.len())
    };
    if !out_en.is_null() {
        *out_en = en;
    }
    if !out_bg.is_null() {
        *out_bg = bg;
    }
}

// ---------- learned ("always Latin") words ----------

/// Remember `word` as always-Latin: it will pass through verbatim, beating
/// dictionaries and autocorrect. Case-insensitive.
///
/// # Safety
/// `d` and `word` must be valid.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_add_user_latin_word(
    d: *mut LangAutoDetector,
    word: *const c_char,
) {
    if d.is_null() {
        return;
    }
    if let Some(w) = c_to_rust_str(word) {
        (*d).inner.add_user_latin_word(w);
    }
}

/// Forget a learned word. Returns 1 if it was present.
///
/// # Safety
/// `d` and `word` must be valid.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_remove_user_latin_word(
    d: *mut LangAutoDetector,
    word: *const c_char,
) -> c_int {
    if d.is_null() {
        return 0;
    }
    match c_to_rust_str(word) {
        Some(w) if (*d).inner.remove_user_latin_word(w) => 1,
        _ => 0,
    }
}

/// Forget all learned words.
///
/// # Safety
/// `d` must be a valid detector pointer.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_clear_user_latin_words(d: *mut LangAutoDetector) {
    if !d.is_null() {
        (*d).inner.clear_user_latin_words();
    }
}

/// Number of learned words.
///
/// # Safety
/// `d` must be a valid detector pointer.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_user_latin_word_count(
    d: *mut LangAutoDetector,
) -> usize {
    if d.is_null() {
        return 0;
    }
    (*d).inner.user_latin_word_count()
}

/// Remember a word as "always Bulgarian" (forced via ⌥⌘B). `word` is the
/// lowercase Latin spelling the user typed.
///
/// # Safety
/// `d` and `word` must be valid.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_add_user_bg_word(
    d: *mut LangAutoDetector,
    word: *const c_char,
) {
    if d.is_null() {
        return;
    }
    if let Some(w) = c_to_rust_str(word) {
        (*d).inner.add_user_bg_word(w);
    }
}

/// Forget a forced-Bulgarian word. Returns 1 if it was present.
///
/// # Safety
/// `d` and `word` must be valid.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_remove_user_bg_word(
    d: *mut LangAutoDetector,
    word: *const c_char,
) -> c_int {
    if d.is_null() {
        return 0;
    }
    match c_to_rust_str(word) {
        Some(w) if (*d).inner.remove_user_bg_word(w) => 1,
        _ => 0,
    }
}

/// Forget all forced-Bulgarian words.
///
/// # Safety
/// `d` must be a valid detector pointer.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_clear_user_bg_words(d: *mut LangAutoDetector) {
    if !d.is_null() {
        (*d).inner.clear_user_bg_words();
    }
}

/// Number of forced-Bulgarian words.
///
/// # Safety
/// `d` must be a valid detector pointer.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_user_bg_word_count(
    d: *mut LangAutoDetector,
) -> usize {
    if d.is_null() {
        return 0;
    }
    (*d).inner.user_bg_word_count()
}

// ---------- callback registration ----------
//
// Callbacks use C signatures the platform shim implements. They are stored as
// raw function pointers; the detector calls them as needed.
//
// SpellCheckFn signature:
//   int callback(const char* word, char* out_buf, size_t out_buf_size)
//   - Writes correction into out_buf (null-terminated)
//   - Returns 1 if a correction was written, 0 otherwise
//
// ScoreFn signature:
//   double callback(const char* text)

pub type CSpellCheckFn = extern "C" fn(*const c_char, *mut c_char, usize) -> c_int;
pub type CScoreFn = extern "C" fn(*const c_char) -> f64;

// Storage for the FFI callbacks. We bridge them to Rust fn pointers via
// global state because Rust fn pointers can't capture environment.
// Single set of globals is acceptable because there's exactly one detector
// per process in practice (the input method instance). Mutex (not static mut)
// because IMK gives no thread-affinity guarantee for callback installation
// vs. use.

static EN_SPELL_CB: Mutex<Option<CSpellCheckFn>> = Mutex::new(None);
static BG_SPELL_CB: Mutex<Option<CSpellCheckFn>> = Mutex::new(None);
static EN_SCORE_CB: Mutex<Option<CScoreFn>> = Mutex::new(None);
static BG_SCORE_CB: Mutex<Option<CScoreFn>> = Mutex::new(None);

fn load_cb<T: Copy>(slot: &Mutex<Option<T>>) -> Option<T> {
    slot.lock().ok().and_then(|g| *g)
}

fn store_cb<T: Copy>(slot: &Mutex<Option<T>>, cb: Option<T>) {
    if let Ok(mut g) = slot.lock() {
        *g = cb;
    }
}

fn bridge_en_spell(word: &str) -> Option<String> {
    bridge_spell(word, load_cb(&EN_SPELL_CB))
}

fn bridge_bg_spell(word: &str) -> Option<String> {
    bridge_spell(word, load_cb(&BG_SPELL_CB))
}

fn bridge_spell(word: &str, cb: Option<CSpellCheckFn>) -> Option<String> {
    let cb = cb?;
    let cword = CString::new(word).ok()?;
    let mut buf = vec![0u8; 256];
    let got = cb(cword.as_ptr(), buf.as_mut_ptr() as *mut c_char, buf.len());
    if got == 0 {
        return None;
    }
    // find null terminator
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8(buf[..end].to_vec()).ok()
}

fn bridge_en_score(text: &str) -> f64 {
    bridge_score(text, load_cb(&EN_SCORE_CB))
}

fn bridge_bg_score(text: &str) -> f64 {
    bridge_score(text, load_cb(&BG_SCORE_CB))
}

fn bridge_score(text: &str, cb: Option<CScoreFn>) -> f64 {
    let Some(cb) = cb else { return 0.0 };
    let Ok(ctext) = CString::new(text) else { return 0.0 };
    cb(ctext.as_ptr())
}

/// Install the English spell-check callback. Pass null to clear.
///
/// # Safety
/// `d` must be a valid detector pointer. Callback must remain valid for the
/// lifetime of the detector.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_set_en_spell_check(
    d: *mut LangAutoDetector,
    cb: Option<CSpellCheckFn>,
) {
    if d.is_null() {
        return;
    }
    store_cb(&EN_SPELL_CB, cb);
    (*d).inner.en_spell_check = if cb.is_some() { Some(bridge_en_spell) } else { None };
}

/// Install the Bulgarian spell-check callback.
///
/// # Safety
/// See `langauto_detector_set_en_spell_check`.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_set_bg_spell_check(
    d: *mut LangAutoDetector,
    cb: Option<CSpellCheckFn>,
) {
    if d.is_null() {
        return;
    }
    store_cb(&BG_SPELL_CB, cb);
    (*d).inner.bg_spell_check = if cb.is_some() { Some(bridge_bg_spell) } else { None };
}

/// Install the English language-scoring callback (NLLanguageRecognizer on Mac).
///
/// # Safety
/// See `langauto_detector_set_en_spell_check`.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_set_en_score(
    d: *mut LangAutoDetector,
    cb: Option<CScoreFn>,
) {
    if d.is_null() {
        return;
    }
    store_cb(&EN_SCORE_CB, cb);
    (*d).inner.score_english = if cb.is_some() { Some(bridge_en_score) } else { None };
}

/// Install the Bulgarian language-scoring callback.
///
/// # Safety
/// See `langauto_detector_set_en_spell_check`.
#[no_mangle]
pub unsafe extern "C" fn langauto_detector_set_bg_score(
    d: *mut LangAutoDetector,
    cb: Option<CScoreFn>,
) {
    if d.is_null() {
        return;
    }
    store_cb(&BG_SCORE_CB, cb);
    (*d).inner.score_bulgarian = if cb.is_some() { Some(bridge_bg_score) } else { None };
}

// Suppress unused-warning when this module is used only via the C ABI.
#[allow(dead_code)]
fn _force_link() -> *const c_void {
    langauto_string_free as *const c_void
}
