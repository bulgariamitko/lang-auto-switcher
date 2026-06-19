//! Language detection flow — decides EN vs BG for each word and tracks context.
//!
//! Ported from LanguageDetector.swift. The two Apple framework dependencies
//! (NLLanguageRecognizer for scoring, NSSpellChecker for spell-correction) are
//! exposed as function-pointer callbacks the platform shim installs. On
//! Linux/Windows the callbacks can be None and the detector degrades to
//! dictionary-only + edit-distance.

use std::collections::HashSet;

use crate::autocorrect::{
    best_bulgarian_typo_fix, correct_bulgarian, correct_english,
    expand_bulgarian_abbreviation, expand_english_abbreviation,
    split_into_two_words, SpellCheckFn,
};
use crate::phonetic::{contains_cyrillic_only_key, is_latin_word, to_cyrillic};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DetectedLanguage {
    English,
    Bulgarian,
    Uncertain,
}

impl DetectedLanguage {
    pub fn as_str(&self) -> &'static str {
        match self {
            DetectedLanguage::English => "EN",
            DetectedLanguage::Bulgarian => "BG",
            DetectedLanguage::Uncertain => "??",
        }
    }
}

#[derive(Debug, Clone)]
pub struct WordResult {
    pub original: String,
    pub converted: String,
    pub language: DetectedLanguage,
    pub confidence: f64,
}

/// NLLanguageRecognizer-style scoring callback. Returns confidence in [0.0, 1.0].
pub type ScoreFn = fn(&str) -> f64;

const CONTEXT_WINDOW_SIZE: usize = 6;
const RECENT_WORDS_MAX: usize = 8;

pub struct LanguageDetector {
    pub en_dict: HashSet<String>,
    pub bg_dict: HashSet<String>,
    pub en_spell_check: Option<SpellCheckFn>,
    pub bg_spell_check: Option<SpellCheckFn>,
    pub score_english: Option<ScoreFn>,
    pub score_bulgarian: Option<ScoreFn>,
    pub default_language: DetectedLanguage,
    /// When false, skip ALL autocorrect: abbreviation expansion (w→with, u→you,
    /// mn→много…), NSSpellChecker corrections, and edit-distance-1 matching.
    /// Words go through as typed (after phonetic conversion only).
    pub autocorrect_enabled: bool,
    /// Typo rescue for Bulgarian words (on by default, independent of
    /// `autocorrect_enabled`): a word in NEITHER dictionary that is mid-BG-flow,
    /// lowercase, and ≥5 letters gets one shot at an edit-distance-1 fix
    /// (adjacent-key substitution preferred) or a missing-space split.
    /// Conservative on purpose — "dpi"/"Windows"-style unknowns stay Latin.
    pub typo_correction_enabled: bool,
    /// Words the user has explicitly reverted ("learned words"). Stored
    /// lowercase. These always pass through verbatim in Latin — they beat
    /// dictionaries, abbreviation expansion, and flow continuation, because
    /// the user already told us a conversion of this word was wrong.
    user_latin_words: HashSet<String>,
    /// Words the user has explicitly forced to Bulgarian (⌥⌘B). Stored as the
    /// lowercase *Latin* spelling the user typed. These always convert to
    /// Cyrillic and establish Bulgarian flow — the mirror image of
    /// `user_latin_words` — so a word missing from the dictionary
    /// ("клипчета", "трейлъри") can be taught once instead of editing files.
    user_bg_words: HashSet<String>,

    last_word_language: DetectedLanguage,
    recent_languages: Vec<DetectedLanguage>,
    recent_confidences: Vec<f64>,
    recent_latin_words: Vec<String>,
}

impl LanguageDetector {
    pub fn new(en_dict: HashSet<String>, bg_dict: HashSet<String>) -> Self {
        Self {
            en_dict,
            bg_dict,
            en_spell_check: None,
            bg_spell_check: None,
            score_english: None,
            score_bulgarian: None,
            default_language: DetectedLanguage::English,
            autocorrect_enabled: false,
            typo_correction_enabled: true,
            user_latin_words: HashSet::new(),
            user_bg_words: HashSet::new(),
            last_word_language: DetectedLanguage::Uncertain,
            recent_languages: Vec::with_capacity(CONTEXT_WINDOW_SIZE),
            recent_confidences: Vec::with_capacity(CONTEXT_WINDOW_SIZE),
            recent_latin_words: Vec::with_capacity(RECENT_WORDS_MAX),
        }
    }

    pub fn is_first_word(&self) -> bool {
        self.recent_languages.is_empty()
    }

    /// Remember a word as "always Latin". Stored lowercase; matching in
    /// `process_word` is case-insensitive.
    pub fn add_user_latin_word(&mut self, word: &str) {
        let w = word.trim().to_lowercase();
        if !w.is_empty() {
            self.user_latin_words.insert(w);
        }
    }

    /// Forget a previously learned word. Returns true if it was present.
    pub fn remove_user_latin_word(&mut self, word: &str) -> bool {
        self.user_latin_words.remove(&word.trim().to_lowercase())
    }

    /// Forget all learned words.
    pub fn clear_user_latin_words(&mut self) {
        self.user_latin_words.clear();
    }

    pub fn user_latin_word_count(&self) -> usize {
        self.user_latin_words.len()
    }

