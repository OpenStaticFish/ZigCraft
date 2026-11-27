import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from opencode_discussion_markdown import reply_body


class ReplyBodyTests(unittest.TestCase):
    def test_mentions_do_not_change_zig_code_or_links(self):
        source = (
            "@octocat &#64;octocat @org/team and `@as`.\n\n"
            '```zig\nconst std = @import("std");\n\nconst n = @as(u8, 1);\n```\n'
        )
        preview = (
            '<p><a class="user-mention notranslate" href="https://github.com/octocat">'
            '@octocat</a> &#64;octocat @org/team and <code>@as</code>. '
            '<a href="https://example.com/@project">project</a></p>\n'
            '<div><pre><span>@import</span>("std");\n\n'
            'const n = <span>@as</span>(u8, 1);</pre></div>\n'
        )
        body = reply_body(source, preview)
        self.assertIn("@\u200boctocat @\u200boctocat @\u200borg/team", body)
        self.assertNotIn("user-mention", body)
        self.assertIn("<code>@as</code>", body)
        self.assertIn('<span>@import</span>("std");&#10;&#10;const n = <span>@as</span>(u8, 1);', body)
        self.assertIn('href="https://example.com/@project"', body)
        self.assertEqual(len(body.splitlines()), 1)

    def test_reply_without_prose_mentions_preserves_source(self):
        source = '**Bold.** `@import("std")` and `actions/checkout@v6`.\n'
        preview = '<p><strong>Bold.</strong> <code>@import("std")</code> and <code>actions/checkout@v6</code>.</p>'
        self.assertEqual(reply_body(source, preview), source)


class DiscussionPublisherTests(unittest.TestCase):
    def publish(self, source, preview=None):
        with tempfile.TemporaryDirectory() as directory:
            files = Path(directory)
            (files / "event").write_text('{"issue":{"number":1005}}')
            (files / "response").write_text(source)
            if preview is not None:
                (files / "preview").write_text(preview)
            result = subprocess.run(
                ["bash", "-euo", "pipefail", "-c", """
                    source scripts/opencode_discussion.sh
                    marker='<!-- opencode-v2-triage:10 -->'
                    gh() {
                        case "$2" in
                            --paginate) echo '[]' ;;
                            markdown)
                                if [[ -f "$FIXTURE/preview" ]]; then
                                    cat "$FIXTURE/preview"
                                else
                                    printf '<p>partial preview'
                                    return 1
                                fi ;;
                            "$repo/issues/1005/comments") cat "${4#body=@}" ;;
                            *) return 1 ;;
                        esac
                    }
                    cp "$FIXTURE/response" "$tmp/response"
                    post_reply
                """],
                env={
                    **os.environ,
                    "GITHUB_REPOSITORY": "OpenStaticFish/ZigCraft",
                    "GITHUB_EVENT_PATH": str(files / "event"),
                    "GITHUB_SHA": "a" * 40,
                    "TMPDIR": directory,
                    "FIXTURE": directory,
                },
                capture_output=True,
                text=True,
                check=True,
            )
        return result.stdout

    def test_oversized_preview_posts_entire_reply_in_an_inert_fence(self):
        source = '@octocat &#64;octocat\n\n~~~zig\n' + '@as(u8, 1);\n' * 1300 + '~~~'
        preview = '<p>@octocat &#64;octocat</p><pre>' + '<span class="pl-c1">@as</span>' * 2300 + '</pre>'
        body = self.publish(source, preview)

        self.assertLess(len(source.encode()), 16_000)
        self.assertGreater(len(preview.encode()), 65_536)
        self.assertLess(len(body.encode()), 65_536)
        self.assertTrue(body.startswith("<!-- opencode-v2-triage:10 -->\n\n"))
        self.assertTrue(body.endswith(f"\n~~~~\n{source}\n~~~~\n"))

    def test_failed_preview_posts_reply_in_an_inert_fence(self):
        source = "@octocat and `@as(u8, 1)`."
        body = self.publish(source)

        self.assertTrue(body.startswith("<!-- opencode-v2-triage:10 -->\n\n"))
        self.assertIn("GitHub's Markdown preview was unavailable", body)
        self.assertNotIn("partial preview", body)
        self.assertTrue(body.endswith(f"\n~~~\n{source}\n~~~\n"))

    def test_discussion_replies_are_not_review_history(self):
        verdict = '```json\n{"reviewed_sha":"example"}\n```'
        bot = {"login": "github-actions[bot]"}
        gate = "<!-- zigcraft-pr-gate:1005:base:head -->\n" + verdict
        comments = [
            {"user": bot, "created_at": "2026-11-27T12:00:00Z", "body": gate},
            {"user": bot, "created_at": "2026-11-27T12:01:00Z", "body": "<!-- opencode-v2-triage:10 -->\n\n" + verdict},
            {"user": bot, "created_at": "2026-11-27T12:02:00Z", "body": "<!-- opencode-v2-slash:11 -->\n\n" + verdict},
        ]
        reviews = [{"user": bot, "submitted_at": "2026-11-27T12:03:00Z", "body": "Formal review"}]
        result = subprocess.run(
            ["jq", "-s", "-f", "scripts/opencode_review_history.jq"],
            input=json.dumps(comments) + "\n" + json.dumps(reviews),
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual([review["body"] for review in json.loads(result.stdout)], ["Formal review", gate])


if __name__ == "__main__":
    unittest.main()
