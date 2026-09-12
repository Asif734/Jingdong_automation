from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from .codex_runner import CodexRunner, locate_codex
from .conversation_store import ConversationStore, StaleConversation
from .knowledge_retriever import KnowledgeRetriever
from .prompt_builder import MODEL, REASONING_EFFORT
from .service import ModelTesterService


class MissingCodexRunner:
    def generate(self, prompt, images, session_id):
        raise RuntimeError("未找到本地 Codex。请先安装 Codex，并在 PowerShell 运行 codex 后选择使用 ChatGPT 登录。")


def _snapshot(value): return {"id":value.id, "version":value.version, "messages":list(value.messages)}


def create_server(service, web_root: Path, handshake: str, port: int):
    web_root = Path(web_root)
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args): pass
        def _json(self, status, value):
            data = json.dumps(value, ensure_ascii=False).encode("utf-8")
            self.send_response(status); self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data))); self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(data)
        def _body(self):
            size = int(self.headers.get("Content-Length", "0"));
            if size > 30 * 1024 * 1024: raise ValueError("请求超过 30 MB")
            return json.loads(self.rfile.read(size) or b"{}")
        def do_GET(self):
            path = urlparse(self.path).path
            if path == "/api/health": return self._json(200, {"status":"ok", "model":MODEL, "reasoning_effort":REASONING_EFFORT})
            if path == "/api/status":
                command = locate_codex(); return self._json(200, {"codex_found":command is not None, "model":MODEL, "reasoning_effort":REASONING_EFFORT, "retriever":"v2-top12"})
            if path == "/api/conversations": return self._json(200, [_snapshot(x) for x in service.list_conversations()])
            if path.startswith("/api/conversations/"):
                try: return self._json(200, _snapshot(service.get_conversation(path.rsplit("/", 1)[-1])))
                except Exception as exc: return self._json(404, {"error":str(exc)})
            target = "index.html" if path == "/" else path.lstrip("/")
            file = (web_root / target).resolve()
            if web_root.resolve() not in file.parents or not file.is_file(): return self._json(404, {"error":"not found"})
            data = file.read_bytes(); self.send_response(200); self.send_header("Content-Type", mimetypes.guess_type(file.name)[0] or "application/octet-stream")
            self.send_header("Content-Security-Policy", "default-src 'self'; img-src 'self' blob: data:; style-src 'self'; script-src 'self'")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        def do_POST(self):
            path = urlparse(self.path).path
            try: value = self._body()
            except Exception as exc: return self._json(400, {"error":str(exc)})
            if path == "/api/conversations": return self._json(201, _snapshot(service.create_conversation()))
            if path == "/api/shutdown":
                if value.get("token") != handshake: return self._json(403, {"error":"forbidden"})
                self._json(200, {"status":"stopping"}); threading.Thread(target=self.server.shutdown, daemon=True).start(); return
            if path.startswith("/api/conversations/") and path.endswith("/messages"):
                cid = path.split("/")[3]; temporary = []
                try:
                    for item in value.get("images", []):
                        suffix = "." + item.get("name", "image.png").rsplit(".", 1)[-1].lower()
                        handle = tempfile.NamedTemporaryFile(delete=False, suffix=suffix); handle.write(base64.b64decode(item["data"])); handle.close(); temporary.append(Path(handle.name))
                    result = service.send(cid, str(value.get("text", "")), temporary, int(value["expected_version"]))
                    return self._json(200, {
                        "reply":result.reply,
                        "action":result.action,
                        "transfer_reason":result.transfer_reason,
                        "reason":result.reason,
                        "conversation":_snapshot(result.snapshot),
                        "citations":result.citations,
                        "diagnostic":result.diagnostic,
                    })
                except StaleConversation as exc: return self._json(409, {"error":str(exc)})
                except Exception as exc: return self._json(500, {"error":str(exc)})
                finally:
                    for item in temporary: item.unlink(missing_ok=True)
            return self._json(404, {"error":"not found"})
        def do_DELETE(self):
            path = urlparse(self.path).path
            try:
                if path == "/api/conversations": service.delete_all()
                elif path.startswith("/api/conversations/"): service.delete_conversation(path.rsplit("/", 1)[-1])
                else: return self._json(404, {"error":"not found"})
                return self._json(200, {"status":"deleted"})
            except Exception as exc: return self._json(404, {"error":str(exc)})
    return ThreadingHTTPServer(("127.0.0.1", port), Handler)


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--root", required=True); parser.add_argument("--port", type=int, default=0); parser.add_argument("--token", required=True); args = parser.parse_args()
    root = Path(args.root).resolve(); data = root / "data"; resources = root / "resources"
    command = locate_codex()
    runner = CodexRunner(command, resources / "reply-output.schema.json", data / "traces") if command else MissingCodexRunner()
    service = ModelTesterService(
        ConversationStore(data / "conversations"),
        KnowledgeRetriever(resources / "V2Knowledge", resources / "V2Knowledge" / "cache", data / "v2-cache"),
        runner,
        resources / "KnowledgeBase" / "Grozziie-China-KB.zip",
        data / "sessions.json",
    )
    server = create_server(service, root / "web", args.token, args.port)
    print(json.dumps({"status":"ready", "port":server.server_port}, ensure_ascii=False), flush=True)
    try: server.serve_forever()
    finally: server.server_close()


if __name__ == "__main__": main()
