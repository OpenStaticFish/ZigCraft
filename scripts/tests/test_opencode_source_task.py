import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import opencode_source_task as task


class SourceTaskTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.addCleanup(os.chdir, Path.cwd())
        os.chdir(temp.name)
        self.folder = Path("response")
        self.folder.mkdir()
        self.result = self.folder / "response.txt"
        self.target = Path("src/tests.zig")
        self.target.parent.mkdir()
        self.target.write_text('const std = @import("std");\n')
        Path("src/module.zig").write_text("pub const demo = 1;\n")
        Path("src/module_tests.zig").write_text('const module = @import("module.zig");\n')
        Path("src/link.zig").symlink_to("module.zig")
        for filename in (".github/prompts/audit.md", ".github/prompts/test-writer.md",
                         ".agents/skills/test-writer/SKILL.md"):
            path = Path(filename)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((SCRIPTS.parent / path).read_bytes())
        for args in (("init", "-q"), ("add", "."),
                     ("-c", "user.name=Fixture", "-c", "user.email=fixture@example.org",
                      "commit", "-qm", "fixture")):
            subprocess.run(["git", *args], check=True)
        env = patch.dict(os.environ, {
            "MODULE": "fixture", "SCAN_PATHS": "src",
            "GITHUB_SHA": task.git("rev-parse", "HEAD").decode().strip(),
            "RUNNER_TEMP": temp.name, "GITHUB_OUTPUT": "outputs",
            "GITHUB_REPOSITORY": "OpenStaticFish/ZigCraft", "GITHUB_RUN_ID": "7",
        })
        env.start()
        self.addCleanup(env.stop)

    def test_snapshot_uses_only_committed_regular_source(self):
        Path("src/module.zig").write_text("uncommitted changes")
        data, request = task.snapshot("audit")
        self.assertLessEqual(len(request), 96 * 1024)
        sources = {entry["path"]: entry["source"] for entry in data["files"]}
        self.assertEqual(sources["src/module.zig"], "pub const demo = 1;\n")
        self.assertNotIn("src/link.zig", sources)

    def test_historical_prompts_have_resolved_task_scope_and_publisher_contracts(self):
        Path("open_prs.json").write_text(json.dumps([{"number": 19, "title": "Scope fix"}]))
        data, request = task.snapshot("audit")
        self.assertEqual(data["open_prs"], [{"number": 19, "title": "Scope fix"}])
        for term in ("Concurrency Bugs", '`src/`', '{"finding":null}', '"criteria"', "source-index.txt"):
            self.assertIn(term, request.decode())
        self.assertNotIn(b"$MODULE_PATH", request)
        self.assertNotIn(b"src/{module}", request)
        with patch.dict(os.environ, SCAN_PATHS="src/module.zig"):
            data, request = task.snapshot("test-writer")
        self.assertLessEqual(len(request), 96 * 1024)
        self.assertEqual(data["test_target"], "src/module_tests.zig")
        for term in ("for `fixture`, targeting `dev`", "- `src/module.zig`", "Untested public functions",
                     "GPU crash paths", "REQUIRED SELF-REVIEW", '{"tests":[]}', '"protects"', '"gaps"'):
            self.assertIn(term, request.decode())
        for token in (b"$MODULE", b"$DEFAULT_BRANCH", b"$SCAN_PATHS"):
            self.assertNotIn(token, request)

    def test_finding_must_cite_an_actual_line_and_has_stable_marker(self):
        finding = dict(path="src/module.zig", line=1, scope="demo", priority="Medium",
                       title="Demo mismatch", impact="Observed symptom", fix="Fix demo", summary="Evidence",
                       criteria=["Check demo", "Pass tests", "Verify result"])
        self.result.write_text(json.dumps({"finding": finding}))
        task.audit(self.folder)
        issue = json.loads(Path("audit-issue.json").read_text())
        self.assertIn("opencode-audit-run:7", issue["body"])
        self.assertIn("src/module.zig#L1", issue["body"])
        self.assertIn("```zig\npub const demo = 1;\n```", issue["body"])
        self.assertIn("- [ ] Verify result", issue["body"])
        marker = Path("outputs").read_text().splitlines()[0]
        finding["title"] = "Reworded"
        self.result.write_text(json.dumps({"finding": finding}))
        task.audit(self.folder)
        self.assertEqual(Path("outputs").read_text().count(marker), 2)
        finding["line"] = 2
        self.result.write_text(json.dumps({"finding": finding}))
        with self.assertRaises(ValueError):
            task.audit(self.folder)
        finding.update(path="src/link.zig", line=1)
        self.result.write_text(json.dumps({"finding": finding}))
        with self.assertRaises(ValueError):
            task.audit(self.folder)
        finding["path"] = "src/tests.zig"
        self.result.write_text(json.dumps({"finding": finding}))
        with patch.dict(os.environ, SCAN_PATHS="src/module.zig"), self.assertRaises(ValueError):
            task.audit(self.folder)

    def test_zero_results_skip_publication(self):
        self.result.write_text('{"finding":null}')
        task.audit(self.folder)
        self.result.write_text('{"tests":[]}')
        task.apply_tests(self.folder)
        self.assertEqual(Path("outputs").read_text(), "found=false\nchanged=false\n")
        self.assertFalse(Path("audit-issue.json").exists())

    def test_audit_cites_complete_pinned_file_read_through_tools(self):
        path = Path("src/large.zig")
        path.write_text("// A source line\n" * 1000 + "pub const source_evidence = 1;\n")
        task.git("add", "--", str(path))
        task.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.org",
                 "commit", "-qm", "large source")
        finding = dict(path=str(path), line=1001, scope="source_evidence", priority="Low", title="Example",
                       summary="Example summary", impact="Observed symptom", fix="Correct the value",
                       criteria=["Review value", "Pass tests", "Check fixture"])
        self.result.write_text(json.dumps({"finding": finding}))
        with patch.dict(os.environ, GITHUB_SHA=task.git("rev-parse", "HEAD").decode().strip(),
                        SCAN_PATHS=str(path)):
            _, request = task.snapshot("audit")
            self.assertNotIn(b"pub const source_evidence", request)
            path.write_text("// uncommitted local content\n")
            task.audit(self.folder)
        issue = json.loads(Path("audit-issue.json").read_text())
        self.assertIn("pub const source_evidence = 1;", issue["body"])
        self.assertNotIn("uncommitted local content", issue["body"])

    def proposal(self):
        return {"tests": [{"name": f"check production case {i}",
                           "protects": f"Verify production case {i}",
                           "body": f'    try std.testing.expectEqual({i}, Example.get({i}));'}
                          for i in range(3)], "gaps": "GPU integration requires a device."}

    def test_fixed_target_append_only(self):
        proposal = self.proposal()
        self.result.write_text(json.dumps(proposal))
        original = self.target.read_bytes()
        task.apply_tests(self.folder)
        self.assertTrue(self.target.read_bytes().startswith(original))
        self.assertEqual(task.git("diff", "--name-only"), b"src/tests.zig\n")
        self.assertEqual(self.target.read_text().count('test "'), 3)

    def test_adjacent_test_target_is_derived_from_committed_sources(self):
        self.result.write_text(json.dumps(self.proposal()))
        target = Path("src/module_tests.zig")
        original = target.read_bytes()
        with patch.dict(os.environ, SCAN_PATHS="src/module.zig"):
            task.apply_tests(self.folder)
        self.assertTrue(target.read_bytes().startswith(original))
        self.assertEqual(task.git("diff", "--name-only"), b"src/module_tests.zig\n")
        self.assertIn("target=src/module_tests.zig\n", Path("outputs").read_text())
        body = Path("test-pr-body.md").read_text()
        self.assertIn("3 regression tests added to `src/module_tests.zig`", body)
        self.assertIn("Verify production case 2", body)
        self.assertIn("GPU integration requires a device", body)

    def test_reject_target_or_escape_or_oversize(self):
        proposal = self.proposal()
        self.result.write_text(json.dumps({**proposal, "path": ".github/workflows/build.yml"}))
        with self.assertRaises(ValueError):
            task.apply_tests(self.folder)
        proposal["tests"][0]["body"] = "    }\n    comptime {"
        self.result.write_text(json.dumps(proposal))
        with self.assertRaises(ValueError):
            task.apply_tests(self.folder)
        self.result.write_bytes(b" " * 32769)
        with self.assertRaises(ValueError):
            task.apply_tests(self.folder)
        self.assertFalse(task.git("diff", "--name-only"))

    def test_reject_symlink_and_executable_target(self):
        self.result.write_text(json.dumps(self.proposal()))
        self.target.unlink()
        self.target.symlink_to("module.zig")
        with self.assertRaises(ValueError):
            task.apply_tests(self.folder)
        self.target.unlink()
        self.target.write_bytes(task.git("show", "HEAD:src/tests.zig"))
        self.target.chmod(0o755)
        with self.assertRaises(ValueError):
            task.apply_tests(self.folder)

    def test_publisher_dco_branch_and_retry_without_github(self):
        # Bare local origin; the gh fixture models only the GitHub metadata and
        # records PR creation. Neither a token nor a network is involved.
        task.git("init", "--bare", "-q", "origin.git")
        task.git("remote", "add", "origin", str(Path("origin.git").resolve()))
        task.git("push", "-q", "origin", "HEAD:refs/heads/dev")
        Path("scripts").mkdir()
        Path("scripts/configure_git_identity.sh").write_bytes(
            (SCRIPTS / "configure_git_identity.sh").read_bytes())
        Path("bin").mkdir()
        gh = Path("bin/gh")
        gh.write_text("""#!/bin/sh
set -eu
case "$*" in
    *'/pulls?'*) if test -f created; then echo 1; fi ;;
    *'/git/ref/heads/'*) branch=${2#*/git/ref/heads/}; git --git-dir=origin.git rev-parse "refs/heads/$branch" ;;
    *'/labels/automated-test'|'auth setup-git') ;;
    'pr create '*) echo "$*" >> created ;;
    *) exit 1 ;;
esac
""")
        gh.chmod(0o755)
        self.result.write_text(json.dumps(self.proposal()))
        task.apply_tests(self.folder)
        env = {**os.environ, "PATH": f"{gh.parent.resolve()}:{os.environ['PATH']}",
               "GITHUB_SERVER_URL": "https://github.com", "TEST_TARGET": str(self.target),
               "FOCUSED_TEST": "check production case 0"}
        script = ["bash", str(SCRIPTS / "publish_generated_tests.sh")]
        published = subprocess.run(script, env=env, check=True, capture_output=True)
        self.assertTrue(Path("created").exists(), published.stdout)
        branch = "refs/heads/feature/opencode-test-writer-7"
        commit = task.git("--git-dir=origin.git", "rev-parse", branch).decode().strip()
        self.assertIn(b"Signed-off-by: opencode[bot]", task.git("show", "-s", "--format=%B", commit))
        self.assertEqual(task.git("diff", "--name-only", os.environ["GITHUB_SHA"], commit),
                         b"src/tests.zig\n")
        self.assertIn("--base dev --head feature/opencode-test-writer-7", Path("created").read_text())
        subprocess.run(script, env=env, check=True, capture_output=True)
        self.assertEqual(len(Path("created").read_text().splitlines()), 1)

    def test_schedule_and_dispatch_require_current_authorized_dev_revision(self):
        gh = Path("gh")
        gh.write_text("""#!/bin/sh
case "$*" in
    *default_branch*) echo dev ;;
    *git/ref/heads/dev*) echo "$CURRENT_SHA" ;;
    *collaborators/trusted/*) echo write ;;
    *) echo read ;;
esac
""")
        gh.chmod(0o755)
        env = {**os.environ, "PATH": f"{Path.cwd()}:{os.environ['PATH']}",
               "CURRENT_SHA": os.environ["GITHUB_SHA"], "GITHUB_REF": "refs/heads/dev",
               "GITHUB_ACTOR": "trusted", "GITHUB_TRIGGERING_ACTOR": "trusted"}

        def authorized(event, **overrides):
            result = subprocess.run(["bash", str(SCRIPTS / "authorize_source_task.sh")],
                                    env={**env, "GITHUB_EVENT_NAME": event, **overrides}, capture_output=True)
            return result.returncode == 0

        for event in ("schedule", "workflow_dispatch"):
            self.assertTrue(authorized(event))
            self.assertFalse(authorized(event, GITHUB_SHA="stale"))
            self.assertFalse(authorized(event, GITHUB_REF="refs/heads/other"))
            self.assertFalse(authorized(event, GITHUB_ACTOR="guest"))
            self.assertFalse(authorized(event, GITHUB_TRIGGERING_ACTOR="guest"))
        self.assertFalse(authorized("pull_request_target"))


if __name__ == "__main__":
    unittest.main()
