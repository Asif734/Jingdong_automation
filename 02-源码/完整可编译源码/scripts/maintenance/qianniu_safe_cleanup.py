#!/usr/bin/env python3
"""Conservative cleanup for Version B runtime data.

Only completed, timestamped video artifacts and old terminal CLI traces are
eligible. Unknown or malformed state always fails closed.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import stat
import tempfile
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable


HASH_RE = re.compile(r"^[0-9a-f]{64}$")
RUNTIME_NAME = "AI客服记录-任务隔离候选版"


@dataclass(frozen=True)
class CleanupPolicy:
    retention_days: int = 30
    high_watermark_bytes: int = 10 * 1024**3
    target_bytes: int = 8 * 1024**3


@dataclass
class CleanupReport:
    checked_at: str
    trigger: str
    bytes_before: int
    bytes_after: int
    deleted_hashes: list[str] = field(default_factory=list)
    skipped: list[dict[str, str]] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    status: str = "ok"


@dataclass(frozen=True)
class FileIdentity:
    device: int
    inode: int
    size: int
    modified_ns: int
    mode: int


@dataclass
class Candidate:
    message_hash: str
    completed_at: datetime
    paths: list[Path]
    identities: dict[Path, FileIdentity]
    bytes: int


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_iso(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except ValueError:
        return None


def _identity(path: Path) -> FileIdentity:
    value = path.lstat()
    return FileIdentity(value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_mode)


def _tree_size(path: Path) -> int:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return 0
    if stat.S_ISLNK(info.st_mode):
        return 0
    if stat.S_ISREG(info.st_mode):
        return info.st_size
    if not stat.S_ISDIR(info.st_mode):
        return 0
    total = info.st_size
    for child in path.iterdir():
        total += _tree_size(child)
    return total


def _inside(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(root)
        return True
    except ValueError:
        return False


def _collect_identities(path: Path, root: Path) -> tuple[dict[Path, FileIdentity], int]:
    if not _inside(path, root):
        raise ValueError("outsideRuntimeRoot")
    try:
        first = _identity(path)
    except FileNotFoundError:
        return {}, 0
    if stat.S_ISLNK(first.mode):
        raise ValueError("symlinkRejected")
    identities = {path: first}
    total = first.size if stat.S_ISREG(first.mode) else 0
    if stat.S_ISDIR(first.mode):
        for child in path.iterdir():
            child_identities, child_size = _collect_identities(child, root)
            identities.update(child_identities)
            total += child_size
    return identities, total


def _atomic_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def _candidate(entry: dict, root: Path, skipped: list[dict[str, str]]) -> Candidate | None:
    message_hash = entry.get("messageHash")
    if entry.get("phase") != "completed":
        return None
    if not isinstance(message_hash, str) or not HASH_RE.fullmatch(message_hash):
        skipped.append({"messageHash": "invalid", "reason": "invalidMessageHash"})
        return None
    completed_at = _parse_iso(entry.get("completedAt"))
    if completed_at is None:
        skipped.append({"messageHash": message_hash, "reason": "missingCompletedAt"})
        return None

    expected_video = root / "收到的视频" / f"{message_hash}.mp4"
    recorded_path = entry.get("videoFilePath")
    if recorded_path and Path(recorded_path).resolve(strict=False) != expected_video.resolve(strict=False):
        skipped.append({"messageHash": message_hash, "reason": "recordedPathMismatch"})
        return None
    paths = [
        expected_video,
        root / "收到的视频帧和音轨" / message_hash,
        root / "收到的视频证据" / message_hash,
    ]
    identities: dict[Path, FileIdentity] = {}
    total = 0
    try:
        for path in paths:
            values, size = _collect_identities(path, root)
            identities.update(values)
            total += size
    except ValueError as error:
        skipped.append({"messageHash": message_hash, "reason": str(error)})
        return None
    if not identities:
        return None
    return Candidate(message_hash, completed_at, paths, identities, total)


def _unchanged(candidate: Candidate) -> bool:
    for path, expected in candidate.identities.items():
        try:
            if _identity(path) != expected:
                return False
        except FileNotFoundError:
            return False
    return True


def _delete_candidate(candidate: Candidate) -> None:
    for path in candidate.paths:
        try:
            info = path.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("symlinkRejected")
        if stat.S_ISDIR(info.st_mode):
            shutil.rmtree(path)
        elif stat.S_ISREG(info.st_mode):
            path.unlink()
        else:
            raise ValueError("unsupportedFileType")


def _cleanup_terminal_traces(root: Path, cutoff: datetime, report: CleanupReport, dry_run: bool) -> None:
    trace_root = root / "运行状态" / "CLI轨迹"
    if not trace_root.is_dir() or trace_root.is_symlink():
        return
    for path in trace_root.iterdir():
        try:
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
                continue
            modified = datetime.fromtimestamp(info.st_mtime, timezone.utc)
            if modified > cutoff:
                continue
            terminal = False
            with path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        terminal = False
                        break
                    terminal = terminal or event.get("event") == "process.completed"
            if not terminal or _identity(path) != FileIdentity(info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_mode):
                continue
            if not dry_run:
                path.unlink()
        except (OSError, UnicodeError):
            report.skipped.append({"messageHash": "cli-trace", "reason": "traceUnreadableOrChanging"})


def _write_audit(root: Path, report: CleanupReport) -> None:
    log_root = root / "Maintenance" / "logs"
    log_root.mkdir(parents=True, exist_ok=True)
    stamp = report.checked_at.replace(":", "").replace("-", "")
    _atomic_json(log_root / f"cleanup-{stamp}.json", asdict(report))
    _atomic_json(root / "Maintenance" / "last-check.json", asdict(report))


def run_cleanup(
    runtime_root: Path,
    now: datetime,
    dry_run: bool,
    *,
    policy: CleanupPolicy = CleanupPolicy(),
    before_delete: Callable[[Candidate], None] | None = None,
) -> CleanupReport:
    root_input = Path(runtime_root).expanduser()
    if root_input.name != RUNTIME_NAME or root_input.is_symlink():
        return CleanupReport(_iso(now), "blocked", 0, 0, errors=["invalidRuntimeRoot"], status="blocked")
    root_input.mkdir(parents=True, exist_ok=True)
    root = root_input.resolve(strict=True)
    bytes_before = _tree_size(root)
    report = CleanupReport(_iso(now), "none", bytes_before, bytes_before)
    maintenance = root / "Maintenance"
    maintenance.mkdir(parents=True, exist_ok=True)
    lock_path = maintenance / "cleanup.lock"

    with lock_path.open("a+") as lock_handle:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            report.trigger = "busy"
            report.status = "busy"
            return report

        state_path = root / "运行状态" / "媒体路由" / "video-analysis-inbox.json"
        if not state_path.exists():
            _cleanup_terminal_traces(root, now.astimezone(timezone.utc) - timedelta(days=policy.retention_days), report, dry_run)
            report.bytes_after = _tree_size(root)
            _write_audit(root, report)
            return report
        if not state_path.is_file() or state_path.is_symlink():
            report.trigger = "blocked"
            report.status = "blocked"
            report.errors.append("videoAnalysisStateMissingOrUnsafe")
            _write_audit(root, report)
            return report
        try:
            payload = json.loads(state_path.read_text(encoding="utf-8"))
            entries = payload["entries"]
            if not isinstance(entries, list):
                raise ValueError("entriesNotArray")
        except (OSError, UnicodeError, json.JSONDecodeError, KeyError, ValueError) as error:
            report.trigger = "blocked"
            report.status = "blocked"
            report.errors.append(f"videoAnalysisStateInvalid:{type(error).__name__}")
            _write_audit(root, report)
            return report

        candidates = [candidate for entry in entries if isinstance(entry, dict)
                      if (candidate := _candidate(entry, root, report.skipped)) is not None]
        candidates.sort(key=lambda item: (item.completed_at, item.message_hash))
        cutoff = now.astimezone(timezone.utc) - timedelta(days=policy.retention_days)
        selected = [candidate for candidate in candidates if candidate.completed_at <= cutoff]
        if bytes_before >= policy.high_watermark_bytes:
            report.trigger = "capacity"
            projected = bytes_before - sum(candidate.bytes for candidate in selected)
            selected_hashes = {candidate.message_hash for candidate in selected}
            for candidate in candidates:
                if projected <= policy.target_bytes:
                    break
                if candidate.message_hash in selected_hashes:
                    continue
                selected.append(candidate)
                selected_hashes.add(candidate.message_hash)
                projected -= candidate.bytes
        elif selected:
            report.trigger = "age"

        changed = False
        for candidate in selected:
            if before_delete is not None:
                before_delete(candidate)
                before_delete = None
            if not _unchanged(candidate):
                report.skipped.append({"messageHash": candidate.message_hash, "reason": "identityChanged"})
                continue
            if dry_run:
                continue
            try:
                _delete_candidate(candidate)
            except (OSError, ValueError) as error:
                report.skipped.append({"messageHash": candidate.message_hash, "reason": type(error).__name__})
                report.status = "partial"
                continue
            for entry in entries:
                if isinstance(entry, dict) and entry.get("messageHash") == candidate.message_hash:
                    entry["videoFilePath"] = ""
                    entry["bytes"] = 0
            report.deleted_hashes.append(candidate.message_hash)
            changed = True

        if changed:
            _atomic_json(state_path, payload)
        _cleanup_terminal_traces(root, cutoff, report, dry_run)
        report.bytes_after = _tree_size(root)
        if report.trigger == "capacity" and report.bytes_after > policy.target_bytes:
            report.status = "partial"
            report.errors.append("safeCandidatesInsufficient")
        _write_audit(root, report)
        return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-root", required=True, type=Path)
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    report = run_cleanup(arguments.runtime_root, datetime.now(timezone.utc), arguments.dry_run)
    print(json.dumps(asdict(report), ensure_ascii=False, sort_keys=True))
    return {"ok": 0, "busy": 3, "blocked": 4, "partial": 5}.get(report.status, 5)


if __name__ == "__main__":
    raise SystemExit(main())
