import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import opencode_v2_pr as pilot


class PullRequestPilot(unittest.TestCase):
    target = ("7", "a" * 40, "b" * 40)

    def setUp(self):
        self.temp = self.enterContext(tempfile.TemporaryDirectory())
        self.root = Path(self.temp)
        self.enterContext(patch.dict(os.environ, {
            "RUNNER_TEMP": self.temp, "GITHUB_OUTPUT": str(self.root / "outputs"),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary"),
            "GITHUB_RUN_ID": "55", "GITHUB_RUN_ATTEMPT": "2",
            "GITHUB_ACTOR": "writer", "GITHUB_TRIGGERING_ACTOR": "writer",
        }))
        self.pr = {
            "number": 7, "state": "open", "draft": False, "user": {"login": "writer"},
            "head": {"sha": self.target[2], "repo": {"full_name": pilot.REPO}},
            "base": {"sha": self.target[1], "ref": "dev", "repo": {"full_name": pilot.REPO}},
        }
        self.comments = []
        self.permission = "write"
        self.legacy = "disabled_manually"
        self.pending = 0
        self.api = self.enterContext(patch.object(pilot, "api", side_effect=self.github))
        self.response = self.root / "pr-output" / "response.txt"
        self.response.parent.mkdir()
        self.response.write_text(json.dumps({
            "findings": ["</pre> ```json @maintainer"], "limitations": "Diff-only.",
        }))

    def github(self, path, *, diff=False, body=None):
        if path == "pulls/7":
            return self.pr
        if path == "collaborators/writer/permission":
            return {"permission": self.permission}
        if path == f"compare/{self.target[1]}...{self.target[2]}" and diff:
            return "diff --git a/t b/t\n"
        if path == "actions/workflows/opencode-pr.yml":
            return {"state": self.legacy}
        if path.startswith("actions/workflows/opencode-pr.yml/runs?status="):
            return {"total_count": self.pending}
        if path == "issues/7/comments?per_page=25&page=1":
            return self.comments
        if path == "issues/7/comments" and body:
            self.comments.append({"body": body["body"], "user": {"login": "github-actions[bot]"}})
            return {}
        self.fail(f"Unexpected GitHub operation: {path}")

    def test_shadow_prepares_pinned_diff_and_only_writes_summary(self):
        self.legacy = "active"
        pilot.prepare(*self.target, advisory=False)
        self.assertEqual((self.root / "outputs").read_text(), "request=opencode-pr-request-55-2\n")
        request = (self.root / "pr-input/request.txt").read_text()
        self.assertEqual(request, pilot.PROMPT + "diff --git a/t b/t\n")
        pilot.report(*self.target, advisory=False)
        summary = (self.root / "summary").read_text()
        for sha in self.target[1:]:
            self.assertIn(sha, summary)
        self.assertFalse(self.comments)

    def test_ineligible_requests_never_create_input(self):
        for obj, key, value in (
            (self.pr["head"]["repo"], "full_name", "fork/ZigCraft"),
            (self.pr, "draft", True),
            (self.pr["user"], "login", "dependabot[bot]"),
            (self.pr["head"], "sha", "0" * 40),
            (self.pr["base"], "ref", "main"),
        ):
            with self.subTest(key=key, value=value), patch.dict(obj, {key: value}):
                pilot.prepare(*self.target, advisory=False)
                self.assertFalse((self.root / "outputs").exists())
        self.permission = "read"
        pilot.prepare(*self.target, advisory=False)
        self.assertFalse((self.root / "pr-input").exists())

    def test_cutover_requires_disabled_and_drained_workflow(self):
        for state, pending in (("active", 0), ("disabled_manually", 1)):
            self.legacy, self.pending = state, pending
            for operation in (pilot.prepare, pilot.report):
                with self.subTest(state=state, operation=operation), self.assertRaises(pilot.PilotError):
                    operation(*self.target, advisory=True)
        self.assertFalse(self.comments)
        self.assertFalse((self.root / "outputs").exists())

    def test_publication_is_deduplicated_and_cannot_supply_gate_verdict(self):
        pilot.report(*self.target, advisory=True)
        pilot.report(*self.target, advisory=True)
        pilot.prepare(*self.target, advisory=True)
        self.assertFalse((self.root / "outputs").exists())
        self.assertEqual(len(self.comments), 1)
        body = self.comments[0]["body"]
        self.assertNotIn("```json", body)
        self.assertNotIn("@maintainer", body)
        self.assertIn("&lt;/pre&gt;", body)
        self.assertIn("<ul><li>", body)
        self.assertIn("<p>Diff-only.</p>", body)
        self.assertNotIn("<pre>", body)

    def test_changed_base_or_head_prevents_publication(self):
        for side in ("base", "head"):
            with patch.dict(self.pr[side], {"sha": "0" * 40}), self.assertRaises(pilot.PilotError):
                pilot.report(*self.target, advisory=True)
        self.assertFalse(self.comments)

    def test_advisory_cutover_does_not_duplicate_existing_gateway_gate_review(self):
        number, base, head = self.target
        self.comments.append({"user": {"login": "github-actions[bot]"},
                              "body": f"<!-- zigcraft-pr-gate:{number}:{base}:{head} -->\nReviewed."})
        pilot.prepare(*self.target, advisory=True)
        self.assertFalse((self.root / "pr-input").exists())

    def test_rejects_invalid_response_before_contacting_github(self):
        for response in (
            " " * (pilot.OUTPUT_LIMIT + 1),
            '{"findings": ["x"], "limitations": "foo", "recommendation": "MERGE"}',
            '{"findings": [], "limitations": "\\n::notice::"}',
            '{"findings": [false], "limitations": "foo"}',
        ):
            self.response.write_text(response)
            with self.assertRaises(pilot.PilotError):
                pilot.report(*self.target, advisory=True)
        self.api.assert_not_called()


if __name__ == "__main__":
    unittest.main()
