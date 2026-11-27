"""Render untrusted OpenCode prose in wrapping GitHub HTML blocks."""

import re
from opencode_v2_pr import escape_text


def paragraphs(value):
    text = value.replace("\r\n", "\n").replace("\r", "\n")
    # No blank lines inside the HTML block: Markdown images and fences from
    # the model must remain text even after a paragraph or line break.
    return "".join("<p>" + escape_text(p).replace("\n", "<br>") + "</p>"
                   for p in re.split(r"\n\s*\n", text))
