#!/usr/bin/env python3
"""Contract tests for the embedded one-click installer payload."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
INSTALLER = Path(
    os.environ.get(
        "AUTOREPLY_INSTALLER_APP",
        ROOT / "build-output" / "安装并启动.app",
    )
)
RESOURCES = INSTALLER / "Contents" / "Resources"
PAYLOAD = RESOURCES / "千牛全自动客服-版本B.app"
MANIFEST = RESOURCES / "distribution-manifest.json"


def relative_files(root: Path) -> list[str]:
    return sorted(
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and not path.is_symlink() and path.name != ".DS_Store"
    )


class InstallerPayloadTests(unittest.TestCase):
    def test_manifest_covers_and_hashes_every_payload_file(self) -> None:
        self.assertTrue(PAYLOAD.is_dir(), f"missing payload: {PAYLOAD}")
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
        declared = sorted(item["path"] for item in data["files"])
        self.assertEqual(declared, relative_files(PAYLOAD))
        self.assertEqual(data["schemaVersion"], 1)
        self.assertEqual(data["architecture"], "arm64")
        for item in data["files"]:
            digest = hashlib.sha256((PAYLOAD / item["path"]).read_bytes()).hexdigest()
            self.assertEqual(item["sha256"], digest, item["path"])

    def test_payload_and_installer_are_arm64_and_signed(self) -> None:
        for app in (PAYLOAD, INSTALLER):
            result = subprocess.run(
                ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        for executable in (
            PAYLOAD / "Contents" / "MacOS" / "AutoReplyApp",
            INSTALLER / "Contents" / "MacOS" / "QianniuInstallerApp",
        ):
            result = subprocess.run(
                ["/usr/bin/lipo", "-archs", str(executable)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "arm64")


if __name__ == "__main__":
    unittest.main()
