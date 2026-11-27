import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from opencode_discussion_markdown import reply_body


class ReplyBodyTests(unittest.TestCase):
    def test_mentions_do_not_change_alerts_zig_code_or_links(self):
        source = (
            "@octocat &#64;octocat @org/team and `@octocat`.\n\n"
            "> [!NOTE]\n> This is an alert.\n\n"
            "<https://example.com/@project>\n\n"
            '```zig\nconst std = @import("std");\n```\n'
        )
        alert_and_code = (
            '<div class="markdown-alert markdown-alert-note"><p>This is an alert.</p></div>'
            '<p><a href="https://example.com/@project">https://example.com/@project</a></p>'
            '<pre><span>@import</span>("std");</pre>'
        )
        candidate = source.replace("@octocat &#64;octocat @org/team", "@\u200boctocat &#64;\u200boctocat @\u200borg/team")

        def render(text):
            if text == source:
                return ('<p><a class="user-mention" href="https://github.com/octocat">@octocat</a> '
                        '&#64;octocat @org/team and <code>@octocat</code>.</p>' + alert_and_code)
            if text == candidate:
                return '<p>@\u200boctocat @\u200boctocat @\u200borg/team and <code>@octocat</code>.</p>' + alert_and_code

            tags = re.findall(r"Zc[0-9a-f]+Q[0-9]+Z", text)
            self.assertEqual(len(tags), 6)
            prose, entity, team, inline, link, fenced = tags
            return (f'<p>@{prose}octocat @{entity}octocat @{team}org/team and <code>@{inline}octocat</code>.</p>'
                    f'<a href="https://example.com/@{link}project">https://example.com/@{link}project</a>'
                    f'<pre>@{fenced}import("std");</pre>')

        self.assertEqual(reply_body(source, render), candidate)

    def test_reply_without_prose_mentions_preserves_source(self):
        source = '**Bold.** `@import("std")` and `actions/checkout@v6`.\n'
        preview = '<p><strong>Bold.</strong> <code>@import("std")</code> and <code>actions/checkout@v6</code>.</p>'
        self.assertEqual(reply_body(source, lambda _: preview), source)

    def test_autolink_without_mentions_preserves_source(self):
        url = "https://example.com/@project"
        source = f"<{url}>\n"
        preview = f'<p><a href="{url}">{url}</a></p>'
        self.assertEqual(reply_body(source, lambda _: preview), source)

    def test_large_preview_does_not_expand_published_markdown(self):
        code = "@as(u8, 1);\n" * 1300
        source = f"@octocat\n\n```zig\n{code}```"
        candidate = f"@\u200boctocat\n\n```zig\n{code}```"
        highlighted = '<pre>' + '<span class="pl-c1">@as</span>(u8, 1);\n' * 2100 + '</pre>'
        self.assertGreater(len(highlighted.encode()), 65_536)

        def render(text):
            if text == source:
                return '<p>@octocat</p>' + highlighted
            if text == candidate:
                return '<p>@\u200boctocat</p>' + highlighted
            return '<p>' + text.splitlines()[0] + '</p><pre>code omitted</pre>'

        self.assertEqual(reply_body(source, render), candidate)

    def test_unverified_edit_falls_back_to_literal_text(self):
        source = "@octocat\n\n~~~zig\n@as(u8, 1);\n~~~"
        body = reply_body(source, lambda _: "<p>@octocat</p>")
        self.assertIn("Could not verify mention handling", body)
        self.assertTrue(body.endswith(f"\n~~~~\n{source}\n~~~~\n"))


class DiscussionPublisherTests(unittest.TestCase):
    def test_failed_preview_posts_reply_in_an_inert_fence(self):
        source = "@octocat and `@as(u8, 1)`."
        with tempfile.TemporaryDirectory() as directory:
            files = Path(directory)
            (files / "event").write_text('{"issue":{"number":1005}}')
            (files / "response").write_text(source)
            gh = files / "gh"
            gh.write_text("#!/bin/sh\ncat >/dev/null\nprintf '<p>partial preview'\nexit 1\n")
            gh.chmod(0o700)
            result = subprocess.run(
                ["bash", "-euo", "pipefail", "-c", """
                    source scripts/opencode_discussion.sh
                    marker='<!-- opencode-v2-triage:10 -->'
                    gh() {
                        case "$2" in
                            --paginate) echo '[]' ;;
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
                    "PATH": f"{directory}{os.pathsep}{os.environ['PATH']}",
                },
                capture_output=True,
                text=True,
                check=True,
            )

        body = result.stdout
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
