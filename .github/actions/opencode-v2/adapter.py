"""Trusted entry points for the hosted Linux inference runner (Python stdlib only)."""

import ipaddress
import json
import os
from pathlib import Path
import re
import resource
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


MODEL_CONFIG = Path(__file__).with_name("model.json")
REQUEST_LIMIT = 96 * 1024
RESPONSE_LIMIT = 32 * 1024
IMAGE_LIMIT = 4 * 1024 * 1024
ACCOUNT = "zc-inference"


class StageError(ValueError):
    """Only fixed operator-facing messages, never provider or request text."""


def require(condition, message):
    if not condition:
        raise StageError(message)


def endpoint(url):
    parsed = urlsplit(url)
    require(
        re.fullmatch(r"https://[a-z0-9.-]+\.ts\.net(?::[0-9]+)?/v1", url)
        and parsed.hostname and parsed.port != 0,
        "Expected a protected HTTPS MagicDNS proxy URL ending in /v1",
    )
    return parsed.hostname, parsed.port or 443


def bounded_file(path, limit):
    require(not path.is_symlink() and path.is_file() and 0 < path.stat().st_size <= limit,
            "Missing, empty or oversized inference file")
    return path.read_bytes()


def request():
    directory = Path(os.environ["RUNNER_TEMP"]) / "opencode-request"
    profile = os.environ["PROFILE"]
    require(profile in {"default", "review", "vision"}, "Unknown inference profile")
    files = {p.name for p in directory.iterdir()}
    require(files == ({"request.txt", "image.png"} if profile == "vision" else {"request.txt"}),
            "Unexpected request artifact contents")
    text = bounded_file(directory / "request.txt", REQUEST_LIMIT).decode()
    require(text.strip() and "\0" not in text, "Invalid text request")
    image = None
    if profile == "vision":
        image = bounded_file(directory / "image.png", IMAGE_LIMIT)
        require(image.startswith(b"\x89PNG\r\n\x1a\n"), "Expected PNG evidence")
    return text, image


def config(url, vision):
    selection = json.loads(MODEL_CONFIG.read_text())
    deny = [{"action": "*", "resource": "*", "effect": "deny"}]
    return {
        "model": "zigcraft/selected",
        "share": "disabled",
        "update": "disable",
        "snapshots": False,
        "permissions": deny,
        "policies": [
            {"action": "provider.use", "resource": "*", "effect": "deny"},
            {"action": "provider.use", "resource": "zigcraft", "effect": "allow"},
            {"action": "tool.use", "resource": "*", "effect": "deny"},
            {"action": "mcp.use", "resource": "*", "effect": "deny"},
            {"action": "skill.use", "resource": "*", "effect": "deny"},
        ],
        "agents": {"inference": {"description": "Answer the supplied request using only its data.",
                                 "mode": "primary", "steps": 1, "permissions": deny}},
        "providers": {"zigcraft": {
            "name": "ZigCraft proxy",
            "env": ["ZIGCRAFT_PROXY_KEY"],
            "package": "@opencode/ai/providers/openai-compatible/responses",
            "settings": {"baseURL": url, "timeout": 120000, "transport": "http"},
            # V2.3 can still advertise its built-in skill even with a deny-all
            # agent. Remove tools on the wire as well as denying execution.
            "body": {"tools": [], "store": False, "reasoning": {"effort": selection["reasoning_effort"]}},
            "models": {"selected": {"modelID": selection["model"], "capabilities": {
                "tools": False, "input": ["text", "image"] if vision else ["text"],
                "output": ["text"],
            }}},
        }},
    }


def command(*args, **kwargs):
    return subprocess.check_output(args, stderr=subprocess.DEVNULL, **kwargs)


def connect():
    """Verify the peer itself, not just that some host answered a HTTPS request."""
    host, port = endpoint(os.environ["BASE_URL"])
    status = json.loads(command("tailscale", "status", "--json"))
    peers = [p for p in status["Peer"].values() if p["DNSName"].rstrip(".") == host]
    require(len(peers) == 1 and peers[0]["Online"], "Proxy peer unavailable")
    addresses = {a[4][0] for a in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)}
    require(addresses and addresses <= set(peers[0]["TailscaleIPs"]), "Proxy DNS/peer mismatch")
    ipv4 = next(ip for ip in addresses if ipaddress.ip_address(ip).version == 4)
    require(ipaddress.ip_address(ipv4) in ipaddress.ip_network("100.64.0.0/10")
            and json.loads(command("ip", "-j", "route", "get", ipv4))[0]["dev"] == "tailscale0",
            "Expected a direct tailnet route")
    try:
        with socket.create_connection((ipv4, port), timeout=10) as conn:
            with ssl.create_default_context().wrap_socket(conn, server_hostname=host):
                pass
    except ssl.SSLError:
        raise StageError("Proxy TLS verification failed") from None
    except OSError:
        raise StageError("Proxy TCP connection failed") from None

    # Only this new unprivileged account is restricted. The runner and tailscaled
    # still need their control planes. Standalone uses a local client/server.
    command("sudo", "-n", "useradd", "--system", "--no-create-home", ACCOUNT)
    for firewall in ("iptables", "ip6tables"):
        rule = ["sudo", "-n", firewall, "-w", "-I", "OUTPUT", "1",
                "-m", "owner", "--uid-owner", ACCOUNT]
        command(*rule, "-j", "REJECT")
        command(*rule, "-o", "lo", "-p", "tcp", "-j", "ACCEPT")
        if firewall == "iptables":
            command(*rule, "-o", "tailscale0", "-p", "tcp", "-d", ipv4,
                    "--dport", str(port), "-j", "ACCEPT")
    command("sudo", "-n", "tee", "-a", "/etc/hosts", input=f"\n{ipv4} {host}\n".encode())


