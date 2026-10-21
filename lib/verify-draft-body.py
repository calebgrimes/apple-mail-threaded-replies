#!/usr/bin/env python3
"""Read the newest Apple Mail draft with a given subject off disk and report the
length of its text/html body, plus a warning if the body is quote-wrapped.

Mail will save an empty compose window without complaint, and `content of msg`
reads back empty for a body that arrived by paste, so neither AppleScript's
return code nor the `content` property proves the text landed. The .emlx on disk
is the only honest witness.

Usage:
    verify-draft-body.py "Subject line"                  -> prints the HTML body length
    verify-draft-body.py "Subject line" --dump           -> prints the HTML body itself
    verify-draft-body.py "Subject line" --needle "text"  -> length, or 0 if "text" is absent

--needle matters for replies: the quoted history alone is long enough to look like
a healthy body, so length by itself would pass a reply whose new text never landed.

Exit 0 always; a length of 0 means "not found or empty", which the caller treats
as failure.
"""

import glob
import json
import quopri
import os
import re
import subprocess
import sys
from html import unescape as html_unescape

MAIL_ROOT = os.path.expanduser("~/Library/Mail")
# Second witness for when the .emlx has not hit disk yet. mail-mcp reads the
# draft out of Mail's live message store via JXA; unlike `content of <outgoing
# message>` (which reads 0 for a pasted body), a saved draft's content reads
# back honestly there. On some days every staging run failed
# verification while the drafts were perfect: Exchange writes the local .emlx
# minutes late, far beyond the caller's poll window, so the disk witness saw
# nothing and three good drafts were condemned per run.
# Optional. Set HMAIL_MAIL_MCP to use another path. If the file is absent, this
# second witness is skipped and the .emlx on disk is the only witness.
MAIL_MCP = os.environ.get("HMAIL_MAIL_MCP", "/opt/homebrew/opt/mail-mcp/bin/mail-mcp")
# Mail's own chrome. Present in every composed message, so it must not count
# toward "the body has content".
BOILERPLATE = re.compile(
    r"<html>|</html>|<head>.*?</head>|<body[^>]*>|</body>|<meta[^>]*>", re.S | re.I
)


def draft_files():
    for path in glob.glob(
        os.path.join(MAIL_ROOT, "V*", "*", "Drafts.mbox", "**", "Messages", "*.emlx"),
        recursive=True,
    ):
        if path.endswith(".partial.emlx"):
            continue
        yield path


def html_part(raw):
    """Return the text/html part of a raw .emlx, decoded, or ''.

    Mail writes the part quoted-printable, so `=` arrives as `=3D` and any line
    over 76 columns is soft-wrapped with a trailing `=`. Both break a plain
    substring search: a needle like "no second set of eyes" failed
    against a perfectly good draft because Mail had wrapped it as "no second =\\n
    set of eyes". Decode here so both the length and the needle see real text.
    """
    idx = raw.find("Content-Type: text/html")
    if idx == -1:
        idx = raw.lower().find("content-type: text/html")
        if idx == -1:
            return ""
    blank = raw.find("\n\n", idx)
    if blank == -1:
        return ""
    # Mail writes Content-Transfer-Encoding ABOVE Content-Type, so the header
    # block starts at this part's MIME boundary, not at the Content-Type line.
    part_start = raw.rfind("--Apple-Mail=", 0, idx)
    headers = raw[part_start if part_start != -1 else max(0, idx - 400) : blank]
    rest = raw[blank + 2 :]
    end = rest.find("\n--Apple-Mail=")
    if end == -1:
        end = rest.find("\n<?xml version")
    body = rest[:end] if end != -1 else rest

    if re.search(r"content-transfer-encoding:\s*quoted-printable", headers, re.I):
        try:
            body = quopri.decodestring(body.encode("utf-8", "replace")).decode(
                "utf-8", "replace"
            )
        except (ValueError, UnicodeError):
            pass  # undecodable: judge the raw text rather than reporting empty
    return body


def _needle_in(content, needle):
    """The same needle logic the disk path uses, against plain text."""
    flat = re.sub(r"\s+", " ", content).strip().lower()
    want = re.sub(r"\s+", " ", needle).strip().lower()
    if not want:
        return True
    if want in flat:
        return True
    # Whitespace-free comparison, for the same reason as the disk path: the
    # renderer may insert spacing the source line never had. Every character
    # must still be present in order.
    return re.sub(r"\s+", "", want) in re.sub(r"\s+", "", flat)


