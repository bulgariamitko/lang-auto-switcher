//! Language detection flow — decides EN vs BG for each word and tracks context.
//!
//! Ported from LanguageDetector.swift. The two Apple framework dependencies
//! (NLLanguageRecognizer for scoring, NSSpellChecker for spell-correction) are
//! exposed as function-pointer callbacks the platform shim installs. On
//! Linux/Windows the callbacks can be None and the detector degrades to
//! dictionary-only + edit-distance.

use std::collections::HashSet;

use crate::autocorrect::{
    correct_bulgarian, correct_english, expand_bulgarian_abbreviation,
    expand_english_abbreviation, SpellCheckFn,
};
use crate::phonetic::{is_latin_word, to_cyrillic};

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
            last_word_language: DetectedLanguage::Uncertain,
            recent_languages: Vec::with_capacity(CONTEXT_WINDOW_SIZE),
            recent_confidences: Vec::with_capacity(CONTEXT_WINDOW_SIZE),
            recent_latin_words: Vec::with_capacity(RECENT_WORDS_MAX),
        }
    }

    pub fn is_first_word(&self) -> bool {
        self.recent_languages.is_empty()
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

        // 1. English abbreviation expansion (unless we're in a Bulgarian flow)
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
            // In NEITHER dictionary — respect current flow first
            if self.last_word_language == DetectedLanguage::English && streak_len >= 2 {
                if let Some(corrected) = correct_english(word, &self.en_dict, self.en_spell_check) {
                    detected = DetectedLanguage::English;
                    output = corrected;
                    confidence = 0.8;
                } else {
                    detected = DetectedLanguage::English;
                    output = word.to_string();
                    confidence = 0.5;
                }
            } else if self.last_word_language == DetectedLanguage::Bulgarian && streak_len >= 2 {
                detected = DetectedLanguage::Bulgarian;
                output = cyrillic.clone();
                confidence = 0.5;
            } else {
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
        if detected == DetectedLanguage::English && confidence >= 1.0 {
            if let Some(corrected) = correct_english(&output, &self.en_dict, self.en_spell_check) {
                output = corrected;
            }
        } else if detected == DetectedLanguage::Bulgarian && confidence >= 1.0 {
            if let Some(corrected) = correct_bulgarian(&output, &self.bg_dict, self.bg_spell_check) {
                output = corrected;
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
        let r = d.process_word("u");
        assert_eq!(r.converted, "you");
        assert_eq!(r.language, DetectedLanguage::English);
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
