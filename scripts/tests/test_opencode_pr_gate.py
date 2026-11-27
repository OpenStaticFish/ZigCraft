import json
import os
from contextlib import chdir
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


class PinnedTrees(unittest.TestCase):
    def test_fetch_changed_pr_ref_and_reject_ambiguous_history(self):
        with tempfile.TemporaryDirectory() as tmp, chdir(tmp):
            def git(*args):
                return subprocess.check_output(["git", "-c", "user.name=Fixture", "-c", "user.email=t@example.org", *args])

            git("init", "-qb", "dev")
            source = Path("file")
            middle = "unchanged\n" * 20
            source.write_text("old\n" + middle + "old\n")
            link = Path("link")
            link.write_text("old\n")
            git("add", "file", "link")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD").decode().strip()
            git("update-ref", "refs/pull/3/head", base)
            git("clone", "-q", "--no-local", ".", "trusted")
            git("switch", "-qc", "feature")
            source.write_text("first\n" + middle + "second\n")
            link.unlink()
            link.symlink_to("file")
            git("commit", "-qam", "head")
            source.write_text("first\n" + middle + "old\n")
            head = git("rev-parse", "HEAD").decode().strip()
            git("update-ref", "refs/pull/3/head", head)
            with chdir("trusted"):
                with self.assertRaisesRegex(gate.pr.PilotError, "refs moved"):
                    gate.pinned_diff("3", base, base)
                diff, count = gate.pinned_diff("3", base, head)
                self.assertEqual((count, diff.count("diff --git ")), (2, 3))
                self.assertIn("+first\n", diff)
                self.assertIn("+second\n", diff)
                self.assertEqual(git("rev-parse", "HEAD").decode().strip(), base)
            # Both merge tips change the same file relative to either parent.
            git("add", "file")
            tree = git("write-tree").decode().strip()
            sibling = git("commit-tree", "dev^{tree}", "-p", base, "-m", "sibling").decode().strip()
            left = git("commit-tree", tree, "-p", head, "-p", sibling, "-m", "left").decode().strip()
            right = git("commit-tree", tree, "-p", sibling, "-p", head, "-m", "right").decode().strip()
            git("update-ref", "refs/heads/dev", left)
            git("update-ref", "refs/pull/3/head", right)
            with chdir("trusted"), self.assertRaisesRegex(gate.pr.PilotError, "Ambiguous merge base"):
                gate.pinned_diff("3", left, right)


