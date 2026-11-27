"""Opt-in GitHub GFM check; sends only a fixed, synthetic comment to /markdown."""

from html.parser import HTMLParser
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from opencode_prose import paragraphs


class RenderingTest(unittest.TestCase):
    @unittest.skipUnless(os.getenv("OPENCODE_TEST_GITHUB_RENDER") == "1", "requires authenticated gh")
    def test_wrapping_prose_with_inert_model_markup(self):
        text = "See #991 or OpenStaticFish/ZigCraft#991, @someone and https://example.org.\n\n"
        text += "    ```html\n<img src=x> ![image](https://example.org/image.png)\n```"
        payload = {"mode": "gfm", "context": "OpenStaticFish/ZigCraft", "text": paragraphs(text)}
        rendered = subprocess.check_output(["gh", "api", "markdown", "--method", "POST", "--input", "-"],
                                           input=json.dumps(payload), text=True)
        tags = []

        class CaptureTags(HTMLParser):
            def handle_starttag(self, tag, attrs):
                tags.append(tag)

        CaptureTags().feed(rendered)
        self.assertEqual(tags.count("p"), 2)
        self.assertFalse({"pre", "code", "img", "a"}.intersection(tags), rendered)
