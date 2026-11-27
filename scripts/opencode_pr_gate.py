"""Publish the required head status from the trusted gateway response."""

import json
import os
from pathlib import Path
import sys

# -I excludes the working directory. Only import from the pinned checkout.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import opencode_v2_pr as pr


SEVERITIES = ("critical", "high", "medium", "low")
PROMPT = Path(__file__).resolve().parents[1] / ".github/prompts/pr-review.md"


def output(key, value):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as dest:
        print(f"{key}={value}", file=dest)


def status(head, context, state, description):
    pr.api(f"statuses/{head}", body={
        "context": context, "state": state, "description": description,
        "target_url": (f"https://github.com/{pr.REPO}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
                       f"/attempts/{os.environ['GITHUB_RUN_ATTEMPT']}"),
    })


def authorize_event():
    event = os.environ["GITHUB_EVENT_NAME"]
    if event not in ("pull_request_target", "workflow_dispatch") or not pr.authorized():
        raise pr.PilotError("Unexpected event or unauthorized actor")


def start(number, base, head):
    authorize_event()
    current = pr.api(f"pulls/{number}")
    # Never post to an arbitrary dispatch-supplied SHA. If only the base
    # moved, invalidate the verified head's old pass and fail preparation.
    if not pr.matches_target(current, number, current["base"]["sha"], head):
        raise pr.PilotError("PR is ineligible or the requested head has changed")
    output("bound", "true")
    status(head, "ai-merge-gate", "pending", "Awaiting pinned diff review")


def prepare(number, base, head):
    current = pr.api(f"pulls/{number}")
    if not pr.matches_target(current, number, base, head):
        raise pr.PilotError("PR changed before preparation")
    diff = pr.api(f"compare/{base}...{head}", diff=True)
    if (not diff.startswith("diff --git ") or "\0" in diff
            or 1 + diff.count("\ndiff --git ") != current["changed_files"]):
        raise pr.PilotError("Missing, incomplete or invalid PR diff")
    request = f"{PROMPT.read_text(encoding='utf-8')}\nBase SHA: {base}\nHead SHA: {head}\n\nUntrusted diff:\n{diff}"
    if len(request.encode()) > pr.INPUT_LIMIT or not pr.eligible(number, base, head):
        raise pr.PilotError("PR changed or request exceeds the gateway limit")
    directory = Path(os.environ["RUNNER_TEMP"]) / "pr-input"
    directory.mkdir(mode=0o700)
    (directory / "request.txt").write_text(request, encoding="utf-8")
    output("request", f"opencode-gate-request-{os.environ['GITHUB_RUN_ID']}-{os.environ['GITHUB_RUN_ATTEMPT']}")


def unique_keys(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise pr.PilotError("Duplicate verdict field")
        obj[key] = value
    return obj


def verdict(raw, base, head):
    obj = json.loads(raw, object_pairs_hook=unique_keys)
    fields = {"reviewed_base", "reviewed_sha", "overall_confidence_score", "recommendation", *SEVERITIES}
    if type(obj) is not dict or set(obj) != fields:
        raise pr.PilotError("Invalid gate verdict fields")
    if obj["reviewed_base"] != base or obj["reviewed_sha"] != head:
        raise pr.PilotError("Verdict does not match the reviewed revisions")
    score = obj["overall_confidence_score"]
    recommendation = obj["recommendation"]
    if type(score) is not int or not 0 <= score <= 100:
        raise pr.PilotError("Invalid confidence score")
    if recommendation not in ("MERGE", "MERGE WITH FIXES", "DO NOT MERGE"):
        raise pr.PilotError("Invalid gate recommendation")
    lines = [f"Recommendation: **{recommendation}** · Confidence: **{score}/100**"]
    for severity in SEVERITIES:
        findings = obj[severity]
        if not isinstance(findings, list) or len(findings) > 12:
            raise pr.PilotError("Invalid gate findings")
        text = "\n".join(f"• {pr.plain_text(item)}" for item in findings)
        lines.append(f"**{severity.title()} ({len(findings)})**" + (f"\n<pre>{text}</pre>" if text else ""))
    passed = not any(obj[s] for s in ("critical", "high", "medium")) and score >= 80 and recommendation == "MERGE"
    return passed, "\n\n".join(lines)


def review_comment(number, base, head, text):
    marker = f"<!-- zigcraft-pr-gate:{number}:{base}:{head} -->\n"
    # The advisory pilot recognizes static reviews when cutover is enabled.
    body = marker + f"<!-- zigcraft-static-review -->\n### AI merge gate · `{head}`\n\nBase `{base}`. Diff-only review.\n\n" + text
    if len(body) > 65536:
        raise pr.PilotError("Rendered gate review exceeds the comment limit")
    for page in range(1, 101):
        comments = pr.api(f"issues/{number}/comments?per_page=25&page={page}")
        for comment in comments:
            if comment["user"]["login"] == "github-actions[bot]" and (comment["body"] or "").startswith(marker):
                if comment["body"] != body:
                    pr.api(f"issues/comments/{int(comment['id'])}", method="PATCH", body={"body": body})
                return
        if len(comments) < 25:
            pr.api(f"issues/{number}/comments", body={"body": body})
            return
    raise pr.PilotError("Too many comments to verify deduplication")


def publish(number, base, head):
    raw = pr.response_data(Path(os.environ["RUNNER_TEMP"]) / "pr-output")
    passed, text = verdict(raw, base, head)
    authorize_event()
    if not pr.eligible(number, base, head):
        raise pr.PilotError("PR changed before publication")
    review_comment(number, base, head, text)
    if not pr.eligible(number, base, head):
        raise pr.PilotError("PR changed before status publication")
    status(head, "ai-review", "success", "Pinned diff review complete")
    state = "success" if passed else "failure"
    status(head, "ai-merge-gate", state, "Review passed" if passed else "Review does not meet merge criteria")
    output("passed", str(passed).lower())


def fail(number, base, head):
    # The prepare job already verified the head. Never transfer a failed
    # review's status to a newer revision, even after a force-push.
    status(head, "ai-merge-gate", "failure", "Pinned diff review could not be validated")
    status(head, "ai-review", "failure", "Pinned diff review failed")


if __name__ == "__main__":
    try:
        {"start": start, "prepare": prepare, "publish": publish, "fail": fail}[sys.argv[1]](*pr.target())
    except Exception as error:
        # API errors, diffs, responses and parse errors may contain untrusted data.
        sys.exit(f"PR gate failed ({type(error).__name__}).")
