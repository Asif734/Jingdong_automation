import hashlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Resources" / "V2Knowledge"))

from rag_b0 import KnowledgeIndex


class PersistentKnowledgeIndexTests(unittest.TestCase):
    def make_knowledge_zip(self, root: Path) -> tuple[Path, str]:
        path = root / "knowledge.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("first.md", "# 蓝牙连接\n\n打开手机蓝牙并连接打印机。")
            archive.writestr("second.md", "# 走纸问题\n\n检查纸张安装方向。")
        return path, hashlib.sha256(path.read_bytes()).hexdigest()

    def test_second_load_reuses_complete_artifacts_without_opening_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            knowledge_zip, digest = self.make_knowledge_zip(root)
            index_root = root / "indexes"

            first = KnowledgeIndex.load_or_build(
                knowledge_zip, index_root, digest, "v2-index-1"
            )
            artifact = index_root / f"{digest}-v2-index-1"
            self.assertEqual(
                {"manifest.json", "sections.jsonl", "lexical.sqlite", "ready.marker"},
                {path.name for path in artifact.iterdir()},
            )
            first.connection.close()

            with mock.patch(
                "rag_b0.zipfile.ZipFile", side_effect=AssertionError("ZIP reopened")
            ):
                second = KnowledgeIndex.load_or_build(
                    knowledge_zip, index_root, digest, "v2-index-1"
                )

            self.assertEqual(len(second.sections), 2)
            self.assertEqual(second.zip_sha256, digest)
            second.connection.close()

    def test_missing_ready_marker_rebuilds_instead_of_loading_partial_index(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            knowledge_zip, digest = self.make_knowledge_zip(root)
            index_root = root / "indexes"
            first = KnowledgeIndex.load_or_build(
                knowledge_zip, index_root, digest, "v2-index-1"
            )
            first.connection.close()
            artifact = index_root / f"{digest}-v2-index-1"
            (artifact / "ready.marker").unlink()

            rebuilt = KnowledgeIndex.load_or_build(
                knowledge_zip, index_root, digest, "v2-index-1"
            )

            self.assertTrue((artifact / "ready.marker").is_file())
            self.assertEqual(len(rebuilt.sections), 2)
            rebuilt.connection.close()

    def test_algorithm_version_uses_a_separate_artifact_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            knowledge_zip, digest = self.make_knowledge_zip(root)
            index_root = root / "indexes"
            first = KnowledgeIndex.load_or_build(
                knowledge_zip, index_root, digest, "v2-index-1"
            )
            first.connection.close()

            second = KnowledgeIndex.load_or_build(
                knowledge_zip, index_root, digest, "v2-index-2"
            )

            self.assertTrue((index_root / f"{digest}-v2-index-1" / "ready.marker").is_file())
            self.assertTrue((index_root / f"{digest}-v2-index-2" / "ready.marker").is_file())
            second.connection.close()

    def test_rejects_untrusted_digest_and_unsafe_algorithm_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            knowledge_zip, digest = self.make_knowledge_zip(root)

            with self.assertRaisesRegex(ValueError, "knowledge_sha256"):
                KnowledgeIndex.load_or_build(knowledge_zip, root / "indexes", "wrong", "v2-index-1")
            with self.assertRaisesRegex(ValueError, "algorithm_version"):
                KnowledgeIndex.load_or_build(
                    knowledge_zip, root / "indexes", digest, "../outside"
                )


if __name__ == "__main__":
    unittest.main()
