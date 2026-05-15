// langauto_core.h
// C ABI for the LangAutoSwitcher cross-platform core.
// See langauto-core/src/ffi.rs for the canonical doc comments.

#ifndef LANGAUTO_CORE_H
#define LANGAUTO_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- language enum ----------
#define LANGAUTO_LANG_ENGLISH   0
#define LANGAUTO_LANG_BULGARIAN 1
#define LANGAUTO_LANG_UNCERTAIN 2

// ---------- opaque detector handle ----------
typedef struct LangAutoDetector LangAutoDetector;

// ---------- callbacks (set by platform shim) ----------
//
// Spell check: writes correction (null-terminated UTF-8) into out_buf if found.
// Returns 1 if a correction was written, 0 otherwise.
typedef int (*LangAutoSpellCheckFn)(const char* word, char* out_buf, size_t out_buf_size);

// Language score: returns confidence in [0.0, 1.0] for the given text.
typedef double (*LangAutoScoreFn)(const char* text);

// ---------- memory management ----------
// Strings returned by this library MUST be freed with this function.
void langauto_string_free(char* s);

// ---------- phonetic free functions ----------
char* langauto_to_cyrillic(const char* text);
int   langauto_is_latin_word(const char* text);
int   langauto_contains_cyrillic(const char* text);

// ---------- user keymap overrides ----------
// `latin` and `cyrillic` are unicode scalar values. Override map is
// process-wide; affects `langauto_to_cyrillic` and the detector's
// internal Cyrillic comparisons.
void langauto_set_char_override(uint32_t latin, uint32_t cyrillic);
void langauto_clear_char_overrides(void);

// ---------- detector lifecycle ----------
// Both dictionaries are passed as newline-separated UTF-8 text.
// Returns NULL on invalid input.
LangAutoDetector* langauto_detector_new(const char* en_dict_text,
                                        const char* bg_dict_text);
void langauto_detector_free(LangAutoDetector* d);

// ---------- detector operations ----------
// Returns converted string (caller frees with langauto_string_free).
// Writes detected language (LANGAUTO_LANG_*) and confidence to outputs if non-NULL.
char* langauto_detector_process_word(LangAutoDetector* d,
                                     const char* word,
                                     int* out_lang,
                                     double* out_conf);

void langauto_detector_reset_context(LangAutoDetector* d);
int  langauto_detector_is_first_word(LangAutoDetector* d);

int  langauto_detector_word_in_en_dict(LangAutoDetector* d, const char* word);
int  langauto_detector_word_in_bg_dict(LangAutoDetector* d, const char* cyrillic_word);

void langauto_detector_set_default_language(LangAutoDetector* d, int lang);
int  langauto_detector_get_default_language(LangAutoDetector* d);

// ---------- callback registration ----------
// Pass NULL to clear an installed callback.
void langauto_detector_set_en_spell_check(LangAutoDetector* d, LangAutoSpellCheckFn cb);
void langauto_detector_set_bg_spell_check(LangAutoDetector* d, LangAutoSpellCheckFn cb);
void langauto_detector_set_en_score(LangAutoDetector* d, LangAutoScoreFn cb);
void langauto_detector_set_bg_score(LangAutoDetector* d, LangAutoScoreFn cb);

#ifdef __cplusplus
}
#endif

#endif // LANGAUTO_CORE_H