class MergeGate(unittest.TestCase):
    number, base, head = "3", "a" * 40, "b" * 40
    diff = "diff --git a/source.zig b/source.zig\n--- a/source.zig\n+++ b/source.zig\n@@ -1 +1 @@\n-before\n+after\n"

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
        self.enterContext(patch.object(gate, "pinned_diff", return_value=(self.diff, 1)))
        self.enterContext(patch.object(gate.pr, "api", side_effect=self.github))

    def github(self, path, *, diff=False, body=None, method=None, pagination=None):
        if path == "pulls/3":
            return self.pr
        if path == "pulls/3/reviews?per_page=100":
            pagination["last"] = 1
            return [None, {}, {"id": 9, "user": {"login": "opencode-agent[bot]"}, "body": "Previous formal review"}]
        if path == "issues/55":
            return {"title": "Linked issue", "body": "Requested behavior"}
        if path == "issues/56":
            return {"title": "Incomplete issue", "body": {}}
        if path == "collaborators/dev/permission":
            return {"permission": self.permission}
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
        self.pr.update(body="<!-- Fixes #1 -->\n```md\nCloses #2\nResolves #3\n```\n`Fixes #4`\n> Fixes #5\nFixes #55, closes #56",
                       comments=5, labels=[None, {}, {"name": "automated-test"}])
        self.comments.append({"id": 17, "user": {"login": "github-actions[bot]"},
                              "body": f"<!-- zigcraft-pr-gate:3:{self.base}:{self.head} -->\nPrevious finding"})
        self.comments.extend([None, {}, {"user": []}, {"body": 5, "user": {"login": "github-actions[bot]"}}])
        gate.prepare(*self.target)
        prompt = (self.root / "pr-input/request.txt").read_text()
        for text in ("Previous finding", "Previous formal review", "Requested behavior", "Incomplete issue", "automated-test",
                     "**PR to review:** #3", "Single Responsibility", "Return one JSON object"):
            self.assertIn(text, prompt)
        self.assertTrue(prompt.endswith(self.diff))
        self.decision["fixed"]["high"] = ["source.zig:2 releases the previous allocation."]
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

    def test_inconclusive_current_review_withholds_merge_despite_stale_passing_comment(self):
        old_base = "c" * 40
        _, old_report = gate.verdict(json.dumps({**self.decision, "reviewed_base": old_base}), old_base, self.head, self.number)
        previous = gate.review_header(self.number, old_base, self.head) + old_report
        self.comments.append({"user": {"login": "github-actions[bot]"}, "body": previous})
        self.decision.update(recommendation="DO NOT MERGE",
                             verdict_reason="The prior concern involves a binary change with no supporting source diff.")
        self.response.write_text(json.dumps(self.decision))
        gate.publish(*self.target)
        self.assertEqual(self.states[-1], ("ai-merge-gate", "failure"))
        self.assertEqual(self.comments[0]["body"], previous)
        self.assertTrue(self.comments[1]["body"].startswith(gate.review_header(*self.target)))
        for comment, base in zip(self.comments, [old_base, self.base], strict=True):
            machine = json.loads(comment["body"].split("```json\n")[1].split("\n```")[0])
            self.assertEqual((machine["reviewed_sha"], machine["reviewed_base"]), (self.head, base))
        self.assertIn(self.decision["verdict_reason"], self.comments[1]["body"])

    def test_review_search_finds_later_pages_and_reports_caps(self):
        gate_entry = {"user": {"login": "github-actions[bot]"}, "body": gate.review_header(*self.target) + "Prior blocker"}
        formal_entry = {"user": {"login": "opencode-agent[bot]"}, "body": "Formal blocker"}
        for comment_count, formal_count, complete in [(75, 201, True), (125, 301, False)]:
            self.pr["comments"] = comment_count
            gate_page = (comment_count + 24) // 25 - 2

            def pages(path, **kwargs):
                if path.startswith("issues/3/comments?"):
                    return [gate_entry] if path.endswith(f"page={gate_page}") else [{}] * 25
                if path.startswith("pulls/3/reviews?"):
                    if path.endswith("&page=2"):
                        return [{**formal_entry, "body": "Older formal review"}]
                    if path.endswith("&page=3"):
                        return [formal_entry]
                    if path.endswith("&page=4"):
                        return [{}]
                    kwargs["pagination"]["last"] = (formal_count + 99) // 100
                    return [{}] * 100
                return self.github(path, **kwargs)

            with self.subTest(complete=complete), patch.object(gate.pr, "api", side_effect=pages):
                previous, context = gate.review_context(self.pr)
                self.assertEqual(previous, [gate_entry["body"]])
                self.assertEqual(context["formal_review_excerpts"][0]["body"], formal_entry["body"])
                coverage = context["history_coverage"]
                self.assertEqual(coverage["comment_search_complete"], complete)
                self.assertEqual(coverage["formal_body_search_complete"], complete)
                self.assertFalse(coverage["inline_review_comments_included"])

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

    def test_optional_requests_share_one_wall_clock_budget(self):
        self.pr.update(body="Fixes #1, fixes #2, fixes #3, fixes #4", comments=25)
        elapsed = 0
        def delayed(path, **kwargs):
            nonlocal elapsed
            if path.startswith("issues/"):
                elapsed += 8
                raise TimeoutError()
            return self.github(path, **kwargs)
        with patch("opencode_deadline.time.monotonic", side_effect=lambda: elapsed), \
                patch("opencode_deadline.signal.setitimer") as timer, patch.object(gate.pr, "api", side_effect=delayed):
            gate.prepare(*self.target)
        self.assertEqual([call.args[1] for call in timer.call_args_list if call.args[1]], [20, 12, 4])
        text = (self.root / "pr-input/request.txt").read_text()
        for path in ("issues/1", "issues/3/comments?", "pulls/3/reviews?"):
            self.assertIn(path, text.split('{"unavailable":')[1].splitlines()[0])
        self.assertTrue(text.endswith(self.diff))

    def test_long_formal_review_keeps_blocker_substance(self):
        finding = "**[HIGH]** `" + "path/" * 100 + "foo.zig:4` - Dangling pointer\n**Confidence:** High\n**Description:** Freed twice."
        excerpt = gate.review_excerpt("Summary. " * 1000 + "\n" + finding, 240)
        for part in ("HIGH:", "foo.zig:4", "Dangling pointer", "Freed twice."):
            self.assertIn(part, excerpt)

    def test_optional_context_cannot_displace_pinned_diff(self):
        for refs in (" " * 6000 + "Fixes #55", " ".join(f"fixes #{i}" for i in range(55, 60))):
            with patch.object(gate.pr, "api", return_value=[]):
                self.assertTrue(gate.review_context({**self.pr, "body": refs})[1]["history_coverage"]["linked_issues_partial"])
        self.pr.update(body="界" * 6000, comments=1)
        self.comments.append({"user": {"login": "github-actions[bot]"},
                              "body": gate.review_header(self.number, self.base, self.head) + "summary" * 900
                              + "\n**High (1)**\n<pre>• source.zig:10: stale handle used after free</pre>"})
        diff = self.diff.rstrip("\n") + ("d" * (gate.pr.INPUT_LIMIT - len(gate.PROMPT.read_bytes()) - 1100)) + "\n"
        with patch.object(gate, "pinned_diff", return_value=(diff, 1)):
            gate.prepare(*self.target)
        text = (self.root / "pr-input/request.txt").read_text()
        self.assertTrue(text.endswith(diff))
        self.assertLessEqual(len(text.encode()), gate.pr.INPUT_LIMIT)
        self.assertNotIn(self.pr["body"], text)
        self.assertIn("source.zig:10: stale handle used after free", text)
        self.assertIn("[Partial previous review: details truncated]", text)

    def test_documented_diff_budget_and_previous_verdict_only_boundary(self):
        header = "diff --git a/t b/t\n--- a/t\n+++ b/t\n@@ -0,0 +1 @@\n+"
        old_limit = gate.pr.INPUT_LIMIT - 1088 - len(f"\nBase SHA: {self.base}\nHead SHA: {self.head}\n\nUntrusted diff:\n")
        for size in (89 * 1024, 94 * 1024, old_limit, gate.pr.INPUT_LIMIT):
            diff = header + "x" * (size - len(header) - 1) + "\n"
            with tempfile.TemporaryDirectory() as runner, patch.dict(os.environ, RUNNER_TEMP=runner), \
                    patch.object(gate, "pinned_diff", return_value=(diff, 1)):
                request = Path(runner) / "pr-input/request.txt"
                if size <= old_limit:
                    gate.prepare(*self.target)
                    self.assertTrue(request.read_text().endswith(diff))
                    self.assertLessEqual(request.stat().st_size, gate.pr.INPUT_LIMIT)
                    self.assertEqual(request.read_text().startswith(gate.COMPACT_PROMPT), size > 89 * 1024)
                    if size > 89 * 1024:
                        self.assertIn("Withhold MERGE for binary/gitlink", request.read_text())
                        self.assertIn("Untrusted context", request.read_text())
                        self.assertIn("max 12 verified fix notes each", request.read_text())
                        self.assertIn("locations <=384 UTF-8 bytes after HTML escaping", request.read_text())
                else:
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
        expected = prefix + "Prior gate history: omitted\nFormal review history: omitted\n" + diff
        with tempfile.TemporaryDirectory() as runner, patch.dict(os.environ, RUNNER_TEMP=runner), \
                patch.object(gate.pr, "INPUT_LIMIT", len(expected.encode())):
            gate.prepare(*self.target)
            self.assertEqual((Path(runner) / "pr-input/request.txt").read_text(), expected)

    def test_formal_excerpts_shrink_individually_and_report_omission(self):
        entries = [{"head": self.head, "body": "Newest concern. " * 500},
                   {"head": self.base, "body": "Older concern. " * 500}]
        fields, remaining, status = gate.pack_history(entries, "previous_formal_review", 550, True)
        self.assertEqual(len(fields), 1)
        newest = json.loads(fields[0])["previous_formal_review"]
        self.assertEqual(newest["head"], self.head)
        self.assertIn("Newest concern", newest["excerpt"])
        self.assertIn("truncated", newest["excerpt"])
        self.assertEqual(remaining + len(fields[0].encode()), 550)
        self.assertEqual(status, "partial")

    def test_status_writers_and_legacy_comment_parser_cutover(self):
        # Check actual context writers too, including workflows which inherit
        # repository-default permissions instead of requesting statuses:write.
        owners = subprocess.check_output(["git", "grep", "-lF", "ai-merge-gate", "--",
                                          ".github/actions", ".github/workflows", "scripts", ":!scripts/tests"],
                                         cwd=ROOT, text=True).splitlines()
        self.assertEqual(owners, ["scripts/opencode_pr_gate.py"])
        # Ruby/Psych is the workflow YAML parser used by workflow-validation.
        listing = subprocess.check_output(["ruby", "-ryaml", "-rjson", "-e", """
          jobs = {}
          Dir['.github/workflows/*.{yml,yaml}'].each do |file|
            workflow = YAML.load_file(file)
            workflow.fetch('jobs').each do |name, job|
              perms = job.fetch('permissions', workflow['permissions'])
              if perms == 'write-all' || (perms.is_a?(Hash) && perms['statuses'] == 'write')
                jobs[File.basename(file) + ':' + name] = job['steps']
              end
            end
          end
          puts JSON.generate(jobs)
        """], cwd=ROOT, text=True)
        jobs = json.loads(listing)
        self.assertEqual(set(jobs), {"opencode-pr.yml:prepare", "opencode-pr.yml:publish", "benchmark.yml:benchmark"})
        benchmark = json.dumps(jobs["benchmark.yml:benchmark"])
        self.assertIn("context: 'performance/benchmark'", benchmark)
        self.assertNotIn("ai-merge-gate", benchmark)
        publish = jobs["opencode-pr.yml:publish"]
        self.assertTrue(any(s.get("with", {}).get("name") == "${{ needs.infer.outputs.response-artifact }}" for s in publish))
        self.assertIn("python3 -I scripts/opencode_pr_gate.py publish", [s.get("run") for s in publish])
        for retired in ("evaluate_ai_merge_gate.sh", "publish_ai_merge_gate.sh"):
            self.assertFalse((ROOT / "scripts" / retired).exists())
            self.assertNotIn(retired, listing)

    def test_large_report_preserves_all_findings_and_verdict(self):
        item = {**self.finding, "impact": "`" * 1000, "description": "&" * 1000}
        locations = ["`" * 70 + f".zig:{line}" for line in range(1, 13)]
        self.decision.update(low=[{**item, "location": location} for location in locations], test_status="passed")
        raw = json.dumps(self.decision)
        self.assertLess(len(raw.encode()), gate.pr.OUTPUT_LIMIT)
        passed, report = gate.verdict(raw, self.base, self.head, self.number)
        self.assertTrue(passed)  # Test status is informational, independent CI enforces test results.
        self.assertIn("abbreviated", report)
        self.assertLess(len(report.encode()), 65000)
        self.assertEqual(report.count("<strong>[LOW]</strong>"), 12)
        gate.review_comment(*self.target, report)
        self.assertLessEqual(len(self.comments[0]["body"].encode()), 65536)
        for location in locations:
            self.assertIn(f"<code>{gate.pr.escape_text(location)}</code>", report)
        self.assertIn("- [ ] Tests present and passing (unverified", report)
        machine = json.loads(report.split("```json\n")[1].split("\n```")[0])
        self.assertEqual(machine["recommendation"], "MERGE")

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
