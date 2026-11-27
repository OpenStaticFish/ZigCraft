"""Publish the required head status from the trusted gateway response."""

import os
from pathlib import Path
import sys

# -I excludes the working directory. Only import from the pinned checkout.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import opencode_v2_pr as pr


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
    pr.prepare_request(number, base, head, current)
    output("request", f"opencode-gate-request-{os.environ['GITHUB_RUN_ID']}-{os.environ['GITHUB_RUN_ATTEMPT']}")


def review_comment(number, base, head, text):
    marker = f"<!-- zigcraft-pr-gate:{number}:{base}:{head} -->\n"
    # The advisory pilot recognizes static reviews when cutover is enabled.
    body = marker + f"<!-- zigcraft-static-review -->\n### AI merge gate · `{head}`\n\nBase `{base}`.\n\n" + text
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
    passed, text = pr.review_result(Path(os.environ["RUNNER_TEMP"]) / "pr-output", head)
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