    /// Remember a word as "always Bulgarian". Stored as the lowercase Latin
    /// spelling; matching in `process_word` is case-insensitive.
    pub fn add_user_bg_word(&mut self, word: &str) {
        let w = word.trim().to_lowercase();
        if !w.is_empty() {
            self.user_bg_words.insert(w);
        }
    }

    /// Forget a previously forced word. Returns true if it was present.
    pub fn remove_user_bg_word(&mut self, word: &str) -> bool {
        self.user_bg_words.remove(&word.trim().to_lowercase())
    }

    /// Forget all forced-Bulgarian words.
    pub fn clear_user_bg_words(&mut self) {
        self.user_bg_words.clear();
    }

    pub fn user_bg_word_count(&self) -> usize {
        self.user_bg_words.len()
    }

    pub fn reset_context(&mut self) {
        self.recent_languages.clear();
        self.recent_confidences.clear();
        self.recent_latin_words.clear();
        self.last_word_language = DetectedLanguage::Uncertain;
    }

    pub fn process_word(&mut self, word: &str) -> WordResult {
        if !is_latin_word(word) {
            return WordResult {
                original: word.to_string(),
                converted: word.to_string(),
                language: DetectedLanguage::Uncertain,
                confidence: 0.0,
            };
        }

        let lower = word.to_lowercase();

        // 0. Learned words: the user reverted a conversion of this word once,
        // so it always stays Latin verbatim. Transparent to the streak
        // (no push_context) so it behaves like "Windows"/"dpi" pass-throughs.
        if self.user_latin_words.contains(&lower) {
            return WordResult {
                original: word.to_string(),
                converted: word.to_string(),
                language: DetectedLanguage::Uncertain,
                confidence: 1.0,
            };
        }

        // 0b. Forced-Bulgarian words: the user pressed ⌥⌘B on this word once,
        // so it always converts to Cyrillic and establishes Bulgarian flow —
        // the mirror image of the learned-Latin pass-through above. This lets
        // an out-of-dictionary word be taught without editing any files.
        if self.user_bg_words.contains(&lower) {
            let cyrillic = to_cyrillic(word);
            self.push_context(DetectedLanguage::Bulgarian, 1.0);
            self.track_latin_word(word);
            return WordResult {
                original: word.to_string(),
                converted: cyrillic,
                language: DetectedLanguage::Bulgarian,
                confidence: 1.0,
            };
        }

        // 1. English abbreviation expansion (unless we're in a Bulgarian flow)
        if self.autocorrect_enabled {
            if let Some(expanded) = expand_english_abbreviation(&lower) {
                if self.last_word_language != DetectedLanguage::Bulgarian {
                    self.push_context(DetectedLanguage::English, 1.0);
                    self.track_latin_word(word);
                    return WordResult {
                        original: word.to_string(),
                        converted: expanded.to_string(),
                        language: DetectedLanguage::English,
                        confidence: 1.0,
                    };
                }
            }

            // 2. Bulgarian abbreviation expansion (only in Bulgarian flow)
            if let Some(bg_expanded) = expand_bulgarian_abbreviation(&lower) {
                if self.last_word_language == DetectedLanguage::Bulgarian {
                    self.push_context(DetectedLanguage::Bulgarian, 1.0);
                    self.track_latin_word(word);
                    return WordResult {
                        original: word.to_string(),
                        converted: bg_expanded.to_string(),
                        language: DetectedLanguage::Bulgarian,
                        confidence: 1.0,
                    };
                }
            }
        }

        // 3. Convert to Cyrillic, check both dictionaries
        let cyrillic = to_cyrillic(word);
        let cyrillic_lower = cyrillic.to_lowercase();

        let is_english = self.en_dict.contains(&lower);
        let is_bulgarian = self.bg_dict.contains(&cyrillic_lower);

        let both = is_bulgarian && is_english;
        let streak_len = self.consecutive_streak_length();

        let detected: DetectedLanguage;
        let mut output: String;
        let confidence: f64;

        if both {
            let r = self.resolve_ambiguous(word, &cyrillic);
            detected = r.0;
            output = r.1;
            confidence = r.2;
        } else if is_bulgarian && !is_english {
            if self.last_word_language == DetectedLanguage::English
                && streak_len >= 3
                && lower.chars().count() <= 3
            {
                detected = DetectedLanguage::English;
                output = word.to_string();
                confidence = 0.6;
            } else {
                detected = DetectedLanguage::Bulgarian;
                output = cyrillic.clone();
                confidence = 1.0;
            }
        } else if is_english && !is_bulgarian {
            if self.last_word_language == DetectedLanguage::Bulgarian
                && streak_len >= 3
                && lower.chars().count() <= 3
            {
                detected = DetectedLanguage::Bulgarian;
                output = cyrillic.clone();
                confidence = 0.6;
            } else {
                detected = DetectedLanguage::English;
                output = word.to_string();
                confidence = 1.0;
            }
        } else {
            // In NEITHER dictionary. Latin is the default: we don't recognise
            // the word in either language, so we never guess a Cyrillic
            // transliteration here. The 234k-entry, fully-inflected BG
            // dictionary means an unknown word is almost always genuinely
            // foreign (a brand like "Windows", a name, an English word) — not
            // a mistyped Bulgarian one — so transliterating it was the wrong
            // default.
            //
            // Exception: a word containing a Cyrillic-only key (\ [ ] ` …) is
            // a deliberate Cyrillic letter the user typed — nobody puts those
            // mid-word in English — so it overrides the Latin default and even
            // an English streak.
            let cyrillic_key_signal = contains_cyrillic_only_key(word);

            if self.last_word_language == DetectedLanguage::English
                && streak_len >= 2
                && !cyrillic_key_signal
            {
                // Continue an English streak; spell-correct only when
                // autocorrect is on. Output stays Latin either way.
                let corrected = if self.autocorrect_enabled {
                    correct_english(word, &self.en_dict, self.en_spell_check)
                } else {
                    None
                };
                if let Some(corrected) = corrected {
                    detected = DetectedLanguage::English;
                    output = corrected;
                    confidence = 0.8;
                } else {
                    detected = DetectedLanguage::English;
                    output = word.to_string();
                    confidence = 0.5;
                }
            } else if !self.autocorrect_enabled {
                // Default path (autocorrect off). First give a mid-BG-flow
                // word one shot at typo rescue ("изтриеп" → "изтриеш",
                // "можешда" → "можеш да"); if that declines, keep the word
                // verbatim in Latin and stay transparent (Uncertain) so a
                // lone unknown word neither transliterates nor flips the
                // surrounding flow.
                if let Some(fixed) = self.try_bulgarian_typo_fix(word, &cyrillic_lower) {
                    detected = DetectedLanguage::Bulgarian;
                    output = fixed;
                    confidence = 0.85;
                } else if cyrillic_key_signal {
                    // No dictionary/typo match, but the Cyrillic-only key
                    // makes the intent clear — convert verbatim ("превютата").
                    detected = DetectedLanguage::Bulgarian;
                    output = cyrillic.clone();
                    confidence = 0.9;
                } else {
                    detected = DetectedLanguage::Uncertain;
                    output = word.to_string();
                    confidence = 0.0;
                }
            } else if cyrillic_key_signal {
                // Autocorrect on, but the Cyrillic-only key still pins the
                // language to Bulgarian; spell-correct toward it if we can.
                detected = DetectedLanguage::Bulgarian;
                output = correct_bulgarian(&cyrillic, &self.bg_dict, self.bg_spell_check)
                    .unwrap_or_else(|| cyrillic.clone());
                confidence = 0.9;
            } else {
                // Autocorrect opt-in: allow aggressive two-language spell
                // correction, which may still recover a mistyped Bulgarian word.
                let en_spell = correct_english(word, &self.en_dict, self.en_spell_check);
                let bg_spell = correct_bulgarian(&cyrillic, &self.bg_dict, self.bg_spell_check);

                if bg_spell.is_some() && en_spell.is_none() {
                    detected = DetectedLanguage::Bulgarian;
                    output = bg_spell.unwrap();
                    confidence = 0.8;
                } else if en_spell.is_some() && bg_spell.is_none() {
                    detected = DetectedLanguage::English;
                    output = en_spell.unwrap();
                    confidence = 0.8;
                } else if en_spell.is_some() && bg_spell.is_some() {
                    match self.last_word_language {
                        DetectedLanguage::Bulgarian => {
                            detected = DetectedLanguage::Bulgarian;
                            output = bg_spell.unwrap();
                            confidence = 0.7;
                        }
                        DetectedLanguage::English => {
                            detected = DetectedLanguage::English;
                            output = en_spell.unwrap();
                            confidence = 0.7;
                        }
                        DetectedLanguage::Uncertain => {
                            let r = self.resolve_unknown(word, &cyrillic);
                            detected = r.0;
                            output = r.1;
                            confidence = r.2;
                        }
                    }
                } else {
                    let r = self.resolve_unknown(word, &cyrillic);
                    detected = r.0;
                    output = r.1;
                    confidence = r.2;
                }
            }
        }

        // 4. Apply spell correction AFTER detection for high-confidence matches
        if self.autocorrect_enabled {
            if detected == DetectedLanguage::English && confidence >= 1.0 {
                if let Some(corrected) = correct_english(&output, &self.en_dict, self.en_spell_check) {
                    output = corrected;
                }
            } else if detected == DetectedLanguage::Bulgarian && confidence >= 1.0 {
                if let Some(corrected) = correct_bulgarian(&output, &self.bg_dict, self.bg_spell_check) {
                    output = corrected;
                }
            }
        }

        self.push_context(detected, confidence);
        self.track_latin_word(word);

        WordResult {
            original: word.to_string(),
            converted: output,
            language: detected,
            confidence,
        }
    }

