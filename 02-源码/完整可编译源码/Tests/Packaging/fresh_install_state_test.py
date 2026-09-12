#!/usr/bin/env python3
"""Runs the package-owned no-send fresh-install readiness harness."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
MARKER = "FRESH_READINESS_JSON="


class FreshInstallStateTests(unittest.TestCase):
    def test_fresh_install_reaches_read_only_ready_without_existing_profile(self) -> None:
        result = subprocess.run(
            [
                "/usr/bin/swift", "test", "--package-path", str(ROOT),
                "--filter", "FirstRunCoordinatorTests/testFreshInstallReadinessContract",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = [line for line in result.stdout.splitlines() if MARKER in line]
        self.assertTrue(lines, result.stdout)
        state = json.loads(lines[-1].split(MARKER, 1)[1])
        self.assertEqual(state["phase"], "readOnlyReady")
        self.assertTrue(state["ocrPrepared"])
        self.assertTrue(state["v2Prepared"])
        self.assertTrue(state["profileCreated"])
        self.assertFalse(state["endToEndVerified"])


if __name__ == "__main__":
    unittest.main()
