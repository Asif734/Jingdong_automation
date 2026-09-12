#!/usr/bin/python3
"""Relocate absolute python.org framework dependencies inside an app bundle."""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys


SOURCE_PREFIX = "/Library/Frameworks/Python.framework/Versions/3.12/"


def output(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL)


def is_macho(path: pathlib.Path) -> bool:
    try:
        return "Mach-O" in output("/usr/bin/file", str(path))
    except (OSError, subprocess.CalledProcessError):
        return False


def dependencies(path: pathlib.Path) -> list[str]:
    try:
        lines = output("/usr/bin/otool", "-L", str(path)).splitlines()[1:]
    except (OSError, subprocess.CalledProcessError):
        return []
    return [line.strip().split(" (compatibility", 1)[0] for line in lines]


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: relocate-python.py APP_RESOURCES")
    resources = pathlib.Path(sys.argv[1]).resolve()
    framework = resources / "Python.framework"
    version_root = framework / "Versions" / "3.12"
    if not version_root.exists():
        raise SystemExit(f"missing bundled Python framework: {version_root}")

    for candidate in resources.rglob("*"):
        if not candidate.is_file() or not is_macho(candidate):
            continue
        for dependency in dependencies(candidate):
            if not dependency.startswith(SOURCE_PREFIX):
                continue
            suffix = dependency.removeprefix(SOURCE_PREFIX)
            target = version_root / suffix
            relative = os.path.relpath(target, candidate.parent)
            replacement = f"@loader_path/{relative}"
            subprocess.check_call([
                "/usr/bin/install_name_tool",
                "-change",
                dependency,
                replacement,
                str(candidate),
            ])

    python_library = version_root / "Python"
    if python_library.exists():
        subprocess.check_call([
            "/usr/bin/install_name_tool",
            "-id",
            "@rpath/Python",
            str(python_library),
        ])


if __name__ == "__main__":
    main()