    // ---------- private helpers ----------

    /// Typo rescue for a word in NEITHER dictionary. Guards keep the
    /// "unknown words stay Latin" policy intact for the cases it exists for:
    /// - only mid-Bulgarian-flow (foreign words usually arrive in EN context)
    /// - never for capitalized words (brands/proper nouns: "Windows")
    /// - never for short words (<5 letters: "dpi", "css", "png" are
    ///   abbreviations, not typos)
    fn try_bulgarian_typo_fix(&self, word: &str, cyrillic_lower: &str) -> Option<String> {
        if !self.typo_correction_enabled {
            return None;
        }
        if self.last_word_language != DetectedLanguage::Bulgarian {
            return None;
        }
        if word.chars().next().map_or(false, |c| c.is_uppercase()) {
            return None;
        }
        if cyrillic_lower.chars().count() < 5 {
            return None;
        }

        if let Some(fixed) = best_bulgarian_typo_fix(cyrillic_lower, &self.bg_dict) {
            return Some(fixed);
        }
        split_into_two_words(cyrillic_lower, &self.bg_dict)
    }

    fn resolve_ambiguous(&self, word: &str, cyrillic: &str) -> (DetectedLanguage, String, f64) {
        let dominant = self.dominant_recent_language();
        if dominant == DetectedLanguage::Bulgarian {
            return (DetectedLanguage::Bulgarian, cyrillic.to_string(), 0.9);
        } else if dominant == DetectedLanguage::English {
            return (DetectedLanguage::English, word.to_string(), 0.9);
        }

        if self.last_word_language == DetectedLanguage::Bulgarian {
            return (DetectedLanguage::Bulgarian, cyrillic.to_string(), 0.8);
        } else if self.last_word_language == DetectedLanguage::English {
            return (DetectedLanguage::English, word.to_string(), 0.8);
        }

        // Context-based NL scoring (callback)
        let mut all = self.recent_latin_words.clone();
        all.push(word.to_string());
        let context_phrase = all.join(" ");
        let context_cyrillic = to_cyrillic(&context_phrase);

        let en_score = self.score_english.map(|f| f(&context_phrase)).unwrap_or(0.0);
        let bg_score = self.score_bulgarian.map(|f| f(&context_cyrillic)).unwrap_or(0.0);

        if bg_score > en_score + 0.1 {
            return (DetectedLanguage::Bulgarian, cyrillic.to_string(), bg_score);
        } else if en_score > bg_score + 0.1 {
            return (DetectedLanguage::English, word.to_string(), en_score);
        }

        match self.default_language {
            DetectedLanguage::Bulgarian => (DetectedLanguage::Bulgarian, cyrillic.to_string(), 0.5),
            _ => (DetectedLanguage::English, word.to_string(), 0.5),
        }
    }

