#!/usr/bin/env python3
"""Convert a plain-text / light-markdown email body into Apple Mail compose HTML.

Why this exists
---------------
Apple Mail 16 (macOS 15.4) wraps ANY body supplied through the AppleScript
`content` property in `<blockquote type="cite">` inside an
`Apple-Mail-URLShareWrapperClass` div, and emits a `>`-prefixed text/plain
alternative. Gmail and iOS Mail read `blockquote type="cite"` as quoted history,
so the recipient sees a nearly empty message with a "show trimmed content" /
"show history" control hiding the actual body. Verified on new messages and
replies alike, on both construction paths, and in already-sent mail.

The only reliable escape is to paste real HTML into the compose window's body,
which is what `mail-draft.applescript` does. This module produces that HTML
and hands back a hex blob suitable for AppleScript's
`set the clipboard to «data HTML...»`.

Usage:
    text-to-mail-html.py BODY_FILE            -> prints hex of the HTML
    text-to-mail-html.py BODY_FILE --html     -> prints the HTML itself
    text-to-mail-html.py BODY_FILE --pre-html -> BODY_FILE already holds HTML
"""

import binascii
import html
import re
import sys

# Bare URLs and email addresses we turn into real anchors, so the message keeps
# working links the way a hand-typed Mail message does.
URL_RE = re.compile(r"""(?<![">])\bhttps?://[^\s<>"')\]]+""")
EMAIL_RE = re.compile(r"(?<![\w.@-])[\w.+-]+@[\w-]+\.[\w.-]+\b")


def _inline(text):
    """Escape a line, then apply inline markdown and autolinking."""
    out = html.escape(text, quote=False)

    # **bold** and *italic* / _italic_
    out = re.sub(r"\*\*(?=\S)(.+?)(?<=\S)\*\*", r"<b>\1</b>", out)
    out = re.sub(r"(?<![\w*])\*(?=\S)([^*]+?)(?<=\S)\*(?![\w*])", r"<i>\1</i>", out)
    out = re.sub(r"(?<![\w_])_(?=\S)([^_]+?)(?<=\S)_(?![\w_])", r"<i>\1</i>", out)

    # [label](url) before bare-URL autolinking, so we do not double-wrap.
    out = re.sub(
        r"\[([^\]]+)\]\((https?://[^\s)]+)\)",
        lambda m: '<a href="%s">%s</a>' % (m.group(2), m.group(1)),
        out,
    )

    # Bare URLs, skipping anything already inside an href.
    def link_url(m):
        url = m.group(0)
        trail = ""
        while url and url[-1] in ".,;:!?":
            trail = url[-1] + trail
            url = url[:-1]
        return '<a href="%s">%s</a>%s' % (url, url, trail)

    parts = re.split(r'(<a href="[^"]*">.*?</a>)', out)
    out = "".join(p if p.startswith("<a href=") else URL_RE.sub(link_url, p) for p in parts)

    parts = re.split(r'(<a href="[^"]*">.*?</a>)', out)
    out = "".join(
        p
        if p.startswith("<a href=")
        else EMAIL_RE.sub(lambda m: '<a href="mailto:%s">%s</a>' % (m.group(0), m.group(0)), p)
        for p in parts
    )
    return out


def _render_bullets(items, start=0, depth=0):
    """Render (depth, html) pairs as nested <ul class="MailOutline"> markup.

    A deeper item is nested INSIDE its parent <li>, which is what Mail writes for
    a list indented by hand and what every mail client renders correctly. A first
    item deeper than its list (no parent to hang from) is pulled up to this level
    rather than dropped.
    """
    html = ['<ul class="MailOutline">']
    i = start
    while i < len(items):
        item_depth, text = items[i]
        if item_depth < depth:
            break
        if item_depth > depth and html[-1].endswith("</li>"):
            # Hang the deeper run inside the <li> just emitted.
            child, i = _render_bullets(items, i, item_depth)
            html[-1] = html[-1][: -len("</li>")] + child + "</li>"
            continue
        html.append("<li>%s</li>" % text)
        i += 1
    html.append("</ul>")
    return "".join(html), i


def text_to_html(text):
    """Plain text / light markdown -> the div-per-line HTML Mail composes natively.

    Mail's own editor emits one <div> per visual line and <div><br></div> for a
    blank line. Matching that shape means the draft is indistinguishable from one
    you typed, so Mail generates a correct text/plain alternative on send.
    """
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    # Trim leading/trailing blank lines; Mail adds its own spacing.
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()

    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Bullet list: consecutive -/*/• lines become one <ul class="MailOutline">,
        # the same markup Mail writes for a list typed by hand. Leading whitespace
        # nests the item one level per 2 spaces (a tab counts as 4), because
        # notes often hang detail under a parent bullet.
        if re.match(r"^[-*•]\s+\S", stripped):
            items = []
            while i < len(lines) and re.match(r"^[-*•]\s+\S", lines[i].strip()):
                raw = lines[i].replace("\t", "    ")
                depth = (len(raw) - len(raw.lstrip(" "))) // 2
                items.append((depth, _inline(re.sub(r"^[-*•]\s+", "", raw.strip()))))
                i += 1
            out.append(_render_bullets(items)[0])
            continue

        # Numbered list.
        if re.match(r"^\d+[.)]\s+\S", stripped):
            items = []
            while i < len(lines) and re.match(r"^\d+[.)]\s+\S", lines[i].strip()):
                items.append(_inline(re.sub(r"^\d+[.)]\s+", "", lines[i].strip())))
                i += 1
            out.append(
                '<ol class="MailOutline">' + "".join("<li>%s</li>" % it for it in items) + "</ol>"
            )
            continue

        if not stripped:
            out.append("<div><br></div>")
        else:
            # Markdown headings lose the hashes and keep the emphasis.
            m = re.match(r"^#{1,6}\s+(.*)$", stripped)
            if m:
                out.append("<div><b>%s</b></div>" % _inline(m.group(1)))
            else:
                out.append("<div>%s</div>" % _inline(line))
        i += 1

    return "".join(out) if out else "<div><br></div>"


def main():
    args = [a for a in sys.argv[1:]]
    if not args:
        sys.exit("usage: text-to-mail-html.py BODY_FILE [--html|--pre-html]")

    body_file = args[0]
    flags = set(args[1:])

    with open(body_file, encoding="utf-8") as f:
        raw = f.read()

    doc = raw if "--pre-html" in flags else text_to_html(raw)

    if "--html" in flags:
        sys.stdout.write(doc)
    else:
        sys.stdout.write(binascii.hexlify(doc.encode("utf-8")).decode("ascii"))


if __name__ == "__main__":
    main()
