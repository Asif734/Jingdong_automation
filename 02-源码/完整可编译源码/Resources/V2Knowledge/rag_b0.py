from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import uuid
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


MODEL_RE = re.compile(r"(?<![A-Za-z0-9])[A-Z]{1,6}-?\d{2,5}[A-Z]{0,4}(?![A-Za-z0-9])", re.I)
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
CJK_RE = re.compile(r"[\u3400-\u9fff]+")
ASCII_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.+-]*")
SPACE_RE = re.compile(r"\s+")
NON_PRODUCT_MODEL_RE = re.compile(r"^(?:WIN(?:DOWS)?|MACOS|IOS|ANDROID)\d*[A-Z]*$", re.I)


def document_role_weight(document: str) -> float:
    """Prefer authoritative/specialized sources over broad learning corpora."""
    name = document.casefold()
    weight = 0.0
    if "confirmed_customer_service_updates" in name:
        weight += 4.0
    if any(part in name for part in ("official_specs", "manual_customer_reply", "after_sales_issues")):
        weight += 3.0
    if name.startswith("printernoble_"):
        weight += 2.0
    if any(part in name for part in ("connectivity_os", "driver_install", "feed_modes", "model_dimensions")):
        weight += 2.5
    if any(part in name for part in ("policy", "video_materials", "video_analysis", "shift_overlap")):
        weight += 2.0
    if "product_selling_points" in name:
        weight += 1.5
    if "training" in name:
        weight -= 6.0
    if "competitor" in name:
        weight -= 5.0
    if name == "readme.md":
        weight -= 8.0
    return weight


@dataclass(frozen=True)
class Section:
    document: str
    ordinal: int
    heading_path: tuple[str, ...]
    body: str
    context: str
    models: tuple[str, ...]
    heading_models: tuple[str, ...]


@dataclass(frozen=True)
class QueryInfo:
    text: str
    latest_customer_text: str
    active_models: tuple[str, ...]


@dataclass(frozen=True)
class RetrievalResult:
    documents: tuple[str, ...]
    context: str
    needs_full_kb_fallback: bool
    score: float
    chunks: tuple[Section, ...]


def _models(text: str) -> tuple[str, ...]:
    return tuple(
        sorted(
            {
                match.upper()
                for match in MODEL_RE.findall(text)
                if not NON_PRODUCT_MODEL_RE.fullmatch(match)
            }
        )
    )


def _affirmed_models(text: str) -> tuple[str, ...]:
    affirmed: list[str] = []
    for match in MODEL_RE.finditer(text):
        if NON_PRODUCT_MODEL_RE.fullmatch(match.group(0)):
            continue
        before = text[max(0, match.start() - 10) : match.start()]
        after = text[match.end() : match.end() + 24]
        negated_before = re.search(r"(?:不是|并非|非|别用|不要用|排除)\s*$", before)
        negated_after = re.search(r"^(?:\s|的|这个|这台|包装|机器|型号|尺寸)*(?:不是|并非|不要|别|不用|排除|作废|旧)", after)
        if negated_before or negated_after:
            continue
        affirmed.append(match.group(0).upper())
    return tuple(sorted(set(affirmed)))


def _render_context(path: Sequence[str], body: str) -> str:
    headings = "\n".join(f"{'#' * (i + 1)} {title}" for i, title in enumerate(path))
    if headings and body.strip():
        return f"{headings}\n\n{body.strip()}"
    return headings or body.strip()


def parse_markdown_sections(document: str, markdown: str) -> list[Section]:
    """Split Markdown at headings while retaining the full heading ancestry."""
    sections: list[Section] = []
    stack: list[str] = []
    current_path: tuple[str, ...] = ()
    body_lines: list[str] = []

    def flush() -> None:
        body = "\n".join(body_lines).strip()
        if not body and not current_path:
            return
        context = _render_context(current_path, body)
        sections.append(
            Section(
                document=Path(document).name,
                ordinal=len(sections),
                heading_path=current_path,
                body=body,
                context=context,
                models=_models(context),
                heading_models=_models(" ".join(current_path)),
            )
        )

    for line in markdown.splitlines():
        match = HEADING_RE.match(line)
        if not match:
            body_lines.append(line)
            continue
        flush()
        body_lines = []
        level = len(match.group(1))
        title = match.group(2).strip()
        stack = stack[: level - 1]
        stack.append(title)
        current_path = tuple(stack)
    flush()
    return sections


