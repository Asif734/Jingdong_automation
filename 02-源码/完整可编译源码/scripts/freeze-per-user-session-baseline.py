#!/usr/bin/env python3
"""Create a non-overwriting rollback snapshot before per-user sessions.

The snapshot contains only this experimental source tree and its currently
installed app. Live customer history and queues are deliberately excluded.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from typing import Any


REPOSITORY = Path(__file__).resolve().parents[1]
DEFAULT_APP = Path("/Applications/千牛全自动客服-实验版.app")
DEFAULT_PARENT = REPOSITORY.parent
EXCLUDED_NAMES = {
    ".git",
    ".DS_Store",
    "node_modules",
    "output",
    "outputs",
    "evidence",
    "installation-backups",
}


def ignore_generated(_directory: str, names: list[str]) -> list[str]:
    return [
        name
        for name in names
        if name in EXCLUDED_NAMES or name.startswith(".build")
    ]


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1_048_576), b""):
            digest.update(chunk)
    return digest.hexdigest()


def hashes(root: Path) -> dict[str, str]:
    return {
        str(path.relative_to(root)): file_sha256(path)
        for path in sorted(root.rglob("*"))
        if path.is_file() and path.name != "manifest.json"
    }


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    payload = (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".manifest.", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    try:
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def freeze(
    source_root: Path,
    installed_app: Path,
    destination: Path,
    verify_signature: bool = True,
) -> dict[str, Any]:
    source_root = source_root.resolve()
    installed_app = installed_app.resolve()
    destination = destination.resolve()
    if destination.exists():
        raise FileExistsError(destination)
    if not source_root.is_dir():
        raise FileNotFoundError(source_root)
    if not installed_app.is_dir():
        raise FileNotFoundError(installed_app)

    destination.mkdir(parents=True)
    try:
        shutil.copytree(
            source_root,
            destination / "source",
            ignore=ignore_generated,
            symlinks=True,
        )
        app_copy = destination / "app" / installed_app.name
        app_copy.parent.mkdir(parents=True)
        if verify_signature:
            subprocess.run(["/usr/bin/ditto", str(installed_app), str(app_copy)], check=True)
            subprocess.run(
                ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app_copy)],
                check=True,
            )
        else:
            shutil.copytree(installed_app, app_copy, symlinks=True)

        manifest: dict[str, Any] = {
            "name": "per-user-session-baseline",
            "created_at": datetime.now().astimezone().isoformat(),
            "source": str(source_root),
            "installed_app": str(installed_app),
            "rollback": "Restore app/source only; never overwrite newer history or queues.",
            "files": hashes(destination),
        }
        atomic_json(destination / "manifest.json", manifest)
        return manifest
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=REPOSITORY)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument("--destination", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    destination = arguments.destination or DEFAULT_PARENT / f"per-user-session-baseline-{stamp}"
    manifest = freeze(arguments.source, arguments.app, destination)
    print(json.dumps({
        "snapshot": str(destination),
        "hashed_files": len(manifest["files"]),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