def live_store_length(subject, needle):
    """Length of the newest matching draft in Mail's live store, or 0.

    Only consulted when the disk shows nothing, and only when a needle is
    available. Without a needle this witness cannot be trusted for replies:
    the live content includes the quoted history, which is long enough to pass
    a length check on its own even when the new text never landed. The needle
    ties the verdict to the body we actually meant to stage, which also keeps a
    stale same-subject draft from an earlier day from vouching for this run.

    The Apple-Mail-URLShareWrapperClass fingerprint cannot be checked here
    (plain text, no HTML), but that wrapper only ever comes from the `content`
    property, which the staging scripts never touch; the disk path still checks
    it whenever the .emlx is available.
    """
    if not needle or not os.path.exists(MAIL_MCP):
        return 0
    try:
        proc = subprocess.run(
            [MAIL_MCP, "tool", "list_drafts"],
            capture_output=True, text=True, timeout=60,
        )
        drafts = json.loads(proc.stdout).get("drafts", [])
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError, ValueError):
        return 0

    cands = [d for d in drafts if subject in (d.get("subject") or "")]
    cands.sort(key=lambda d: d.get("date_received") or "")
    for d in reversed(cands):
        length = d.get("content_length") or 0
        if length < 20:
            continue  # a failed paste's empty shell must not vouch for anything
        content = d.get("content_preview") or ""
        if len(content) < length and not _needle_in(content, needle):
            # Preview is truncated; fetch the full body before judging.
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
                content = (
                    json.loads(proc.stdout).get("message", {}).get("content", "")
                )
            except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError, ValueError):
                continue
        if _needle_in(content, needle):
            return length
    return 0


def main():
    if len(sys.argv) < 2:
        print(0)
        return
    subject = sys.argv[1]
    rest = sys.argv[2:]
    dump = "--dump" in rest
    needle = ""
    if "--needle" in rest:
        i = rest.index("--needle")
        if i + 1 < len(rest):
            needle = rest[i + 1]

    best = None
    best_mtime = -1.0
    for path in draft_files():
        try:
            st = os.stat(path)
            if st.st_mtime <= best_mtime:
                continue
            with open(path, encoding="utf-8", errors="replace") as f:
                raw = f.read()
        except OSError:
            continue
        m = re.search(r"^Subject: (.*)$", raw, re.M)
        if not m or subject not in m.group(1):
            continue
        best, best_mtime = raw, st.st_mtime

    if best is None:
        # Nothing on disk yet. On Exchange the .emlx routinely lags the save by
        # minutes, so ask Mail's live store before declaring the body missing.
        print(live_store_length(subject, needle))
        return

    body = html_part(best)
    if dump:
        sys.stdout.write(body)
        return

    stripped = BOILERPLATE.sub("", body).strip()

    # Judge only the text we just wrote, which Mail parks above the quoted
    # history. Everything from the first <blockquote> on is the thread behind us:
    # we did not author it, we cannot fix it, and it must not cast a verdict on
    # this draft. Scoping here also stops the needle from matching its own echo
    # in the quoted copy of an earlier send.
    quote_at = stripped.find("<blockquote")
    new_text = stripped[:quote_at] if quote_at > 0 else stripped

    # Apple-Mail-URLShareWrapperClass is the unambiguous fingerprint of the
    # `content`-property bug: Mail has quote-wrapped our own text, so the message
    # will collapse behind "show history" on the recipient's phone. Report 0 so
    # the caller fails loudly instead of shipping it. Older messages in a thread
    # often carry the fingerprint in their quoted history; that is history, not
    # this draft, and it is why this looks at new_text and not the whole body.
    if "Apple-Mail-URLShareWrapperClass" in new_text:
        print(0)
        return

    if needle:
        # Tags become spaces (not nothing) so adjacent <div>s do not fuse two words
        # into one, and Mail's &nbsp; runs collapse the same way the needle's do.
        flat = re.sub(r"<[^>]+>", " ", new_text).replace("&nbsp;", " ")
        flat = re.sub(r"\s+", " ", html_unescape(flat)).strip().lower()
        want = re.sub(r"\s+", " ", needle).strip().lower()
        if want and want not in flat:
            # Tags become spaces, so a needle that straddles one gains whitespace
            # the source line never had ("Results (https://" against
            # "Results ( https://"). body-needle.py avoids handing us such a
            # phrase, but comparing with whitespace removed keeps an older or
            # hand-passed needle from condemning a draft that is genuinely fine.
            # Every character still has to be present, in order, so a losing
            # clipboard race still fails.
            if re.sub(r"\s+", "", want) not in re.sub(r"\s+", "", flat):
                # The disk file may be a stale draft from an earlier run of the
                # same subject (deleted drafts linger in Drafts.mbox), while the
                # draft we just saved has not reached disk. Let the live store
                # cast the deciding vote before failing.
                print(live_store_length(subject, needle))
                return

    if len(new_text) < 20:
        # Found a file but its body is empty or near-empty: could be a stale
        # shell from a failed earlier attempt, with our real save still in
        # transit to disk. Same deciding vote.
        live = live_store_length(subject, needle)
        if live >= 20:
            print(live)
            return

    print(len(new_text))


if __name__ == "__main__":
    main()
