"""Make mentions inert without changing Markdown code or URLs."""

import json
import re
import subprocess
import sys
from html import escape
from html.parser import HTMLParser
from itertools import count
from pathlib import Path
from secrets import token_hex


LITERAL_TAGS = {"a", "code", "pre"}
AT_SIGN = re.compile(r"@|&#0*64(?:;|(?![0-9]))|&#[xX]0*40(?:;|(?![0-9A-Fa-f]))|&commat;")


class ReplyHTML(HTMLParser):
    def __init__(self, rendered):
        super().__init__()
        self.parts = []
        self.prose = []
        self.literal_depth = 0
        self.mention_link = False
        self.changed = False
        self.feed(rendered)
        self.close()

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            classes = (dict(attrs).get("class") or "").split()
            self.mention_link = bool({"user-mention", "team-mention"}.intersection(classes))
            self.changed |= self.mention_link
            if self.mention_link:
                return
        if tag in LITERAL_TAGS:
            self.literal_depth += 1
        self.parts.append(self.get_starttag_text())

    def handle_endtag(self, tag):
        if tag == "a" and self.mention_link:
            self.mention_link = False
            return
        if tag in LITERAL_TAGS:
            self.literal_depth -= 1
        self.parts.append(f"</{tag}>")

    def handle_startendtag(self, tag, attrs):
        self.parts.append(self.get_starttag_text())

    def handle_data(self, data):
        if not self.literal_depth:
            self.prose.append(data)
            # GitHub has already decoded entities. Break handles even when
            # the reply names a team or user the preview cannot resolve.
            neutral = re.sub(r"(?<![A-Za-z0-9_])@(?=[A-Za-z0-9])", "@\u200b", data)
            self.changed |= neutral != data
            data = neutral
        self.parts.append(escape(data, quote=False))


def literal_reply(markdown, reason):
    # A fence longer than any run in the 16 KB source keeps the entire
    # fallback literal, including mentions, and fits within the body limit.
    fence = "~" * max(3, 1 + max(map(len, re.findall(r"~+", markdown)), default=0))
    return f"{reason}; showing the original text.\n\n{fence}\n{markdown}\n{fence}\n"


def reply_body(markdown, render):
    rendered = render(markdown)
    if not rendered.strip():
        return literal_reply(markdown, "GitHub's Markdown preview was unavailable")

    expected = ReplyHTML(rendered)
    if not expected.changed:
        return markdown

    # Tag each source @ in a throwaway preview so GitHub identifies whether
    # each occurrence belongs to code, a link, or mention-capable prose.
    token = f"Zc{token_hex(4)}Q"
    indices = count()
    annotated = AT_SIGN.sub(lambda match: f"{match[0]}{token}{next(indices)}Z", markdown)
    rendered = render(annotated)
    if not rendered.strip():
        return literal_reply(markdown, "GitHub's Markdown preview was unavailable")

    annotated_preview = ReplyHTML(rendered)
    tag = re.compile(rf"(?<![A-Za-z0-9_])@{token}([0-9]+)Z(?=[A-Za-z0-9])")
    prose_indices = {int(index) for text in annotated_preview.prose for index in tag.findall(text)}
    indices = count()
    candidate = AT_SIGN.sub(
        lambda match: match[0] + ("\u200b" if next(indices) in prose_indices else ""), markdown
    )

    # The annotation may itself influence parsing. Confirm the edited source
    # renders exactly like the original except for the neutralized mentions.
    verified = ReplyHTML(render(candidate))
    if not verified.changed and "".join(verified.parts) == "".join(expected.parts):
        return candidate
    return literal_reply(markdown, "Could not verify mention handling in the formatted reply")


def github_preview(repository, markdown):
    request = json.dumps({"mode": "gfm", "context": repository, "text": markdown})
    try:
        result = subprocess.run(
            ["gh", "api", "--method", "POST", "markdown", "--input", "-"],
            input=request,
            encoding="utf-8",
            stdout=subprocess.PIPE,
            check=False,
            timeout=20,
        )
    except subprocess.TimeoutExpired:
        return ""
    return result.stdout if result.returncode == 0 else ""


if __name__ == "__main__":
    repository, path = sys.argv[1:]
    source = Path(path).read_bytes().decode("utf-8")
    sys.stdout.write(reply_body(source, lambda text: github_preview(repository, text)))
