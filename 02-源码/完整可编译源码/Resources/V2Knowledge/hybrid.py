from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

import numpy as np

from rag_b0 import QueryInfo, Section, document_role_weight


def reciprocal_rank_fusion(
    *rankings: Sequence[str],
    constant: float = 60.0,
    weights: Sequence[float] | None = None,
) -> list[str]:
    if weights is None:
        weights = [1.0] * len(rankings)
    if len(weights) != len(rankings):
        raise ValueError("weights must match rankings")
    scores: dict[str, float] = {}
    first_seen: dict[str, int] = {}
    sequence = 0
    for ranking, weight in zip(rankings, weights):
        for rank, document in enumerate(ranking, start=1):
            first_seen.setdefault(document, sequence)
            sequence += 1
            scores[document] = scores.get(document, 0.0) + weight / (constant + rank)
    return sorted(scores, key=lambda document: (-scores[document], first_seen[document], document))


@dataclass
class SemanticDocumentIndex:
    model: object
    sections: tuple[Section, ...]
    embeddings: np.ndarray

    @classmethod
    def build(
        cls,
        sections: Sequence[Section],
        cache_directory: Path | str,
        model_name: str = "BAAI/bge-small-zh-v1.5",
    ) -> "SemanticDocumentIndex":
        from fastembed import TextEmbedding

        cache_directory = Path(cache_directory)
        cache_directory.mkdir(parents=True, exist_ok=True)
        texts = [section.context for section in sections]
        content_hash = hashlib.sha256("\n\0\n".join(texts).encode()).hexdigest()
        safe_model = model_name.replace("/", "--")
        vectors_path = cache_directory / f"{safe_model}-{content_hash[:16]}.npy"
        metadata_path = vectors_path.with_suffix(".json")
        model = TextEmbedding(model_name=model_name, cache_dir=str(cache_directory / "models"))
        if vectors_path.exists() and metadata_path.exists():
            metadata = json.loads(metadata_path.read_text())
            if metadata.get("content_sha256") == content_hash and metadata.get("model") == model_name:
                return cls(model=model, sections=tuple(sections), embeddings=np.load(vectors_path))
        embeddings = np.asarray(list(model.embed(texts, batch_size=32)), dtype=np.float32)
        np.save(vectors_path, embeddings)
        metadata_path.write_text(
            json.dumps(
                {
                    "model": model_name,
                    "content_sha256": content_hash,
                    "sections": len(sections),
                    "shape": list(embeddings.shape),
                },
                ensure_ascii=False,
                indent=2,
            )
            + "\n"
        )
        return cls(model=model, sections=tuple(sections), embeddings=embeddings)

    def _section_scores(self, query: QueryInfo) -> np.ndarray:
        if not query.text.strip():
            return np.asarray([], dtype=np.float32)
        query_vector = np.asarray(next(iter(self.model.query_embed(query.text))), dtype=np.float32)
        similarities = self.embeddings @ query_vector
        active = set(query.active_models)
        scores = similarities.astype(np.float32, copy=True)
        for index, section in enumerate(self.sections):
            if active & set(section.models):
                scores[index] += 0.18
            if section.heading_models and active and not (active & set(section.heading_models)):
                scores[index] -= 0.12
            scores[index] += document_role_weight(section.document) * 0.01
        return scores

    def rank_sections(self, query: QueryInfo) -> list[Section]:
        scores = self._section_scores(query)
        if not len(scores):
            return []
        order = sorted(
            range(len(self.sections)),
            key=lambda index: (-float(scores[index]), self.sections[index].document, self.sections[index].ordinal),
        )
        return [self.sections[index] for index in order]

    def rank(self, query: QueryInfo) -> list[str]:
        scores = self._section_scores(query)
        if not len(scores):
            return []
        document_scores: dict[str, float] = {}
        for index, section in enumerate(self.sections):
            score = float(scores[index])
            document_scores[section.document] = max(document_scores.get(section.document, -10.0), score)
        return sorted(document_scores, key=lambda document: (-document_scores[document], document))
