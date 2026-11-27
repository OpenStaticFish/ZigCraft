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


def render_gfm(body):
    payload = {"mode": "gfm", "context": "OpenStaticFish/ZigCraft", "text": body}
    return subprocess.check_output(["gh", "api", "markdown", "--method", "POST", "--input", "-"],
                                   input=json.dumps(payload), text=True)


class RenderingTest(unittest.TestCase):
    def test_full_checkout_publisher_entry_points(self):
        root = Path(__file__).resolve().parents[2]
        workflows = root / ".github/workflows"
        callers = {"opencode_discussion": ("opencode", "opencode-triage"),
                   "opencode_source_task": ("opencode-audit", "opencode-test-writer"),
                   "visual_inference": ("visual-test",)}
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            event = directory / "event.json"
            event.write_text(json.dumps({"repository": {"full_name": "fixture/other"}}))
            response = directory / "response"
            response.mkdir()
            (response / "response.txt").write_text('{"finding":null}')
            env = {"PATH": os.environ["PATH"], "GITHUB_EVENT_PATH": str(event), "GITHUB_EVENT_NAME": "issue_comment",
                   "GITHUB_OUTPUT": str(directory / "outputs"), "PYTHONDONTWRITEBYTECODE": "1"}
            args = {"opencode_discussion": ["prepare"], "opencode_source_task": ["check-finding", str(response)],
                    "visual_inference": ["signals", str(directory / "missing.log")]}
            for script, names in callers.items():
                path = f"scripts/{script}.py"
                for name in names:
                    workflow = (workflows / f"{name}.yml").read_text()
                    self.assertIn(f"python3 {path}", workflow)
                    self.assertNotIn("sparse-checkout:", workflow, "Update this test to use the new checkout layout")
                with self.subTest(script=script):
                    subprocess.run(["python3", path, *args[script]], env=env, cwd=root,
                                   capture_output=True, text=True, check=True)

    @unittest.skipUnless(os.getenv("OPENCODE_TEST_GITHUB_RENDER") == "1", "requires authenticated gh")
    def test_gfm_wrapping_prose_with_inert_model_markup(self):
        text = "See #991 or OpenStaticFish/ZigCraft#991, @someone and https://example.org.\n\n"
        text += "    ```html\n<img src=x> ![image](https://example.org/image.png)\n```"
        rendered = render_gfm(paragraphs(text))
        tags = []

        class CaptureTags(HTMLParser):
            def handle_starttag(self, tag, attrs):
                tags.append(tag)

        CaptureTags().feed(rendered)
        self.assertEqual(tags.count("p"), 2)
        self.assertFalse({"pre", "code", "img", "a"}.intersection(tags), rendered)
