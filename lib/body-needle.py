#!/usr/bin/env python3
"""Pick a proof-of-paste needle from an outgoing mail body.

mail-draft.applescript stages a draft by putting HTML on the clipboard and
pasting it into a compose window. Length alone does not prove the right text
landed: a spreadsheet cell copied mid-run once won the race and a
draft containing a stray cell value verified clean. So the caller passes one distinctive
phrase from the body to verify-draft-body.py, which fails the run if it is absent.

The needle must be a phrase that appears VERBATIM in the rendered HTML, so this
strips only what the renderer itself removes:

  - the leading list marker and indentation
  - markdown emphasis characters (* _ ` #), which become tags, not text

It deliberately does NOT strip brackets or parentheses. Those are ordinary prose
('("checked out," lacking charisma)'), they survive into the HTML, and removing
them produces a phrase that is nowhere in the body, so the needle can never match
and every staging attempt fails. That bug made every staging attempt fail.

Lines carrying a link are skipped, whether markdown (`[text](url)`) or a bare URL.
Neither survives into the rendered text intact: the converter wraps a bare URL in
an <a>, and the verifier turns tags into spaces, so a needle spanning the boundary
gains a space the source line never had. One needle
"Reviewing your results (https://example.com/" was checked against
a body reading "Reviewing your results ( https://..." and failed, so three
good drafts were built, verified as empty, and deleted.

Usage:
    body-needle.py BODY_FILE   -> prints up to 60 chars of the longest plain line
"""

import re
import sys

MAX = 60
LEADING = re.compile(r"^[\s>*•+-]+")
EMPHASIS = re.compile(r"[*_`#]")
LINK = re.compile(r"https?://|www\.", re.I)


def needle(text: str) -> str:
    best = ""
    for line in text.splitlines():
        candidate = LEADING.sub("", line).strip()
        if "](" in candidate or LINK.search(candidate):
            continue
        candidate = EMPHASIS.sub("", candidate).strip()
        if len(candidate) > len(best):
            best = candidate
    return best[:MAX].strip()


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: body-needle.py BODY_FILE", file=sys.stderr)
        return 1
    try:
        with open(sys.argv[1], encoding="utf-8", errors="ignore") as fh:
            print(needle(fh.read()))
    except OSError:
        print("")  # no needle is better than a failed staging run
    return 0


if __name__ == "__main__":
    sys.exit(main())
