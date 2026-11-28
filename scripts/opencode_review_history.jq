def discussion_reply:
    (.body // "") | test("^<!-- opencode-v2-(triage|slash):");

def review_comment:
    (.body // "") | test("^<!-- zigcraft-(pr-gate|v2-advisory|static-review)|```json[\\s\\S]*\"reviewed_sha\"");

[.[][]
    | select(.user.login | IN("github-actions[bot]", "opencode-agent[bot]"))
    | select(discussion_reply | not)
    | select(.submitted_at or review_comment)
    | {date: (.submitted_at // .created_at), body}]
| sort_by(.date) | reverse | .[:3]
| map(.body |= .[:3500])
