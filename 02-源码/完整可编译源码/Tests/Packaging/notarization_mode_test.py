#!/usr/bin/env python3
"""Notarization mode must be explicit and must never overclaim ad-hoc output."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "notarize-distribution.sh"


class NotarizationModeTests(unittest.TestCase):
    def run_notary(self, identity: str, profile: str | None = None) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            dmg = Path(directory) / "fixture.dmg"
            dmg.write_bytes(b"fixture")
            environment = os.environ.copy()
            environment["AUTOREPLY_SIGNING_IDENTITY"] = identity
            environment.pop("AUTOREPLY_NOTARY_PROFILE", None)
            if profile is not None:
                environment["AUTOREPLY_NOTARY_PROFILE"] = profile
            return subprocess.run(
                [str(SCRIPT), str(dmg)],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )

    def test_ad_hoc_mode_never_claims_notarized(self) -> None:
        result = self.run_notary("-")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NOTARIZATION_SKIPPED_ADHOC", result.stderr)

    def test_missing_profile_fails_before_submission(self) -> None:
        result = self.run_notary("Developer ID Application: Test")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AUTOREPLY_NOTARY_PROFILE", result.stderr)


if __name__ == "__main__":
    unittest.main()
