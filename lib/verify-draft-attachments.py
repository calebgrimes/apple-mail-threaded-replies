#!/usr/bin/env python3
"""Prove that attachments actually landed on an Apple Mail draft.

AppleScript's `count of mail attachments` reads 0 on a saved draft even when the
files are present, and mail-draft.applescript's body verifier only looks at the
text/html part. So a run could attach nothing, verify the body, and report
success. That happened with a PDF whose path contained spaces:
Finder's Go To Folder autocomplete mangled the typed path, the file never
attached, and the draft reported clean.

Size is the honest, format-agnostic witness. Mail base64-encodes attachments
(~1.37x), so a draft carrying them cannot be smaller than the payload itself.
Filename matching is not reliable: Mail may RFC 2231 split or encode the
`filename*=` parameter.

Usage:
    verify-draft-attachments.py "Subject line" FILE [FILE ...]

Prints "ok <emlx_bytes> >= <expected_bytes>" and exits 0 when the draft is large
enough to hold the payload; prints a reason and exits 1 otherwise.
"""

import glob
import json
import os
import re
import subprocess
import sys

MAIL_ROOT = os.path.expanduser("~/Library/Mail")
# Second witness, same rationale as verify-draft-body.py: on Exchange the
# .emlx can land minutes after the save, so "no draft found on disk" is often
# a lag, not a missing draft. Mail's live store answers immediately and lists
# a saved draft's attachments by their real (un-RFC-2231-mangled) names.
# Optional. Set HMAIL_MAIL_MCP to use another path. If the file is absent, this
# second witness is skipped and the .emlx on disk is the only witness.
MAIL_MCP = os.environ.get("HMAIL_MAIL_MCP", "/opt/homebrew/opt/mail-mcp/bin/mail-mcp")
# Base64 costs 4 bytes per 3. Allow slack for the newline-wrapped encoding and
# MIME headers on one side, and for Mail recompressing an image on the other.
MIN_RATIO = 1.0


def newest_draft(subject):
    hits = []
    pattern = os.path.join(MAIL_ROOT, "V*", "*", "Drafts.mbox", "**", "Messages", "*.emlx")
    for path in glob.glob(pattern, recursive=True):
        if path.endswith(".partial.emlx"):
            continue
        try:
            raw = open(path, errors="replace").read(8192)
        except OSError:
            continue
        found = re.search(r"^Subject: (.*)$", raw, re.M)
        if found and found.group(1).strip() == subject.strip():
            hits.append(path)
    if not hits:
        return None
    return max(hits, key=os.path.getmtime)


def live_store_has(subject, files):
    """True if the newest matching draft in Mail's live store carries every
    expected file, matched by basename. Deciding vote when the disk witness is
    absent or stale, never a substitute when the disk check passes."""
    if not os.path.exists(MAIL_MCP):
        return False
    try:
        proc = subprocess.run(
            [MAIL_MCP, "tool", "list_drafts"],
            capture_output=True, text=True, timeout=60,
        )
        drafts = json.loads(proc.stdout).get("drafts", [])
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return False
    cands = [d for d in drafts if (d.get("subject") or "").strip() == subject.strip()]
    cands.sort(key=lambda d: d.get("date_received") or "")
    if not cands:
        return False
    d = cands[-1]
    try:
        proc = subprocess.run(
            [
                MAIL_MCP, "tool", "get_message_content",
                "--message-id", str(d.get("draft_id")),
                "--mailbox-path", d.get("mailbox") or "Drafts",
                "--account", d.get("account") or "",
            ],
            capture_output=True, text=True, timeout=60,
        )
        msg = json.loads(proc.stdout).get("message", {})
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return False
    names = {(a.get("name") or "").lower() for a in (msg.get("attachments") or [])}
    return all(os.path.basename(f).lower() in names for f in files)


def main():
    if len(sys.argv) < 3:
        print("usage: verify-draft-attachments.py SUBJECT FILE [FILE ...]", file=sys.stderr)
        return 2

    subject = sys.argv[1]
    files = sys.argv[2:]

    expected = 0
    for f in files:
        if not os.path.isfile(f):
            print("attachment source missing: " + f)
            return 1
        expected += os.path.getsize(f)

    path = newest_draft(subject)
    if path is None:
        if live_store_has(subject, files):
            print("ok (live store: all %d attachment(s) present; .emlx not on disk yet)"
                  % len(files))
            return 0
        print("no draft found on disk for subject: " + subject)
        return 1

    actual = os.path.getsize(path)
    floor = int(expected * MIN_RATIO)
    if actual < floor:
        # The disk file may be a stale same-subject draft (batch drafts can share
        # subjects across recipients on the same day) while the real save is still
        # in transit. Deciding vote goes to the live store before failing.
        if live_store_has(subject, files):
            print("ok (live store confirms attachments; disk copy stale or lagging)")
            return 0
        print(
            "draft is %d bytes, too small to hold %d bytes of attachments "
            "(need at least %d) -> nothing attached" % (actual, expected, floor)
        )
        return 1

    # Size alone is not enough. Base64 inflates by ~1.37x, so ONE large file can
    # push the draft past a floor computed from several files and mask a missing
    # small one. That happened once: a small .xlsx silently did not
    # attach beside a larger .pdf and this check reported ok.
    # Counting the attachment parts is format-agnostic and does not depend on
    # filename encoding, which RFC 2231 can split or escape.
    try:
        raw = open(path, errors="replace").read()
    except OSError as exc:
        print("could not re-read the draft: %s" % exc)
        return 1
    parts = len(re.findall(r"^Content-Disposition:\s*(?:attachment|inline)", raw, re.M | re.I))
    if parts < len(files):
        if live_store_has(subject, files):
            print("ok (live store confirms attachments; disk copy stale or lagging)")
            return 0
        print(
            "draft carries %d attachment part(s), expected %d -> %d file(s) did not attach"
            % (parts, len(files), len(files) - parts)
        )
        return 1

    print("ok %d >= %d, %d attachment part(s)" % (actual, floor, parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
