import json
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from app.knowledge_retriever import KnowledgeRetriever


class KnowledgeRetrieverTests(unittest.TestCase):
    def test_returns_v2_documents_and_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / "cache").mkdir(); (root / "seed").mkdir()
            (root / "sibling.py").write_text("VALUE = '供电'\n", encoding="utf-8")
            (root / "retrieve_top12.py").write_text(
                "from sibling import VALUE\ndef retrieve(request):\n return {'version':'v2-top12','documents':['m880.md'],'context':'SOURCE: m880.md\\n'+VALUE}\n",
                encoding="utf-8",
            )
            kb = root / "kb.zip"; kb.write_bytes(b"zip")
            result = KnowledgeRetriever(root, root / "seed", root / "cache").retrieve('{"v":"M880"}\n', kb)
            self.assertEqual(("m880.md",), result.documents)
            self.assertEqual("v2-top12", result.mode)

    def test_failure_returns_full_zip_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); root.mkdir(exist_ok=True)
            kb = root / "kb.zip"; kb.write_bytes(b"zip")
            errors = io.StringIO()
            with redirect_stderr(errors):
                result = KnowledgeRetriever(root, root / "seed", root / "cache").retrieve("{}\n", kb)
            self.assertEqual("full-zip-fallback", result.mode)
            self.assertEqual("", result.context)
            self.assertIn("V2 knowledge retrieval failed", errors.getvalue())
            self.assertIn("retrieve_top12.py", errors.getvalue())
