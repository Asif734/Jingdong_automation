import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from app.conversation_store import ConversationStore, StaleConversation


class ConversationStoreTests(unittest.TestCase):
    def test_round_trip_version_and_delete(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = ConversationStore(Path(tmp))
            created = store.create()
            snap = store.append_customer(created.id, "你好", [], 0)
            self.assertEqual(1, snap.version)
            self.assertEqual("customer", snap.messages[0]["sender"])
            snap = store.append_service(created.id, "您好", 1)
            self.assertEqual(2, snap.version)
            lines = (Path(tmp) / created.id / "history.jsonl").read_text(encoding="utf-8").splitlines()
            self.assertEqual(["customer", "service"], [json.loads(x)["sender"] for x in lines])
            store.delete(created.id)
            self.assertFalse((Path(tmp) / created.id).exists())

    def test_stale_version_cannot_duplicate_customer_message(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = ConversationStore(Path(tmp)); c = store.create()
            store.append_customer(c.id, "A", [], 0)
            with self.assertRaises(StaleConversation):
                store.append_customer(c.id, "A", [], 0)

    def test_image_is_copied_and_size_is_limited(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "图.png"; source.write_bytes(b"\x89PNG\r\n\x1a\nbody")
            store = ConversationStore(Path(tmp) / "data", max_image_bytes=20)
            c = store.create(); snap = store.append_customer(c.id, "[图片]", [source], 0)
            saved = Path(snap.messages[0]["image_paths"][0])
            self.assertTrue(saved.exists()); self.assertEqual(".png", saved.suffix)
            source.write_bytes(b"x" * 21)
            with self.assertRaises(ValueError):
                store.append_customer(c.id, "large", [source], 1)

