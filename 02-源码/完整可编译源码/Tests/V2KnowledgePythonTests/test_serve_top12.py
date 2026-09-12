import io
import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Resources" / "V2Knowledge"))

from serve_top12 import serve


class FakeEngine:
    def __init__(self, fail_semantic: bool = False):
        self.fail_semantic = fail_semantic
        self.queries = []
        self.lexical_queries = []

    @property
    def ready_version(self):
        return "v2-top12"

    def query(self, history_jsonl):
        self.queries.append(history_jsonl)
        if self.fail_semantic:
            raise RuntimeError("semantic unavailable")
        return {
            "version": "v2-top12",
            "documents": ["answer.md"],
            "context": "SOURCE: answer.md\nanswer",
        }

    def query_lexical_only(self, history_jsonl):
        self.lexical_queries.append(history_jsonl)
        return {
            "version": "v2-lexical-only",
            "documents": ["fallback.md"],
            "context": "SOURCE: fallback.md\nfallback",
        }


class ServeTop12Tests(unittest.TestCase):
    def records(self, value):
        return [json.loads(line) for line in value.getvalue().splitlines()]

    def test_one_worker_serves_multiple_queries_with_matching_ids(self):
        engine = FakeEngine()
        source = io.StringIO(
            '{"id":"a","history_jsonl":"first"}\n'
            '{"id":"b","history_jsonl":"second"}\n'
        )
        output = io.StringIO()

        serve(engine, source, output)

        records = self.records(output)
        self.assertEqual(records[0], {"type": "ready", "version": "v2-top12"})
        self.assertEqual([record["id"] for record in records[1:]], ["a", "b"])
        self.assertTrue(all(record["ok"] for record in records[1:]))
        self.assertEqual(engine.queries, ["first", "second"])

    def test_bad_request_returns_error_and_next_request_still_succeeds(self):
        engine = FakeEngine()
        source = io.StringIO(
            'not-json\n'
            '{"id":"good","history_jsonl":"question"}\n'
        )
        output = io.StringIO()

        serve(engine, source, output)

        records = self.records(output)
        self.assertFalse(records[1]["ok"])
        self.assertIsNone(records[1]["id"])
        self.assertEqual(records[2]["id"], "good")
        self.assertTrue(records[2]["ok"])

    def test_semantic_failure_returns_lexical_only_context_without_zip_path(self):
        engine = FakeEngine(fail_semantic=True)
        source = io.StringIO('{"id":"a","history_jsonl":"question"}\n')
        output = io.StringIO()

        serve(engine, source, output)

        response = self.records(output)[1]
        self.assertTrue(response["ok"])
        self.assertEqual(response["result"]["version"], "v2-lexical-only")
        self.assertNotIn(".zip", response["result"]["context"].casefold())
        self.assertEqual(engine.lexical_queries, ["question"])

    def test_build_requires_and_verifies_persistent_worker_resource(self):
        build_script = (ROOT / "scripts" / "build-app.sh").read_text(encoding="utf-8")

        self.assertGreaterEqual(build_script.count("serve_top12.py"), 2)

    def test_build_generates_and_verifies_trusted_knowledge_manifest(self):
        build_script = (ROOT / "scripts" / "build-app.sh").read_text(encoding="utf-8")

        self.assertIn('"knowledge_sha256"', build_script)
        self.assertIn('"index_algorithm_version"', build_script)
        self.assertGreaterEqual(build_script.count("KnowledgeBase/manifest.json"), 2)


if __name__ == "__main__":
    unittest.main()
