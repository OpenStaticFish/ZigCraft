"""Offline event-to-publication fixtures; no token or private service required."""

import base64
from http.client import IncompleteRead
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import opencode_discussion as discussion
from opencode_deadline import lookup_budget
from test_opencode_prose import MARKUP, live_gfm, render_gfm


class DiscussionFixture(unittest.TestCase):
    def setUp(self):
        self.temp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.enterContext(patch.dict(os.environ, {
            "RUNNER_TEMP": str(self.temp), "GITHUB_OUTPUT": str(self.temp / "output"),
            "GITHUB_EVENT_PATH": str(self.temp / "event"), "GITHUB_REPOSITORY": discussion.REPO,
            "GITHUB_SHA": "a" * 40, "GITHUB_REF": "refs/heads/dev", "GITHUB_EVENT_NAME": "issue_comment",
            "GITHUB_RUN_ID": "11", "GITHUB_RUN_ATTEMPT": "2", "APP_SLUG": "fixture",
        }))
        self.issue = dict(id=1, number=1, state="open", title="Update the fixture", body="Details",
                          labels=[], user={"login": "author"})
        self.comment = dict(id=2, body="/oc explain the fixture", user={"login": "author", "id": 3, "type": "User"},
                            issue_url=f"{discussion.API}{discussion.ROOT}/issues/1")
        self.file = "src/example.zig"
        self.original = b"const x = 1;\n"
        self.reads = {
            "issues/1": self.issue, "git/ref/heads/dev": {"object": {"sha": "a" * 40}},
            "issues/comments/2": self.comment, "collaborators/author/permission": {"permission": "write"},
            "issues/1/comments?per_page=50&page=1": [],
            "pulls?state=all&head=OpenStaticFish%3Afeature%2Fopencode-comment-2": [],
            f"git/trees/{'a'*40}?recursive=1": {"truncated": False, "tree": [
                {"type": "blob", "mode": "100644", "path": self.file, "sha": "blob", "size": len(self.original)}
            ]},
            "git/blobs/blob": {"encoding": "base64", "content": base64.b64encode(self.original).decode()},
            f"git/commits/{'a'*40}": {"tree": {"sha": "base-tree"}},
            f"commits/{'a'*40}?per_page=30": {"sha": "a"*40, "commit": {"message": "fixture change"}, "files": []},
            "issues/1/timeline?per_page=100": [],
            f"actions/runs?head_sha={'a'*40}&per_page=30": {"workflow_runs": []},
        }
        self.writes = []
        self.enterContext(patch.object(discussion, "repo", side_effect=self.repo))
        self.enterContext(patch.object(discussion, "api", return_value={"created_at": "2020-01-01T00:00:00Z", "id": 123}))

    def repo(self, path, data=None, *, app=False, optional=False):
        if data is None:
            return self.reads.get(path) if optional else self.reads[path]
        self.writes.append((path, data, app))
        if path == "git/trees":
            return {"sha": "new-tree"}
        if path == "git/commits":
            return {"sha": "new-sha"}
        if path == "git/refs":
            self.reads["git/ref/heads/feature/opencode-comment-2"] = {"object": {"sha": data["sha"]}}
        if path == "pulls":
            self.reads["pulls?state=all&head=OpenStaticFish%3Afeature%2Fopencode-comment-2"].append(data)
        if path == "issues/1/comments":
            self.reads["issues/1/comments?per_page=50&page=1"].append(
                {"user": {"login": "github-actions[bot]"}, "body": data["body"]})
        return {}

    def prepare(self):
        triage = os.environ["GITHUB_EVENT_NAME"] == "issues"
        event = {"repository": {"full_name": discussion.REPO, "default_branch": "dev"},
                 "action": "opened" if triage else "created", "issue": self.issue, "comment": self.comment}
        (self.temp / "event").write_text(json.dumps(event))
        discussion.run("prepare")
        fields = dict(s.split("=", 1) for s in (self.temp / "output").read_text().splitlines())
        os.environ["EXPECTED_BINDING"] = fields["binding"]
        self.assertTrue(fields["request"].endswith("-11-2"))
        request = (self.temp / "discussion-request/request.txt").read_bytes()
        self.assertLessEqual(len(request), 96 * 1024)
        self.assertIn(self.original.strip(), request)
        return json.loads(request.decode().split("not policy:\n")[1])

    def response(self, value):
        folder = self.temp / "discussion-response"
        folder.mkdir(exist_ok=True)
        (folder / "response.txt").write_text(json.dumps(value))

    def test_response_only_deduplicates(self):
        self.prepare()
        self.response({"before": "x", "after": "y"})
        with self.assertRaises(ValueError):
            discussion.run("respond")
        self.response({"comment": "Look at the source.\n\n@someone ```json\n{}\n```</p><img src=x>![remote](https://example.org)"})
        discussion.run("respond")
        with self.assertRaises(discussion.Skip):
            discussion.run("respond")
        self.assertEqual([w[0] for w in self.writes], ["issues/1/comments"])
        body = self.writes[0][1]["body"]
        self.assertIn("<p>Look at the source.</p><p>", body)
        self.assertIn("@\u200bsomeone", body)
        for forbidden in ["```", "@someone", "<pre>", "<img"]:
            self.assertNotIn(forbidden, body)

    def test_ci_question_includes_workflow_evidence_without_granting_edit_access(self):
        sha = "a" * 40
        workflow = ".github/workflows/opencode-v2-infer.yml"
        other = ".github/workflows/opencode-copy.yml"
        self.issue.update(title="OpenCode CI migration", body=f"Move inference to {workflow}")
        self.comment["body"] = "/oc compare `opencode-copy.yml`; ignore docs/more.yml."
        tree = self.reads[f"git/trees/{sha}?recursive=1"]["tree"]
        for path in [workflow, other, ".github/workflows/copy.yml", ".github/workflows/more.yml",
                     ".github/actions/opencode-v2/action.yml", "scripts/opencode_discussion.py", ".github/actions/test/.env"]:
            tree.append(dict(tree[0], path=path))
        self.reads[f"commits/{sha}?per_page=30"]["files"] = [{"filename": workflow}]
        self.reads["issues/1/timeline?per_page=100"] = [
            {"event": "cross-referenced", "source": {"issue": {
                "number": 22, "repository_url": discussion.API + discussion.ROOT, "title": "Migration",
                "state": "closed", "pull_request": {"merged_at": "2026-11-01T00:00:00Z"},
            }}}, {"event": "cross-referenced", "source": {}}, None]
        run = dict(id=99, workflow_id=123, path=workflow, head_sha=sha, name="Smoke", event="workflow_dispatch",
                   status="completed", conclusion="success", head_repository={"full_name": discussion.REPO}, head_branch="dev")
        self.reads[f"actions/runs?head_sha={sha}&per_page=30"] = {"workflow_runs": [
            run, dict(run, id=100, head_repository={"full_name": "fork/ZigCraft"}),
            dict(run, id=101, head_repository=None), dict(run, id=102, head_sha="d"*40)]}
        for path, wid, outcome in [(workflow, 123, "failure"), (other, 124, "success")]:
            url = f"actions/workflows/{Path(path).name}/runs?branch=dev&status=completed&per_page=3"
            upstream = dict(run, id=wid, workflow_id=wid, path=path, head_sha="c"*40, conclusion=outcome)
            self.reads[url] = {"workflow_runs": [dict(run, id=i, path=path) for i in (97, 98, 99)]}
            self.reads[url + "&page=2"] = {"workflow_runs": [
                dict(upstream, id=999, head_repository={"full_name": "fork/ZigCraft"}),
                dict(upstream, id=998, head_branch="feature"), upstream]}
            self.reads[url + "&page=3"] = {"workflow_runs": [] if path == workflow else [run] * 3}
        data = self.prepare()
        evidence = data["github"]
        self.assertCountEqual(list(data["files"])[:2], [workflow, other])
        queried = [c.args[0].split("/")[2] for c in discussion.repo.call_args_list if c.args[0].startswith("actions/workflows/")]
        self.assertCountEqual(queried, [Path(workflow).name, Path(other).name] * 3)
        self.assertNotIn(".github/actions/test/.env", data["files"])
        self.assertEqual(evidence["revision_commit"]["data"]["changed_paths_first_30"], [workflow])
        linked = evidence["cross_referenced_prs_sample"]
        self.assertEqual(linked["data"][0]["number"], 22)
        self.assertEqual(linked["status"], "partial")
        origins = evidence["workflow_runs_at_revision_sample"]["data"]
        self.assertEqual({k: [r["id"] for r in rows] for k, rows in origins.items()},
                         {"upstream": [99], "fork": [100], "unknown": [101]})
        history_sample = evidence["recent_completed_dev_runs_at_other_revisions"]
        self.assertEqual(history_sample["partial_paths"], [other])
        self.assertEqual(history_sample["status"], "partial")
        history = history_sample["data"]
        self.assertEqual(history[0]["revision"], "c"*40)
        self.assertCountEqual([(r["workflow_id"], r["path"], r["queried_path"], r["conclusion"])
                               for r in history],
                         [(123, workflow, workflow, "failure"), (124, other, other, "success")])
        with self.assertRaises(discussion.Skip):
            discussion.command(f"/oc edit {workflow} update this")

    def test_old_account_triage(self):
        os.environ["GITHUB_EVENT_NAME"] = "issues"
        self.issue.update(title="Flickering terrain", body="Flickers while walking")
        tree = self.reads[f"git/trees/{'a'*40}?recursive=1"]["tree"]
        tree.append(dict(tree[0], path=".github/workflows/ci.yml"))
        self.assertEqual(list(self.prepare()["files"]), [self.file])
        self.response({"skip": True})
        with self.assertRaises(discussion.Skip):
            discussion.run("respond")
        self.response({"comment": "Please provide reproduction steps."})
        discussion.run("respond")
        with self.assertRaises(discussion.Skip):
            discussion.run("respond")
        self.assertEqual([w[0] for w in self.writes], ["issues/1/comments"])

    def test_triage_can_read_but_not_edit_readme(self):
        os.environ["GITHUB_EVENT_NAME"] = "issues"
        self.issue.update(title="README.md build instructions", body="The documented build fails")
        tree = self.reads[f"git/trees/{'a'*40}?recursive=1"]["tree"]
        tree.append(dict(tree[0], path="README.md"))
        self.assertEqual(next(iter(self.prepare()["files"])), "README.md")
        with self.assertRaises(discussion.Skip):
            discussion.command("/oc edit README.md change the build instructions")

    def test_timeline_second_page_and_cap(self):
        url = "issues/1/timeline?per_page=100"
        self.reads[url] = [{"event": "commented"}] * 100
        pr = {"number": 21, "repository_url": discussion.API + discussion.ROOT, "title": "Linked",
              "state": "open", "pull_request": {"merged_at": None}}
        self.reads[url + "&page=2"] = [{"event": "cross-referenced", "source": {"issue": pr}}]
        for count, partial in [(1, False), (100, True)]:
            self.reads[url + "&page=2"] += [{"event": "commented"}] * (count - 1)
            data = discussion.github_evidence({"head": "a" * 40, "number": 1}, [])
            linked = data["cross_referenced_prs_sample"]
            self.assertEqual([row["number"] for row in linked["data"]], [21])
            self.assertEqual(linked["status"], "partial" if partial else "sampled")

    def test_unavailable_actions_metadata_does_not_block_source_answer(self):
        sha = "a" * 40
        self.reads[f"commits/{sha}?per_page=30"]["commit"]["message"] = ""
        self.reads[f"git/trees/{sha}?recursive=1"]["tree"][0]["mode"] = "100755"

        def unavailable(path, *args, **kwargs):
            if path.startswith("actions/runs?"):
                raise IncompleteRead(b"partial response")
            return self.repo(path, *args, **kwargs)

        discussion.repo.side_effect = unavailable
        evidence = self.prepare()["github"]
        self.assertEqual(evidence["workflow_runs_at_revision_sample"], {"status": "unavailable"})
        self.assertEqual(evidence["revision_commit"]["data"]["subject"], "")

    def test_expired_optional_budget_still_supplies_source(self):
        with patch("opencode_deadline.time.monotonic", side_effect=[0, 1, 16, 17]):
            self.prepare()
        paths = [call.args[0] for call in discussion.repo.call_args_list if call.kwargs.get("optional")]
        self.assertFalse(any(path.startswith(("actions/runs?", "issues/1/timeline?")) for path in paths))

    def test_running_optional_lookup_is_interrupted(self):
        # A broken alarm must not hang the test runner.
        subprocess.run([sys.executable, "-B", "-m", "unittest", "test_opencode_discussion.DiscussionFixture.stalled_lookup",
                        "test_opencode_discussion.DiscussionFixture.stalled_parser"],
                       cwd=Path(__file__).parent, check=True, timeout=5, capture_output=True)

    def stalled_lookup(self):
        interrupted = []

        def block(path, *args, **kwargs):
            if path.startswith("commits/") and kwargs.get("optional"):
                interrupted.append(path)
                signal.pause()
            return self.repo(path, *args, **kwargs)

        handler = signal.getsignal(signal.SIGALRM)
        discussion.repo.side_effect = block
        with patch.object(discussion, "lookup_budget", side_effect=lambda _: lookup_budget(0.1)):
            data = self.prepare()
        self.assertEqual(interrupted, [f"commits/{data['revision']}?per_page=30"])
        self.assertEqual(data["github"]["revision_commit"], {"status": "unavailable"})
        self.assertEqual(data["files"][self.file], self.original.decode())
        self.assertEqual(signal.getsignal(signal.SIGALRM), handler)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0, 0))

    def stalled_parser(self):
        handler = signal.getsignal(signal.SIGALRM)
        with patch.object(discussion, "lookup_budget", side_effect=lambda _: lookup_budget(0.1)), \
                patch.object(discussion, "run_summaries", side_effect=lambda _: signal.pause()) as parser:
            data = self.prepare()
        parser.assert_called_once()
        self.assertEqual(data["github"]["workflow_runs_at_revision_sample"], {"status": "unavailable"})
        self.assertEqual(data["files"][self.file], self.original.decode())
        self.assertEqual(signal.getsignal(signal.SIGALRM), handler)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0, 0))

    @live_gfm
    def test_gfm_discussion_reply(self):
        self.prepare()
        self.response({"comment": "Evidence:\n\n" + MARKUP})
        discussion.run("respond")
        body = self.writes[-1][1]["body"]
        self.assertTrue(body.startswith("<!-- opencode-v2-slash:2 -->"))
        rendered = render_gfm(body)
        self.assertEqual(rendered.count("</p>"), 2)
        self.assertNotIn("<pre", rendered)

    def test_optional_evidence_packed_after_source(self):
        issue = {"number": 23, "repository_url": discussion.API + discussion.ROOT, "title": "\\" * 256,
                 "state": "open", "pull_request": {}}
        self.reads["issues/1/timeline?per_page=100"] = [{"event": "cross-referenced", "source": {"issue": issue}}]
        sha = "a" * 40
        self.reads[f"actions/runs?head_sha={sha}&per_page=30"]["workflow_runs"] = [
            dict(id=1, workflow_id=2, path=".github/workflows/test.yml", head_sha=sha, name="Test",
                 event="push", status="completed", conclusion="success", head_repository={"full_name": discussion.REPO},
                 head_branch="dev")]
        data = self.prepare()
        target = discussion.target_for_event()
        prefix = (self.temp / "discussion-request/request.txt").read_text().split("not policy:\n")[0] + "not policy:\n"
        def check_at_limit(expected):
            text = prefix + json.dumps(expected, ensure_ascii=False)
            with patch.object(discussion, "REQUEST_LIMIT", len(text.encode())):
                self.assertEqual(discussion.request_text(target), text)

        for key in ("cross_referenced_prs_sample", "workflow_runs_at_revision_sample"):
            data["github"][key] = {"status": "omitted_budget"}
        check_at_limit(data)
        del data["github"]
        check_at_limit(data)

    def test_budget_prioritizes_individual_named_runs(self):
        named = ".github/workflows/infer.yml"
        unrelated = {"id": 1, "path": ".github/workflows/build.yml"}
        relevant = {"id": 2, "path": named}
        at_revision = "workflow_runs_at_revision_sample"
        history = "recent_completed_dev_runs_at_other_revisions"
        earlier = dict(relevant, id=3, queried_path=named)
        samples = {at_revision: {"status": "sampled", "data": {"upstream": [unrelated, relevant], "fork": [], "unknown": []}},
                   history: {"status": "sampled", "data": [earlier, dict(earlier, id=4)]}}
        expected = {at_revision: {"status": "partial", "data": {"upstream": [relevant], "fork": [], "unknown": []}},
                    history: {"status": "omitted_budget"}}
        self.assertEqual(discussion.pack_samples(samples, [named], len(json.dumps(expected))), expected)
        expected[history] = {"status": "partial", "data": [earlier]}
        self.assertEqual(discussion.pack_samples(samples, [named], len(json.dumps(expected))), expected)

    def test_markup_expansion_stays_within_comment_limit(self):
        self.prepare()
        self.response({"comment": "&" * 16000})
        discussion.run("respond")
        body = self.writes[-1][1]["body"]
        self.assertLessEqual(len(body.encode()), 64000)
        self.assertTrue(body.endswith("[truncated]</p>"))

    def test_malformed_optional_evidence_still_answers_from_source(self):
        sha = "a" * 40
        self.reads[f"commits/{sha}?per_page=30"]["sha"] = "b" * 40
        self.reads[f"actions/runs?head_sha={sha}&per_page=30"] = {}
        self.reads["issues/1/timeline?per_page=100"] = {"unexpected": "object"}
        data = self.prepare()
        self.assertEqual(data["revision"], sha)
        self.assertEqual(data["files"][self.file], self.original.decode())
        self.assertEqual({k for k, sample in data["github"].items() if sample["status"] == "unavailable"},
                         {"revision_commit", "workflow_runs_at_revision_sample", "cross_referenced_prs_sample"})

    def test_young_account_skips_before_preparation(self):
        os.environ["GITHUB_EVENT_NAME"] = "issues"
        discussion.api.return_value = {"created_at": "2090-01-01T00:00:00Z"}
        with self.assertRaises(discussion.Skip):
            self.prepare()
        self.assertFalse((self.temp / "discussion-request").exists())

    def test_authorized_edit_opens_only_feature_pr_against_dev(self):
        self.comment["body"] = f"/oc edit {self.file} change x to 2"
        self.prepare()
        self.response({"before": "x = 1", "after": "x = 2"})
        discussion.run("validate-edit")
        self.assertEqual(self.writes, [])
        discussion.run("edit")
        self.assertTrue(all(w[2] for w in self.writes))
        tree, commit, ref, pr = [w[1] for w in self.writes]
        self.assertEqual(tree["tree"], [{"path": self.file, "mode": "100644", "type": "blob",
                                         "content": "const x = 2;\n"}])
        self.assertIn("Signed-off-by: fixture[bot]", commit["message"])
        self.assertEqual(ref["ref"], "refs/heads/feature/opencode-comment-2")
        self.assertEqual((pr["base"], pr["head"]), ("dev", "feature/opencode-comment-2"))
        with self.assertRaises(discussion.Skip):
            discussion.run("edit")

    def test_permissions_rechecked(self):
        self.prepare()
        self.reads["collaborators/author/permission"]["permission"] = "read"
        self.response({"comment": "stale"})
        with self.assertRaises(discussion.Skip):
            discussion.run("respond")
        self.assertEqual(self.writes, [])

    def test_fork_skips_before_preparation(self):
        self.issue["pull_request"] = {}
        self.reads["pulls/1"] = {"state": "open", "head": {"repo": {"full_name": "fork/ZigCraft"}}}
        with self.assertRaises(discussion.Skip):
            self.prepare()
        self.assertFalse((self.temp / "discussion-request").exists())

    def test_stale_dev_skips_publication(self):
        self.prepare()
        self.reads["git/ref/heads/dev"]["object"]["sha"] = "b" * 40
        self.response({"comment": "stale"})
        with self.assertRaises(discussion.Skip):
            discussion.run("respond")
        self.assertEqual(self.writes, [])

    def test_stale_same_repo_head_skips_publication(self):
        base = self.reads["git/ref/heads/dev"]["object"]["sha"]
        self.issue["pull_request"] = {}
        self.reads["pulls/1"] = {"state": "open", "base": {"repo": {"full_name": discussion.REPO},
                                "ref": "dev", "sha": base}, "head": {"repo": {"full_name": discussion.REPO},
                                "ref": "feature/fixture", "sha": base}}
        self.prepare()
        self.reads["pulls/1"]["head"]["sha"] = "c" * 40
        self.response({"comment": "stale"})
        with self.assertRaises(discussion.Skip):
            discussion.run("respond")
        self.assertEqual(self.writes, [])

    def test_edit_rejects_symlink(self):
        self.reads[f"git/trees/{'a'*40}?recursive=1"]["tree"][0]["mode"] = "120000"
        self.comment["body"] = f"/oc edit {self.file} change a word"
        with self.assertRaises(discussion.Skip):
            self.prepare()
        self.assertFalse((self.temp / "discussion-request").exists())

    def test_edited_comment_skips_publication(self):
        self.prepare()
        self.comment["body"] = "/oc edit src/example.zig overwrite this"
        self.response({"comment": "stale"})
        with self.assertRaises(discussion.Skip):
            discussion.run("respond")
        self.assertEqual(self.writes, [])

    def test_forbidden_paths_and_patch(self):
        for path in ["../escape", ".github/workflows/lint.yml", "modules/a/src/../build.zig",
                     "build.zig", "docs/.config/x.md", "src/x.zig;touch", "/src/a.zig"]:
            with self.subTest(path=path), self.assertRaises(discussion.Skip):
                discussion.command("/oc edit " + path + " change it")
        for patch in [{"before": "missing", "after": "new"}, {"before": "x", "after": "x"},
                      {"before": "x", "after": "\x00"}, {"before": "x", "after": "a" * 8193}]:
            with self.assertRaises(ValueError):
                discussion.apply_patch("abc x", patch)


if __name__ == "__main__":
    unittest.main()
