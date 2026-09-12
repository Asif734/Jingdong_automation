#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import zipfile
from pathlib import Path

from hybrid import SemanticDocumentIndex, reciprocal_rank_fusion
from rag_b0 import KnowledgeIndex, extract_query_text


PINNED = (
    "grozziie_china_customer_service_policy_kb.md",
    "customer_service_global_clarification_policy_kb.md",
)

MEDIA_DOCUMENT = "qianniu_video_materials_kb.md"
MAX_CONTEXT_CHARACTERS = 36_000


def load_history(jsonl: str) -> list[dict]:
    messages: list[dict] = []
    for line in jsonl.splitlines():
        line = line.strip()
        if not line:
            continue
        value = json.loads(line)
        if isinstance(value, dict):
            messages.append(value)
    return messages


def load_documents(zip_path: Path) -> dict[str, str]:
    with zipfile.ZipFile(zip_path) as archive:
        return {
            Path(name).name: archive.read(name).decode("utf-8")
            for name in archive.namelist()
            if name.lower().endswith(".md")
        }


def focused_sections(history, query, allowed, lexical, semantic, include_media=False) -> list[str]:
    by_key = {f"{section.document}#{section.ordinal}": section for section in lexical.sections}
    lexical_sections = [section for section in lexical.rank_sections(history) if section.document in allowed]
    semantic_sections = [section for section in semantic.rank_sections(query) if section.document in allowed]
    ranking = reciprocal_rank_fusion(
        [f"{section.document}#{section.ordinal}" for section in lexical_sections],
        [f"{section.document}#{section.ordinal}" for section in semantic_sections],
        constant=10,
        weights=(0.5, 1.0),
    )
    counts: dict[str, int] = {}
    selected: list[str] = []
    selected_keys: set[str] = set()

    # A media request needs the original URL-bearing section, not merely the
    # nearby setup rule or the generic video index.  Rank these sections with
    # the same semantic model and reserve at most two slots so normal evidence
    # remains dominant and unrelated links are not sprayed into the prompt.
    if include_media:
        for section in semantic_sections:
            if section.document not in allowed:
                continue
            context = section.context.casefold()
            if ".mp4" not in context or not ("http://" in context or "https://" in context):
                continue
            key = f"{section.document}#{section.ordinal}"
            selected.append(f"SOURCE: {section.document}\n{section.context}")
            selected_keys.add(key)
            if len(selected) >= 2:
                break

    for key in ranking:
        if key in selected_keys:
            continue
        section = by_key[key]
        if counts.get(section.document, 0) >= 3:
            continue
        selected.append(f"SOURCE: {section.document}\n{section.context}")
        selected_keys.add(key)
        counts[section.document] = counts.get(section.document, 0) + 1
        if len(selected) >= 16:
            break
    return selected


def is_media_request(query) -> bool:
    text = query.text.casefold()
    return any(term in text for term in ("视频", "教程", "链接", "video", ".mp4"))


def compact_original_context(selected: list[str], focus: list[str]) -> str:
    kept: list[str] = []
    used = 0
    for section in focus:
        addition = len(section) + (9 if kept else 0)
        if kept and used + addition > MAX_CONTEXT_CHARACTERS:
            continue
        kept.append(section)
        used += addition
    candidate_list = "\n".join(f"- {name}" for name in selected)
    blocks = [
        "<retrieved_document_candidates>\n"
        + candidate_list
        + "\n</retrieved_document_candidates>"
    ]
    if kept:
        blocks.append(
            "<most_relevant_original_sections>\n"
            + "\n\n---\n\n".join(kept)
            + "\n</most_relevant_original_sections>"
        )
    return "\n\n".join(blocks)


def ensure_seed_cache(seed: Path, writable: Path) -> None:
    marker = writable / ".v2-seed-ready"
    if marker.exists():
        return
    writable.mkdir(parents=True, exist_ok=True)
    shutil.copytree(seed, writable, dirs_exist_ok=True)
    marker.write_text("v2-top12\n", encoding="utf-8")


class RetrieverEngine:
    def __init__(self, lexical: KnowledgeIndex, semantic: SemanticDocumentIndex | None):
        self.lexical = lexical
        self.semantic = semantic

    @property
    def ready_version(self) -> str:
        return "v2-top12" if self.semantic is not None else "v2-lexical-only"

    @classmethod
    def from_paths(cls, zip_path: Path, writable_cache: Path) -> "RetrieverEngine":
        lexical = KnowledgeIndex.build(zip_path)
        semantic = SemanticDocumentIndex.build(lexical.sections, writable_cache)
        return cls(lexical, semantic)

    def query(self, history_jsonl: str) -> dict:
        if self.semantic is None:
            raise RuntimeError("semantic index is unavailable")
        history = load_history(history_jsonl)
        query = extract_query_text(history)
        lexical_rank = list(self.lexical.retrieve(history, limit=28).documents)
        semantic_rank = self.semantic.rank(query)
        route = self.lexical.model_documents(query.active_models)
        ranking = reciprocal_rank_fusion(
            lexical_rank,
            semantic_rank,
            route,
            constant=3,
            weights=(0.25, 1.0, 0.5),
        )
        selected = list(dict.fromkeys([
            *PINNED,
            *([MEDIA_DOCUMENT] if is_media_request(query) else []),
            *ranking[:12],
        ]))
        allowed = set(selected)
        focus = focused_sections(
            history,
            query,
            allowed,
            self.lexical,
            self.semantic,
            include_media=is_media_request(query),
        )
        return {
            "version": "v2-top12",
            "documents": selected,
            "context": compact_original_context(selected, focus),
        }

    def query_lexical_only(self, history_jsonl: str) -> dict:
        history = load_history(history_jsonl)
        query = extract_query_text(history)
        lexical_rank = list(self.lexical.retrieve(history, limit=28).documents)
        route = self.lexical.model_documents(query.active_models)
        ranking = reciprocal_rank_fusion(
            lexical_rank,
            route,
            constant=3,
            weights=(1.0, 0.5),
        )
        selected = list(dict.fromkeys([
            *PINNED,
            *([MEDIA_DOCUMENT] if is_media_request(query) else []),
            *ranking[:12],
        ]))
        allowed = set(selected)
        counts: dict[str, int] = {}
        focus: list[str] = []
        for section in self.lexical.rank_sections(history):
            if section.document not in allowed or counts.get(section.document, 0) >= 3:
                continue
            focus.append(f"SOURCE: {section.document}\n{section.context}")
            counts[section.document] = counts.get(section.document, 0) + 1
            if len(focus) >= 16:
                break
        return {
            "version": "v2-lexical-only",
            "documents": selected,
            "context": compact_original_context(selected, focus),
        }


def retrieve(request: dict) -> dict:
    zip_path = Path(request["knowledge_base_path"])
    writable_cache = Path(request["cache_directory"])
    ensure_seed_cache(Path(request["seed_cache_directory"]), writable_cache)
    return RetrieverEngine.from_paths(zip_path, writable_cache).query(request["history_jsonl"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    request = json.loads(Path(args.request).read_text(encoding="utf-8"))
    result = retrieve(request)
    Path(args.output).write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