def extract_query_text(history: Sequence[dict]) -> QueryInfo:
    conversation_messages = [
        str(message.get("v", "")).strip()
        for message in history
        if message.get("sender") in {"customer", "service"} and str(message.get("v", "")).strip()
    ]
    customer_messages = [
        str(message.get("v", "")).strip()
        for message in history
        if message.get("sender") == "customer" and str(message.get("v", "")).strip()
    ]
    latest = customer_messages[-1] if customer_messages else ""
    latest_models = _affirmed_models(latest)
    if latest_models:
        active = latest_models
    else:
        active = ()
        for message in reversed(customer_messages[:-1]):
            found = _affirmed_models(message)
            if found:
                active = found
                break
    # The latest message is repeated to give it more lexical weight without
    # deleting useful earlier customer context.
    text = "\n".join(conversation_messages + ([latest, latest] if latest else []))
    return QueryInfo(text=text, latest_customer_text=latest, active_models=active)


def lexical_tokens(text: str) -> tuple[str, ...]:
    """Generate deterministic CJK bigram/trigram and ASCII tokens for FTS5."""
    values: list[str] = []
    for token in ASCII_RE.findall(text):
        normalized = token.casefold()
        if len(normalized) >= 2 or any(ch.isdigit() for ch in normalized):
            values.append(normalized)
    for run in CJK_RE.findall(text):
        if len(run) == 1:
            values.append(run)
            continue
        for size in (2, 3):
            if len(run) >= size:
                values.extend(run[index : index + size] for index in range(len(run) - size + 1))
    # Preserve order and cap pathological chat histories.
    return tuple(dict.fromkeys(values))


def _fts_query(tokens: Iterable[str], maximum: int = 96) -> str:
    escaped = []
    for token in list(tokens)[-maximum:]:
        escaped.append('"' + token.replace('"', '""') + '"')
    return " OR ".join(escaped)


