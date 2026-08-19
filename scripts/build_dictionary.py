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

SCRIPTS = {
    "cyrillic": lambda c: "CYRILLIC" in unicodedata.name(c, ""),
    "latin":    lambda c: "LATIN" in unicodedata.name(c, ""),
    "greek":    lambda c: "GREEK" in unicodedata.name(c, ""),
}


def build(src_path, out_path, script):
    in_script = SCRIPTS[script]
    seen = set()
    kept = dropped = 0
    with open(src_path, encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            word = line.strip().lower()
            if not word:
                continue
            # One token only, no digits, no punctuation, nothing from another
            # alphabet. Length 2..30 drops single letters and OCR runs.
            if not (2 <= len(word) <= 30) or not all(in_script(c) for c in word):
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
    print(f"{out_path}: kept {kept:,} of {total:,} ({100*kept/total:.0f}%), dropped {dropped:,}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    script = "cyrillic"
    if "--script" in sys.argv:
        script = sys.argv[sys.argv.index("--script") + 1]
    build(sys.argv[1], sys.argv[2], script)
