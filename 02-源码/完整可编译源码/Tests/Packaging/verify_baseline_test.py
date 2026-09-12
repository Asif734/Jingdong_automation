"""Behavior test for the baseline verifier's isolated mutation fixture."""

from pathlib import Path
import subprocess
import sys
import unittest


class VerifyBaselineTest(unittest.TestCase):
    # Removing either protected-file comparison makes the verifier self-test
    # accept the deliberately modified working copy.
    def test_self_test_accepts_unchanged_fixture_and_rejects_mutation(self) -> None:
        root = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [sys.executable, str(root / "scripts" / "verify-baseline.py"), "--self-test"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("unchanged fixture: PASS", result.stdout)
        self.assertIn("mutated fixture: FAIL as expected", result.stdout)
        self.assertIn("original source mutation: FAIL as expected", result.stdout)
        self.assertIn("installed app mutation: FAIL as expected", result.stdout)
        self.assertIn("installed app added file: FAIL as expected", result.stdout)


if __name__ == "__main__":
    unittest.main()
