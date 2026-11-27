"""Trusted preparation and schema checks for the audit and test-writer callers."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from opencode_prose import paragraphs


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git(*args):
    return subprocess.check_output(["git", *args])


def output(key, value):
    require("\n" not in value and "\r" not in value, "invalid job output")
    with open(os.environ["GITHUB_OUTPUT"], "a") as out:
        print(f"{key}={value}", file=out)


def artifact_file(folder, name, limit):
    path = folder / name
    require(set(folder.iterdir()) == {path}, "unexpected artifact members")
    require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= limit,
            "invalid artifact file")
    return path.read_bytes()


def snapshot(kind):
    # Select only committed regular Zig blobs; never follow a working-tree link.
    roots = os.environ["SCAN_PATHS"].split()
    if kind == "test-writer":
        roots += [str(Path(root).with_name(Path(root).stem + "_tests.zig"))
                  for root in roots if root.endswith(".zig")]
        roots += sorted({"/".join(root.split("/")[:2]) + "/src/root.zig"
                         for root in roots if root.startswith("modules/")})
    files = []
    entries = git("ls-tree", "-rz", "HEAD", "--", *roots)
    for entry in entries.split(b"\0"):
        if not entry:
            continue
        header, path = entry.decode().split("\t", 1)
        mode, _, oid = header.split()
        if mode == "100644" and re.fullmatch(r"(?:modules|src)/[A-Za-z0-9_/-]+\.zig", path):
            files.append((path, oid))
    # Start with the named production files, then immediate tests/exports.
    files.sort(key=lambda pair: (pair[0] not in roots, pair[0]))
    require(files, "selected module has no tracked Zig source")
    prompt = Path(f".github/prompts/{kind}.md").read_text()
    data = {"module": os.environ["MODULE"], "revision": os.environ["GITHUB_SHA"], "files": []}

    def encode():
        return (prompt + "\n" + json.dumps(data, ensure_ascii=False) + "\n").encode()

    for path, oid in files:
        if int(git("cat-file", "-s", oid)) > 1024 * 1024:
            continue
        blob = git("cat-file", "blob", oid)
        if b"\0" in blob:
            continue
        # Complete lines only; line numbers remain those of the original file.
        prefix = blob[:12000].decode("utf-8", errors="ignore")
        if len(blob) > 12000:
            prefix = prefix.rpartition("\n")[0]
        if not prefix.strip():
            continue
        data["files"].append({"path": path, "source": prefix})
        if len(encode()) > 96 * 1024:
            data["files"].pop()
            break
    require(data["files"], "empty source snapshot")
    return data, encode()


def response(folder):
    return json.loads(artifact_file(folder, "response.txt", 32 * 1024))


def audit(folder):
    result = response(folder)
    require(type(result) is dict and set(result) == {"finding"}, "invalid audit response")
    finding = result["finding"]
    if finding is None:
        output("found", "false")
        return
    require(type(finding) is dict and set(finding) == {
        "path", "line", "scope", "priority", "title", "summary", "impact", "fix",
    }, "invalid audit finding")
    for field, limit in (("title", 120), ("summary", 1200), ("impact", 800), ("fix", 1200)):
        text = finding[field]
        require(type(text) is str and 1 <= len(text.strip()) <= limit and text.isprintable()
                and not any(marker in text for marker in ("@", "<", ">", "://")),
                "invalid audit prose")
    require(finding["priority"] in ("Critical", "High", "Medium", "Low"), "invalid priority")
    require(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]{0,127}", finding["scope"]), "invalid scope")
    data, _ = snapshot("audit")
    sources = {f["path"]: f["source"].splitlines() for f in data["files"]}
    path, line = finding["path"], finding["line"]
    require(path in sources and type(line) is int and 1 <= line <= len(sources[path]),
            "finding outside the supplied excerpt")
    marker = hashlib.sha256(f"{path}:{finding['scope']}".encode()).hexdigest()
    location = f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/blob/{data['revision']}/{path}#L{line}"
    body = (f"<!-- opencode-audit:{marker} -->\n<!-- opencode-audit-run:{os.environ['GITHUB_RUN_ID']} -->\n"
            f"**Module:** `{data['module']}` · **Location:** [{path}:{line}]({location}) "
            f"(`{finding['scope']}`)\n")
    for key in ("summary", "impact", "fix"):
        body += f"\n### {key.capitalize()}\n\n{paragraphs(finding[key])}\n"
    Path(os.environ["RUNNER_TEMP"], "audit-issue.json").write_text(json.dumps({
        "title": f"[Audit][{finding['priority']}] {finding['title']}",
        "labels": ["automated-audit"], "body": body,
    }))
    output("marker", marker)
    output("found", "true")


TEST_PATH = "src/tests.zig"


def check_body(body):
    require(type(body) is str and 1 <= len(body) <= 6000 and
            all(c == "\n" or c.isprintable() for c in body), "invalid test body")
    # Keep every declaration inside its one named test. Ignore brace characters
    # in strings/chars/comments; exclude Zig's multi-line string syntax.
    depth = 0
    for line in body.split("\n"):
        require(not line or line.startswith("    "), "unindented test statement")
        require(not line.lstrip().startswith("\\\\") and "zig fmt:" not in line,
                "unsupported Zig literal or formatting directive")
        tokens = re.sub(r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|//.*''', "", line)
        require(not any(ch in tokens for ch in "'\"\\"), "invalid quoted literal")
        for ch in tokens:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                require(depth >= 0, "statement escapes test block")
    require(depth == 0, "unbalanced test body")


def apply_tests(folder):
    result = response(folder)
    require(type(result) is dict and set(result) == {"tests"} and type(result["tests"]) is list,
            "invalid test proposal")
    tests = result["tests"]
    if not tests:
        output("changed", "false")
        return
    require(3 <= len(tests) <= 8, "expected 3-8 tests")
    entry = git("ls-tree", "HEAD", TEST_PATH)
    target = Path(TEST_PATH)
    require(entry.startswith(b"100644 blob ") and target.is_file() and not target.is_symlink()
            and not target.stat().st_mode & 0o111
            and target.resolve() == Path.cwd() / TEST_PATH, "unsafe test target")
    original = git("show", f"HEAD:{TEST_PATH}")
    require(original == target.read_bytes(), "test target differs from pinned base")
    additions, names = [], []
    for test in tests:
        require(type(test) is dict and set(test) == {"name", "body"}, "invalid test fields")
        name, body = test["name"], test["body"]
        require(type(name) is str and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._:-]{2,119}", name)
                and name not in names and f'test "{name}"'.encode() not in original,
                "invalid or duplicate test name")
        check_body(body)
        additions.append(f'\ntest "{name}" {{\n{body.rstrip()}\n}}\n')
        names.append(name)
    target.write_bytes(original + "".join(additions).encode())
    output("changed", "true")
    output("filter", names[0])
    output("digest", hashlib.sha256(target.read_bytes()).hexdigest())


if __name__ == "__main__":
    command, folder = sys.argv[1], Path(sys.argv[2])
    if command in ("audit", "test-writer"):
        _, request = snapshot(command)
        folder.mkdir(exist_ok=False)
        (folder / "request.txt").write_bytes(request)
    elif command == "check-finding":
        audit(folder)
    elif command == "apply-tests":
        apply_tests(folder)
    else:
        raise SystemExit("unknown source task")
