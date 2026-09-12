from __future__ import annotations

import json
import os
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from .conversation_store import ConversationSnapshot, ConversationStore
from .model import PromptInput, PromptSubmission
from .prompt_builder import build_continuation_prompt, build_initial_prompt


@dataclass(frozen=True)
class SendResult:
    reply: str
    action: str
    transfer_reason: str
    reason: str
    snapshot: ConversationSnapshot
    citations: tuple[str, ...]
    diagnostic: dict


class ModelTesterService:
    def __init__(self, store, retriever, runner, knowledge_zip: Path, sessions_path: Path):
        self.store = store; self.retriever = retriever; self.runner = runner
        self.knowledge_zip = Path(knowledge_zip); self.sessions_path = Path(sessions_path)
        self._locks: dict[str, threading.Lock] = {}; self._sessions = self._load_sessions()

    def create_conversation(self): return self.store.create()
    def get_conversation(self, value): return self.store.get(value)
    def list_conversations(self): return self.store.list()
    def delete_conversation(self, value):
        self.store.delete(value); self._sessions.pop(value, None); self._save_sessions()
    def delete_all(self): self.store.delete_all(); self._sessions = {}; self._save_sessions()

    def send(self, conversation_id: str, text: str, uploads: list[Path], expected_version: int) -> SendResult:
        lock = self._locks.setdefault(conversation_id, threading.Lock())
        with lock:
            started = time.perf_counter()
            customer = self.store.append_customer(conversation_id, text, uploads, expected_version)
            history = self._jsonl(customer.messages)
            target = self._jsonl([customer.messages[-1]])
            retrieval_started = time.perf_counter()
            knowledge = self.retriever.retrieve(history, self.knowledge_zip)
            retrieval_ms = round((time.perf_counter()-retrieval_started)*1000, 1)
            all_images = tuple(path for message in customer.messages for path in message.get("image_paths", []))
            current_images = tuple(customer.messages[-1].get("image_paths", []))
            session = self._sessions.get(conversation_id)
            value = PromptInput(conversation_id, str(customer.version), history, target, all_images, (str(self.knowledge_zip),), knowledge.context)
            submission = PromptSubmission(target if session else history, current_images if session else all_images)
            prompt = build_continuation_prompt(value, submission) if session else build_initial_prompt(value, submission)
            generated = self.runner.generate(prompt, [Path(x) for x in submission.image_paths], session)
            service = self.store.append_service(conversation_id, generated.reply_text, customer.version)
            if generated.session_id:
                self._sessions[conversation_id] = generated.session_id; self._save_sessions()
            diagnostic = dict(generated.timing); diagnostic.update({"retrieval_ms":retrieval_ms, "total_ms":round((time.perf_counter()-started)*1000,1), "retriever":knowledge.mode})
            return SendResult(
                generated.reply_text,
                generated.action,
                generated.transfer_reason,
                generated.reason,
                service,
                knowledge.documents,
                diagnostic,
            )

    def _load_sessions(self):
        try: return json.loads(self.sessions_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError): return {}

    def _save_sessions(self):
        self.sessions_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.sessions_path.with_suffix(f".{uuid.uuid4().hex}.tmp")
        tmp.write_text(json.dumps(self._sessions, ensure_ascii=False), encoding="utf-8"); os.replace(tmp, self.sessions_path)

    @staticmethod
    def _jsonl(messages): return "".join(json.dumps(x, ensure_ascii=False, separators=(",", ":"))+"\n" for x in messages)
