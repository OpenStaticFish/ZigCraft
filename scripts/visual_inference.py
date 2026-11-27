"""Bound the evidence and findings exchanged with the visual-test inference job."""

import json
import os
import re
import stat
import sys
from pathlib import Path

from opencode_prose import paragraphs


PROMPTS = Path(__file__).resolve().parents[1] / ".github/prompts"
PNG_LIMIT = 4 * 1024 * 1024
# Only these fixed strings can cross from runner logs into a request.
SIGNALS = (
    "golden screenshot is effectively black",
    "actual screenshot is effectively black",
    "golden screenshot missing",
    "visual golden diff exceeds tolerance",
    "vk_error_device_lost",
    "vk_error_initialization_failed",
    "screenshotcapturefailed",
    "segmentation fault",
    "panic:",
    "timed out waiting for weston",
)


def bounded_file(path, limit):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= limit:
        raise ValueError("Expected a nonempty bounded regular file")
    return path.read_bytes()


def normalize(source, dest):
    from io import BytesIO
    from PIL import Image

    if not source.exists():
        raise ValueError("Capture unavailable: no menu screenshot was produced")
    png = bounded_file(source, PNG_LIMIT)
    with Image.open(BytesIO(png), formats=["PNG"]) as image:
        if image.width * image.height > 4_194_304 or image.n_frames != 1:
            raise ValueError("Capture unavailable: expected a single bounded PNG")
        image.verify()
    with Image.open(BytesIO(png), formats=["PNG"]) as image:
        pixels = image.convert("RGBA")
        pixels.info.clear()
        encoded = BytesIO()
        pixels.save(encoded, format="PNG")
    if encoded.tell() > PNG_LIMIT:
        raise ValueError("Capture unavailable: normalized PNG exceeds the request limit")
    dest.write_bytes(encoded.getvalue())


def diagnostic_signals(paths):
    matches = set()
    for path in paths:
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as log:
            log.seek(max(0, os.fstat(log.fileno()).st_size - 64 * 1024))
            tail = log.read(64 * 1024).lower()
        matches.update(signal for signal in SIGNALS if signal.encode() in tail)
    return sorted(matches)


def prepare(image, directory, env):
    steps = {key.lower(): env[key] or "skipped" for key in ("CAPTURE", "IMAGE", "COMPARISON")}
    if any(value not in {"success", "failure", "skipped"} for value in steps.values()):
        raise ValueError("Unexpected capture step outcome")
    directory.mkdir()
    if env["CAPTURE_RESULT"] == "success" and all(value == "success" for value in steps.values()):
        (directory / "image.png").write_bytes(bounded_file(image, PNG_LIMIT))
        profile = "vision"
        text = (PROMPTS / "visual-test-verify.md").read_text()
    elif env["CAPTURE_RESULT"] == "failure":
        profile = "default"
        signals = json.loads(env["DIAGNOSTICS"] or "[]")
        if not isinstance(signals, list) or any(value not in SIGNALS for value in signals):
            raise ValueError("Unexpected diagnostic signal")
        evidence = {
            "capture_status": "available" if steps["image"] == "success" else "capture unavailable",
            "steps": steps,
            "diagnostic_signatures": signals,
        }
        text = (PROMPTS / "visual-test-diagnose.md").read_text() + "\n" + json.dumps(evidence)
    else:
        raise ValueError("Incomplete deterministic result")
    if len(text.encode()) > 96 * 1024:
        raise ValueError("Request exceeds adapter limit")
    (directory / "request.txt").write_text(text, encoding="utf-8")
    return profile


def advisory(profile, response, output, env):
    answer = json.loads(bounded_file(response, 32 * 1024).decode("utf-8"))
    if not isinstance(answer, dict) or set(answer) != {"disposition", "observation"}:
        raise ValueError("Invalid visual advisory schema")
    if profile == "vision" and answer == {"disposition": "no_finding", "observation": ""}:
        return
    observation = answer["observation"]
    if (profile not in {"default", "vision"} or answer["disposition"] != "finding"
            or not isinstance(observation, str) or not observation.isprintable()
            or not observation.strip() or len(observation) > 2000):
        raise ValueError("Invalid visual advisory")
    sha, run = env["GITHUB_SHA"], env["GITHUB_RUN_ID"]
    if not re.fullmatch(r"[a-f0-9]{40}", sha) or not re.fullmatch(r"[0-9]+", run):
        raise ValueError("Invalid capture provenance")
    context = "Failure diagnosis" if profile == "default" else "Image observation"
    url = f"https://github.com/OpenStaticFish/ZigCraft/actions/runs/{run}"
    output.write_text(f"{context} for `{sha}` ([workflow run]({url})).\n\n"
                      f"{paragraphs(observation)}\n", encoding="utf-8")


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    if command == "normalize":
        normalize(*map(Path, args))
    elif command == "signals":
        print("diagnostics=" + json.dumps(diagnostic_signals(map(Path, args))))
    elif command == "prepare":
        print("profile=" + prepare(Path(args[0]), Path(args[1]), os.environ))
    elif command == "advisory":
        advisory(args[0], Path(args[1]), Path(args[2]), os.environ)
    else:
        raise SystemExit("Unknown visual inference command")
