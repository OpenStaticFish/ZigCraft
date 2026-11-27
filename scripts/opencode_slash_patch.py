"""Validate and publish a one-file text replacement; never check out the candidate tree."""

import os
import re
from urllib.parse import quote


def allowed_path(path):
    part = r"[A-Za-z0-9][A-Za-z0-9_-]*"
    return bool(re.fullmatch(rf"(?:src/|modules/{part}/src/)(?:{part}/)*{part}\.zig", path)
                or re.fullmatch(rf"docs/(?:{part}/)*{part}\.md", path))


def apply_patch(original, value):
    if set(value) != {"before", "after"}:
        raise ValueError("invalid replacement schema")
    before, after = value["before"], value["after"]
    for text in (before, after):
        if (not isinstance(text, str) or len(text.encode()) > 8192
                or re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", text)):
            raise ValueError("invalid replacement text")
    if not before.strip() or original.count(before) != 1 or before == after:
        raise ValueError("replacement must identify a unique change")
    updated = original.replace(before, after, 1)
    if not updated.strip() or len(updated.encode()) > 48 * 1024:
        raise ValueError("result must be non-empty bounded source text")
    return updated


def publish_pr(target, updated, repo, api, current_target):
    branch, parent = target["branch"], target["base"]
    if (not re.fullmatch(r"feature/opencode-comment-[1-9][0-9]*", branch)
            or not allowed_path(target["path"])):
        raise ValueError("invalid edit target")
    base_tree = repo(f"git/commits/{parent}")["tree"]["sha"]
    tree = repo("git/trees", {"base_tree": base_tree, "tree": [
        {"path": target["path"], "mode": "100644", "type": "blob", "content": updated}
    ]}, app=True)["sha"]
    branch_ref = repo(f"git/ref/heads/{branch}", optional=True)
    if branch_ref:
        # Recovery after branch creation succeeded but opening the PR failed. An
        # unrelated branch, or one with subsequent human edits, is never reused.
        commit = repo(f"git/commits/{branch_ref['object']['sha']}")
        if commit["tree"]["sha"] != tree or [p["sha"] for p in commit["parents"]] != [parent]:
            raise ValueError("automation branch already exists with different contents")
        sha = commit["sha"]
    else:
        login = os.environ["APP_SLUG"] + "[bot]"
        user_id = api(f"/users/{quote(login, safe='')}")["id"]
        email = f"{user_id}+{login}@users.noreply.github.com"
        title = f"fix: apply requested edit for #{target['number']}"
        sha = repo("git/commits", {"tree": tree, "parents": [parent],
                                   "message": f"{title}\n\nSigned-off-by: {login} <{email}>",
                                   "author": {"name": login, "email": email}}, app=True)["sha"]
        # Create only. No update, force push, or write to the original branch.
        if current_target() != target:
            raise ValueError("target changed before branch creation")
        repo("git/refs", {"ref": f"refs/heads/{branch}", "sha": sha}, app=True)
    if current_target() != target or repo(f"git/ref/heads/{branch}")["object"]["sha"] != sha:
        raise ValueError("branch revision changed before PR creation")
    repo("pulls", {"head": branch, "base": "dev",
                   "title": f"fix: proposed edit to {target['path']}",
                   "body": (f"Requested in #{target['number']}. Based on `{parent}`.\n\n"
                            "This is a generated one-file proposal. Review the diff and normal CI.")}, app=True)
