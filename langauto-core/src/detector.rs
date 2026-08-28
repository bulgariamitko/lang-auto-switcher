//! Language detection flow — decides EN vs BG for each word and tracks context.
//!
//! Ported from LanguageDetector.swift. The two Apple framework dependencies
//! (NLLanguageRecognizer for scoring, NSSpellChecker for spell-correction) are
//! exposed as function-pointer callbacks the platform shim installs. On
//! Linux/Windows the callbacks can be None and the detector degrades to
//! dictionary-only + edit-distance.

use std::collections::{HashMap, HashSet};

use crate::autocorrect::{
    best_typo_fix, correct_bulgarian, correct_english,
    split_into_two_words, SpellCheckFn,
};
use crate::lang::LanguagePack;
use crate::packs;

/// Which language a word was decided to be. `Lang(i)` indexes the detector's
/// pack list, so the set of languages is configuration rather than a fixed
/// enum — adding a fourth language does not touch this type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DetectedLanguage {
    Uncertain,
    Lang(usize),
}

impl DetectedLanguage {
    /// The Latin base pack is always first, so these name the two languages
    /// that ship enabled by default and keep call sites readable.
    pub const ENGLISH: Self = DetectedLanguage::Lang(0);
    pub const BULGARIAN: Self = DetectedLanguage::Lang(1);

    pub fn index(&self) -> Option<usize> {
        match self {
            DetectedLanguage::Lang(i) => Some(*i),
            DetectedLanguage::Uncertain => None,
        }
    }

    pub fn is_uncertain(&self) -> bool {
        matches!(self, DetectedLanguage::Uncertain)
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
    /// Every language currently enabled. Index 0 is the Latin base (English):
    /// unknown words fall back to it, because "not recognised" should leave
    /// the text as typed rather than guess a transliteration. Everything the
    /// detector knows about a language lives in its pack, so supporting a
    /// fourth language is a matter of pushing another one here.
    pub packs: Vec<LanguagePack>,
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
    /// Words the user pinned to a specific language with ⌥⌘B, stored as
    /// the lowercase Latin spelling they typed mapped to the pack index.
    user_forced_words: HashMap<String, usize>,

    last_word_language: DetectedLanguage,
    recent_languages: Vec<DetectedLanguage>,
    recent_confidences: Vec<f64>,
    recent_latin_words: Vec<String>,

    /// Language of the word to the RIGHT, when the caller has already seen it
    /// (see `resolve_pending`). Only set for the duration of a single
    /// `process_word` call. An ambiguous word consults this before any
    /// left-hand signal, because the caller only holds a word when the left
    /// side was inconclusive in the first place.
    right_hint: Option<DetectedLanguage>,
}

/// Frozen copy of the rolling context, so a word can be classified as a
/// look-ahead peek and then un-done. See `LanguageDetector::snapshot`.
#[derive(Clone)]
pub struct ContextSnapshot {
    last_word_language: DetectedLanguage,
    recent_languages: Vec<DetectedLanguage>,
    recent_confidences: Vec<f64>,
    recent_latin_words: Vec<String>,
}

impl LanguageDetector {
    /// The default two-language setup: English plus Bulgarian.
    pub fn new(en_dict: HashSet<String>, bg_dict: HashSet<String>) -> Self {
        Self::with_packs(vec![packs::english(en_dict), packs::bulgarian(bg_dict)])
    }

