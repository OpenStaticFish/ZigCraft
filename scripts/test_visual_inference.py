"""Disposable caller fixtures; run with Python 3, Pillow, and ImageMagick 7."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from PIL import Image
from PIL.PngImagePlugin import PngInfo

import visual_inference as visual


class VisualInferenceTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.capture = self.root / "capture.png"
        self.image = self.root / "image.png"
        self.request = self.root / "request"
        self.response = self.root / "response.txt"
        self.issue = self.root / "issue.md"
        self.env = dict(CAPTURE_RESULT="success", CAPTURE="success", IMAGE="success",
                        COMPARISON="success", DIAGNOSTICS="[]",
                        GITHUB_SHA="a" * 40, GITHUB_RUN_ID="12345")

    def compare(self, golden):
        return subprocess.run(
            ["bash", Path(__file__).with_name("compare_visual_golden.sh"),
             self.image, golden, self.root / "diff.png"],
            capture_output=True,
        )

    def test_validated_vision_and_no_finding(self):
        metadata = PngInfo()
        metadata.add_text("Comment", "do not forward this metadata")
        Image.new("RGB", (32, 24), "purple").save(self.capture, pnginfo=metadata)
        visual.normalize(self.capture, self.image)
        self.assertEqual(self.compare(self.capture).returncode, 0)
        profile = visual.prepare(self.image, self.request, self.env)
        self.assertEqual(profile, "vision")
        self.assertEqual({p.name for p in self.request.iterdir()}, {"request.txt", "image.png"})
        text = (self.request / "request.txt").read_text()
        self.assertIn((visual.PROMPTS / "visual-test-verify.md").read_text(), text)
        self.assertIn('{"disposition":"no_finding","observation":""}', text)
        self.assertNotIn(b"do not forward", (self.request / "image.png").read_bytes())
        self.response.write_text('{"disposition":"no_finding","observation":""}')
        visual.advisory(profile, self.response, self.issue, self.env)
        self.assertFalse(self.issue.exists())

    def test_missing_capture_is_not_a_visual_pass(self):
        with self.assertRaisesRegex(ValueError, "Capture unavailable"):
            visual.normalize(self.capture, self.image)
        self.env.update(CAPTURE_RESULT="failure", IMAGE="failure", COMPARISON="skipped")
        profile = visual.prepare(self.image, self.request, self.env)
        self.assertEqual(profile, "default")
        self.assertEqual([p.name for p in self.request.iterdir()], ["request.txt"])
        text = (self.request / "request.txt").read_text()
        url = "https://github.com/OpenStaticFish/ZigCraft/actions/runs/12345"
        self.assertIn((visual.PROMPTS / "visual-test-diagnose.md").read_text().replace("$WORKFLOW_URL", url), text)
        self.assertIn(url, text)
        self.assertNotIn("$WORKFLOW_URL", text)
        self.assertIn("capture unavailable", text)
        self.assertIn('{"disposition":"finding","observation":', text)
        self.response.write_text('{"disposition":"no_finding","observation":""}')
        with self.assertRaises(ValueError):
            visual.advisory(profile, self.response, self.issue, self.env)

    def test_failed_comparison_forwards_only_fixed_signals(self):
        Image.new("RGB", (32, 24), "purple").save(self.image)
        Image.new("RGB", (32, 24), "black").save(self.capture)
        comparison = self.compare(self.capture)
        self.assertNotEqual(comparison.returncode, 0)
        log = self.root / "comparison.log"
        log.write_bytes(comparison.stdout + comparison.stderr + b"\nprivate diagnostic payload")
        signals = visual.diagnostic_signals([log])
        self.assertEqual(signals, ["golden screenshot is effectively black"])
        self.env.update(CAPTURE_RESULT="failure", COMPARISON="failure",
                        DIAGNOSTICS=json.dumps(signals))
        profile = visual.prepare(self.image, self.request, self.env)
        self.assertEqual(profile, "default")
        self.assertFalse((self.request / "image.png").exists())
        request = (self.request / "request.txt").read_text()
        self.assertIn(signals[0], request)
        self.assertNotIn("private diagnostic payload", request)
        self.response.write_text('{"disposition":"finding","observation":"Golden is black."}')
        visual.advisory(profile, self.response, self.issue, self.env)
        self.assertIn("    Golden is black.", self.issue.read_text())
        self.assertIn(self.env["GITHUB_SHA"], self.issue.read_text())

    def test_reject_malformed_evidence_and_response(self):
        self.capture.write_bytes(b"\x89PNG\r\n\x1a\nnot a PNG")
        with self.assertRaises(OSError):
            visual.normalize(self.capture, self.image)
        self.capture.write_bytes(b"x" * (visual.PNG_LIMIT + 1))
        with self.assertRaises(ValueError):
            visual.normalize(self.capture, self.image)
        for body in [b"{}" + b" " * 32768, b'{"disposition":"pass","observation":""}']:
            self.response.write_bytes(body)
            with self.assertRaises(ValueError):
                visual.advisory("vision", self.response, self.issue, self.env)
            self.assertFalse(self.issue.exists())


if __name__ == "__main__":
    unittest.main()
