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
// Language is an INDEX into the detector's enabled-language list, so this is
// no longer limited to two. 0 is always the Latin base (English) and 1 the
// first added language, which keeps these two names accurate. UNCERTAIN moved
// to -1 because 2 now means "the third language".
#define LANGAUTO_LANG_ENGLISH   0
#define LANGAUTO_LANG_BULGARIAN 1
#define LANGAUTO_LANG_UNCERTAIN (-1)

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

// Build a detector from any number of languages instead of a fixed pair.
// Create it empty, then append languages base-first. `keys`/`letters` are
// parallel arrays of `n` Unicode scalars: pressing keys[i] types letters[i].
// `confuse_a`/`confuse_b` name letter pairs users mix up. Pass an empty keymap
// with is_latin_base=1 for a language written in the Latin alphabet.
// Returns the new language's index, or -1 on invalid input.
LangAutoDetector* langauto_detector_new_empty(void);
int    langauto_detector_add_pack(LangAutoDetector* d,
                                  const char* id,
                                  const char* display_name,
                                  const char* dict_text,
                                  const uint32_t* keys,
                                  const uint32_t* letters,
                                  size_t n,
                                  const char* vowels,
                                  const uint32_t* confuse_a,
                                  const uint32_t* confuse_b,
                                  size_t n_confuse,
                                  int is_latin_base);
size_t langauto_detector_pack_count(LangAutoDetector* d);
char*  langauto_detector_pack_id(LangAutoDetector* d, size_t index);

void langauto_detector_free(LangAutoDetector* d);

// ---------- detector operations ----------
// Returns converted string (caller frees with langauto_string_free).
// Writes detected language (LANGAUTO_LANG_*) and confidence to outputs if non-NULL.
char* langauto_detector_process_word(LangAutoDetector* d,
                                     const char* word,
                                     int* out_lang,
                                     double* out_conf);

// Resolve a word that was held back, using the words on BOTH sides of it.
// Returns the converted `pending` text (caller frees); writes the converted
// `next` text to *out_next (caller frees) plus next's language/confidence.
char* langauto_detector_resolve_pending(LangAutoDetector* d,
                                        const char* pending,
                                        const char* next,
                                        int* out_pending_lang,
                                        char** out_next,
                                        int* out_next_lang,
                                        double* out_next_conf);

// 1 when the word to the left was pinned by an exact hit in exactly one
// dictionary, so holding the current word back would gain nothing.
int  langauto_detector_last_context_is_decisive(LangAutoDetector* d);

void langauto_detector_reset_context(LangAutoDetector* d);
int  langauto_detector_is_first_word(LangAutoDetector* d);

int  langauto_detector_word_in_en_dict(LangAutoDetector* d, const char* word);
int  langauto_detector_word_in_bg_dict(LangAutoDetector* d, const char* cyrillic_word);

void langauto_detector_set_default_language(LangAutoDetector* d, int lang);
int  langauto_detector_get_default_language(LangAutoDetector* d);

// Toggle autocorrect (abbreviation expansion + spell suggestions +
// edit-distance-1 matching). Off by default for new detectors.
void langauto_detector_set_autocorrect_enabled(LangAutoDetector* d, int enabled);
int  langauto_detector_get_autocorrect_enabled(LangAutoDetector* d);

// Toggle Bulgarian typo rescue (adjacent-key substitution, transposition,
// edit-distance-1, missing-space split — for unknown words mid-BG-flow).
// On by default for new detectors.
void langauto_detector_set_typo_correction_enabled(LangAutoDetector* d, int enabled);
int  langauto_detector_get_typo_correction_enabled(LangAutoDetector* d);

// Dictionary entry counts (for diagnostics). Out pointers may be NULL.
void langauto_detector_dict_counts(LangAutoDetector* d, size_t* out_en, size_t* out_bg);

// ---------- learned ("always Latin") words ----------
// Words the user reverted: they pass through verbatim, beating dictionaries
// and autocorrect. Matching is case-insensitive; words are stored lowercase.
void   langauto_detector_add_user_latin_word(LangAutoDetector* d, const char* word);
int    langauto_detector_remove_user_latin_word(LangAutoDetector* d, const char* word);
void   langauto_detector_clear_user_latin_words(LangAutoDetector* d);
size_t langauto_detector_user_latin_word_count(LangAutoDetector* d);

// ---------- forced ("always Bulgarian") words ----------
// Words the user forced via the force-to-Bulgarian hotkey: the lowercase Latin
// spelling always converts to Cyrillic and leads Bulgarian flow — the mirror
// image of the learned-Latin words above. Matching is case-insensitive.
void   langauto_detector_add_user_bg_word(LangAutoDetector* d, const char* word);
int    langauto_detector_remove_user_bg_word(LangAutoDetector* d, const char* word);
void   langauto_detector_clear_user_bg_words(LangAutoDetector* d);
size_t langauto_detector_user_bg_word_count(LangAutoDetector* d);

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