    /// Any number of languages. The first pack must be the Latin base.
    pub fn with_packs(packs: Vec<LanguagePack>) -> Self {
        debug_assert!(
            packs.first().map_or(false, |p| p.is_latin_base),
            "the first pack must be the Latin base"
        );
        Self {
            packs,
            en_spell_check: None,
            bg_spell_check: None,
            score_english: None,
            score_bulgarian: None,
            default_language: DetectedLanguage::ENGLISH,
            autocorrect_enabled: false,
            typo_correction_enabled: true,
            user_latin_words: HashSet::new(),
            user_forced_words: HashMap::new(),
            last_word_language: DetectedLanguage::Uncertain,
            recent_languages: Vec::with_capacity(CONTEXT_WINDOW_SIZE),
            recent_confidences: Vec::with_capacity(CONTEXT_WINDOW_SIZE),
            recent_latin_words: Vec::with_capacity(RECENT_WORDS_MAX),
            right_hint: None,
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
        // Kept for the ⌥⌘B shortcut, which pins to the first non-base
        // language. `add_user_forced_word` is the general form.
        let target = (1..self.packs.len()).next().unwrap_or(0);
        self.add_user_forced_word(word, target);
    }

    /// Pin `word` to a specific language for good.
    pub fn add_user_forced_word(&mut self, word: &str, language: usize) {
        let w = word.trim().to_lowercase();
        if !w.is_empty() && language < self.packs.len() {
            self.user_forced_words.insert(w, language);
        }
    }

    /// Forget a previously forced word. Returns true if it was present.
    pub fn remove_user_bg_word(&mut self, word: &str) -> bool {
        self.user_forced_words.remove(&word.trim().to_lowercase()).is_some()
    }

    /// Forget all forced-Bulgarian words.
    pub fn clear_user_bg_words(&mut self) {
        self.user_forced_words.clear();
    }

    pub fn user_bg_word_count(&self) -> usize {
        self.user_forced_words.len()
    }

    pub fn reset_context(&mut self) {
        self.recent_languages.clear();
        self.recent_confidences.clear();
        self.recent_latin_words.clear();
        self.last_word_language = DetectedLanguage::Uncertain;
    }

    /// True when the word immediately to the left was pinned by an exact hit
    /// in exactly ONE dictionary. The caller uses this to decide whether it
    /// needs to wait for the right-hand word at all: when the left side is
    /// this decisive there is nothing a look-ahead could add, so the word can
    /// commit immediately with no visible delay.
    pub fn last_context_is_decisive(&self) -> bool {
        self.last_word_language != DetectedLanguage::Uncertain && self.last_confidence() >= 1.0
    }

    fn snapshot(&self) -> ContextSnapshot {
        ContextSnapshot {
            last_word_language: self.last_word_language,
            recent_languages: self.recent_languages.clone(),
            recent_confidences: self.recent_confidences.clone(),
            recent_latin_words: self.recent_latin_words.clone(),
        }
    }

    fn restore(&mut self, s: ContextSnapshot) {
        self.last_word_language = s.last_word_language;
        self.recent_languages = s.recent_languages;
        self.recent_confidences = s.recent_confidences;
        self.recent_latin_words = s.recent_latin_words;
    }

    /// Decide held-back word(s) using the words on BOTH sides of them.
    ///
    /// The caller holds `pending` (typically ambiguous, with no decisive left
    /// neighbour), then hands it back together with the `next` word the user
    /// went on to type. Ordering matters, so this runs in three steps:
    ///
    ///   1. Classify `next` as a throw-away peek and rewind the context, so
    ///      looking ahead leaves no trace.
    ///   2. Decide `pending` for real, with that peek as a right-hand hint —
    ///      this is the "look left and right" decision.
    ///   3. Decide `next` for real, now that `pending` sits in the context
    ///      where it belongs.
    ///
    /// Returns both results in the order they should be inserted. Step 2 is
    /// also what keeps the context honest: the older code committed the held
    /// word straight to the screen without ever telling the detector about it,
    /// so a held word was invisible to everything that followed.
    ///
    /// `pending` may be SEVERAL words separated by spaces. A message that
    /// opens with two ambiguous words in a row ("move li" — може ли, where
    /// both spellings are also English) gives the first word a neighbour that
    /// cannot vote, so the caller keeps holding and hands the whole run over
    /// once a decisive word finally arrives. Every held word is then decided
    /// against that same right-hand evidence, in the order it was typed. The
    /// returned `converted` is the run joined back with single spaces, and its
    /// language is the first word's — the one the caller held first.
    pub fn resolve_pending(&mut self, pending: &str, next: &str) -> (WordResult, WordResult) {
        let held: Vec<&str> = pending.split(' ').filter(|w| !w.is_empty()).collect();

        let snap = self.snapshot();
        let peek = self.process_word(next);
        self.restore(snap);

        // A peek only steers the decision when it is confident in a language.
        // An Uncertain or low-confidence neighbour (an unknown word, a brand,
        // a number) leaves `pending` to the normal left-hand logic.
        self.right_hint = match peek.language {
            DetectedLanguage::Uncertain => None,
            lang if peek.confidence >= 0.9 => Some(lang),
            _ => None,
        };
        // The hint stays in place for the whole run: one decisive word to the
        // right of all of them is evidence about all of them.
        let decided: Vec<WordResult> = held.iter().map(|w| self.process_word(w)).collect();
        self.right_hint = None;

        let next_result = self.process_word(next);

        let pending_result = match decided.split_first() {
            None => self.process_word(pending),
            Some((first, _)) => WordResult {
                original: pending.to_string(),
                converted: decided
                    .iter()
                    .map(|r| r.converted.as_str())
                    .collect::<Vec<_>>()
                    .join(" "),
                language: first.language,
                confidence: first.confidence,
            },
        };
        (pending_result, next_result)
    }

    /// The `is_latin_word` gate uses the union of every enabled pack's keys,
    /// so a word is "typeable" if any enabled language could have produced it.
    fn is_typeable(&self, word: &str) -> bool {
        !word.is_empty()
            && word.chars().all(|c| {
                c.is_ascii_alphabetic()
                    || self.packs.iter().any(|p| p.has_exclusive_key(&c.to_string()))
            })
    }

    pub fn process_word(&mut self, word: &str) -> WordResult {
        if !self.is_typeable(word) {
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

        // 0b. Words the user forced into a language with ⌥⌘B. The mirror image
        // of the learned-Latin pass-through above: it always converts and
        // always leads the flow, so an out-of-dictionary word can be taught
        // once instead of editing files.
        if let Some(&target) = self.user_forced_words.get(&lower) {
            let converted = self.packs[target].transliterate(word);
            self.push_context(DetectedLanguage::Lang(target), 1.0);
            self.track_latin_word(word);
            return WordResult {
                original: word.to_string(),
                converted,
                language: DetectedLanguage::Lang(target),
                confidence: 1.0,
            };
        }

        // 1. Abbreviation expansion, when the user opted into autocorrect. The
        // base language may expand at any time; another language only while
        // its own flow is running, so "mn" does not become "много" mid-English.
        if self.autocorrect_enabled {
            for (idx, pack) in self.packs.iter().enumerate() {
                if let Some(expanded) = pack.abbreviations.get(&lower) {
                    let in_flow = self.last_word_language == DetectedLanguage::Lang(idx);
                    let base_ok = pack.is_latin_base
                        && !matches!(self.last_word_language, DetectedLanguage::Lang(i) if i != idx);
                    if in_flow || base_ok {
                        let out = expanded.clone();
                        self.push_context(DetectedLanguage::Lang(idx), 1.0);
                        self.track_latin_word(word);
                        return WordResult {
                            original: word.to_string(),
                            converted: out,
                            language: DetectedLanguage::Lang(idx),
                            confidence: 1.0,
                        };
                    }
                }
            }
        }

        // 2. Ask every enabled language the same question: rendered in your
        // script, is this a word you know? This replaces the old pair of
        // is_english / is_bulgarian flags and is what makes N languages work.
        let candidates: Vec<String> =
            self.packs.iter().map(|p| p.transliterate(word)).collect();
        let matches: Vec<usize> = (0..self.packs.len())
            .filter(|&i| self.packs[i].contains(&candidates[i]))
            .collect();

        // A key that only one language uses ("[", "\\", "§") is deliberate:
        // nobody types it mid-English by accident.
        let exclusive: Vec<usize> = (0..self.packs.len())
            .filter(|&i| !self.packs[i].is_latin_base && self.packs[i].has_exclusive_key(word))
            .collect();

        let streak_len = self.consecutive_streak_length();
        let detected: DetectedLanguage;
        let mut output: String;
        let confidence: f64;

        if matches.len() > 1 {
            let r = self.resolve_ambiguous(word, &candidates, &matches);
            detected = r.0;
            output = r.1;
            confidence = r.2;
        } else if matches.len() == 1 {
            let only = matches[0];
            // A short word can ride an established streak in another language
            // ONLY when the flip produces a real word there — otherwise we
            // would be inventing spelling. ("we" must not become "ве".)
            let rider = if lower.chars().count() <= 3 && streak_len >= 3 {
                self.last_word_language
                    .index()
                    .filter(|&i| i != only && self.packs[i].contains(&candidates[i]))
            } else {
                None
            };
            if let Some(i) = rider {
                detected = DetectedLanguage::Lang(i);
                output = candidates[i].clone();
                confidence = 0.6;
            } else {
                detected = DetectedLanguage::Lang(only);
                output = candidates[only].clone();
                confidence = 1.0;
            }
        } else {
            // In NO dictionary. The base language is the default: an unknown
            // word is far more often foreign ("Windows", "dpi") than a
            // mistyped one, so we never guess a transliteration here.
            let r = self.resolve_no_match(word, &candidates, &exclusive, streak_len);
            detected = r.0;
            output = r.1;
            confidence = r.2;
        }

        // 3. Spell correction after detection, for confident matches only.
        if self.autocorrect_enabled && confidence >= 1.0 {
            if let Some(i) = detected.index() {
                let corrected = if self.packs[i].is_latin_base {
                    correct_english(&output, &self.packs[i].dict, self.en_spell_check)
                } else {
                    correct_bulgarian(&output, &self.packs[i].dict, self.bg_spell_check)
                };
                if let Some(c) = corrected {
                    output = c;
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

    /// Pick between languages that ALL recognise the word. Ordered by how
    /// much the evidence is worth: a neighbour we were told about, then the
    /// word to the left when it was decisive, then the recent majority, then
    /// natural-language scoring, then the user's default.
    fn resolve_ambiguous(
        &self,
        word: &str,
        candidates: &[String],
        matches: &[usize],
    ) -> (DetectedLanguage, String, f64) {
        let pick = |i: usize, conf: f64| (DetectedLanguage::Lang(i), candidates[i].clone(), conf);

        // The word to the RIGHT, when the caller looked ahead for us. We only
        // get a hint because the left side was inconclusive, so it leads.
        if let Some(DetectedLanguage::Lang(i)) = self.right_hint {
            if matches.contains(&i) {
                return pick(i, 0.9);
            }
        }

        // The word immediately before, when it was pinned by an exact hit in
        // exactly one dictionary — the strongest signal we record, and fresher
        // than the window. Without this, an English phrase started mid-
        // Bulgarian-text loses every ambiguous word back to the majority.
        if self.last_confidence() >= 1.0 {
            if let Some(i) = self.last_word_language.index() {
                if matches.contains(&i) {
                    return pick(i, 0.9);
                }
            }
        }

        if let Some(i) = self.dominant_recent_language().index() {
            if matches.contains(&i) {
                return pick(i, 0.9);
            }
        }
        if let Some(i) = self.last_word_language.index() {
            if matches.contains(&i) {
                return pick(i, 0.8);
            }
        }

        // Nothing in the context helps — ask the platform's language scorer,
        // giving it the recent words as context rather than the word alone.
        let mut phrase = self.recent_latin_words.clone();
        phrase.push(word.to_string());
        let phrase = phrase.join(" ");
        let mut best: Option<(usize, f64)> = None;
        for &i in matches {
            let rendered = self.packs[i].transliterate(&phrase);
            let score = if self.packs[i].is_latin_base {
                self.score_english.map(|f| f(&rendered)).unwrap_or(0.0)
            } else {
                self.score_bulgarian.map(|f| f(&rendered)).unwrap_or(0.0)
            };
            if best.map_or(true, |(_, b)| score > b) {
                best = Some((i, score));
            }
        }
        if let Some((i, score)) = best {
            // Only trust scoring when it is clearly ahead of the runner-up.
            let runner_up = matches
                .iter()
                .filter(|&&j| j != i)
                .map(|&j| {
                    let rendered = self.packs[j].transliterate(&phrase);
                    if self.packs[j].is_latin_base {
                        self.score_english.map(|f| f(&rendered)).unwrap_or(0.0)
                    } else {
                        self.score_bulgarian.map(|f| f(&rendered)).unwrap_or(0.0)
                    }
                })
                .fold(0.0f64, f64::max);
            if score > runner_up + 0.1 {
                return pick(i, score);
            }
        }

        if let Some(i) = self.default_language.index() {
            if matches.contains(&i) {
                return pick(i, 0.5);
            }
        }
        pick(matches[0], 0.5)
    }

    /// Nothing recognised the word. Decide whether to leave it as typed (the
    /// usual answer) or rescue it into a language.
    fn resolve_no_match(
        &self,
        word: &str,
        candidates: &[String],
        exclusive: &[usize],
        streak_len: usize,
    ) -> (DetectedLanguage, String, f64) {
        // A key only one language uses proves the intent, and outranks even a
        // running streak in another language ("prew\tata" → "превютата").
        let exclusive_lang = exclusive.first().copied();

        if exclusive_lang.is_none()
            && self.last_word_language == DetectedLanguage::ENGLISH
            && streak_len >= 2
        {
            let corrected = if self.autocorrect_enabled {
                correct_english(word, &self.packs[0].dict, self.en_spell_check)
            } else {
                None
            };
            return match corrected {
                Some(c) => (DetectedLanguage::ENGLISH, c, 0.8),
                None => (DetectedLanguage::ENGLISH, word.to_string(), 0.5),
            };
        }

        // A word mid-flow in a transliterating language gets one shot at typo
        // repair, in THAT language.
        if let Some(i) = self.last_word_language.index() {
            if !self.packs[i].is_latin_base {
                if let Some(fixed) = self.try_typo_fix(word, &candidates[i], i) {
                    return (DetectedLanguage::Lang(i), fixed, 0.85);
                }
            }
        }

        if let Some(i) = exclusive_lang {
            let out = if self.autocorrect_enabled {
                correct_bulgarian(&candidates[i], &self.packs[i].dict, self.bg_spell_check)
                    .unwrap_or_else(|| candidates[i].clone())
            } else {
                candidates[i].clone()
            };
            return (DetectedLanguage::Lang(i), out, 0.9);
        }

        // Leave it alone, and stay transparent to the streak so one unknown
        // word neither transliterates nor flips the surrounding flow.
        (DetectedLanguage::Uncertain, word.to_string(), 0.0)
    }

    /// Typo rescue for a word in NO dictionary, against one language.
    /// Guards keep the "unknown words stay as typed" policy intact: only
    /// mid-flow, never for capitalised words (brands), never for short ones.
    fn try_typo_fix(&self, word: &str, candidate: &str, lang: usize) -> Option<String> {
        if !self.typo_correction_enabled {
            return None;
        }
        if word.chars().next().map_or(false, |c| c.is_uppercase()) {
            return None;
        }
        let lowered = candidate.to_lowercase();
        if lowered.chars().count() < 5 {
            return None;
        }
        let pack = &self.packs[lang];
        if let Some(fixed) = best_typo_fix(&lowered, pack) {
            return Some(fixed);
        }
        split_into_two_words(&lowered, &pack.dict)
    }

    /// Confidence of the most recent decided word; 0.0 when nothing has
    /// been decided yet.
    fn last_confidence(&self) -> f64 {
        self.recent_confidences.last().copied().unwrap_or(0.0)
    }

    /// Which language dominates the recent window, counting only
    /// high-confidence decisions. None when there is no clear leader.
    fn dominant_recent_language(&self) -> DetectedLanguage {
        let mut counts = vec![0usize; self.packs.len()];
        for (idx, lang) in self.recent_languages.iter().enumerate() {
            if self.recent_confidences[idx] < 0.9 {
                continue;
            }
            if let Some(i) = lang.index() {
                counts[i] += 1;
            }
        }
        let best = counts.iter().copied().max().unwrap_or(0);
        if best == 0 {
            return DetectedLanguage::Uncertain;
        }
        // A tie is not a majority.
        if counts.iter().filter(|&&c| c == best).count() > 1 {
            return DetectedLanguage::Uncertain;
        }
        let winner = counts.iter().position(|&c| c == best).unwrap();
        DetectedLanguage::Lang(winner)
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
        assert_eq!(result.language, DetectedLanguage::ENGLISH);
        assert_eq!(result.converted, "hello");

        let result = d.process_word("world");
        assert_eq!(result.language, DetectedLanguage::ENGLISH);
    }

    #[test]
    fn bulgarian_sentence_converts() {
        let mut d = LanguageDetector::new(english_dict(), bulgarian_dict());
        let r = d.process_word("napisah");
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
        assert_eq!(r.converted, "написах");

        let r = d.process_word("now");
        // "now" is in EN dict; without context yet it's ambiguous between EN ("now")
        // and BG ("нов"). At this point the previous word was BG, so flow follows BG.
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
        assert_eq!(r.converted, "нов");
    }

    #[test]
    fn abbreviation_expansion_in_english_flow() {
        let mut d = LanguageDetector::new(english_dict(), bulgarian_dict());
        d.autocorrect_enabled = true; // off by default
        let r = d.process_word("u");
        assert_eq!(r.converted, "you");
        assert_eq!(r.language, DetectedLanguage::ENGLISH);
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
            assert_eq!(r.language, DetectedLanguage::BULGARIAN,
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
            assert_eq!(r.language, DetectedLanguage::BULGARIAN,
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
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
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
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
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
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);

        let r = d.process_word("treylyri");
        assert_eq!(r.converted, "трейлъри",
            "treylyri (треълъри) must typo-fix to трейлъри, got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
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
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);

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
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
        assert_eq!(r.converted, "много");
        let r = d.process_word("hubawo");
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
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
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
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
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
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
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);

        let r = d.process_word("na");
        assert_eq!(r.converted, "на");
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);

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
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
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
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
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
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
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
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
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
    fn english_phrase_after_a_bulgarian_sentence_stays_english() {
        // Real user report: after typing a Bulgarian sentence ("…не мога да
        // отговоря на този имейл") the user continued in English with
        // "we will order only" and got back "ве will ордер only".
        //
        // Two separate rules combined to produce it:
        //   • "we" is EN-only, but a short word mid-BG-streak used to flip to
        //     Cyrillic — producing "ве", which is not a word in any language.
        //   • "order" is in BOTH dictionaries ("ордер" is a real BG noun), and
        //     resolve_ambiguous consulted the 6-word majority (still Bulgarian)
        //     before the immediately preceding "will", which was an
        //     unambiguous English hit.
        let en: HashSet<String> = ["we", "will", "order", "only"]
            .iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["не", "мога", "да", "отговоря", "на", "този", "имейл", "ордер"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);

        // Establish a long, high-confidence Bulgarian streak.
        for (latin, cyr) in [
            ("ne", "не"), ("moga", "мога"), ("da", "да"), ("otgoworq", "отговоря"),
            ("na", "на"), ("tozi", "този"), ("imejl", "имейл"),
        ] {
            let r = d.process_word(latin);
            assert_eq!(r.converted, cyr, "setup word {latin:?} should convert");
            assert_eq!(r.language, DetectedLanguage::BULGARIAN);
        }

        // The English phrase must come through verbatim.
        let mut out = Vec::new();
        for word in ["we", "will", "order", "only"] {
            let r = d.process_word(word);
            assert_eq!(r.language, DetectedLanguage::ENGLISH,
                "{word:?} should be English, got {:?}", r.language);
            out.push(r.converted);
        }
        assert_eq!(out.join(" "), "we will order only");
    }

    #[test]
    fn en_only_word_never_flips_to_a_cyrillic_non_word() {
        // Narrow guard for the first half of the bug above: when a word is in
        // the EN dictionary and its transliteration is NOT in the BG one, the
        // BG form is by construction a non-word, so no streak — however long —
        // may flip it. ("we" → "ве")
        let en: HashSet<String> = ["we"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["много", "хубаво", "нали", "това", "е"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        for w in ["towa", "e", "mnogo", "hubawo", "nali"] {
            d.process_word(w);
        }

        let r = d.process_word("we");
        assert_eq!(r.converted, "we",
            "EN-only short word must not flip to the non-word 'ве', got {:?}", r.converted);
        assert_ne!(r.converted, "ве");
        assert_eq!(r.language, DetectedLanguage::ENGLISH);
    }

    #[test]
    fn decisive_previous_word_beats_the_recent_majority() {
        // Second half of the bug, in isolation and in BOTH directions: an
        // ambiguous word (in both dictionaries) follows the language of the
        // word right before it when that word was an exact single-dictionary
        // hit, even while the 6-word window still leans the other way.
        let en: HashSet<String> = ["will", "order", "so"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["ордер", "со", "много", "хубаво", "нали", "това", "е"]
            .iter().map(|s| s.to_string()).collect();

        // BG majority, decisive EN word right before → English.
        let mut d = LanguageDetector::new(en.clone(), bg.clone());
        for w in ["towa", "e", "mnogo", "hubawo", "nali"] {
            d.process_word(w);
        }
        assert_eq!(d.process_word("will").language, DetectedLanguage::ENGLISH);
        let r = d.process_word("order");
        assert_eq!(r.converted, "order",
            "decisive English predecessor must win over the BG majority, got {:?}", r.converted);

        // Mirror: EN majority, decisive BG word right before → Bulgarian.
        let mut d = LanguageDetector::new(en, bg);
        for w in ["will", "will", "will"] {
            d.process_word(w);
        }
        assert_eq!(d.process_word("mnogo").converted, "много");
        let r = d.process_word("order");
        assert_eq!(r.converted, "ордер",
            "decisive Bulgarian predecessor must win over the EN majority, got {:?}", r.converted);
    }

    #[test]
    fn pending_word_is_decided_by_the_word_on_its_right() {
        // "laptop"/"лаптоп" is a real word in both languages, so with nothing
        // decisive on the left the word that FOLLOWS it casts the deciding
        // vote — in both directions.
        let en: HashSet<String> = ["laptop", "is", "broken"]
            .iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["лаптоп", "работи", "добре"]
            .iter().map(|s| s.to_string()).collect();

        // Followed by an English word → stays Latin.
        let mut d = LanguageDetector::new(en.clone(), bg.clone());
        let (p, n) = d.resolve_pending("laptop", "is");
        assert_eq!(p.converted, "laptop",
            "English neighbour should keep it Latin, got {:?}", p.converted);
        assert_eq!(p.language, DetectedLanguage::ENGLISH);
        assert_eq!(n.converted, "is");

        // Followed by a Bulgarian word → converts.
        let mut d = LanguageDetector::new(en, bg);
        let (p, n) = d.resolve_pending("laptop", "raboti");
        assert_eq!(p.converted, "лаптоп",
            "Bulgarian neighbour should convert it, got {:?}", p.converted);
        assert_eq!(p.language, DetectedLanguage::BULGARIAN);
        assert_eq!(n.converted, "работи");
    }

    #[test]
    fn resolved_pending_word_enters_the_context() {
        // Regression: the held word used to be written straight to the screen
        // without ever being fed to the detector, so it was invisible to every
        // word after it. Here "laptop" resolves to Bulgarian via "работи";
        // the NEXT word must then see a Bulgarian context.
        let en: HashSet<String> = ["laptop"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["лаптоп", "работи", "добре"]
            .iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);

        let (p, _) = d.resolve_pending("laptop", "raboti");
        assert_eq!(p.converted, "лаптоп");

        // Two BG words are now in the window, so the streak is real.
        assert_eq!(d.consecutive_streak_length(), 2,
            "both resolved words must be in the context");
        let r = d.process_word("dobre");
        assert_eq!(r.converted, "добре");
        assert_eq!(r.language, DetectedLanguage::BULGARIAN);
    }

    #[test]
    fn look_ahead_peek_leaves_no_trace() {
        // The peek at the right-hand word must be rewound: the next word may
        // only appear ONCE in the context, not twice.
        let en: HashSet<String> = ["laptop"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["лаптоп", "работи"].iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        d.resolve_pending("laptop", "raboti");
        assert_eq!(d.recent_languages.len(), 2,
            "exactly two words were typed; the peek must not leave a third");
        assert_eq!(d.recent_latin_words, vec!["laptop".to_string(), "raboti".to_string()]);
    }

    #[test]
    fn decisive_left_context_needs_no_look_ahead() {
        // The controller only holds a word when the left side is inconclusive.
        // An exact single-dictionary hit makes it conclusive.
        let en: HashSet<String> = ["will", "order"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["ордер", "много"].iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);
        assert!(!d.last_context_is_decisive(), "no context yet is not decisive");

        d.process_word("will"); // EN-only exact hit
        assert!(d.last_context_is_decisive());

        d.process_word("qqqq"); // unknown → Uncertain, context untouched
        assert!(d.last_context_is_decisive(), "a pass-through word leaves the left signal intact");
    }

    #[test]
    fn a_run_of_held_words_is_decided_by_the_first_decisive_one() {
        // "може ли да те помоля" typed phonetically opens with TWO words that
        // are also English ("move" and "li"), so the first word's neighbour
        // cannot vote and one-word look-ahead falls back to English. The
        // caller keeps holding and hands the whole run over once "da" — a
        // Bulgarian-only word — arrives.
        let en: HashSet<String> = ["move", "li", "to"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["може", "ли", "да", "те"].iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);

        let (held, next) = d.resolve_pending("move li", "da");
        assert_eq!(held.converted, "може ли",
            "both held words must follow the decisive word to their right, got {:?}",
            held.converted);
        assert_eq!(held.language, DetectedLanguage::BULGARIAN);
        assert_eq!(next.converted, "да");

        // The run really is in the context now, so what follows keeps flowing.
        assert_eq!(d.process_word("te").converted, "те");
    }

    #[test]
    fn a_held_run_still_follows_an_english_neighbour() {
        // The same mechanism must not become a one-way street into Bulgarian:
        // when the decisive word to the right is English, so is the run.
        let en: HashSet<String> = ["move", "li", "faster"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["може", "ли"].iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);

        let (held, next) = d.resolve_pending("move li", "faster");
        assert_eq!(held.converted, "move li");
        assert_eq!(next.converted, "faster");
    }

    #[test]
    fn uncertain_neighbour_does_not_steer_the_pending_word() {
        // If the word to the right is itself unknown (a brand, a number),
        // it must not vote — the pending word falls back to normal handling
        // and the default language decides.
        let en: HashSet<String> = ["laptop"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["лаптоп"].iter().map(|s| s.to_string()).collect();
        let mut d = LanguageDetector::new(en, bg);

        let (p, n) = d.resolve_pending("laptop", "Zyxwv");
        assert_eq!(n.language, DetectedLanguage::Uncertain,
            "the neighbour really is unknown");
        assert_eq!(p.converted, "laptop",
            "unknown neighbour must not force a conversion, got {:?}", p.converted);
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
    fn a_third_language_works_alongside_the_other_two() {
        // The point of the refactor: nothing in the detector knows how many
        // languages there are. Here English, Bulgarian and a made-up third
        // Cyrillic language are all enabled at once, and each word goes to
        // whichever one recognises it.
        let en: HashSet<String> = ["the", "code", "is"].iter().map(|s| s.to_string()).collect();
        let bg: HashSet<String> = ["много", "хубаво"].iter().map(|s| s.to_string()).collect();
        // A third pack whose alphabet includes ы — a letter Bulgarian lacks.
        let third: HashSet<String> = ["мыло", "было"].iter().map(|s| s.to_string()).collect();
        let ru = crate::lang::LanguagePack::transliterated(
            "ru", "Русский", third,
            &[('m','м'), ('y','ы'), ('l','л'), ('o','о'), ('b','б')],
            "аеиоуыэюя", &[],
        );
        let mut d = LanguageDetector::with_packs(vec![
            crate::packs::english(en),
            crate::packs::bulgarian(bg),
            ru,
        ]);
        assert_eq!(d.packs.len(), 3);

        // English word → English.
        let r = d.process_word("code");
        assert_eq!(r.converted, "code");
        assert_eq!(r.language, DetectedLanguage::ENGLISH);

        // Bulgarian word → Bulgarian (pack 1).
        let r = d.process_word("mnogo");
        assert_eq!(r.converted, "много");
        assert_eq!(r.language, DetectedLanguage::Lang(1));

        // A word only the THIRD language knows → third language, using its own
        // keymap (y→ы, which Bulgarian maps to ъ).
        let r = d.process_word("mylo");
        assert_eq!(r.converted, "мыло",
            "third language must win with its own keymap, got {:?}", r.converted);
        assert_eq!(r.language, DetectedLanguage::Lang(2));
    }

    #[test]
    fn unknown_word_still_stays_latin_with_many_languages() {
        // The "leave it alone" default must survive having more languages to
        // guess with — more packs must not mean more wrong guesses.
        let en: HashSet<String> = HashSet::new();
        let bg: HashSet<String> = ["много", "хубаво"].iter().map(|s| s.to_string()).collect();
        let ru = crate::lang::LanguagePack::transliterated(
            "ru", "Русский",
            ["мыло"].iter().map(|s| s.to_string()).collect(),
            &[('m','м'), ('y','ы'), ('l','л'), ('o','о')],
            "аеиоуы", &[],
        );
        let mut d = LanguageDetector::with_packs(vec![
            crate::packs::english(en), crate::packs::bulgarian(bg), ru,
        ]);
        d.process_word("mnogo");
        d.process_word("hubawo");
        let r = d.process_word("Windows");
        assert_eq!(r.converted, "Windows",
            "unknown word must stay Latin however many languages are enabled");
        assert_eq!(r.language, DetectedLanguage::Uncertain);
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
