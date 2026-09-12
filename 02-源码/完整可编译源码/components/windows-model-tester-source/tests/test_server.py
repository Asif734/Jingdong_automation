import json
import sys
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from app.server import MissingCodexRunner, create_server


class FakeService:
    def create_conversation(self): return type("C", (), {"id":"abc", "version":0, "messages":()})()
    def list_conversations(self): return []


class SendingService(FakeService):
    def send(self, conversation_id, text, uploads, expected_version):
        conversation = type("C", (), {
            "id": conversation_id,
            "version": 2,
            "messages": (
                {"sender":"customer", "v":text},
                {"sender":"service", "v":"好的亲亲，我帮您转人工处理～"},
            ),
        })()
        return type("R", (), {
            "reply":"好的亲亲，我帮您转人工处理～",
            "action":"reply_then_transfer",
            "transfer_reason":"customer_explicitly_requested_human",
            "reason":"客户明确要求人工客服",
            "snapshot":conversation,
            "citations":(),
            "diagnostic":{},
        })()


class ServerTests(unittest.TestCase):
    def test_missing_codex_runner_reports_actionable_error_without_blocking_ui(self):
        with self.assertRaisesRegex(RuntimeError, "安装 Codex.*ChatGPT 登录"):
            MissingCodexRunner().generate("prompt", [], None)

    def test_health_and_conversation_creation_are_local_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = create_server(FakeService(), Path(tmp), "secret", 0)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            base = f"http://127.0.0.1:{server.server_port}"
            with urllib.request.urlopen(base + "/api/health") as response:
                value = json.load(response)
                self.assertEqual("ok", value["status"])
                self.assertEqual("no-store", response.headers["Cache-Control"])
            request = urllib.request.Request(base + "/api/conversations", data=b"{}", method="POST", headers={"Content-Type":"application/json"})
            with urllib.request.urlopen(request) as response: self.assertEqual("abc", json.load(response)["id"])
            server.shutdown(); server.server_close(); thread.join(2)

    def test_shutdown_requires_handshake(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = create_server(FakeService(), Path(tmp), "secret", 0)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            request = urllib.request.Request(f"http://127.0.0.1:{server.server_port}/api/shutdown", data=b"{}", method="POST", headers={"Content-Type":"application/json"})
            with self.assertRaises(urllib.error.HTTPError) as caught: urllib.request.urlopen(request)
            self.assertEqual(403, caught.exception.code)
            server.shutdown(); server.server_close(); thread.join(2)

    def test_message_response_includes_reply_text_and_model_action(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = create_server(SendingService(), Path(tmp), "secret", 0)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            body = json.dumps({"text":"我要人工", "images":[], "expected_version":0}).encode()
            request = urllib.request.Request(
                f"http://127.0.0.1:{server.server_port}/api/conversations/abc/messages",
                data=body,
                method="POST",
                headers={"Content-Type":"application/json"},
            )
            with urllib.request.urlopen(request) as response:
                value = json.load(response)
            self.assertEqual("好的亲亲，我帮您转人工处理～", value["reply"])
            self.assertEqual("reply_then_transfer", value["action"])
            self.assertEqual("customer_explicitly_requested_human", value["transfer_reason"])
            server.shutdown(); server.server_close(); thread.join(2)