    fn resolve_unknown(&self, word: &str, cyrillic: &str) -> (DetectedLanguage, String, f64) {
        if self.last_word_language == DetectedLanguage::Bulgarian {
            return (DetectedLanguage::Bulgarian, cyrillic.to_string(), 0.7);
        } else if self.last_word_language == DetectedLanguage::English {
            return (DetectedLanguage::English, word.to_string(), 0.7);
        }

        let en_score = self.score_english.map(|f| f(word)).unwrap_or(0.0);
        let bg_score = self.score_bulgarian.map(|f| f(cyrillic)).unwrap_or(0.0);

        if self.recent_latin_words.len() >= 2 {
            let mut all = self.recent_latin_words.clone();
            all.push(word.to_string());
            let context_phrase = all.join(" ");
            let context_cyrillic = to_cyrillic(&context_phrase);
            let en_ctx = self.score_english.map(|f| f(&context_phrase)).unwrap_or(0.0);
            let bg_ctx = self.score_bulgarian.map(|f| f(&context_cyrillic)).unwrap_or(0.0);

            let blend_en = en_score * 0.4 + en_ctx * 0.6;
            let blend_bg = bg_score * 0.4 + bg_ctx * 0.6;

            if blend_bg > 0.5 && blend_bg > blend_en + 0.15 {
                return (DetectedLanguage::Bulgarian, cyrillic.to_string(), blend_bg);
            } else if blend_en > 0.5 && blend_en > blend_bg + 0.15 {
                return (DetectedLanguage::English, word.to_string(), blend_en);
            }
        } else {
            if bg_score > 0.5 && bg_score > en_score + 0.15 {
                return (DetectedLanguage::Bulgarian, cyrillic.to_string(), bg_score);
            } else if en_score > 0.5 && en_score > bg_score + 0.15 {
                return (DetectedLanguage::English, word.to_string(), en_score);
            }
        }

        match self.default_language {
            DetectedLanguage::Bulgarian => (DetectedLanguage::Bulgarian, cyrillic.to_string(), 0.3),
            _ => (DetectedLanguage::English, word.to_string(), 0.3),
        }
    }

    fn dominant_recent_language(&self) -> DetectedLanguage {
        let mut bg = 0;
        let mut en = 0;
        for (idx, lang) in self.recent_languages.iter().enumerate() {
            if self.recent_confidences[idx] < 0.9 {
                continue;
            }
            match lang {
                DetectedLanguage::Bulgarian => bg += 1,
                DetectedLanguage::English => en += 1,
                _ => {}
            }
        }
        if bg > en {
            DetectedLanguage::Bulgarian
        } else if en > bg {
            DetectedLanguage::English
        } else {
            DetectedLanguage::Uncertain
        }
    }

    fn consecutive_streak_length(&self) -> usize {
        if self.last_word_language == DetectedLanguage::Uncertain {
            return 0;
        }
        let mut count = 0;
        for (lang, conf) in self
            .recent_languages
            .iter()
            .rev()
            .zip(self.recent_confidences.iter().rev())
        {
            if *lang == self.last_word_language && *conf >= 0.9 {
                count += 1;
            } else if *lang == self.last_word_language {
                continue;
            } else {
                break;
            }
        }
        count
    }

