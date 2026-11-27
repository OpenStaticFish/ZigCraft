"""Publish the required head status from the trusted gateway response."""

import html
import json
import os
from pathlib import Path
import re
import sys
from http.client import HTTPException

# -I excludes the working directory. Only import from the pinned checkout.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import opencode_v2_pr as pr


SEVERITIES = ("critical", "high", "medium", "low")
HEADINGS = ("🔴 Critical Issues (Must Fix - Blocks Merge)", "⚠️ High Priority Issues (Should Fix)",
            "💡 Medium Priority Issues (Nice to Fix)", "ℹ️ Low Priority Suggestions (Optional)")
PRINCIPLES = dict(S="Single Responsibility", O="Open/Closed", L="Liskov Substitution",
                  I="Interface Segregation", D="Dependency Inversion")
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


def text_field(record, key):
    value = record.get(key) if isinstance(record, dict) else None
    return value if isinstance(value, str) else ""


def review_excerpt(body, limit):
    if len(body) <= limit:
        return body
    # Scan the complete report before bounding it: summaries and fixed notes
    # can precede the first open finding by thousands of characters.
    rows = [f"{severity}: {html.unescape(location)} – {html.unescape(title)[:100]}: {html.unescape(description)[:300]}"
            for severity, location, title, description in re.findall(
                r"^<p><strong>\[(CRITICAL|HIGH|MEDIUM|LOW)\]</strong> <code>(.*?)</code> – (.*?)<br>"
                r"<strong>Confidence:</strong> [^<]+<br><strong>Description:</strong> (.*?)<br>", body, re.M)]
    if not rows:
        # The previous gate published its severity groups in preformatted lists.
        for severity, items in re.findall(r"\*\*(Critical|High|Medium|Low) \(\d+\)\*\*\s*<pre>(.*?)</pre>", body, re.S):
            rows.extend(f"{severity}: {html.unescape(item[2:])}" for item in items.splitlines() if item.startswith("• "))
    note = "[Partial previous review: details truncated]\n"
    marker = re.match(r"<!-- zigcraft-pr-gate:\d+:([0-9a-f]{40}):([0-9a-f]{40}) -->", body)
    if marker:
        note += f"Base: {marker[1]} Head: {marker[2]}\n"
    budget = limit - len(note)
    if not rows:
        return note + body[:budget]
    width = max(1, budget // len(rows) - 1)
    return note + "\n".join(row if len(row) <= width else row[:width - 1] + "…" for row in rows)[:budget]


def bot_bodies(records, login, prefix=""):
    for record in records:
        if isinstance(record, dict) and text_field(record.get("user"), "login") == login:
            body = text_field(record, "body")
            if body and body.startswith(prefix):
                yield body


def review_context(current):
    number = current["number"]
    unavailable = []

    def optional(path, expected):
        try:
            result = pr.api(path)
            if isinstance(result, expected):
                return result
        except (OSError, ValueError, HTTPException):
            pass
        unavailable.append(path)
        return expected()

    body = text_field(current, "body")[:6000]
    # Only resolve local closing references, never a user-supplied URL.
    visible = re.sub(r"<!--.*?(?:-->|\Z)|^ {0,3}((`|~)\2{2,})[^\n]*\n.*?(?:^ {0,3}\1\2*[ \t]*$|\Z)"
                     r"|(`+)[^\n]*?\3|^(?: {4}|\t)[^\n]*", " ", body, flags=re.M | re.S)
    refs = re.findall(r"\b(?:close[sd]?|fix(?:es|ed)?|resolve[sd]?)\s+#([1-9][0-9]{0,9})\b", visible, re.I)
    issues = []
    for ref in list(dict.fromkeys(refs))[:4]:
        issue = optional(f"issues/{ref}", dict)
        if text_field(issue, "title"):
            issues.append({"number": ref, "title": issue["title"], "body_excerpt": text_field(issue, "body")[:2000]})
    previous = []
    count = current.get("comments")
    last_page = (count + 24) // 25 if type(count) is int and count > 0 else 0
    first_page = max(1, last_page - 3)
    for page in range(last_page, first_page - 1, -1):
        comments = optional(f"issues/{number}/comments?per_page=25&page={page}", list)
        previous.extend(bot_bodies(reversed(comments), "github-actions[bot]", f"<!-- zigcraft-pr-gate:{number}:"))
    comment_search_complete = (type(count) is int and count >= 0 and first_page == 1
                               and not any("/comments?" in path for path in unavailable))
    # Include the formal reviews left by the pre-migration GitHub app, too.
    legacy = []
    review_url = f"pulls/{number}/reviews?per_page=100"
    formal_search_complete = False
    for url in (review_url, review_url + "&page=2"):
        batch = optional(url, list)
        for review in batch:
            if isinstance(review, dict) and text_field(review.get("user"), "login") == "opencode-agent[bot]":
                if text := text_field(review, "body"):
                    legacy.append({"head": text_field(review, "commit_id") or None, "excerpt": review_excerpt(text, 3000)})
        if len(batch) < 100:
            formal_search_complete = url not in unavailable
            break
    labels = current.get("labels")
    names = [text_field(label, "name") for label in labels] if isinstance(labels, list) else []
    coverage = {"comment_search_complete": comment_search_complete, "formal_search_complete": formal_search_complete,
                "older_gate_reviews_omitted": len(previous) > 2, "older_formal_reviews_omitted": len(legacy) > 2}
    return previous[:2], {"history_coverage": coverage, "unavailable": unavailable,
            "title": text_field(current, "title"), "description_excerpt": body,
            "labels": list(filter(None, names))[:25],
            "linked_issue_excerpts": issues, "formal_review_excerpts": legacy[-2:]}


def prepare(number, base, head):
    current = pr.api(f"pulls/{number}")
    if not pr.matches_target(current, number, base, head):
        raise pr.PilotError("PR changed before preparation")
    diff = pr.api(f"compare/{base}...{head}", diff=True)
    if (not diff.startswith("diff --git ") or "\0" in diff
            or 1 + diff.count("\ndiff --git ") != current["changed_files"]):
        raise pr.PilotError("Missing, incomplete or invalid PR diff")
    prompt = PROMPT.read_text(encoding="utf-8").replace("$PR_NUMBER", number).replace("$HEAD_SHA", head)
    prefix = (f"{prompt}\nBase SHA: {base}\nHead SHA: {head}\n\nOptional untrusted context (missing fields are unknown). "
              "Inline review comments are not included.\n")
    history_status = "Prior gate history: omitted\n"
    suffix = f"\nUntrusted diff:\n{diff}"
    remaining = pr.INPUT_LIMIT - len(prefix.encode()) - len(history_status) - len(suffix.encode())
    if remaining < 0:
        raise pr.PilotError("Prompt and complete diff exceed the gateway limit")
    context = []
    if remaining:
        previous, metadata = review_context(current)
        # Pack the newest history first, before any optional description or issue.
        # All three status words have the same byte length, even at zero headroom.
        coverage = metadata["history_coverage"]
        if coverage["comment_search_complete"] and not coverage["older_gate_reviews_omitted"]:
            history_status = "Prior gate history: sampled\n"
        else:
            history_status = "Prior gate history: partial\n"
        for body in previous:
            for limit in (5500, 2000, 800, 400, 240):
                field = json.dumps({"previous_gate_review": review_excerpt(body, limit)}, ensure_ascii=False) + "\n"
                if len(field.encode()) <= remaining:
                    context.append(field)
                    remaining -= len(field.encode())
                    break
            else:
                history_status = "Prior gate history: partial\n" if context else "Prior gate history: omitted\n"
                break
        for key, value in metadata.items():
            field = json.dumps({key: value}, ensure_ascii=False) + "\n"
            size = len(field.encode())
            if size <= remaining:
                context.append(field)
                remaining -= size
    request = prefix + history_status + "".join(context) + suffix
    if not pr.eligible(number, base, head):
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


def keys(obj, expected):
    if not isinstance(obj, dict) or set(obj) != set(expected):
        raise pr.PilotError("Invalid review fields")


def integer(value, maximum):
    if type(value) is not int or not 0 <= value <= maximum:
        raise pr.PilotError("Invalid review score")
    return value


def location_text(value):
    rendered = pr.plain_text(value)
    if len(rendered.encode()) > 384:
        raise pr.PilotError("Location exceeds the review budget")
    return rendered


def finding(item, severity, prose):
    keys(item, ("location", "title", "confidence", "description", "impact", "suggested_fix"))
    if item["confidence"] not in ("High", "Medium", "Low"):
        raise pr.PilotError("Invalid finding confidence")
    return (f"<p><strong>[{severity.upper()}]</strong> <code>{location_text(item['location'])}</code> – "
            f"{prose(item['title'])}<br><strong>Confidence:</strong> {item['confidence']}<br>"
            f"<strong>Description:</strong> {prose(item['description'])}<br>"
            f"<strong>Impact:</strong> {prose(item['impact'])}<br>"
            f"<strong>Suggested Fix:</strong> {prose(item['suggested_fix'])}</p>")


def review_header(number, base, head):
    return f"<!-- zigcraft-pr-gate:{number}:{base}:{head} -->\n<!-- zigcraft-static-review -->\n\n"


def verdict(raw, base, head, number):
    obj = json.loads(raw, object_pairs_hook=unique_keys)
    passed, text = render_verdict(obj, base, head, number, pr.plain_text)
    # Leave room for the comment's deduplication markers. Validate every full
    # field first; shorten only free text, never the verdict or finding counts.
    budget = 65536 - len(review_header(number, base, head).encode())
    for limit in (500, 250, 125, 60, 24, 8, 1):
        if len(text.encode()) <= budget:
            break

        def abbreviated(value):
            return pr.escape_text(value[:limit] + "…") if len(value) > limit else pr.escape_text(value)

        passed, text = render_verdict(obj, base, head, number, abbreviated)
        text = "Review prose abbreviated to fit GitHub's comment limit.\n\n" + text
    if len(text.encode()) > budget:
        raise pr.PilotError("Review does not fit the comment budget")
    return passed, text


def render_verdict(obj, base, head, number, prose):
    keys(obj, {"reviewed_base", "reviewed_sha", "overall_confidence_score", "recommendation", "verdict_reason",
               "summary", "fixed", "solid", "confidence_breakdown", "no_security_concerns",
               "test_status", *SEVERITIES})
    if obj["reviewed_base"] != base or obj["reviewed_sha"] != head:
        raise pr.PilotError("Verdict does not match the reviewed revisions")
    score = integer(obj["overall_confidence_score"], 100)
    recommendation = obj["recommendation"]
    if recommendation not in ("MERGE", "MERGE WITH FIXES", "DO NOT MERGE"):
        raise pr.PilotError("Invalid gate recommendation")
    lines = ["## 📋 Summary", f"<p>{prose(obj['summary'])}</p>", "## 📌 Review Metadata",
             f"- **Reviewed Commit SHA:** `{head}`\n- **Reviewed PR:** #{number}\n- **Base SHA:** `{base}`"]
    keys(obj["fixed"], SEVERITIES)
    for severity, heading in zip(SEVERITIES, HEADINGS):
        findings = obj[severity]
        fixed = obj["fixed"][severity]
        if not all(isinstance(items, list) and len(items) <= 12 for items in (findings, fixed)):
            raise pr.PilotError("Invalid gate findings")
        lines.append(f"## {heading}")
        lines.extend(f"<p>✅ <strong>[FIXED]</strong> Previous issue: {prose(note)}</p>" for note in fixed)
        lines.extend(finding(item, severity, prose) for item in findings)
        if not findings and not fixed:
            lines.append("None identified.")
    keys(obj["solid"], PRINCIPLES)
    rows = ["<table><thead><tr><th>Principle</th><th>Score</th><th>Notes</th></tr></thead><tbody>"]
    total = 0
    for key, name in PRINCIPLES.items():
        entry = obj["solid"][key]
        keys(entry, ("score", "notes"))
        value = integer(entry["score"], 10)
        total += value
        rows.append(f"<tr><td>{name}</td><td>{value}</td><td>{prose(entry['notes'])}</td></tr>")
    average = total / len(PRINCIPLES)
    rows.append(f"<tr><th>Average</th><td>{average:.1f}</td><td></td></tr></tbody></table>")
    lines.extend(["## 📊 SOLID Principles Score", "".join(rows), "## 🎯 Final Assessment",
                  f"### Overall Confidence Score: {score}%", "### Confidence Breakdown"])
    breakdown = obj["confidence_breakdown"]
    keys(breakdown, ("code_quality", "completeness", "risk_level", "test_coverage"))
    lines.append("\n".join(f"- **{key.replace('_', ' ').title()}:** {integer(breakdown[key], 100)}%"
                           for key in ("code_quality", "completeness", "risk_level", "test_coverage")))
    if type(obj["no_security_concerns"]) is not bool or obj["test_status"] not in ("passed", "failed", "unverified"):
        raise pr.PilotError("Invalid readiness flag")
    checks = [(not obj["critical"], "All critical issues resolved"), (average >= 6, "SOLID average score >= 6.0"),
              (score >= 60, "Overall confidence >= 60%"), (obj["no_security_concerns"], "No security concerns"),
              (obj["test_status"] == "passed", f"Tests present and passing (evidence: {obj['test_status']})")]
    reason = prose(obj["verdict_reason"])
    if recommendation == "MERGE" and (any(obj[s] for s in ("critical", "high", "medium")) or score < 80):
        recommendation = "DO NOT MERGE" if obj["critical"] else "MERGE WITH FIXES"
        reason = "The review does not meet the merge gate's finding or confidence thresholds."
    lines.extend(["### Merge Readiness", "Informational checklist. The AI gate requires zero open critical, high "
                  "or medium issues, confidence ≥80%, and a MERGE verdict. CI tests are separate checks.",
                  "\n".join(f"- [{'x' if ok else ' '}] {label}" for ok, label in checks),
                  "### Verdict", f"**{recommendation}**", f"<p>{reason}</p>"])
    machine = dict(reviewed_sha=head, reviewed_base=base, critical_issues=len(obj["critical"]), high_priority_issues=len(obj["high"]),
                   medium_priority_issues=len(obj["medium"]), overall_confidence_score=score, recommendation=recommendation)
    lines.extend(["## Machine Readable Verdict", "```json\n" + json.dumps(machine, indent=2) + "\n```"])
    return recommendation == "MERGE", "\n\n".join(lines)


def review_comment(number, base, head, text):
    marker = f"<!-- zigcraft-pr-gate:{number}:{base}:{head} -->\n"
    # The advisory pilot recognizes static reviews when cutover is enabled.
    body = review_header(number, base, head) + text
    if len(body.encode()) > 65536:
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
    passed, text = verdict(raw, base, head, number)
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
