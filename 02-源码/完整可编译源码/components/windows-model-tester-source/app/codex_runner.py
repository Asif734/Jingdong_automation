from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

from .model import CodexResult
from .prompt_builder import MODEL, REASONING_EFFORT


def sanitized_environment(source: Mapping[str, str] | None = None) -> dict[str, str]:
    result = dict(os.environ if source is None else source)
    result.pop("OPENAI_API_KEY", None); result.pop("CODEX_API_KEY", None)
    return result


@dataclass(frozen=True)
class CodexCommand:
    path: Path

    def process_command(self, environment: Mapping[str, str]) -> tuple[Path, list[str]]:
        if self.path.suffix.lower() in {".cmd", ".bat"}:
            comspec = Path(environment.get("COMSPEC", r"C:\Windows\System32\cmd.exe"))
            return comspec, ["/d", "/s", "/c", str(self.path)]
        return self.path, []


def locate_codex(environment: Mapping[str, str] | None = None) -> CodexCommand | None:
    env = dict(os.environ if environment is None else environment)
    explicit = env.get("GROZZIIE_CODEX_PATH")
    if explicit and Path(explicit).exists(): return CodexCommand(Path(explicit))
    found = shutil.which("codex", path=env.get("PATH")) or shutil.which("codex.cmd", path=env.get("PATH"))
    if found: return CodexCommand(Path(found))
    appdata = env.get("APPDATA")
    candidate = Path(appdata) / "npm" / "codex.cmd" if appdata else None
    return CodexCommand(candidate) if candidate and candidate.exists() else None


def build_arguments(schema: Path, result: Path, images: list[Path], session_id: str | None) -> list[str]:
    args = ["-a", "never", "exec"]
    if session_id: args.append("resume")
    args += ["--json", "--ignore-user-config", "--ignore-rules", "-m", MODEL, "-c", f'model_reasoning_effort="{REASONING_EFFORT}"', "--skip-git-repo-check"]
    if not session_id: args += ["-s", "read-only"]
    args += ["--output-schema", str(schema), "-o", str(result)]
    for image in images: args += ["-i", str(image)]
    if session_id: args.append(session_id)
    args.append("-")
    return args


class CodexRunner:
    def __init__(self, command: CodexCommand, schema: Path, trace_dir: Path):
        self.command = command; self.schema = schema; self.trace_dir = trace_dir
        trace_dir.mkdir(parents=True, exist_ok=True)

    def check_login(self) -> tuple[bool, str]:
        env = sanitized_environment(); executable, prefix = self.command.process_command(env)
        run = subprocess.run([str(executable), *prefix, "login", "status"], env=env, text=True, capture_output=True, timeout=20)
        status = (run.stdout + run.stderr).strip()
        return run.returncode == 0 and "ChatGPT" in status, status

    @staticmethod
    def parse_result(value: dict) -> CodexResult:
        action = str(value.get("action", "")).strip()
        if action not in {"reply", "reply_then_transfer"}:
            raise RuntimeError(f"不支持的模型动作：{action or '空'}")
        reply = str(value.get("reply_text", "")).strip()
        if not reply:
            raise RuntimeError("Codex 回答为空")
        transfer_reason = str(value.get("transfer_reason", "none")).strip() or "none"
        if action == "reply" and transfer_reason != "none":
            raise RuntimeError("普通回复不能携带转人工原因")
        if action == "reply_then_transfer" and transfer_reason == "none":
            raise RuntimeError("转人工动作缺少原因")
        return CodexResult(
            reply_text=reply,
            action=action,
            transfer_reason=transfer_reason,
            reason=str(value.get("reason", "")).strip(),
            session_id=None,
            timing={},
        )

    def generate(self, prompt: str, images: list[Path], session_id: str | None) -> CodexResult:
        started = time.perf_counter(); env = sanitized_environment(); executable, prefix = self.command.process_command(env)
        with tempfile.TemporaryDirectory(prefix="grozziie-codex-") as tmp:
            result = Path(tmp) / "result.json"
            args = build_arguments(self.schema, result, images, session_id)
            run = subprocess.run([str(executable), *prefix, *args], input=prompt, env=env, text=True, capture_output=True, timeout=300)
            events = []
            for line in run.stdout.splitlines():
                try: events.append(json.loads(line))
                except json.JSONDecodeError: pass
            (self.trace_dir / f"{int(time.time()*1000)}.stderr.log").write_text(run.stderr, encoding="utf-8")
            if run.returncode != 0: raise RuntimeError(f"Codex 退出码 {run.returncode}：{run.stderr[-2000:]}")
            if not result.exists(): raise RuntimeError("Codex 没有产生结构化回答")
            parsed = self.parse_result(json.loads(result.read_text(encoding="utf-8")))
            thread = session_id
            for event in events:
                if event.get("type") == "thread.started": thread = event.get("thread_id") or thread
            return CodexResult(
                parsed.reply_text,
                parsed.action,
                parsed.transfer_reason,
                parsed.reason,
                thread,
                {"codex_ms": round((time.perf_counter()-started)*1000, 1), "events": len(events)},
            )
