"""Make mentions inert without changing Markdown code or URLs."""

import re
import sys
from html import escape
from html.parser import HTMLParser
from pathlib import Path


class ReplyHTML(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
        self.literal_depth = 0
        self.mention_link = False
        self.changed = False

    def handle_starttag(self, tag, attrs):
        if tag in {"code", "pre"}:
            self.literal_depth += 1
        if tag == "a":
            classes = (dict(attrs).get("class") or "").split()
            self.mention_link = bool({"user-mention", "team-mention"}.intersection(classes))
            self.changed |= self.mention_link
            if self.mention_link:
                return
        self.parts.append(self.get_starttag_text())

    def handle_endtag(self, tag):
        if tag in {"code", "pre"}:
            self.literal_depth -= 1
        if tag == "a" and self.mention_link:
            self.mention_link = False
            return
        self.parts.append(f"</{tag}>")

    def handle_startendtag(self, tag, attrs):
        self.parts.append(self.get_starttag_text())

    def handle_data(self, data):
        if not self.literal_depth:
            # GitHub has already decoded entities. Break handles even when
            # the reply names a team or user the preview cannot resolve.
            neutral = re.sub(r"(?<![A-Za-z0-9_])@(?=[A-Za-z0-9]|$)", "@\u200b", data)
            self.changed |= neutral != data
            data = neutral
        self.parts.append(escape(data, quote=False))


def literal_reply(markdown, reason):
    # A fence longer than any run in the 16 KB source keeps the entire
    # fallback literal, including mentions, and fits within the body limit.
    fence = "~" * max(3, 1 + max(map(len, re.findall(r"~+", markdown)), default=0))
    return f"{reason}; showing the original text.\n\n{fence}\n{markdown}\n{fence}\n"


def reply_body(markdown, rendered):
    if not rendered.strip():
        return literal_reply(markdown, "GitHub's Markdown preview was unavailable")

    parser = ReplyHTML()
    parser.feed(rendered)
    parser.close()
    if not parser.changed:
        return markdown
    # One HTML block prevents Markdown from being parsed again after a blank
    # line. Entities preserve line breaks, including blank lines inside code.
    fragment = "".join(parser.parts).replace("\n", "&#10;")
    body = f"<div>{fragment}</div>\n"
    if len(body.encode("utf-8")) <= 64_000:
        return body

    return literal_reply(markdown, "Formatted reply exceeded GitHub's comment limit")


if __name__ == "__main__":
    source, preview = (Path(path).read_bytes().decode("utf-8") for path in sys.argv[1:])
    sys.stdout.write(reply_body(source, preview))
