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
sys.path.insert(0, str(ROOT / ".github/actions/opencode-v2"))
import adapter
import opencode_pr_gate as gate
from test_opencode_prose import render_gfm


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
            "test_status": "unverified",
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
            return [{"id": 9, "user": {"login": "opencode-agent[bot]"}, "body": "Previous formal review"}]
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
        self.pr.update(body="<!-- Fixes #1 -->\n```md\nCloses #2\nResolves #3\n```\n`Fixes #4`\nFixes #55",
                       comments=1, labels=[{"name": "automated-test"}])
        self.comments.append({"id": 17, "user": {"login": "github-actions[bot]"},
                              "body": f"<!-- zigcraft-pr-gate:3:{self.base}:{self.head} -->\nPrevious finding"})
        gate.prepare(*self.target)
        prompt = (self.root / "pr-input/request.txt").read_text()
        for text in ("Previous finding", "Previous formal review", "Requested behavior", "automated-test",
                     "**PR to review:** #3", "Single Responsibility", "Return one JSON object"):
            self.assertIn(text, prompt)
        self.decision["fixed"]["high"] = ["source.zig:2 releases the previous allocation."]
        passed, report = gate.verdict(json.dumps(self.decision), self.base, self.head, self.number)
        self.assertTrue(passed)
        self.assertIn("[FIXED]", report)
        # Historical notes cannot cancel a current finding of the same severity.
        self.decision["high"] = [self.finding]
        passed, report = gate.verdict(json.dumps(self.decision), self.base, self.head, self.number)
        self.assertFalse(passed)
        self.assertIn('"high_priority_issues": 1', report)

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

    def test_inconclusive_current_review_withholds_merge_despite_stale_passing_comment(self):
        old_base = "c" * 40
        _, old_report = gate.verdict(json.dumps({**self.decision, "reviewed_base": old_base}), old_base, self.head, self.number)
        previous = gate.review_header(self.number, old_base, self.head) + old_report
        self.comments.append({"user": {"login": "github-actions[bot]"}, "body": previous})
        self.decision.update(recommendation="DO NOT MERGE",
                             verdict_reason="The prior cleanup concern is relevant, but the error path is not supplied.")
        self.response.write_text(json.dumps(self.decision))
        gate.publish(*self.target)
        self.assertEqual(self.states[-1], ("ai-merge-gate", "failure"))
        self.assertEqual(self.comments[0]["body"], previous)
        self.assertTrue(self.comments[1]["body"].startswith(gate.review_header(*self.target)))
        self.assertIn(self.decision["verdict_reason"], self.comments[1]["body"])

    def test_review_search_finds_later_pages_and_reports_caps(self):
        gate_entry = {"user": {"login": "github-actions[bot]"}, "body": gate.review_header(*self.target) + "Prior blocker"}
        formal_entry = {"user": {"login": "opencode-agent[bot]"}, "body": "Formal blocker"}
        for comment_count, formal_count, complete in [(75, 101, True), (125, 200, False)]:
            self.pr["comments"] = comment_count
            # The gate comment is on the third page back; the formal review is record 101.
            gate_page = (comment_count + 24) // 25 - 2

            def pages(path, **kwargs):
                if path.startswith("issues/3/comments?"):
                    batch = [{}] * 25
                    if path.endswith(f"page={gate_page}"):
                        batch[-1] = gate_entry
                    return batch
                if path.startswith("pulls/3/reviews?"):
                    if path.endswith("&page=2"):
                        return [formal_entry] + [{}] * (formal_count - 101)
                    return [{}] * 100
                return self.github(path, **kwargs)

            with self.subTest(complete=complete), patch.object(gate.pr, "api", side_effect=pages):
                previous, context = gate.review_context(self.pr)
                self.assertEqual(previous, [gate_entry["body"]])
                self.assertEqual(context["formal_review_excerpts"][0]["excerpt"], formal_entry["body"])
                self.assertEqual(context["history_coverage"]["comment_search_complete"], complete)
                self.assertEqual(context["history_coverage"]["formal_search_complete"], complete)

    def test_history_keeps_blocker_after_long_summary_and_fixed_notes(self):
        self.decision["summary"] = "&" * 1000
        self.decision["fixed"]["critical"] = ["`" * 500]
        self.decision["medium"] = [{**self.finding, "title": "Lost & leaked allocation",
                                    "description": "The error path skips cleanup"}]
        self.response.write_text(json.dumps(self.decision))
        gate.publish(*self.target)
        self.assertGreater(self.comments[0]["body"].index("Lost &amp; leaked allocation"), 5500)
        self.pr["comments"] = 1
        gate.prepare(*self.target)
        request = (self.root / "pr-input/request.txt").read_text()
        self.assertIn("[Partial previous review: details truncated]", request)
        self.assertIn("MEDIUM: src/example.zig:10 – Lost & leaked allocation", request)
        self.assertIn("The error path skips cleanup", request)
        self.assertIn(f"Base: {self.base} Head: {self.head}", request)
        self.assertIn("Inline review comments are not included", request)

    def test_gateway_response_at_review_byte_limit_can_publish(self):
        limit = adapter.RESPONSE_LIMIT
        self.assertEqual(limit, gate.pr.OUTPUT_LIMIT)
        self.assertIn(f"{limit} UTF-8 bytes", gate.PROMPT.read_text())
        self.decision["high"] = [{**self.finding, "description": "界" * 830}] * 12
        raw = json.dumps(self.decision, ensure_ascii=False, separators=(",", ":"))
        room = limit - len(raw.encode())
        self.assertGreater(room, 0)
        raw = raw[:-1] + " " * room + "}"

        def transport(text):
            return adapter.response([json.dumps({"type": "text", "part": {"text": text}}).encode(),
                                     b'{"type":"step_finish","part":{"reason":"stop"}}'])

        self.response.write_bytes(transport(raw).encode())
        self.assertEqual(self.response.stat().st_size, limit)
        gate.publish(*self.target)
        self.assertEqual(self.states[-1], ("ai-merge-gate", "failure"))
        self.assertIn('"high_priority_issues": 12', self.comments[-1]["body"])
        with self.assertRaises(adapter.StageError):
            transport(raw[:-1] + " }")

    def test_optional_context_failure_keeps_complete_diff(self):
        self.pr.update(body="Fixes #55", comments=1)

        def unavailable(path, **kwargs):
            if path.startswith(("issues/", "pulls/3/reviews")):
                raise OSError("temporary GitHub failure")
            return self.github(path, **kwargs)

        with patch.object(gate.pr, "api", side_effect=unavailable):
            gate.prepare(*self.target)
        text = (self.root / "pr-input/request.txt").read_text()
        for path in ("issues/55", "issues/3/comments?", "pulls/3/reviews?"):
            self.assertIn(path, text.split('{"unavailable":')[1].splitlines()[0])
        self.assertTrue(text.endswith("diff --git a/source.zig b/source.zig\n"))

    def test_optional_context_cannot_displace_pinned_diff(self):
        self.pr.update(body="界" * 6000, comments=1)
        self.comments.append({"user": {"login": "github-actions[bot]"},
                              "body": gate.review_header(self.number, self.base, self.head) + "summary" * 900
                              + "\n**High (1)**\n<pre>• source.zig:10: stale handle used after free</pre>"})
        diff = "diff --git a/t b/t\n" + ("d" * (gate.pr.INPUT_LIMIT - len(gate.PROMPT.read_bytes()) - 1000))
        with patch.object(gate.pr, "api", side_effect=lambda path, **kw: diff if kw.get("diff") else self.github(path, **kw)):
            gate.prepare(*self.target)
        text = (self.root / "pr-input/request.txt").read_text()
        self.assertTrue(text.endswith(diff))
        self.assertLessEqual(len(text.encode()), gate.pr.INPUT_LIMIT)
        self.assertNotIn(self.pr["body"], text)
        self.assertIn("source.zig:10: stale handle used after free", text)
        self.assertIn("[Partial previous review: details truncated]", text)

    def test_machine_verdict_distinguishes_bases_for_same_head(self):
        for base in [self.base, "c" * 40]:
            _, report = gate.verdict(json.dumps({**self.decision, "reviewed_base": base}), base, self.head, self.number)
            machine = json.loads(report.split("```json\n")[1].split("\n```")[0])
            self.assertEqual((machine["reviewed_sha"], machine["reviewed_base"]), (self.head, base))

    def test_documented_diff_budget_and_previous_verdict_only_boundary(self):
        header = "diff --git a/t b/t\n--- a/t\n+++ b/t\n@@ -0,0 +1 @@\n+"
        for kib in (89, 94):
            diff = header + "x" * (kib * 1024 - len(header) - 1) + "\n"
            with tempfile.TemporaryDirectory() as runner, patch.dict(os.environ, RUNNER_TEMP=runner), \
                    patch.object(gate.pr, "api", side_effect=lambda path, **kw: diff if kw.get("diff") else self.github(path, **kw)):
                request = Path(runner) / "pr-input/request.txt"
                if kib == 89:
                    gate.prepare(*self.target)
                    self.assertTrue(request.read_text().endswith(diff))
                else:
                    # 94 KiB left 2 KiB for the former 1,088-byte prompt and revision headers.
                    with self.assertRaisesRegex(gate.pr.PilotError, "complete diff exceed"):
                        gate.prepare(*self.target)
                    self.assertFalse(request.exists())

    def test_full_diff_with_no_context_room_marks_history_omitted(self):
        self.pr["comments"] = 1
        self.comments.append({"user": {"login": "github-actions[bot]"},
                              "body": gate.review_header(*self.target) + "Prior concern"})
        gate.prepare(*self.target)
        text = (self.root / "pr-input/request.txt").read_text()
        prefix = text[:text.index("Prior gate history:")]
        diff = text[text.index("\nUntrusted diff:"):]
        expected = prefix + "Prior gate history: omitted\n" + diff
        with tempfile.TemporaryDirectory() as runner, patch.dict(os.environ, RUNNER_TEMP=runner), \
                patch.object(gate.pr, "INPUT_LIMIT", len(expected.encode())):
            gate.prepare(*self.target)
            self.assertEqual((Path(runner) / "pr-input/request.txt").read_text(), expected)

    def test_malformed_optional_records_keep_valid_evidence_and_diff(self):
        self.pr.update(body="Fixes #55", comments=1, labels=[None, {}, {"name": "automated-test"}])
        malformed = [None, {}, {"user": []}, {"body": 5, "user": {"login": "github-actions[bot]"}}]
        marker = "<!-- zigcraft-pr-gate:3:previous -->"
        self.comments.extend([{"id": 17, "body": marker, "user": {"login": "github-actions[bot]"}}, *malformed])

        def mixed_records(path, **kwargs):
            result = self.github(path, **kwargs)
            if path == "issues/55":
                return {"title": "Linked issue", "body": {}}
            if path.startswith("pulls/3/reviews?"):
                return malformed + result
            return result

        with patch.object(gate.pr, "api", side_effect=mixed_records):
            gate.prepare(*self.target)
        text = (self.root / "pr-input/request.txt").read_text()
        for evidence in (marker, "Previous formal review", "Linked issue", '"automated-test"'):
            self.assertIn(evidence, text)
        self.assertTrue(text.endswith("diff --git a/source.zig b/source.zig\n"))

    def test_large_report_preserves_all_findings_and_verdict(self):
        item = {**self.finding, "impact": "`" * 1000, "description": "&" * 1000}
        locations = ["modules/" + "nested/" * 36 + f"source.zig:{line}" for line in range(1, 13)]
        self.decision.update(low=[{**item, "location": location} for location in locations], test_status="failed")
        raw = json.dumps(self.decision)
        self.assertLess(len(raw.encode()), gate.pr.OUTPUT_LIMIT)
        passed, report = gate.verdict(raw, self.base, self.head, self.number)
        self.assertTrue(passed)  # Test status is informational, independent CI enforces test results.
        self.assertIn("abbreviated", report)
        self.assertLess(len(report.encode()), 65000)
        self.assertEqual(report.count("<strong>[LOW]</strong>"), 12)
        for location in locations:
            self.assertIn(f"<code>{location}</code>", report)
        self.assertIn("evidence: failed", report)
        machine = json.loads(report.split("```json\n")[1].split("\n```")[0])
        self.assertEqual(machine["recommendation"], "MERGE")

    def test_comment_budget_includes_escaped_locations_and_markers(self):
        path = "`" * 70 + ".zig:1"
        self.decision["low"] = [{**self.finding, "location": path, "description": "&" * 900}] * 12
        gate.review_comment(*self.target, gate.verdict(json.dumps(self.decision), self.base, self.head, self.number)[1])
        self.assertLessEqual(len(self.comments[0]["body"].encode()), 65536)
        self.assertIn(gate.pr.escape_text(path), self.comments[0]["body"])
        self.decision["low"][0]["location"] = "`" * 1000
        with self.assertRaisesRegex(gate.pr.PilotError, "Location"):
            gate.verdict(json.dumps(self.decision), self.base, self.head, self.number)

    def test_every_blocking_severity_threshold_and_verdict_is_independent(self):
        for field, value, expected in [
            ("critical", [self.finding], "DO NOT MERGE"), ("high", [self.finding], "MERGE WITH FIXES"),
            ("medium", [self.finding], "MERGE WITH FIXES"), ("overall_confidence_score", 79, "MERGE WITH FIXES"),
            ("recommendation", "MERGE WITH FIXES", "MERGE WITH FIXES"), ("recommendation", "DO NOT MERGE", "DO NOT MERGE"),
        ]:
            with self.subTest(field=field, value=value):
                self.response.write_text(json.dumps({**self.decision, field: value}))
                gate.publish(*self.target)
                self.assertEqual(self.states[-1], ("ai-merge-gate", "failure"))
                body = self.comments[0]["body"]
                self.assertIn(f"### Verdict\n\n**{expected}**", body)
                machine = json.loads(body.split("```json\n")[1].split("\n```")[0])
                self.assertEqual(machine["recommendation"], expected)
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

    @unittest.skipUnless(os.getenv("OPENCODE_TEST_GITHUB_RENDER") == "1", "requires authenticated gh")
    def test_gfm_complete_gate_report(self):
        self.finding["description"] = "@someone </p> ![remote](https://example.org/image.png) ```json #991"
        self.response.write_text(json.dumps(self.decision))
        gate.publish(*self.target)
        rendered = render_gfm(self.comments[-1]["body"])
        self.assertIn("<table", rendered)
        self.assertIn("<strong>Description:</strong>", rendered)
        self.assertIn("Machine Readable Verdict", rendered)
        self.assertNotIn("<img ", rendered)
        self.assertNotIn('class="user-mention', rendered)
        self.assertNotIn('href="https://example.org', rendered)
        self.assertNotIn('/issues/991"', rendered)

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
