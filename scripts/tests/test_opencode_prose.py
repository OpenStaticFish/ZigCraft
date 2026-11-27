"""Opt-in GitHub GFM check; sends only a fixed, synthetic comment to /markdown."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from opencode_prose import paragraphs


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
