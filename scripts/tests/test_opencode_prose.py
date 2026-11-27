"""Opt-in GitHub GFM check; sends only a fixed, synthetic comment to /markdown."""

from html.parser import HTMLParser
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from opencode_prose import paragraphs
from opencode_v2_pr import findings_list
from visual_inference import advisory


MARKUP = "#991 @someone </p> </li> ![remote](https://example.org/img) ```"
live_gfm = unittest.skipUnless(os.getenv("OPENCODE_TEST_GITHUB_RENDER") == "1", "requires authenticated gh")


def render_gfm(body):
    payload = {"mode": "gfm", "context": "OpenStaticFish/ZigCraft", "text": body}
    rendered = subprocess.check_output(["gh", "api", "markdown", "--input", "-"], input=json.dumps(payload), text=True)
    for unsafe in ('<img ', 'class="user-mention', 'href="https://example.org', '/issues/991"'):
        if unsafe in rendered:
            raise AssertionError(unsafe)
    return rendered


class RenderingTest(unittest.TestCase):
    def test_offline_markdown_wrappers(self):
        paragraph = paragraphs("First.\n\n</p>\n```html\n<img src=x>\n```")
        findings = findings_list(["</li> " + MARKUP, "Second finding"])
        markdown = f"### Summary\n\n{paragraph}\n\n### Findings\n\n{findings}"
        # Enable raw HTML as on GitHub; disabling it would mask broken escaping.
        rendered = subprocess.check_output(["cmark", "--unsafe"], input=markdown, text=True)
        tags = []

        class Tags(HTMLParser):
            def handle_starttag(self, tag, attrs):
                tags.append(tag)

        Tags().feed(rendered)
        self.assertEqual(tags, ["h3", "p", "p", "br", "br", "br", "h3", "ul", "li", "li"])
        self.assertIn("&lt;img src=x&gt;", rendered)

    @live_gfm
    def test_gfm_visual_issue(self):
        with tempfile.TemporaryDirectory() as tmp:
            response, issue = Path(tmp) / "response.txt", Path(tmp) / "issue.md"
            response.write_text(json.dumps({"disposition": "finding", "observation": MARKUP}))
            advisory("vision", response, issue, {"GITHUB_SHA": "a"*40, "GITHUB_RUN_ID": "123"})
            rendered = render_gfm(issue.read_text())
            self.assertIn('href="https://github.com/OpenStaticFish/ZigCraft/actions/runs/123"', rendered)
            self.assertIn("Image observation", rendered)
            self.assertNotIn("<pre", rendered)

    def test_full_checkout_publisher_entry_points(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            event = directory / "event.json"
            event.write_text('{"repository":{"full_name":"fixture/other"}}')
            response = directory / "response"
            response.mkdir()
            (response / "response.txt").write_text('{"finding":null}')
            env = {"PATH": os.environ["PATH"], "GITHUB_EVENT_PATH": str(event), "GITHUB_EVENT_NAME": "issue_comment",
                   "GITHUB_OUTPUT": str(directory / "outputs"), "PYTHONDONTWRITEBYTECODE": "1"}
            for script, args, names in (
                ("opencode_discussion", ["prepare"], ["opencode", "opencode-triage"]),
                ("opencode_source_task", ["check-finding", response], ["opencode-audit", "opencode-test-writer"]),
                ("visual_inference", ["signals"], ["visual-test"]),
            ):
                path = f"scripts/{script}.py"
                for name in names:
                    workflow = (root / f".github/workflows/{name}.yml").read_text()
                    self.assertIn(f"python3 {path}", workflow)
                    self.assertNotIn("sparse-checkout:", workflow)
                subprocess.run(["python3", path, *args], env=env, cwd=root, capture_output=True, check=True)

    @live_gfm
    def test_gfm_wrapping_prose_with_inert_model_markup(self):
        text = "See #991 or OpenStaticFish/ZigCraft#991, @someone and https://example.org.\n\n"
        text += "    ```html\n<img src=x> ![image](https://example.org/image.png)\n```"
        rendered = render_gfm(paragraphs(text))
        self.assertEqual(rendered.count("</p>"), 2)
        for tag in ("<pre", "<code", "<img", "<a "):
            self.assertNotIn(tag, rendered)