def response(events):
    parts = []
    completed = False
    total = 0
    for raw in events:
        total += len(raw)
        require(total <= 512 * 1024, "Oversized CLI event stream")
        event = json.loads(raw)
        kind = event["type"]
        if kind == "text":
            parts.append(event["part"]["text"])
        elif kind == "step_finish":
            require(not completed and event["part"]["reason"] == "stop", "Incomplete model response")
            completed = True
        elif kind in {"error", "retry"}:
            status = event["error"].get("status")
            if status in (401, 403):
                raise StageError("Proxy rejected credentials or model access")
            if status in (402, 429):
                raise StageError("Proxy quota or rate limit reached")
            raise StageError("Model request failed")
        else:
            require(kind in {"step_start", "reasoning"}, "Unexpected CLI event")
    text = "".join(parts).strip()
    require(completed and 0 < len(text.encode()) <= RESPONSE_LIMIT and "\0" not in text,
            "Missing or oversized model response")
    return text


def child():
    # sudo passed only the client key explicitly; do not pass its environment,
    # runner tokens, proxy settings, or repository location through to OpenCode.
    root = Path.cwd()
    home = root / "home"
    home.mkdir(mode=0o700)
    env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8",
           "ZIGCRAFT_PROXY_KEY": os.environ["ZIGCRAFT_PROXY_KEY"]}
    for name in ("CONFIG", "DATA", "STATE", "CACHE"):
        env[f"XDG_{name}_HOME"] = str(home / name.lower())
    runtime = home / "runtime"
    runtime.mkdir(mode=0o700)
    env.update(TMPDIR=str(runtime), XDG_RUNTIME_DIR=str(runtime))
    os.chdir(root / "work")
    args = ["opencode", "--standalone", "run", "--agent", "inference", "--model", "zigcraft/selected",
            "--title", "ZigCraft CI", "--format", "json"]
    if (root / "image.png").exists():
        args.extend(["--file", str(root / "image.png")])
    resource.setrlimit(resource.RLIMIT_FSIZE, (64 << 20, 64 << 20))
    os.execve(root.parent / "opencode", args, env)


def infer():
    text, image = request()
    url = os.environ["BASE_URL"]
    key = os.environ.get("ZIGCRAFT_PROXY_KEY", "")
    require(key.strip(), "Missing proxy client key")
    runner = Path(os.environ["RUNNER_TEMP"])
    # RUNNER_TEMP/checkout can be inaccessible to the dedicated uid. Copy only
    # reviewed executable/config and validated evidence outside the workspace.
    with tempfile.TemporaryDirectory(prefix="zigcraft-", dir="/tmp") as tmp:
        root = Path(tmp)
        root.chmod(0o711)
        shutil.copy2(runner / "opencode", root / "opencode")
        shutil.copyfile(__file__, root / "adapter.py")
        state = root / "cli"
        work = state / "work"
        work.mkdir(parents=True)
        (work / "opencode.json").write_text(json.dumps(config(url, image is not None)))
        if image:
            (state / "image.png").write_bytes(image)
        command("sudo", "-n", "chown", "-R", ACCOUNT, str(state))
        try:
            with tempfile.TemporaryFile() as prompt:
                prompt.write(text.encode())
                prompt.seek(0)
                process = subprocess.Popen(
                    ["sudo", "-n", "-u", ACCOUNT, "--preserve-env=ZIGCRAFT_PROXY_KEY",
                     "timeout", "--kill-after=5", "180", "/usr/bin/python3", "-I", str(root / "adapter.py"), "child"],
                    cwd=state, stdin=prompt, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                )
                try:
                    with process.stdout:
                        # Process retry/error events immediately, before backoff expires.
                        result = response(iter(lambda: process.stdout.readline(512 * 1024 + 1), b""))
                    require(process.wait() == 0, "CLI exited unsuccessfully")
                finally:
                    # This uid was created for this invocation; also stop any
                    # standalone child left behind on timeout or cancellation.
                    subprocess.run(["sudo", "-n", "pkill", "-KILL", "-u", ACCOUNT],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    process.wait()
                require(key not in result and endpoint(url)[0] not in result, "Private value in model response")
        finally:
            command("sudo", "-n", "rm", "-rf", "--", str(state))
    out = runner / "opencode-response"
    out.mkdir(mode=0o700)
    (out / "response.txt").write_text(result)


def main():
    stage = sys.argv[1]
    try:
        if stage == "prepare":
            endpoint(os.environ["BASE_URL"])
            request()
        elif stage == "connect":
            connect()
        elif stage == "infer":
            infer()
        elif stage == "child":
            child()
        else:
            raise ValueError("Unknown stage")
    except StageError as error:
        sys.exit(f"OpenCode {stage}: {error}")
    except Exception:
        # CLI events, subprocess exceptions and socket errors may include
        # prompts, authorization headers or internal addresses.
        sys.exit(f"OpenCode {stage} failed; see docs/opencode-ci.md")


if __name__ == "__main__":
    main()
