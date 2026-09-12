import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Resources" / "V2Knowledge"))

from retrieve_top12 import RetrieverEngine, retrieve
from rag_b0 import Section


class RetrieveTop12Tests(unittest.TestCase):
    def test_engine_builds_indexes_once_and_reuses_them_for_multiple_queries(self):
        lexical = SimpleNamespace(
            sections=(),
            retrieve=lambda history, limit: SimpleNamespace(documents=()),
            model_documents=lambda models: [],
            rank_sections=lambda history: [],
        )
        semantic = SimpleNamespace(
            rank=lambda query: [],
            rank_sections=lambda query: [],
        )
        with mock.patch("retrieve_top12.KnowledgeIndex.build", return_value=lexical) as lexical_build, \
             mock.patch("retrieve_top12.SemanticDocumentIndex.build", return_value=semantic) as semantic_build:
            engine = RetrieverEngine.from_paths(Path("kb.zip"), Path("cache"))
            first = engine.query('{"sender":"customer","v":"怎么连接蓝牙"}\n')
            second = engine.query('{"sender":"customer","v":"怎么连接蓝牙"}\n')

        self.assertEqual(first, second)
        self.assertEqual(lexical_build.call_count, 1)
        self.assertEqual(semantic_build.call_count, 1)

    def test_lexical_only_query_returns_bounded_original_context(self):
        section = Section(
            document="bluetooth.md",
            ordinal=0,
            heading_path=("蓝牙连接",),
            body="打开手机蓝牙并连接打印机。",
            context="# 蓝牙连接\n\n打开手机蓝牙并连接打印机。",
            models=(),
            heading_models=(),
        )
        lexical = SimpleNamespace(
            sections=(section,),
            retrieve=lambda history, limit: SimpleNamespace(documents=("bluetooth.md",)),
            model_documents=lambda models: [],
            rank_sections=lambda history: [section],
        )
        engine = RetrieverEngine(lexical, semantic=None)

        result = engine.query_lexical_only(
            '{"sender":"customer","v":"怎么连接蓝牙"}\n'
        )

        self.assertEqual(result["version"], "v2-lexical-only")
        self.assertIn("SOURCE: bluetooth.md", result["context"])
        self.assertLessEqual(len(result["context"]), 36_000)

    def retrieval_paths(self):
        knowledge_base = Path(os.environ.get("AUTOREPLY_KNOWLEDGE_BASE_SOURCE", ""))
        seed_cache = Path(os.environ.get("AUTOREPLY_V2_SEED_CACHE", ""))
        if not knowledge_base.is_file() or not seed_cache.is_dir():
            self.skipTest("portable V2 test inputs are unavailable")
        return knowledge_base, seed_cache

    def test_video_request_returns_compact_original_evidence_with_tmall_url(self):
        knowledge_base, seed_cache = self.retrieval_paths()
        history = "\n".join(
            [
                '{"sender":"customer","v":"M880班次有重叠"}',
                '{"sender":"service","v":"建议手动打卡"}',
                '{"sender":"customer","v":"视频发给我"}',
            ]
        )
        with tempfile.TemporaryDirectory() as directory:
            result = retrieve(
                {
                    "knowledge_base_path": str(knowledge_base),
                    "history_jsonl": history,
                    "cache_directory": directory,
                    "seed_cache_directory": str(seed_cache),
                }
            )

        self.assertLess(len(result["context"]), 45_000)
        self.assertIn("http://cloud.video.taobao.com", result["context"])
        self.assertTrue(
            "491279010943.mp4" in result["context"]
            or "491279178909.mp4" in result["context"]
        )

    def test_third_party_card_position_video_request_includes_exact_tmall_link(self):
        knowledge_base, seed_cache = self.retrieval_paths()
        history = (
            '{"sender":"customer","v":"M880第三方卡可以打印，但打印位置偏了，'
            '请发第三方卡打印位置微调视频。"}'
        )
        with tempfile.TemporaryDirectory() as directory:
            result = retrieve(
                {
                    "knowledge_base_path": str(knowledge_base),
                    "history_jsonl": history,
                    "cache_directory": directory,
                    "seed_cache_directory": str(seed_cache),
                }
            )

        self.assertLess(len(result["context"]), 45_000)
        self.assertIn("491279178909.mp4", result["context"])


if __name__ == "__main__":
    unittest.main()
