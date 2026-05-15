#!/usr/bin/env python3
"""Append a new release entry to docs/appcast.xml.

Usage:
    scripts/append_appcast.py <version> <build_number> <zip_path> \\
        <ed_signature> <release_notes_url> [<inline_notes_html_path>]

If <inline_notes_html_path> is provided, its contents are embedded as a
CDATA <description> inside the entry — Sparkle renders this directly in
the update dialog instead of fetching the URL.

Idempotent: if an entry for <version> already exists, it is replaced.
"""

import re
import sys
from email.utils import formatdate
from pathlib import Path

APPCAST = Path(__file__).resolve().parents[1] / "docs" / "appcast.xml"


def build_entry(version, build_number, zip_url, length, ed_sig,
                notes_url, notes_html):
    pub_date = formatdate(localtime=False, usegmt=True)
    # Sparkle 2.x prefers releaseNotesLink over description when both are
    # present (it loads the URL in a webview). To force the inline dialog,
    # only emit the link as a fallback when there's no inline html.
    if notes_html:
        safe = notes_html.replace("]]>", "]]]]><![CDATA[>")
        notes_block = (
            "\n            <description><![CDATA[\n"
            f"{safe}\n"
            "            ]]></description>"
        )
    else:
        notes_block = f"\n            <sparkle:releaseNotesLink>{notes_url}</sparkle:releaseNotesLink>"
    return f"""        <item>
            <title>Version {version}</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{build_number}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>{notes_block}
            <enclosure
                url="{zip_url}"
                length="{length}"
                type="application/octet-stream"
                sparkle:edSignature="{ed_sig}" />
        </item>"""


def main():
    if len(sys.argv) not in (6, 7):
        print(__doc__)
        sys.exit(1)

    version, build_number, zip_path, ed_sig, notes_url = sys.argv[1:6]
    notes_html_path = sys.argv[6] if len(sys.argv) == 7 else None
    notes_html = ""
    if notes_html_path:
        p = Path(notes_html_path)
        if p.is_file():
            notes_html = p.read_text().strip()

    zip_path = Path(zip_path)
    length = zip_path.stat().st_size
    zip_url = (
        f"https://github.com/bulgariamitko/lang-auto-switcher/releases/"
        f"download/v{version}/{zip_path.name}"
    )

    xml = APPCAST.read_text()
    new_entry = build_entry(version, build_number, zip_url, length,
                            ed_sig, notes_url, notes_html)

    # Remove an existing entry for this version, if any (re-run safety).
    pattern = re.compile(
        rf"        <item>\s*\n\s*<title>Version {re.escape(version)}</title>.*?</item>\s*\n",
        re.DOTALL,
    )
    xml = pattern.sub("", xml)

    # Insert the new entry just above </channel>, so newest is on top.
    xml = xml.replace("    </channel>", new_entry + "\n    </channel>")

    APPCAST.write_text(xml)
    inline_note = " (with inline notes)" if notes_html else ""
    print(f"✓ appcast.xml updated for v{version} "
          f"(build {build_number}, {length} bytes){inline_note}")


if __name__ == "__main__":
    main()
