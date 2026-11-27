import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import opencode_pr_gate as gate


class MergeGate(unittest.TestCase):
    number, base, head = "3", "a" * 40, "b" * 40

    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.enterContext(patch.dict(os.environ, {
            "RUNNER_TEMP": str(self.root), "GITHUB_OUTPUT": str(self.root / "output"),
            "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2", "GITHUB_EVENT_NAME": "pull_request_target",
            "GITHUB_ACTOR": "dev", "GITHUB_TRIGGERING_ACTOR": "dev",
        }))
        self.target = (self.number, self.base, self.head)
        self.pr = {
            "number": 3, "state": "open", "draft": False, "user": {"login": "dev"},
            "head": {"sha": self.head, "repo": {"full_name": gate.pr.REPO}},
            "base": {"sha": self.base, "ref": "dev", "repo": {"full_name": gate.pr.REPO}},
            "changed_files": 1,
        }
        self.finding = {"location": "src/example.zig:10", "title": "Example", "confidence": "High",
                        "description": "<pre>@name", "impact": "Wrong result", "suggested_fix": "Use the checked value"}
        self.decision = {
            "reviewed_sha": self.head, "reviewed_base": self.base,
            "overall_confidence_score": 80, "recommendation": "MERGE",
            "critical": [], "high": [], "medium": [], "low": [self.finding],
            "summary": "Review summary", "verdict_reason": "Ready based on the supplied changes.",
            "solid": {k: {"score": 8, "notes": "Clear responsibility"} for k in gate.PRINCIPLES},
            "confidence_breakdown": dict(code_quality=85, completeness=80, risk_level=80, test_coverage=70),
            "fixed": {k: [] for k in gate.SEVERITIES}, "no_security_concerns": True,
            "tests_present_and_passing": False,
        }
        self.response = self.root / "pr-output/response.txt"
        self.response.parent.mkdir()
        self.response.write_text(json.dumps(self.decision))
        self.comments = []
        self.states = []
        self.permission = "write"
        self.enterContext(patch.object(gate.pr, "api", side_effect=self.github))

    def github(self, path, *, diff=False, body=None, method=None):
        if path == "pulls/3":
            return self.pr
        if path == "pulls/3/reviews?per_page=100":
            return [{"user": {"login": "opencode-agent[bot]"}, "body": "Previous formal review"}]
        if path == "issues/55":
            return {"title": "Linked issue", "body": "Requested behavior"}
        if path == "collaborators/dev/permission":
            return {"permission": self.permission}
        if path == f"compare/{self.base}...{self.head}" and diff:
            return "diff --git a/source.zig b/source.zig\n"
        if path == f"statuses/{self.head}" and body:
            self.states.append((body["context"], body["state"]))
            return {}
        if path == "issues/3/comments?per_page=25&page=1":
            return self.comments
        if path == "issues/3/comments" and body:
            self.comments.append({"id": 27, **body, "user": {"login": "github-actions[bot]"}})
            return {}
        if path == "issues/comments/27" and method == "PATCH":
            self.comments[-1].update(body)
            return {}
        self.fail(f"Unexpected GitHub operation: {path}")

    def test_manual_dispatch_prepares_only_for_verified_head_and_writer(self):
        with patch.dict(os.environ, GITHUB_EVENT_NAME="workflow_dispatch"):
            self.permission = "read"
            with self.assertRaises(gate.pr.PilotError):
                gate.start(*self.target)
            self.permission = "write"
            with self.assertRaises(gate.pr.PilotError):
                gate.start(self.number, self.base, "f" * 40)
            self.assertFalse(self.states)
            gate.start(*self.target)
            gate.prepare(*self.target)
        self.assertEqual(self.states, [("ai-merge-gate", "pending")])
        self.assertIn("request=opencode-gate-request-123-2", (self.root / "output").read_text())
        request = (self.root / "pr-input/request.txt").read_text()
        for expected in (self.head, self.base, "diff --git"):
            self.assertIn(expected, request)

    def test_unauthorized_pr_actor_cannot_run_inference_or_publish(self):
        self.permission = "read"
        for action in (gate.start, gate.publish):
            with self.subTest(action=action), self.assertRaises(gate.pr.PilotError):
                action(*self.target)
        self.assertFalse((self.root / "output").exists())
        self.assertFalse(self.states)
        self.assertFalse(self.comments)

    def test_review_prompt_receives_previous_findings_and_linked_issue(self):
        self.pr.update(body="Fixes #55", comments=1, labels=[{"name": "automated-test"}])
        self.comments.append({"user": {"login": "github-actions[bot]"},
                              "body": f"<!-- zigcraft-pr-gate:3:{self.base}:{self.head} -->\nPrevious finding"})
        gate.prepare(*self.target)
        prompt = (self.root / "pr-input/request.txt").read_text()
        for text in ("Previous finding", "Previous formal review", "Requested behavior", "automated-test",
                     "**PR to review:** #3", "📊 SOLID Principles Score"):
            self.assertIn(text, prompt)
        self.decision["fixed"]["high"] = ["Released the previous allocation"]
        passed, report = gate.verdict(json.dumps(self.decision), self.base, self.head, self.number)
        self.assertTrue(passed)
        self.assertIn("[FIXED]", report)

    def test_stale_base_and_incomplete_diff_cannot_prepare_a_request(self):
        with patch.dict(self.pr["base"], sha="c" * 40):
            gate.start(*self.target)
            with self.assertRaises(gate.pr.PilotError):
                gate.prepare(*self.target)
        with patch.dict(self.pr, changed_files=2), self.assertRaises(gate.pr.PilotError):
            gate.prepare(*self.target)
        gate.fail(*self.target)
        self.assertFalse((self.root / "pr-input").exists())
        self.assertEqual(self.states, [("ai-merge-gate", "pending"), ("ai-merge-gate", "failure"), ("ai-review", "failure")])

    def test_every_blocking_severity_threshold_and_verdict_is_independent(self):
        for field, value in [
            ("critical", [self.finding]), ("high", [self.finding]), ("medium", [self.finding]),
            ("overall_confidence_score", 79), ("recommendation", "MERGE WITH FIXES"),
            ("recommendation", "DO NOT MERGE"),
        ]:
            with self.subTest(field=field, value=value):
                self.response.write_text(json.dumps({**self.decision, field: value}))
                gate.publish(*self.target)
                self.assertEqual(self.states[-1], ("ai-merge-gate", "failure"))
        self.assertEqual(len(self.comments), 1)
        self.assertIn("DO NOT MERGE", self.comments[0]["body"])

    def test_retry_uses_only_response_and_updates_own_comment(self):
        self.comments.append({"user": {"login": "contributor"}, "body": f"<!-- zigcraft-pr-gate:3:{self.base}:{self.head} -->\n"})
        gate.publish(*self.target)
        gate.publish(*self.target)
        self.assertEqual(self.states[-1], ("ai-merge-gate", "success"))
        self.assertEqual(len(self.comments), 2)
        self.assertNotIn("<pre>", self.comments[-1]["body"])
        body = self.comments[-1]["body"]
        self.assertIn("&lt;pre&gt;@", body)
        for section in ["📋 Summary", "📌 Review Metadata", *gate.HEADINGS, "📊 SOLID Principles Score",
                        "🎯 Final Assessment", "Confidence Breakdown", "Merge Readiness", "Machine Readable Verdict"]:
            self.assertIn(section, body)
        self.assertIn("- [ ] Tests present and passing", body)
        machine = json.loads(body.split("```json\n")[1].split("\n```")[0])
        self.assertEqual(machine["recommendation"], "MERGE")
        self.response.write_text(json.dumps({**self.decision, "high": [{**self.finding, "title": "bug"}]}))
        gate.publish(*self.target)
        self.assertEqual(self.states[-1], ("ai-merge-gate", "failure"))
        self.assertEqual(len(self.comments), 2)
        self.assertIn("bug", self.comments[-1]["body"])
        self.assertTrue(gate.pr.already_reviewed(*self.target))

    def test_invalid_stale_or_missing_artifacts_cannot_publish(self):
        raws = ["not JSON", "{}", "x" * (gate.pr.OUTPUT_LIMIT + 1),
                json.dumps(self.decision).replace('"critical":', '"critical":["bug"], "critical":')]
        for field, value in (
            ("reviewed_sha", self.base), ("reviewed_base", self.head),
            ("overall_confidence_score", True), ("overall_confidence_score", 101),
            ("overall_confidence_score", 80.5), ("critical", False), ("high", [7]),
            ("low", ["\n::error::"]), ("recommendation", "merge"), ("other", "MERGE"),
        ):
            raws.append(json.dumps({**self.decision, field: value}))
        for raw in raws:
            with self.subTest(raw=raw[:20]), self.assertRaises(ValueError):
                self.response.write_text(raw)
                gate.publish(*self.target)
        self.response.unlink()
        with self.assertRaises(gate.pr.PilotError):
            gate.publish(*self.target)
        self.assertFalse(self.states)
        self.assertFalse(self.comments)

    def test_changed_head_or_base_prevents_passing_either_revision(self):
        for side in ("base", "head"):
            with patch.dict(self.pr[side], sha="c" * 40), self.assertRaises(gate.pr.PilotError):
                gate.publish(*self.target)
        self.assertFalse(self.comments)
        self.assertFalse(self.states)
        with patch.object(gate.pr, "eligible", side_effect=[True, False]), self.assertRaises(gate.pr.PilotError):
            gate.publish(*self.target)
        gate.fail(*self.target)
        self.assertEqual(self.states, [("ai-merge-gate", "failure"), ("ai-review", "failure")])

    def test_workflow_rejects_failed_or_foreign_artifacts_but_allows_failed_job_retry(self):
        workflow = (ROOT / ".github/workflows/opencode-pr.yml").read_text()
        step = workflow.split("- name: Require the successful response from this run\n", 1)[1]
        check = step.split("        run: |\n", 1)[1].split("\n      - uses:", 1)[0]
        for prep, infer, artifact, accepted in (
            ("success", "success", "opencode-response-123-2", True),
            ("success", "success", "opencode-response-123-1", True),
            ("success", "success", "opencode-response-123-3", False),
            ("success", "success", "opencode-response-124-2", False),
            ("success", "success", "", False),
            ("failure", "success", "opencode-response-123-2", False),
            ("success", "skipped", "opencode-response-123-2", False),
            ("success", "failure", "opencode-response-123-2", False),
        ):
            with self.subTest(prep=prep, infer=infer, artifact=artifact):
                result = subprocess.run(["bash", "-ec", check], env=dict(os.environ, PREPARE=prep, INFER=infer, RESPONSE=artifact))
                self.assertEqual(result.returncode == 0, accepted)
        self.assertIn("if: failure()", workflow)
        self.assertIn("run: python3 -I scripts/opencode_pr_gate.py fail", workflow)


if __name__ == "__main__":
    unittest.main()
