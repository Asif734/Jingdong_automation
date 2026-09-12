import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from app.conversation_store import ConversationStore
from app.model import CodexResult, KnowledgeResult
from app.service import ModelTesterService


class Retriever:
    def retrieve(self, history, kb):
        return KnowledgeResult("v2-top12", ("m880.md",), "SOURCE: m880.md\n供电", "v2-top12")

class Runner:
    def __init__(self): self.calls = []
    def generate(self, prompt, images, session):
        self.calls.append((prompt, images, session))
        return CodexResult(
            "请重新接通电源。", "reply", "none", "提供下一步排障",
            "session-1", {"codex_ms": 12}
        )

class ModelTesterServiceTests(unittest.TestCase):
    def test_success_persists_customer_then_service_and_reuses_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); kb = root / "kb.zip"; kb.write_bytes(b"zip")
            runner = Runner(); service = ModelTesterService(ConversationStore(root / "conversations"), Retriever(), runner, kb, root / "sessions.json")
            c = service.create_conversation()
            result = service.send(c.id, "M880停电", [], 0)
            self.assertEqual("请重新接通电源。", result.reply)
            self.assertEqual("reply", result.action)
            self.assertEqual("none", result.transfer_reason)
            self.assertEqual(["customer", "service"], [m["sender"] for m in result.snapshot.messages])
            service.send(c.id, "还是不行", [], 2)
            self.assertEqual("session-1", runner.calls[1][2])
            self.assertNotIn("M880停电", runner.calls[1][0])
            self.assertIn("还是不行", runner.calls[1][0])
            self.assertIn("m880.md", result.citations)

    def test_transfer_decision_is_displayed_but_never_executes_qianniu(self):
        class TransferRunner(Runner):
            def generate(self, prompt, images, session):
                return CodexResult(
                    "好的亲亲，我帮您转人工处理～",
                    "reply_then_transfer",
                    "customer_explicitly_requested_human",
                    "客户明确要求人工客服",
                    "session-2",
                    {"codex_ms": 8},
                )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); kb = root / "kb.zip"; kb.write_bytes(b"zip")
            service = ModelTesterService(
                ConversationStore(root / "conversations"), Retriever(), TransferRunner(),
                kb, root / "sessions.json"
            )
            c = service.create_conversation()
            result = service.send(c.id, "我要人工客服", [], 0)
            self.assertEqual("reply_then_transfer", result.action)
            self.assertEqual("customer_explicitly_requested_human", result.transfer_reason)
            self.assertEqual(["customer", "service"], [m["sender"] for m in result.snapshot.messages])

    def test_generation_failure_keeps_customer_only(self):
        class Broken(Runner):
            def generate(self, prompt, images, session): raise RuntimeError("offline")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); kb = root / "kb.zip"; kb.write_bytes(b"zip")
            service = ModelTesterService(ConversationStore(root / "c"), Retriever(), Broken(), kb, root / "s.json")
            c = service.create_conversation()
            with self.assertRaises(RuntimeError): service.send(c.id, "问题", [], 0)
            self.assertEqual(["customer"], [m["sender"] for m in service.get_conversation(c.id).messages])
