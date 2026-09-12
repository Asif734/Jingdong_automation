from __future__ import annotations

import hashlib
import json
import os
import shutil
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


class StaleConversation(RuntimeError):
    pass


@dataclass(frozen=True)
class ConversationSnapshot:
    id: str
    version: int
    messages: tuple[dict, ...]


class ConversationStore:
    SUPPORTED = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"}

    def __init__(self, root: Path, max_image_bytes: int = 20 * 1024 * 1024):
        self.root = Path(root)
        self.max_image_bytes = max_image_bytes
        self.root.mkdir(parents=True, exist_ok=True)

    def create(self) -> ConversationSnapshot:
        value = uuid.uuid4().hex
        folder = self.root / value
        (folder / "images").mkdir(parents=True)
        self._atomic(folder / "history.jsonl", b"")
        self._atomic(folder / "meta.json", json.dumps({"version": 0}, ensure_ascii=False).encode())
        return ConversationSnapshot(value, 0, ())

    def list(self) -> list[ConversationSnapshot]:
        values = []
        for folder in self.root.iterdir():
            if folder.is_dir() and not folder.name.startswith(".deleting-"):
                try: values.append(self.get(folder.name))
                except (OSError, ValueError, json.JSONDecodeError): pass
        return sorted(values, key=lambda x: x.id)

    def get(self, conversation_id: str) -> ConversationSnapshot:
        folder = self._folder(conversation_id)
        version = json.loads((folder / "meta.json").read_text(encoding="utf-8"))["version"]
        messages = tuple(json.loads(line) for line in (folder / "history.jsonl").read_text(encoding="utf-8").splitlines() if line.strip())
        return ConversationSnapshot(conversation_id, int(version), messages)

    def append_customer(self, conversation_id: str, text: str, uploads: Iterable[Path], expected_version: int) -> ConversationSnapshot:
        images = self._copy_images(conversation_id, uploads)
        message = {"sender": "customer", "t": "image" if images and not text.strip() else "text", "v": text.strip() or "[图片]", "timestamp": self._timestamp()}
        if images: message["image_paths"] = images
        return self._append(conversation_id, message, expected_version)

    def append_service(self, conversation_id: str, text: str, expected_version: int) -> ConversationSnapshot:
        return self._append(conversation_id, {"sender":"service", "t":"text", "v":text.strip(), "timestamp":self._timestamp()}, expected_version)

    def delete(self, conversation_id: str) -> None:
        folder = self._folder(conversation_id)
        deleting = self.root / f".deleting-{uuid.uuid4().hex}"
        folder.rename(deleting); shutil.rmtree(deleting)

    def delete_all(self) -> None:
        for value in self.list(): self.delete(value.id)

    def _append(self, conversation_id: str, message: dict, expected_version: int) -> ConversationSnapshot:
        snapshot = self.get(conversation_id)
        if snapshot.version != expected_version:
            raise StaleConversation(f"expected {expected_version}, actual {snapshot.version}")
        messages = (*snapshot.messages, message)
        payload = "".join(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n" for item in messages).encode("utf-8")
        folder = self._folder(conversation_id)
        self._atomic(folder / "history.jsonl", payload)
        self._atomic(folder / "meta.json", json.dumps({"version": expected_version + 1}).encode())
        return ConversationSnapshot(conversation_id, expected_version + 1, messages)

    def _copy_images(self, conversation_id: str, uploads: Iterable[Path]) -> list[str]:
        destination = self._folder(conversation_id) / "images"; output = []
        for raw in uploads:
            source = Path(raw); suffix = source.suffix.lower()
            if suffix not in self.SUPPORTED: raise ValueError(f"不支持的图片格式：{suffix}")
            size = source.stat().st_size
            if size > self.max_image_bytes: raise ValueError("图片超过 20 MB")
            digest = hashlib.sha256(source.read_bytes()).hexdigest()[:20]
            target = destination / f"{digest}{suffix}"
            if not target.exists(): shutil.copy2(source, target)
            output.append(str(target.resolve()))
        return list(dict.fromkeys(output))

    def _folder(self, value: str) -> Path:
        if not value or any(c not in "0123456789abcdef" for c in value.lower()): raise ValueError("invalid conversation id")
        folder = self.root / value
        if not folder.is_dir(): raise KeyError(value)
        return folder

    @staticmethod
    def _timestamp() -> str:
        return time.strftime("%Y-%m-%d %H:%M:%S")

    @staticmethod
    def _atomic(path: Path, data: bytes) -> None:
        temp = path.with_name(path.name + f".{uuid.uuid4().hex}.tmp")
        with temp.open("wb") as handle:
            handle.write(data); handle.flush(); os.fsync(handle.fileno())
        os.replace(temp, path)
