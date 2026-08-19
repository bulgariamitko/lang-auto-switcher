//! LangAutoSwitcher core: pure logic shared across macOS / Linux / Windows.
//!
//! Modules:
//! - `phonetic`:   Latin <-> Cyrillic char mapping, isLatinWord, containsCyrillic
//! - `autocorrect`: abbreviation expansion + edit-distance-1 dictionary correction
//! - `detector`:   the language-detection flow (streaks, dictionary lookups, resolveAmbiguous, etc.)
//! - `ffi`:        C ABI wrappers for Swift / C++ / Python callers
//!
//! Apple-only features (NLLanguageRecognizer, NSSpellChecker) are exposed as
//! function-pointer callbacks the platform shim sets at startup. On Linux/Windows
//! the shim can install no-op callbacks and the detector degrades gracefully.

pub mod lang;
pub mod packs;
pub mod phonetic;
pub mod autocorrect;
pub mod detector;
pub mod ffi;

pub use detector::{DetectedLanguage, LanguageDetector, WordResult};
pub use lang::LanguagePack;
