import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/actions/opencode-v2"))
import adapter


class AdapterContract(unittest.TestCase):
    def test_all_ci_callers_use_the_shared_gateway_workflow(self):
        workflows = Path(__file__).resolve().parents[2] / ".github/workflows"
        for name in ("opencode-pr", "opencode-v2-pr", "opencode-triage", "opencode",
                     "opencode-audit", "opencode-test-writer", "visual-test", "opencode-v2-proxy-smoke"):
            with self.subTest(workflow=name):
                workflow = (workflows / f"{name}.yml").read_text()
                self.assertIn("uses: ./.github/workflows/opencode-v2-infer.yml", workflow)
                self.assertNotIn("anomalyco/opencode/github@", workflow)

    def test_text_and_image_requests_share_gateway_model_and_effort(self):
        url = "https://proxy.example.ts.net/v1"
        for vision in (False, True):
            providers = adapter.config(url, vision)["providers"]
            self.assertEqual(set(providers), {"zigcraft"})
            provider = providers["zigcraft"]
            self.assertEqual(provider["settings"]["baseURL"], url)
            self.assertEqual(provider["models"]["selected"]["modelID"], "gpt-6.2-sol")
            self.assertEqual(provider["body"]["reasoning"], {"effort": "medium"})

    def test_endpoint_rejects_other_schemes_hosts_and_paths(self):
        self.assertEqual(adapter.endpoint("https://proxy.example.ts.net:8443/v1"),
                         ("proxy.example.ts.net", 8443))
        for url in ("http://proxy.example.ts.net/v1", "https://api.example.org/v1",
                    "https://user@proxy.example.ts.net/v1", "https://proxy.example.ts.net/v1?key=X",
                    "https://proxy.example.ts.net/v1/../other"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                adapter.endpoint(url)

    def test_request_allows_only_named_bounded_data(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(adapter.os.environ,
                                                               RUNNER_TEMP=temp, PROFILE="default"):
            request = Path(temp, "opencode-request")
            request.mkdir()
            prompt = request / "request.txt"
            prompt.write_text("test prompt")
            self.assertEqual(adapter.request(), ("test prompt", None))
            config = request / "opencode.json"
            config.write_text("{}")
            with self.assertRaises(ValueError):
                adapter.request()
            config.unlink()
            prompt.write_bytes(b"a" * (adapter.REQUEST_LIMIT + 1))
            with self.assertRaises(ValueError):
                adapter.request()

    def test_client_key_is_required_before_cli_start(self):
        with patch.object(adapter, "request", return_value=("test", None)), \
                patch.dict(adapter.os.environ, BASE_URL="https://proxy.example.ts.net/v1", ZIGCRAFT_PROXY_KEY=""), \
                self.assertRaisesRegex(adapter.StageError, "Missing proxy client key"):
            adapter.infer()

    def test_peer_verification_precedes_tls_and_firewall(self):
        status = {"Peer": {"p": {"DNSName": "other.example.ts.net.", "Online": True}}}
        with patch.dict(adapter.os.environ, BASE_URL="https://proxy.example.ts.net/v1"), \
                patch.object(adapter, "command", return_value=json.dumps(status)) as cmd, \
                self.assertRaisesRegex(adapter.StageError, "Proxy peer unavailable"):
            adapter.connect()
        cmd.assert_called_once_with("tailscale", "status", "--json")

    def test_response_requires_completed_tool_free_request(self):
        text = {"type": "text", "part": {"text": "OK"}}
        stop = {"type": "step_finish", "part": {"reason": "stop"}}
        def stream(*events):
            return [json.dumps(event).encode() for event in events]
        self.assertEqual(adapter.response(stream(text, stop)), "OK")
        for events in [(text,), (text, {"type": "tool_use"}, stop),
                       (text, {"type": "step_finish", "part": {"reason": "length"}}),
                       (text, stop, {"type": "error", "error": {"status": 403}}),
                       ({"type": "retry", "error": {"status": 429}}, text, stop)]:
            with self.subTest(events=events), self.assertRaises(adapter.StageError):
                adapter.response(stream(*events))
