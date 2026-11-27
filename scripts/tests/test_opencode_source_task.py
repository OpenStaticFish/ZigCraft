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
        Path("src/link.zig").symlink_to("module.zig")
        Path(".github/prompts").mkdir(parents=True)
        Path(".github/prompts/audit.md").write_text("trusted audit")
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

    def test_finding_must_cite_an_actual_line_and_has_stable_marker(self):
        finding = dict(path="src/module.zig", line=1, scope="demo", priority="Medium",
                       title="Demo mismatch", impact="Observed symptom", fix="Fix demo", summary="Evidence")
        self.result.write_text(json.dumps({"finding": finding}))
        task.audit(self.folder)
        issue = json.loads(Path("audit-issue.json").read_text())
        self.assertIn("opencode-audit-run:7", issue["body"])
        self.assertIn("src/module.zig#L1", issue["body"])
        self.assertIn("<p>Evidence</p>", issue["body"])
        marker = Path("outputs").read_text().splitlines()[0]
        finding["title"] = "Reworded"
        self.result.write_text(json.dumps({"finding": finding}))
        task.audit(self.folder)
        self.assertEqual(Path("outputs").read_text().count(marker), 2)
        finding["line"] = 2
        self.result.write_text(json.dumps({"finding": finding}))
        with self.assertRaises(ValueError):
            task.audit(self.folder)

    def test_zero_results_skip_publication(self):
        self.result.write_text('{"finding":null}')
        task.audit(self.folder)
        self.result.write_text('{"tests":[]}')
        task.apply_tests(self.folder)
        self.assertEqual(Path("outputs").read_text(), "found=false\nchanged=false\n")
        self.assertFalse(Path("audit-issue.json").exists())

    def proposal(self):
        return {"tests": [{"name": f"check production case {i}",
                           "body": f'    try std.testing.expectEqual({i}, Example.get({i}));'}
                          for i in range(3)]}

    def test_fixed_target_append_only(self):
        proposal = self.proposal()
        self.result.write_text(json.dumps(proposal))
        original = self.target.read_bytes()
        task.apply_tests(self.folder)
        self.assertTrue(self.target.read_bytes().startswith(original))
        self.assertEqual(task.git("diff", "--name-only"), b"src/tests.zig\n")
        self.assertEqual(self.target.read_text().count('test "'), 3)

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
               "GITHUB_SERVER_URL": "https://github.com"}
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


if __name__ == "__main__":
    unittest.main()
