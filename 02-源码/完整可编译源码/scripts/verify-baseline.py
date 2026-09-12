#!/usr/bin/env python3
"""Verify the immutable pre-automation baseline and protected source copies.

This intentionally has no repair mode. A mismatch is evidence to inspect, not
an invitation to rewrite a prior app, source tree, queue, or customer history.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


REPOSITORY = Path(__file__).resolve().parents[1]
DEFAULT_FROZEN_ROOT = REPOSITORY.parent / "current-before-autoreply-20260826-225405"
PROJECT_ROOT = REPOSITORY.parents[1]
SOURCE_MAPPINGS = {
    "batch-source": "components/batch-source",
    "ocr-source": "components/ocr-source",
    "sender-source": "components/sender-source",
    "unread-source": "components/unread-source",
}
ORIGINAL_SOURCE_ROOTS = {
    "batch-source": PROJECT_ROOT / "versions/copy-experiment/codex-batch-source",
    "ocr-source": PROJECT_ROOT / "versions/copy-experiment/source",
    "sender-source": PROJECT_ROOT / "versions/copy-experiment/sender-source",
    "unread-source": PROJECT_ROOT / "work/qianniu-unread-assistant",
}
ADDITIVE_COMPONENT_FILES = {
    ("ocr-source", "Sources/QianniuOCRAppSupport/AutomationCaptureBridge.swift"),
}
OLD_INSTALLED_APPS = {
    "千牛未读助手.app": Path("/Applications/千牛未读助手.app"),
    "AI客服三件套-通用复制实验版.app": Path("/Applications/AI客服三件套-通用复制实验版.app"),
}


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1_048_576), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def source_files(root: Path) -> set[str]:
    # Match work/freeze-autoreply-baseline.py exactly: these are generated or
    # deliberately excluded from the immutable source snapshot.
    ignored_directories = {"node_modules", "output", "outputs", "evidence", "installation-backups", ".git"}
    return {
        str(path.relative_to(root))
        for path in root.rglob("*")
        if path.is_file() and not any(part in ignored_directories or part.startswith(".build") for part in path.relative_to(root).parts)
        and path.name != ".DS_Store"
    }


def verify(frozen_root: Path, workspace: Path, verify_signatures: bool,
           original_source_roots: dict[str, Path] = ORIGINAL_SOURCE_ROOTS,
           installed_old_apps: dict[str, Path] = OLD_INSTALLED_APPS) -> list[str]:
    failures: list[str] = []
    manifest_path = frozen_root / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        expected: dict[str, str] = manifest["files"]
    except (OSError, ValueError, KeyError) as error:
        return [f"cannot read frozen manifest: {error}"]

    for relative, expected_hash in expected.items():
        path = frozen_root / relative
        if not path.is_file():
            failures.append(f"frozen file missing: {relative}")
        elif digest(path) != expected_hash:
            failures.append(f"frozen SHA256 mismatch: {relative}")

    for source_name, workspace_relative in SOURCE_MAPPINGS.items():
        prefix = f"sources/{source_name}/"
        protected = {item[len(prefix):] for item in expected if item.startswith(prefix)}
        if not protected:
            continue
        current_root = workspace / workspace_relative
        if not current_root.is_dir():
            failures.append(f"protected source root missing: {workspace_relative}")
            continue
        actual = source_files(current_root)
        allowed = {relative for name, relative in ADDITIVE_COMPONENT_FILES if name == source_name}
        for relative in sorted(protected):
            current = current_root / relative
            frozen = frozen_root / prefix / relative
            if not current.is_file():
                failures.append(f"protected source missing: {workspace_relative}/{relative}")
            elif digest(current) != expected[f"{prefix}{relative}"]:
                failures.append(f"protected source changed: {workspace_relative}/{relative}")
            elif not frozen.is_file():
                failures.append(f"frozen protected source missing: {prefix}{relative}")
        for relative in sorted(actual - protected - allowed):
            failures.append(f"unexpected additive component file: {workspace_relative}/{relative}")

        original_root = original_source_roots.get(source_name)
        if original_root is None or not original_root.is_dir():
            failures.append(f"original source root missing: {source_name}: {original_root}")
            continue
        original_files = source_files(original_root)
        for relative in sorted(protected):
            original = original_root / relative
            if not original.is_file():
                failures.append(f"original source missing: {source_name}/{relative}")
            elif digest(original) != expected[f"{prefix}{relative}"]:
                failures.append(f"original source changed: {source_name}/{relative}")
        for relative in sorted(original_files - protected):
            failures.append(f"unexpected original source file: {source_name}/{relative}")

    # The new app contains two copied algorithms. WindowCapture must remain
    # byte-identical; NativeSession has only the two approved label/destination
    # substitutions recorded in Task 2.
    app_root = workspace / "Sources/AutoReplyApp"
    if app_root.exists():
        frozen_unread = frozen_root / "sources/unread-source/Sources/UnreadApp"
        window_capture = app_root / "WindowCapture.swift"
        if not window_capture.is_file() or digest(window_capture) != digest(frozen_unread / "WindowCapture.swift"):
            failures.append("copied WindowCapture.swift differs from frozen source")
        native = app_root / "NativeSession.swift"
        try:
            expected_native = (frozen_unread / "NativeSession.swift").read_text(encoding="utf-8")
            expected_native = expected_native.replace("“千牛未读助手”", "“千牛全自动客服-实验版”")
            expected_native = expected_native.replace("QianniuUnreadAssistant", "QianniuAutoReplyScheduler")
            if native.read_text(encoding="utf-8") != expected_native:
                failures.append("copied NativeSession.swift has changes beyond approved labels/destination")
        except OSError as error:
            failures.append(f"cannot verify copied NativeSession.swift: {error}")

    frozen_apps = sorted({relative.split("/")[1] for relative in expected if relative.startswith("apps/") and ".app/" in relative})
    for app_name in frozen_apps:
        installed = installed_old_apps.get(app_name)
        if installed is None or not installed.is_dir():
            failures.append(f"installed old app missing: {app_name}: {installed}")
            continue
        prefix = f"apps/{app_name}/"
        protected_files = {item[len(prefix):] for item in expected if item.startswith(prefix)}
        for relative in sorted(protected_files):
            installed_file = installed / relative
            if not installed_file.is_file():
                failures.append(f"installed old app file missing: {app_name}/{relative}")
            elif digest(installed_file) != expected[f"{prefix}{relative}"]:
                failures.append(f"installed old app file changed: {app_name}/{relative}")
        for relative in sorted({str(path.relative_to(installed)) for path in installed.rglob("*") if path.is_file()} - protected_files):
            failures.append(f"unexpected installed old app file: {app_name}/{relative}")

    if verify_signatures:
        if shutil.which("codesign") is None:
            failures.append("codesign is unavailable")
        else:
            for app_name in frozen_apps:
                check_signature(frozen_root / "apps" / app_name, "frozen app", failures)
            for app_name in frozen_apps:
                installed = installed_old_apps.get(app_name)
                if installed is not None:
                    check_signature(installed, f"installed old app {app_name}", failures)
    return failures


def check_signature(app: Path, description: str, failures: list[str]) -> None:
    if not app.is_dir():
        failures.append(f"{description} missing: {app}")
        return
    result = subprocess.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)],
                            text=True, capture_output=True, check=False)
    if result.returncode != 0:
        failures.append(f"{description} signature invalid: {app}: {(result.stderr or result.stdout).strip()}")


def run_self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="verify-baseline-") as temporary:
        temp = Path(temporary)
        frozen = temp / "frozen"
        workspace = temp / "workspace"
        original = temp / "original-batch"
        installed = temp / "installed-old.app"
        frozen_file = frozen / "sources/batch-source/Sources/Protected.swift"
        work_file = workspace / "components/batch-source/Sources/Protected.swift"
        original_file = original / "Sources/Protected.swift"
        frozen_app_file = frozen / "apps/Old.app/Contents/Info.plist"
        installed_app_file = installed / "Contents/Info.plist"
        frozen_file.parent.mkdir(parents=True)
        work_file.parent.mkdir(parents=True)
        original_file.parent.mkdir(parents=True)
        frozen_app_file.parent.mkdir(parents=True)
        installed_app_file.parent.mkdir(parents=True)
        frozen_file.write_text("let protected = true\n", encoding="utf-8")
        work_file.write_text("let protected = true\n", encoding="utf-8")
        original_file.write_text("let protected = true\n", encoding="utf-8")
        frozen_app_file.write_text("baseline app bytes\n", encoding="utf-8")
        installed_app_file.write_text("baseline app bytes\n", encoding="utf-8")
        (frozen / "manifest.json").write_text(json.dumps({"files": {
            "sources/batch-source/Sources/Protected.swift": digest(frozen_file),
            "apps/Old.app/Contents/Info.plist": digest(frozen_app_file),
        }}), encoding="utf-8")
        fixture_sources = {"batch-source": original}
        fixture_apps = {"Old.app": installed}
        unchanged = verify(frozen, workspace, verify_signatures=False,
                           original_source_roots=fixture_sources, installed_old_apps=fixture_apps)
        if unchanged:
            print("unchanged fixture: unexpected failure")
            for failure in unchanged:
                print(f"  {failure}")
            return 1
        print("unchanged fixture: PASS")
        work_file.write_text("let protected = false\n", encoding="utf-8")
        changed = verify(frozen, workspace, verify_signatures=False,
                         original_source_roots=fixture_sources, installed_old_apps=fixture_apps)
        if not any("protected source changed" in failure for failure in changed):
            print("mutated fixture: unexpectedly passed")
            return 1
        print("mutated fixture: FAIL as expected")
        work_file.write_text("let protected = true\n", encoding="utf-8")
        original_file.write_text("let protected = false\n", encoding="utf-8")
        changed = verify(frozen, workspace, verify_signatures=False,
                         original_source_roots=fixture_sources, installed_old_apps=fixture_apps)
        if not any("original source changed" in failure for failure in changed):
            print("original source mutation: unexpectedly passed")
            return 1
        print("original source mutation: FAIL as expected")
        original_file.write_text("let protected = true\n", encoding="utf-8")
        installed_app_file.write_text("resigned but changed app bytes\n", encoding="utf-8")
        changed = verify(frozen, workspace, verify_signatures=False,
                         original_source_roots=fixture_sources, installed_old_apps=fixture_apps)
        if not any("installed old app file changed" in failure for failure in changed):
            print("installed app mutation: unexpectedly passed")
            return 1
        print("installed app mutation: FAIL as expected")
        installed_app_file.write_text("baseline app bytes\n", encoding="utf-8")
        added_app_file = installed / "Contents/Resources/added-after-freeze.txt"
        added_app_file.parent.mkdir(parents=True)
        added_app_file.write_text("unexpected\n", encoding="utf-8")
        changed = verify(frozen, workspace, verify_signatures=False,
                         original_source_roots=fixture_sources, installed_old_apps=fixture_apps)
        if not any("unexpected installed old app file" in failure for failure in changed):
            print("installed app added file: unexpectedly passed")
            return 1
        print("installed app added file: FAIL as expected")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frozen-root", type=Path, default=DEFAULT_FROZEN_ROOT)
    parser.add_argument("--workspace", type=Path, default=REPOSITORY)
    parser.add_argument("--original-source-root", action="append", default=[], metavar="NAME=PATH",
                        help="override one original source root (batch-source, ocr-source, sender-source, unread-source)")
    parser.add_argument("--installed-old-app", action="append", default=[], metavar="APP_NAME=PATH",
                        help="override one installed old app path by frozen app name")
    parser.add_argument("--skip-signature", action="store_true", help="skip frozen/installed app codesign checks")
    parser.add_argument("--self-test", action="store_true", help="prove an isolated changed protected fixture is rejected")
    args = parser.parse_args()
    if args.self_test:
        return run_self_test()
    try:
        original_source_roots = overrides(args.original_source_root, ORIGINAL_SOURCE_ROOTS, "original source root")
        installed_old_apps = overrides(args.installed_old_app, OLD_INSTALLED_APPS, "installed old app")
    except ValueError as error:
        parser.error(str(error))
    failures = verify(args.frozen_root, args.workspace, verify_signatures=not args.skip_signature,
                      original_source_roots=original_source_roots, installed_old_apps=installed_old_apps)
    if failures:
        print("BASELINE VERIFICATION FAILED", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(f"BASELINE VERIFIED: {args.frozen_root}")
    return 0


def overrides(values: list[str], defaults: dict[str, Path], label: str) -> dict[str, Path]:
    result = dict(defaults)
    for value in values:
        name, separator, path = value.partition("=")
        if not separator or not name or not path:
            raise ValueError(f"{label} must use NAME=PATH: {value}")
        if name not in defaults:
            raise ValueError(f"unknown {label} name: {name}")
        result[name] = Path(path)
    return result


if __name__ == "__main__":
    raise SystemExit(main())
