#!/usr/bin/env python3
"""Export a small, allowlisted and redacted Version B diagnostic package."""

from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import re
import subprocess
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path


RUNTIME_NAME = "AI客服记录-任务隔离候选版"
APP_PATH = Path("/Applications/千牛全自动客服-版本B.app")
USER_PATH_RE = re.compile(r"/Users/[^/\s\"']+")


def _redact(value):
    if isinstance(value, dict):
        return {str(key): _redact(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_redact(item) for item in value]
    if isinstance(value, str):
        return USER_PATH_RE.sub("~", value)
    return value


def _read_redacted_json(path: Path):
    try:
        return _redact(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {"status": "unreadable", "source": path.name}


def _tree_size(path: Path) -> int:
    total = 0
    if not path.exists() or path.is_symlink():
        return total
    for root, directories, files in os.walk(path, followlinks=False):
        directories[:] = [name for name in directories if not (Path(root) / name).is_symlink()]
        for name in files:
            item = Path(root) / name
            try:
                if not item.is_symlink():
                    total += item.stat().st_size
            except OSError:
                continue
    return total


def _app_summary() -> dict:
    result = {"installed": APP_PATH.is_dir(), "path": "/Applications/千牛全自动客服-版本B.app"}
    plist_path = APP_PATH / "Contents" / "Info.plist"
    if plist_path.is_file():
        try:
            with plist_path.open("rb") as handle:
                info = plistlib.load(handle)
            result.update(
                bundleIdentifier=info.get("CFBundleIdentifier"),
                shortVersion=info.get("CFBundleShortVersionString"),
                buildVersion=info.get("CFBundleVersion"),
            )
        except (OSError, plistlib.InvalidFileException):
            result["metadata"] = "unreadable"
    if result["installed"]:
        check = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(APP_PATH)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        result["signatureValid"] = check.returncode == 0
    return result


def export_diagnostic(runtime_root: Path, desktop: Path, now: datetime) -> Path:
    runtime = Path(runtime_root).expanduser()
    if runtime.name != RUNTIME_NAME:
        raise ValueError("invalid runtime root")
    desktop = Path(desktop).expanduser()
    desktop.mkdir(parents=True, exist_ok=True)
    stamp = now.astimezone(timezone.utc).strftime("%Y%m%d-%H%M%S")
    output = desktop / f"千牛版本B-脱敏诊断包-{stamp}.zip"

    allowed = [
        runtime / "运行状态" / "自动配置" / "machine-compatibility.json",
        runtime / "运行状态" / "自动配置" / ".last-known-good.json",
        runtime / "运行状态" / "自动配置" / "universal-install-v1.json",
        runtime / "Maintenance" / "last-check.json",
    ]
    log_root = runtime / "Maintenance" / "logs"
    if log_root.is_dir() and not log_root.is_symlink():
        allowed.extend(sorted(log_root.glob("*.json"), key=lambda item: item.stat().st_mtime)[-20:])

    with tempfile.TemporaryDirectory(prefix="qianniu-version-b-diagnostic-") as temporary:
        staging = Path(temporary)
        for source in allowed:
            if not source.is_file() or source.is_symlink():
                continue
            destination = staging / source.name
            destination.write_text(
                json.dumps(_read_redacted_json(source), ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
        summary = {
            "schemaVersion": 1,
            "createdAt": now.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            "macOS": platform.mac_ver()[0],
            "machine": platform.machine(),
            "runtimeBytes": _tree_size(runtime),
            "app": _app_summary(),
            "privacy": {
                "customerMessagesIncluded": False,
                "customerMediaIncluded": False,
                "codexCredentialsIncluded": False,
                "operatorIdentityIncluded": False,
            },
        }
        (staging / "system-summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in sorted(staging.iterdir()):
                archive.write(path, path.name)
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-root", type=Path, required=True)
    parser.add_argument("--desktop", type=Path, default=Path.home() / "Desktop")
    arguments = parser.parse_args()
    try:
        output = export_diagnostic(arguments.runtime_root, arguments.desktop, datetime.now(timezone.utc))
    except (OSError, ValueError) as error:
        print(f"诊断包生成失败：{error}")
        return 1
    print(f"诊断包已生成：{output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