class KnowledgeIndex:
    def __init__(self, connection: sqlite3.Connection, sections: Sequence[Section], zip_sha256: str):
        self.connection = connection
        self.sections = tuple(sections)
        self.zip_sha256 = zip_sha256
        self._by_key = {(section.document, section.ordinal): section for section in sections}

    @classmethod
    def build(cls, zip_path: Path | str, database_path: Path | str | None = None) -> "KnowledgeIndex":
        zip_path = Path(zip_path)
        digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
        sections: list[Section] = []
        with zipfile.ZipFile(zip_path) as archive:
            for name in sorted(item for item in archive.namelist() if item.lower().endswith(".md")):
                markdown = archive.read(name).decode("utf-8")
                sections.extend(parse_markdown_sections(Path(name).name, markdown))

        connection = sqlite3.connect(str(database_path) if database_path else ":memory:")
        connection.row_factory = sqlite3.Row
        connection.execute("DROP TABLE IF EXISTS sections_fts")
        connection.execute(
            "CREATE VIRTUAL TABLE sections_fts USING fts5(lex, document UNINDEXED, ordinal UNINDEXED, tokenize='unicode61')"
        )
        connection.executemany(
            "INSERT INTO sections_fts(lex, document, ordinal) VALUES (?, ?, ?)",
            [
                (
                    " ".join(lexical_tokens(" ".join(section.heading_path) + "\n" + section.body)),
                    section.document,
                    section.ordinal,
                )
                for section in sections
            ],
        )
        connection.commit()
        return cls(connection, sections, digest)

    @classmethod
    def load_or_build(
        cls,
        zip_path: Path | str,
        index_root: Path | str,
        knowledge_sha256: str,
        algorithm_version: str,
    ) -> "KnowledgeIndex":
        if not re.fullmatch(r"[0-9a-f]{64}", knowledge_sha256):
            raise ValueError("knowledge_sha256 must be 64 lowercase hexadecimal characters")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", algorithm_version):
            raise ValueError("algorithm_version contains unsupported characters")
        zip_path = Path(zip_path)
        index_root = Path(index_root)
        index_root.mkdir(parents=True, exist_ok=True)
        target = index_root / f"{knowledge_sha256}-{algorithm_version}"
        loaded = cls._load_persistent(target, knowledge_sha256, algorithm_version)
        if loaded is not None:
            return loaded

        if target.exists():
            target.rename(index_root / f"{target.name}.invalid-{uuid.uuid4().hex}")
        building = index_root / f"{target.name}.building-{uuid.uuid4().hex}"
        building.mkdir()
        built = cls.build(zip_path, building / "lexical.sqlite")
        try:
            if built.zip_sha256 != knowledge_sha256:
                raise ValueError("knowledge ZIP SHA-256 does not match the trusted manifest")
            sections_path = building / "sections.jsonl"
            with sections_path.open("w", encoding="utf-8") as handle:
                for section in built.sections:
                    handle.write(json.dumps(cls._section_payload(section), ensure_ascii=False))
                    handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            manifest = {
                "knowledge_sha256": knowledge_sha256,
                "algorithm_version": algorithm_version,
                "documents": len({section.document for section in built.sections}),
                "sections": len(built.sections),
            }
            cls._write_synced_text(
                building / "manifest.json",
                json.dumps(manifest, ensure_ascii=False, sort_keys=True) + "\n",
            )
            cls._write_synced_text(building / "ready.marker", "v2-persistent-index\n")
        finally:
            built.connection.close()
        building.rename(target)
        loaded = cls._load_persistent(target, knowledge_sha256, algorithm_version)
        if loaded is None:
            raise RuntimeError("persistent knowledge index failed validation after build")
        return loaded

    @staticmethod
    def _section_payload(section: Section) -> dict:
        return {
            "document": section.document,
            "ordinal": section.ordinal,
            "heading_path": list(section.heading_path),
            "body": section.body,
            "context": section.context,
            "models": list(section.models),
            "heading_models": list(section.heading_models),
        }

    @staticmethod
    def _write_synced_text(path: Path, value: str) -> None:
        with path.open("w", encoding="utf-8") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())

    @classmethod
    def _load_persistent(
        cls,
        directory: Path,
        knowledge_sha256: str,
        algorithm_version: str,
    ) -> "KnowledgeIndex | None":
        manifest_path = directory / "manifest.json"
        sections_path = directory / "sections.jsonl"
        database_path = directory / "lexical.sqlite"
        marker_path = directory / "ready.marker"
        if not all(path.is_file() for path in (manifest_path, sections_path, database_path, marker_path)):
            return None
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            if manifest.get("knowledge_sha256") != knowledge_sha256:
                return None
            if manifest.get("algorithm_version") != algorithm_version:
                return None
            sections = []
            for line in sections_path.read_text(encoding="utf-8").splitlines():
                payload = json.loads(line)
                sections.append(
                    Section(
                        document=str(payload["document"]),
                        ordinal=int(payload["ordinal"]),
                        heading_path=tuple(payload["heading_path"]),
                        body=str(payload["body"]),
                        context=str(payload["context"]),
                        models=tuple(payload["models"]),
                        heading_models=tuple(payload["heading_models"]),
                    )
                )
            if len(sections) != int(manifest["sections"]):
                return None
            connection = sqlite3.connect(str(database_path))
            connection.row_factory = sqlite3.Row
            row_count = int(connection.execute("SELECT COUNT(*) FROM sections_fts").fetchone()[0])
            if row_count != len(sections):
                connection.close()
                return None
            return cls(connection, sections, knowledge_sha256)
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError, sqlite3.Error):
            return None

    def _scored_sections(self, history: Sequence[dict]) -> tuple[QueryInfo, list[tuple[float, Section]]]:
        query = extract_query_text(history)
        tokens = lexical_tokens(query.text)
        expression = _fts_query(tokens)
        if not expression:
            return query, []

        rows = self.connection.execute(
            "SELECT document, ordinal, bm25(sections_fts) AS rank "
            "FROM sections_fts WHERE sections_fts MATCH ? ORDER BY rank LIMIT 80",
            (expression,),
        ).fetchall()
        if not rows:
            return query, []

        query_token_set = set(tokens)
        scored: list[tuple[float, Section]] = []
        for position, row in enumerate(rows):
            section = self._by_key[(row["document"], int(row["ordinal"]))]
            section_tokens = set(lexical_tokens(" ".join(section.heading_path) + "\n" + section.body))
            overlap = len(query_token_set & section_tokens)
            score = overlap * 0.35 + max(0.0, 3.0 - position * 0.04)
            if query.active_models:
                active = set(query.active_models)
                if active & set(section.models):
                    score += 12.0
                if section.heading_models and not (active & set(section.heading_models)):
                    score -= 8.0
            if query.latest_customer_text:
                latest_tokens = set(lexical_tokens(query.latest_customer_text))
                score += len(latest_tokens & section_tokens) * 0.55
            score += document_role_weight(section.document)
            scored.append((score, section))

        scored.sort(key=lambda value: (-value[0], value[1].document, value[1].ordinal))
        return query, scored

    def rank_sections(self, history: Sequence[dict], limit: int = 80) -> list[Section]:
        _, scored = self._scored_sections(history)
        return [section for _, section in scored[:limit]]

    def retrieve(self, history: Sequence[dict], limit: int = 6) -> RetrievalResult:
        query, scored = self._scored_sections(history)
        if not scored:
            return RetrievalResult((), "", True, 0.0, ())
        # Rank documents first. A long catch-all document must not consume the
        # entire candidate budget merely because several of its sections match.
        best_per_document: dict[str, tuple[float, Section]] = {}
        for score, section in scored:
            current = best_per_document.get(section.document)
            if current is None or score > current[0]:
                best_per_document[section.document] = (score, section)
        document_candidates = sorted(
            best_per_document.values(),
            key=lambda value: (-value[0], value[1].document, value[1].ordinal),
        )
        selected: list[Section] = []
        for score, section in document_candidates:
            if query.active_models and section.heading_models:
                if not (set(query.active_models) & set(section.heading_models)):
                    continue
            selected.append(section)
            if len(selected) >= limit:
                break

        best_score = scored[0][0] if scored else 0.0
        # A model match or several lexical matches is required before the
        # fast path is trusted. Otherwise the caller must use the full ZIP.
        confident = bool(selected) and (best_score >= 5.0 or bool(query.active_models))
        if not confident:
            return RetrievalResult((), "", True, best_score, ())

        documents = tuple(dict.fromkeys(section.document for section in selected))
        context_parts = [
            f"SOURCE: {section.document}\nSECTION: {' > '.join(section.heading_path)}\n{section.context}"
            for section in selected
        ]
        return RetrievalResult(
            documents=documents,
            context="\n\n---\n\n".join(context_parts),
            needs_full_kb_fallback=False,
            score=best_score,
            chunks=tuple(selected),
        )

    def model_documents(self, models: Sequence[str]) -> list[str]:
        active = {model.upper() for model in models}
        if not active:
            return []
        scores: dict[str, float] = {}
        for section in self.sections:
            if not (active & set(section.models)):
                continue
            score = document_role_weight(section.document)
            if active & set(section.heading_models):
                score += 3.0
            scores[section.document] = max(scores.get(section.document, -100.0), score)
        return sorted(scores, key=lambda document: (-scores[document], document))


def write_manifest(index: KnowledgeIndex, path: Path | str) -> None:
    payload = {
        "zip_sha256": index.zip_sha256,
        "documents": len({section.document for section in index.sections}),
        "sections": len(index.sections),
    }
    Path(path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
