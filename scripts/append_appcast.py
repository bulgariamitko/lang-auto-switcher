#!/usr/bin/env python3
"""Append a new release entry to docs/appcast.xml.

Usage:
    scripts/append_appcast.py <version> <build_number> <zip_path> \\
        <ed_signature> <release_notes_url>

Idempotent: if an entry for <version> already exists, replaces it.
"""

import os
import re
import sys
from email.utils import formatdate
from pathlib import Path

APPCAST = Path(__file__).resolve().parents[1] / "docs" / "appcast.xml"


def build_entry(version, build_number, zip_url, length, ed_sig, notes_url):
    pub_date = formatdate(localtime=False, usegmt=True)
    return f"""        <item>
            <title>Version {version}</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{build_number}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink>{notes_url}</sparkle:releaseNotesLink>
            <enclosure
                url="{zip_url}"
                length="{length}"
                type="application/octet-stream"
                sparkle:edSignature="{ed_sig}" />
        </item>"""


def main():
    if len(sys.argv) != 6:
        print(__doc__)
        sys.exit(1)

    version, build_number, zip_path, ed_sig, notes_url = sys.argv[1:]
    zip_path = Path(zip_path)
    length = zip_path.stat().st_size
    zip_url = (
        f"https://github.com/bulgariamitko/lang-auto-switcher/releases/"
        f"download/v{version}/{zip_path.name}"
    )

    xml = APPCAST.read_text()
    new_entry = build_entry(version, build_number, zip_url, length, ed_sig, notes_url)

    # Remove an existing entry for this version, if any (re-run safety).
    pattern = re.compile(
        rf"        <item>\s*\n\s*<title>Version {re.escape(version)}</title>.*?</item>\s*\n",
        re.DOTALL,
    )
    xml = pattern.sub("", xml)

    # Insert the new entry just above </channel>, so newest is on top.
    xml = xml.replace("    </channel>", new_entry + "\n    </channel>")

    APPCAST.write_text(xml)
    print(f"✓ appcast.xml updated for v{version} (build {build_number}, {length} bytes)")


if __name__ == "__main__":
    main()
