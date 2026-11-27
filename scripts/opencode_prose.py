"""Render untrusted OpenCode prose in wrapping GitHub HTML blocks."""

import html
import re


def escape_text(value):
    # GitHub resolves mentions after decoding HTML entities; separate the
    # name from the @ so rendering cannot notify a user or team.
    escaped = html.escape(value, quote=False).replace("@", "@\u200b")
    return re.sub(r"#(?=[0-9])", "#\u200b", escaped).replace("`", "&#96;")


def paragraphs(value):
    text = value.replace("\r\n", "\n").replace("\r", "\n")
    # No blank lines inside the HTML block: Markdown images and fences from
    # the model must remain text even after a paragraph or line break.
    return "".join("<p>" + escape_text(p).replace("\n", "<br>") + "</p>"
                   for p in re.split(r"\n\s*\n", text))
