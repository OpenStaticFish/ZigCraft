"""Exercise the downloaded CLI's actual Responses wire format against loopback."""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from threading import Thread
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / ".github/actions/opencode-v2"))
import adapter


@unittest.skipUnless(os.environ.get("OPENCODE_TEST_CLI"), "requires the pinned v2.3.0 executable")
class WireContract(unittest.TestCase):
    def test_all_profiles_request_sol_with_medium_reasoning(self):
        seen = []
        item = {"id": "msg_test", "type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": "OK", "annotations": []}]}
        events = [
            ("response.created", {"response": {"id": "resp_test", "status": "in_progress"}}),
            ("response.output_item.added", {"item": dict(item, content=[]), "output_index": 0}),
            ("response.output_text.delta", {"item_id": item["id"], "output_index": 0, "content_index": 0,
                                            "delta": "OK"}),
            ("response.output_item.done", {"item": item, "output_index": 0}),
            ("response.completed", {"response": {"id": "resp_test", "status": "completed", "output": [item],
                                                 "usage": {"input_tokens": 10, "output_tokens": 1}}}),
        ]

        class Proxy(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                has_image = any(part.get("type") == "input_image" for message in body["input"]
                                for part in message.get("content", []) if isinstance(part, dict))
                seen.append((self.path, self.headers.get("Authorization"), body["model"],
                             body.get("reasoning"), body.get("tools"), has_image))
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for kind, fields in events:
                    data = json.dumps(dict(type=kind, **fields))
                    self.wfile.write(f"event: {kind}\ndata: {data}\n\n".encode())

        with HTTPServer(("127.0.0.1", 0), Proxy) as proxy, tempfile.TemporaryDirectory() as temp:
            Thread(target=proxy.serve_forever, daemon=True).start()
            try:
                root = Path(temp)
                (root / "opencode").symlink_to(Path(os.environ["OPENCODE_TEST_CLI"]).resolve())
                for profile in ("default", "review", "vision"):
                    with self.subTest(profile=profile):
                        seen.clear()
                        state = root / profile
                        work = state / "work"
                        work.mkdir(parents=True)
                        vision = profile == "vision"
                        if vision:
                            (state / "image.png").write_bytes((ROOT / "docs/visual-test/golden/menu.png").read_bytes())
                        cfg = adapter.config(f"http://127.0.0.1:{proxy.server_port}/v1", vision=vision)
                        (work / "opencode.json").write_text(json.dumps(cfg))
                        process = subprocess.run([sys.executable, adapter.__file__, "child"], cwd=state,
                                                 input=b"Reply OK", env={"ZIGCRAFT_PROXY_KEY": "fixture"},
                                                 capture_output=True, timeout=30)
                        self.assertEqual(process.returncode, 0)
                        self.assertEqual(adapter.response(process.stdout.splitlines()), "OK")
                        self.assertEqual(seen, [("/v1/responses", "Bearer fixture", "gpt-6.2-sol",
                                                 {"effort": "medium"}, [], vision)])
            finally:
                proxy.shutdown()
