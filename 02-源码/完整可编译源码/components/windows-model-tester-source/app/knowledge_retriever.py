from __future__ import annotations

import importlib.util
import sys
import threading
import traceback
from pathlib import Path

from .model import KnowledgeResult


class KnowledgeRetriever:
    _lock = threading.Lock()

    def __init__(self, v2_root: Path, seed_cache: Path, writable_cache: Path):
        self.v2_root = Path(v2_root); self.seed_cache = Path(seed_cache); self.writable_cache = Path(writable_cache)

    def retrieve(self, history_jsonl: str, knowledge_zip: Path) -> KnowledgeResult:
        try:
            with self._lock:
                script = self.v2_root / "retrieve_top12.py"
                if not script.exists(): raise FileNotFoundError(script)
                spec = importlib.util.spec_from_file_location("grozziie_v2_retrieve", script)
                if spec is None or spec.loader is None: raise ImportError(script)
                module = importlib.util.module_from_spec(spec)
                sys.path.insert(0, str(self.v2_root))
                try: spec.loader.exec_module(module)
                finally:
                    if sys.path and sys.path[0] == str(self.v2_root): sys.path.pop(0)
                value = module.retrieve({
                    "knowledge_base_path": str(knowledge_zip),
                    "history_jsonl": history_jsonl,
                    "cache_directory": str(self.writable_cache),
                    "seed_cache_directory": str(self.seed_cache),
                })
            if value.get("version") != "v2-top12" or not str(value.get("context", "")).strip(): raise ValueError("invalid v2 output")
            return KnowledgeResult("v2-top12", tuple(value.get("documents", [])), str(value["context"]), "v2-top12")
        except Exception:
            print("V2 knowledge retrieval failed; using full ZIP fallback", file=sys.stderr)
            traceback.print_exc()
            return KnowledgeResult("full-zip", (Path(knowledge_zip).name,), "", "full-zip-fallback")
