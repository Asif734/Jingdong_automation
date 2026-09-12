from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class PromptInput:
    uid: str
    history_version: str
    history_jsonl: str
    target_customer_jsonl: str
    image_paths: tuple[str, ...]
    knowledge_base_paths: tuple[str, ...] = ()
    retrieved_knowledge_context: str = ""


@dataclass(frozen=True)
class PromptSubmission:
    history_jsonl: str
    image_paths: tuple[str, ...]


@dataclass(frozen=True)
class KnowledgeResult:
    version: str
    documents: tuple[str, ...]
    context: str
    mode: str


@dataclass(frozen=True)
class CodexResult:
    reply_text: str
    action: str
    transfer_reason: str
    reason: str
    session_id: str | None
    timing: dict[str, Any]
