#!/usr/bin/env python3
"""Build a LangAutoSwitcher dictionary from Tesseract's language data.

    scripts/build_dictionary.py <tesseract-lang> <output.txt> [--script cyrillic|latin|greek]

Tesseract's word lists are frequency-ranked and harvested from web text, which
makes them excellent at modern vocabulary and full of junk: about a third of
the Bulgarian list is punctuation, abbreviations with trailing dots, OCR
artefacts like "|--" and stray Latin inside Cyrillic text. None of that
belongs in a dictionary the detector trusts, because every junk entry is a
chance to "recognise" a word that is not a word.

So we keep only entries that are entirely letters of the target script.
"""
import re
import sys
import unicodedata

# Short words are only trusted when they are common; see the filter below.
SHORT_LEN = 3
SHORT_MAX_RANK = 20_000

SCRIPTS = {
    "cyrillic": lambda c: "CYRILLIC" in unicodedata.name(c, ""),
    "latin":    lambda c: "LATIN" in unicodedata.name(c, ""),
    "greek":    lambda c: "GREEK" in unicodedata.name(c, ""),
}


def build(src_path, out_path, script):
    in_script = SCRIPTS[script]
    seen = set()
    kept = dropped = short_dropped = 0
    with open(src_path, encoding="utf-8", errors="ignore") as fh:
        for rank, line in enumerate(fh):
            word = line.strip().lower()
            if not word:
                continue
            # One token only, no digits, no punctuation, nothing from another
            # alphabet. Single letters are kept — "и", "в", "с" are real words
            # — because the frequency rule below is what actually separates
            # them from debris.
            if not (1 <= len(word) <= 30) or not all(in_script(c) for c in word):
                dropped += 1
                continue
            # A short word must also be COMMON. The source is frequency
            # ordered, and short entries in its tail are overwhelmingly OCR
            # debris: real Russian short words ("и", "в", "на", "не") all rank
            # inside the first few thousand, while 7,000 more sit past rank
            # 50,000 ("фху", "кд", "уц"). Those matter far more than their
            # number suggests, because short words are what collide between
            # languages — "ше" at rank 122,399 was enough to turn the English
            # "we" into Russian.
            if len(word) <= SHORT_LEN and rank > SHORT_MAX_RANK:
                short_dropped += 1
                dropped += 1
                continue
            if word in seen:
                continue
            seen.add(word)
            kept += 1
    with open(out_path, "w", encoding="utf-8") as out:
        for word in sorted(seen):
            out.write(word + "\n")
    total = kept + dropped
    print(f"{out_path}: kept {kept:,} of {total:,} ({100*kept/total:.0f}%), "
          f"dropped {dropped:,} ({short_dropped:,} of them rare short words)")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    script = "cyrillic"
    if "--script" in sys.argv:
        script = sys.argv[sys.argv.index("--script") + 1]
    build(sys.argv[1], sys.argv[2], script)