    fn push_context(&mut self, lang: DetectedLanguage, confidence: f64) {
        if lang == DetectedLanguage::Uncertain {
            return;
        }
        self.last_word_language = lang;
        self.recent_languages.push(lang);
        self.recent_confidences.push(confidence);
        if self.recent_languages.len() > CONTEXT_WINDOW_SIZE {
            self.recent_languages.remove(0);
            self.recent_confidences.remove(0);
        }
    }

    fn track_latin_word(&mut self, word: &str) {
        self.recent_latin_words.push(word.to_string());
        if self.recent_latin_words.len() > RECENT_WORDS_MAX {
            self.recent_latin_words.remove(0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn english_dict() -> HashSet<String> {
        ["hello", "how", "are", "you", "world", "the", "code", "and", "want", "to", "write"]
            .iter().map(|s| s.to_string()).collect()
    }

    fn bulgarian_dict() -> HashSet<String> {
        ["здравей", "как", "си", "добре", "написах", "нов", "код", "това", "е", "само", "проба"]
            .iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn english_sentence_stays_english() {
        let mut d = LanguageDetector::new(english_dict(), bulgarian_dict());
        let result = d.process_word("hello");
        assert_eq!(result.language, DetectedLanguage::English);
        assert_eq!(result.converted, "hello");

        let result = d.process_word("world");
        assert_eq!(result.language, DetectedLanguage::English);
    }

    #[test]
    fn bulgarian_sentence_converts() {
        let mut d = LanguageDetector::new(english_dict(), bulgarian_dict());
        let r = d.process_word("napisah");
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
        assert_eq!(r.converted, "написах");

        let r = d.process_word("now");
        // "now" is in EN dict; without context yet it's ambiguous between EN ("now")
        // and BG ("нов"). At this point the previous word was BG, so flow follows BG.
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
        assert_eq!(r.converted, "нов");
    }

    #[test]
    fn abbreviation_expansion_in_english_flow() {
        let mut d = LanguageDetector::new(english_dict(), bulgarian_dict());
        d.autocorrect_enabled = true; // off by default
        let r = d.process_word("u");
        assert_eq!(r.converted, "you");
        assert_eq!(r.language, DetectedLanguage::English);
    }

    #[test]
    fn autocorrect_off_by_default_leaves_abbreviations_alone() {
        // The user opted out of "w → with"-style rewrites. With autocorrect
        // disabled (the default), short Latin tokens must pass through as
        // typed — no abbreviation expansion in either direction.
        let mut d = LanguageDetector::new(english_dict(), bulgarian_dict());
        assert!(!d.autocorrect_enabled, "autocorrect must default to off");

        let r = d.process_word("w");
        assert_eq!(r.converted, "w", "'w' should not expand to 'with'");
        assert_ne!(r.converted, "with");

        let r = d.process_word("u");
        assert_eq!(r.converted, "u", "'u' should not expand to 'you'");
    }

    #[test]
    fn autocorrect_off_skips_spell_check_fallback() {
        // When the word is in NEITHER dictionary and autocorrect is off,
        // the detector must not consult the spell-check callback — it
        // should fall through to resolve_unknown() with the raw word.
        let en: HashSet<String> = ["hello"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = HashSet::new();
        let mut d = LanguageDetector::new(en, bg);
        fn cb(_w: &str) -> Option<String> {
            // If autocorrect path is taken, this would rewrite "helo" → "hello".
            Some("hello".to_string())
        }
        d.en_spell_check = Some(cb);

        let r = d.process_word("helo");
        assert_eq!(r.converted, "helo", "autocorrect off must skip spell-check rewrite");
    }

    #[test]
    fn bg_short_function_word_at_sentence_start_does_not_lock_english() {
        // Regression: sentences like "ama to za po-golemi…" used to stay
        // Latin for the first 4 words because "ama"/"za"/"po"/"da" leaked
        // into the English dictionary as Scrabble entries, defaulting the
        // first-word resolve_ambiguous() to English and dragging the rest
        // along in EN flow until a clearly-BG-only word forced a flip.
        //
        // With those Scrabble entries removed from en-dictionary.txt, the
        // first BG-only word should commit BG and the rest follow.
        let en: HashSet<String> = ["to"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["ама", "то", "за", "по", "големи", "бройки", "не"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        for (word, expected) in [
            ("ama", "ама"), ("to", "то"), ("za", "за"), ("po", "по"),
            ("golemi", "големи"), ("brojki", "бройки"), ("ne", "не"),
        ] {
            let r = d.process_word(word);
            assert_eq!(r.language, DetectedLanguage::Bulgarian,
                "word {word:?} should be Bulgarian, got {:?}", r.language);
            assert_eq!(r.converted, expected, "word {word:?}: wrong conversion");
        }
    }

    #[test]
    fn bg_sentence_starting_with_w_does_not_get_mangled_by_autocorrect() {
        // Regression: with phonetic mapping `w → в`, the Bulgarian sentence
        // "в момента го гледам но отнема време" is typed as
        // "w momenta go gledam no otnema wreme". The previous build expanded
        // the standalone "w" to "with" (English abbreviation table), which
        // (a) committed an English word at the very start of a Bulgarian
        // sentence and (b) locked the EN flow for the rest of it.
        //
        // With autocorrect off by default, "w" must transliterate to "в"
        // and the whole sentence must come out Cyrillic.
        let en: HashSet<String> = ["no"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = [
            "в", "момента", "го", "гледам", "но", "отнема", "време",
        ].iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);

        let pairs = [
            ("w",       "в"),
            ("momenta", "момента"),
            ("go",      "го"),
            ("gledam",  "гледам"),
            ("no",      "но"),
            ("otnema",  "отнема"),
            ("wreme",   "време"),
        ];
        let mut converted = Vec::new();
        for (latin, expected_cyr) in pairs {
            let r = d.process_word(latin);
            assert_eq!(r.language, DetectedLanguage::Bulgarian,
                "{latin:?} should land in Bulgarian, got {:?}", r.language);
            assert_eq!(r.converted, expected_cyr,
                "{latin:?}: expected {expected_cyr:?}, got {:?}", r.converted);
            converted.push(r.converted);
        }
        assert_eq!(converted.join(" "),
                   "в момента го гледам но отнема време");
    }

    #[test]
    fn bg_sentence_starting_with_w_breaks_when_autocorrect_is_on() {
        // Mirror of the test above — proves the autocorrect path is what
        // caused the original bug. With autocorrect ON, the standalone "w"
        // expands to "with" before phonetic conversion ever runs, so the
        // first word is English and the sentence is corrupted.
        let en: HashSet<String> = ["no", "with"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = [
            "в", "момента", "го", "гледам", "но", "отнема", "време",
        ].iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        d.autocorrect_enabled = true;

        let r = d.process_word("w");
        assert_eq!(r.converted, "with",
            "with autocorrect on, 'w' is expanded — this is the bug we turned off");
    }

    #[test]
    fn unknown_word_with_cyrillic_only_key_converts() {
        // Regression: "с превютата на файловете…" typed as
        // "s prew\tata na ...". "превютата" (preview + article, a colloquial
        // loanword) is in NEITHER dictionary, and at sentence start there's
        // no BG flow yet — so it used to stay Latin, showing the literal '\'.
        // But the '\' key only exists to type 'ю': its presence proves the
        // user is typing Bulgarian, so the word must convert.
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["на", "файловете"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);

        // First real word of the sentence — no prior context.
        let r = d.process_word("prew\\tata");
        assert_eq!(r.converted, "превютата",
            "word with a Cyrillic-only key ('\\') must convert, got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
        assert_ne!(r.converted, "prew\\tata", "the literal backslash must not survive");

        // And it establishes BG flow for the rest of the sentence.
        let r = d.process_word("na");
        assert_eq!(r.converted, "на");
        let r = d.process_word("fajlowete");
        assert_eq!(r.converted, "файловете");
    }

    #[test]
    fn cyrillic_only_key_overrides_english_streak() {
        // Even mid-English-streak, a word with a bracket/backslash key is a
        // deliberate Cyrillic switch and must convert rather than stay Latin.
        let en: HashSet<String> = ["the", "code", "is"]
            .iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = HashSet::new();
        let mut d = LanguageDetector::new(en, bg);
        d.process_word("the");
        d.process_word("code");
        d.process_word("is");

        // "ka[ta" → "кашта" (no dict needed; the '[' forces Cyrillic).
        let r = d.process_word("ka[ta");
        assert_eq!(r.converted, "кашта",
            "a Cyrillic-only key must override the English streak, got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
    }

    #[test]
    fn typo_fix_still_wins_over_raw_cyrillic_for_special_key_words() {
        // A word that has BOTH a Cyrillic-only key and a fixable typo must
        // still get the typo fix (best spelling), not the raw conversion.
        // "iztire[" → raw "изтиреш", but the dict has "изтриеш": typo fix wins.
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["можеш", "да", "изтриеш"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        d.process_word("move["); // можеш — establishes BG flow
        d.process_word("da");

        let r = d.process_word("iztire[");
        assert_eq!(r.converted, "изтриеш",
            "typo fix must beat raw cyrillic, got {:?}", r.converted);
    }

    #[test]
    fn dictionary_loanword_plurals_convert_not_typo_corrected() {
        // Regression: "...имат видеа treylyri". Two modern loanword forms that
        // were missing from the BG dictionary:
        //   • "видеа" (plural of видео). Typing "videa" maps to "видеа", but
        //     with it absent the typo-rescuer "fixed" it to the nearest real
        //     word "видра" (otter). An exact dictionary entry must win outright.
        //   • "трейлъри". Typed "treylyri" maps to "треълъри" (the user pressed
        //     'y'→ъ instead of 'j'→й for й); with "трейлъри" in the dictionary
        //     the typo-fixer recovers it (edit distance 1).
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["имат", "видео", "видеа", "видра", "трейлъри"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);

        d.process_word("imat"); // имат — establishes BG flow

        let r = d.process_word("videa");
        assert_eq!(r.converted, "видеа",
            "exact dict entry must win, not the typo 'видра', got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Bulgarian);

        let r = d.process_word("treylyri");
        assert_eq!(r.converted, "трейлъри",
            "treylyri (треълъри) must typo-fix to трейлъри, got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
    }

    #[test]
    fn forced_bg_word_always_converts_and_leads_flow() {
        // The user pressed ⌥⌘B on "klip`eta" (клипчета) once. It is in NEITHER
        // dictionary, but the forced set must make it convert verbatim every
        // time afterwards — even as the first word with no prior context — and
        // establish Bulgarian flow for what follows.
        let en: HashSet<String> = ["clip"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["са", "хубави"].iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        d.add_user_bg_word("klip`eta");

        let r = d.process_word("klip`eta");
        assert_eq!(r.converted, "клипчета",
            "forced word must convert verbatim, got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Bulgarian);

        // It led the flow, so a following short BG word rides the streak.
        let r = d.process_word("sa");
        assert_eq!(r.converted, "са");

        // Case-insensitive and forgettable.
        assert!(d.remove_user_bg_word("KLIP`ETA"));
        assert_eq!(d.user_bg_word_count(), 0);
    }

    #[test]
    fn capitalized_unknown_word_in_bg_flow_stays_latin() {
        // Regression: "...В смисъл Windows е нали" — typed in Latin, the
        // brand name "Windows" is in NEITHER dictionary (en-dict has only
        // "window"; "виндовс" isn't Bulgarian). With a Bulgarian streak
        // established, the NEITHER-branch flow-continuation rule used to
        // transliterate it to "Виндовс". The capital W marks it as a foreign
        // proper noun: it must pass through verbatim as Latin, and the
        // Bulgarian words after it must still convert.
        let en: HashSet<String> = ["window"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["много", "хубаво", "е", "нали"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);

        // Establish a Bulgarian streak (both BG-only words).
        let r = d.process_word("mnogo");
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
        assert_eq!(r.converted, "много");
        let r = d.process_word("hubawo");
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
        assert_eq!(r.converted, "хубаво");

        // The brand name must stay Latin, not become "Виндовс".
        let r = d.process_word("Windows");
        assert_eq!(r.converted, "Windows",
            "capitalized unknown word in BG flow must stay Latin, got {:?}", r.converted);
        assert_ne!(r.converted, "Виндовс");
        assert_eq!(r.language, DetectedLanguage::Uncertain,
            "proper noun should be transparent to the language streak");

        // Bulgarian flow must survive the proper noun.
        let r = d.process_word("nali");
        assert_eq!(r.converted, "нали",
            "BG flow must continue after the proper noun, got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
    }

    #[test]
    fn unknown_word_in_bg_flow_stays_latin_by_default() {
        // Policy: a word in NEITHER dictionary defaults to Latin — we never
        // guess a Cyrillic transliteration. This holds even mid-Bulgarian-flow
        // and regardless of case, because the 234k-entry BG dictionary makes
        // an unknown word almost certainly foreign rather than a mistyped BG
        // word. (Autocorrect-off is the default.)
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["много", "хубаво", "нали"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        d.process_word("mnogo");
        d.process_word("hubawo");

        let r = d.process_word("abcdef"); // unknown, lowercase
        assert_eq!(r.converted, "abcdef",
            "unknown word must stay Latin, got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Uncertain,
            "unknown word should be transparent to the streak");

        // The Bulgarian flow must survive an unknown Latin word.
        let r = d.process_word("nali");
        assert_eq!(r.converted, "нали");
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
    }

    #[test]
    fn unknown_word_after_a_number_in_bg_flow_stays_latin() {
        // Regression: "...файловете на 300 dpi" — typed in Latin as
        // "...failovete na 300 dpi". "dpi" is in NEITHER dictionary (it isn't
        // an English Scrabble word and "дпи" isn't Bulgarian), so it must stay
        // Latin instead of transliterating to "дпи". The intervening "300" is
        // non-alphabetic: process_word returns it Uncertain WITHOUT touching
        // context, so the Bulgarian streak from "na" still leads into "dpi".
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["това", "на"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);

        // Phonetic map is QWERTY-position based: в is typed 'w' (not 'v').
        let r = d.process_word("towa");
        assert_eq!(r.converted, "това");
        assert_eq!(r.language, DetectedLanguage::Bulgarian);

        let r = d.process_word("na");
        assert_eq!(r.converted, "на");
        assert_eq!(r.language, DetectedLanguage::Bulgarian);

        // The number is non-alphabetic — passes through, context untouched.
        let r = d.process_word("300");
        assert_eq!(r.converted, "300");
        assert_eq!(r.language, DetectedLanguage::Uncertain);

        // "dpi" must stay Latin, not become "дпи".
        let r = d.process_word("dpi");
        assert_eq!(r.converted, "dpi",
            "unit abbreviation in BG flow must stay Latin, got {:?}", r.converted);
        assert_ne!(r.converted, "дпи");
        assert_eq!(r.language, DetectedLanguage::Uncertain);
    }

    #[test]
    fn bg_typo_adjacent_key_substitution_is_corrected() {
        // Real user report: "ок можеш да ги изтриеп от при нас вече" —
        // "изтриеп" is a typo for "изтриеш" (п is typed 'p', ш is typed '[',
        // and p/[ are adjacent keys). The dictionary also contains the
        // distance-1 neighbors "изтрием" and "изтрие"; the adjacent-key
        // ranking must pick "изтриеш" over both.
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["можеш", "да", "ги", "изтрие", "изтрием", "изтриеш"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);

        // "можеш" is typed "move[" (ж='v', ш='[').
        let r = d.process_word("move[");
        assert_eq!(r.converted, "можеш");
        let r = d.process_word("da");
        assert_eq!(r.converted, "да");
        let r = d.process_word("gi");
        assert_eq!(r.converted, "ги");

        let r = d.process_word("iztriep");
        assert_eq!(r.converted, "изтриеш",
            "typo 'изтриеп' must correct to 'изтриеш', got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
    }

    #[test]
    fn bg_typo_transposed_letters_are_corrected() {
        // "letters are shifted": "изтиреш" (ир swapped) → "изтриеш".
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["можеш", "да", "изтриеш"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        d.process_word("move[");
        d.process_word("da");

        let r = d.process_word("iztire["); // изтиреш
        assert_eq!(r.converted, "изтриеш",
            "transposed letters must be corrected, got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
    }

    #[test]
    fn bg_missing_space_is_split_into_two_words() {
        // Spacebar missed: "можешда" → "можеш да".
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["това", "можеш", "да"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        d.process_word("towa");

        let r = d.process_word("move[da"); // можешда
        assert_eq!(r.converted, "можеш да",
            "joined words must be split, got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
    }

    #[test]
    fn typo_correction_keeps_short_unknowns_latin() {
        // "dpi" must stay Latin even though its transliteration "дпи" is
        // edit-distance-1 from the real Bulgarian word "дни" — short
        // unknowns are abbreviations, not typos.
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["дни", "това", "на"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        d.process_word("towa");
        d.process_word("na");

        let r = d.process_word("dpi");
        assert_eq!(r.converted, "dpi",
            "short unknown must not be 'typo-fixed' to дни, got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Uncertain);
    }

    #[test]
    fn typo_correction_keeps_capitalized_unknowns_latin() {
        // Capitalized = proper noun/brand. Even a perfect distance-1 match
        // must not fire.
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["това", "изтриеш"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        d.process_word("towa");

        let r = d.process_word("Iztriep");
        assert_eq!(r.converted, "Iztriep",
            "capitalized unknown must stay Latin, got {:?}", r.converted);
    }

    #[test]
    fn typo_correction_requires_bulgarian_flow() {
        // No BG context → no rescue; the word stays Latin (default policy).
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["изтриеш"].iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);

        let r = d.process_word("iztriep"); // first word, no flow
        assert_eq!(r.converted, "iztriep");
        assert_eq!(r.language, DetectedLanguage::Uncertain);
    }

    #[test]
    fn typo_correction_can_be_disabled() {
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["можеш", "да", "изтриеш"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        assert!(d.typo_correction_enabled, "typo correction must default to on");
        d.typo_correction_enabled = false;
        d.process_word("move[");
        d.process_word("da");

        let r = d.process_word("iztriep");
        assert_eq!(r.converted, "iztriep",
            "with typo correction off the word must stay Latin, got {:?}", r.converted);
    }

    #[test]
    fn learned_word_beats_typo_correction() {
        // If the user reverted a "correction" once, never fix it again.
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["можеш", "да", "изтриеш"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        d.add_user_latin_word("iztriep");
        d.process_word("move[");
        d.process_word("da");

        let r = d.process_word("iztriep");
        assert_eq!(r.converted, "iztriep");
    }

    #[test]
    fn learned_word_stays_latin_even_when_in_bg_dictionary() {
        // The user reverted a conversion of this word once, so it must stay
        // Latin forever — even though its transliteration IS a valid
        // Bulgarian dictionary word and the flow is Bulgarian.
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["това", "на", "нали"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        d.add_user_latin_word("na"); // "na" → "на" is in the BG dict

        let r = d.process_word("towa");
        assert_eq!(r.converted, "това");

        let r = d.process_word("na");
        assert_eq!(r.converted, "na",
            "learned word must stay Latin, got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Uncertain);

        // Matching is case-insensitive.
        let r = d.process_word("Na");
        assert_eq!(r.converted, "Na");

        // The Bulgarian flow must survive the learned word.
        let r = d.process_word("nali");
        assert_eq!(r.converted, "нали");
        assert_eq!(r.language, DetectedLanguage::Bulgarian);
    }

    #[test]
    fn learned_word_beats_abbreviation_expansion() {
        // Learned words win over autocorrect's abbreviation table: if the
        // user said "w" stays "w", it must not expand to "with" even with
        // autocorrect on.
        let mut d = LanguageDetector::new(english_dict(), bulgarian_dict());
        d.autocorrect_enabled = true;
        d.add_user_latin_word("w");

        let r = d.process_word("w");
        assert_eq!(r.converted, "w");
    }

    #[test]
    fn learned_words_can_be_removed_and_cleared() {
        let mut d = LanguageDetector::new(english_dict(), bulgarian_dict());
        d.add_user_latin_word("dpi");
        d.add_user_latin_word("Foo"); // stored lowercase
        assert_eq!(d.user_latin_word_count(), 2);

        assert!(d.remove_user_latin_word("FOO"));
        assert!(!d.remove_user_latin_word("foo"));
        assert_eq!(d.user_latin_word_count(), 1);

        d.clear_user_latin_words();
        assert_eq!(d.user_latin_word_count(), 0);

        // After forgetting, normal detection applies again.
        d.add_user_latin_word("napisah");
        d.clear_user_latin_words();
        let r = d.process_word("napisah");
        assert_eq!(r.converted, "написах");
    }

    #[test]
    fn reset_context_clears_state() {
        let mut d = LanguageDetector::new(english_dict(), bulgarian_dict());
        d.process_word("hello");
        assert!(!d.is_first_word());
        d.reset_context();
        assert!(d.is_first_word());
        assert_eq!(d.last_word_language, DetectedLanguage::Uncertain);
    }
}
