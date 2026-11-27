import unittest

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


if __name__ == "__main__":
    unittest.main()
