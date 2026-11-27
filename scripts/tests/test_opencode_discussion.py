"""Offline event-to-publication fixtures; no token or private service required."""

import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import opencode_discussion as discussion


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
        return request.decode()

    def response(self, value):
        folder = self.temp / "discussion-response"
        folder.mkdir(exist_ok=True)
        (folder / "response.txt").write_text(json.dumps(value))

    def test_response_only_deduplicates(self):
        self.prepare()
        self.response({"before": "x", "after": "y"})
        with self.assertRaises(ValueError):
            discussion.run("respond")
        self.response({"comment": "Look at the source. @someone ```json\n{}\n```</pre>![remote](https://example.org)"})
        discussion.run("respond")
        with self.assertRaises(discussion.Skip):
            discussion.run("respond")
        self.assertEqual([w[0] for w in self.writes], ["issues/1/comments"])
        body = self.writes[0][1]["body"]
        for forbidden in ["```", "@someone", "</pre>!"]:
            self.assertNotIn(forbidden, body)

    def test_old_account_triage(self):
        os.environ["GITHUB_EVENT_NAME"] = "issues"
        request = self.prepare()
        self.assertIn(Path(".github/prompts/triage.md").read_text(), request)
        self.assertIn('{"skip":true}', request)
        self.assertIn('{"comment":', request)
        self.response({"skip": True})
        with self.assertRaises(discussion.Skip):
            discussion.run("respond")
        self.response({"comment": "Please provide reproduction steps."})
        discussion.run("respond")
        with self.assertRaises(discussion.Skip):
            discussion.run("respond")
        self.assertEqual([w[0] for w in self.writes], ["issues/1/comments"])

    def test_audit_triage_supplies_related_issues_and_prs(self):
        os.environ["GITHUB_EVENT_NAME"] = "issues"
        self.issue["labels"] = [{"name": "automated-audit"}]
        url = discussion.API + discussion.ROOT
        items = [dict(title="Self", number=1, state="open", repository_url=url),
                 dict(title="Related fix", number=8, state="open", repository_url=url, pull_request={}),
                 dict(title="Unrelated repo", number=9, state="closed", repository_url=url + "-other")]
        discussion.api.return_value = {"items": items}
        request = self.prepare()
        self.assertIn('"title": "Related fix", "type": "pull request"', request)
        self.assertNotIn('"title": "Self"', request)
        self.assertNotIn("Unrelated repo", request)
        discussion.api.assert_called_once_with(
            "/search/issues?q=repo%3AOpenStaticFish%2FZigCraft+in%3Atitle+Update+the+fixture&per_page=6")

    def test_inline_command_retains_context_and_authorization(self):
        self.comment["body"] = "About this issue: /opencode what does the code do?"
        request = self.prepare()
        self.assertIn(r'"instruction": "About this issue:\nwhat does the code do?"', request)
        self.reads["collaborators/author/permission"]["permission"] = "read"
        with self.assertRaises(discussion.Skip):
            discussion.run("respond")

    def test_command_requires_standalone_token(self):
        for body in ["Read ./oc", "look at https://host/oc x", "/october soon", "/opencode"]:
            with self.subTest(body=body), self.assertRaises(discussion.Skip):
                discussion.command(body)
        self.assertEqual(discussion.command("Explain this /oc"), ("respond", "", "Explain this"))

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
