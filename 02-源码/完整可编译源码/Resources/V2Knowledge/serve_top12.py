#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import TextIO

from hybrid import SemanticDocumentIndex
from rag_b0 import KnowledgeIndex
from retrieve_top12 import RetrieverEngine, ensure_seed_cache


def _emit(output_stream: TextIO, value: dict) -> None:
    output_stream.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    output_stream.flush()


def serve(engine: RetrieverEngine, input_stream: TextIO, output_stream: TextIO) -> None:
    _emit(output_stream, {"type": "ready", "version": engine.ready_version})
    for line in input_stream:
        request_id = None
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("request must be a JSON object")
            if request.get("type") == "shutdown":
                return
            request_id = request.get("id")
            history_jsonl = request.get("history_jsonl")
            if not isinstance(request_id, str) or not request_id:
                raise ValueError("request id must be a nonempty string")
            if not isinstance(history_jsonl, str):
                raise ValueError("history_jsonl must be a string")
            try:
                result = engine.query(history_jsonl)
            except Exception as semantic_error:
                print(f"semantic query failed; using lexical-only: {semantic_error}", file=sys.stderr)
                result = engine.query_lexical_only(history_jsonl)
            _emit(output_stream, {"id": request_id, "ok": True, "result": result})
        except Exception as error:
            _emit(output_stream, {"id": request_id, "ok": False, "error": str(error)})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--knowledge-base", required=True)
    parser.add_argument("--knowledge-sha256", required=True)
    parser.add_argument("--cache-directory", required=True)
    parser.add_argument("--seed-cache-directory", required=True)
    parser.add_argument("--index-root", required=True)
    parser.add_argument("--index-algorithm-version", required=True)
    args = parser.parse_args()

    cache_directory = Path(args.cache_directory)
    ensure_seed_cache(Path(args.seed_cache_directory), cache_directory)
    lexical = KnowledgeIndex.load_or_build(
        Path(args.knowledge_base),
        Path(args.index_root),
        args.knowledge_sha256,
        args.index_algorithm_version,
    )
    try:
        semantic = SemanticDocumentIndex.build(lexical.sections, cache_directory)
    except Exception as error:
        print(f"semantic index unavailable; starting lexical-only: {error}", file=sys.stderr)
        semantic = None
    serve(RetrieverEngine(lexical, semantic), sys.stdin, sys.stdout)


if __name__ == "__main__":
    main()
