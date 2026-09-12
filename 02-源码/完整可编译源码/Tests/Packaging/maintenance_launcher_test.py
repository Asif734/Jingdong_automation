#!/usr/bin/env python3
import os
import pathlib
import subprocess
import tempfile
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
PACKAGING = PROJECT_ROOT / "Packaging" / "自动维护"


class MaintenanceLauncherTests(unittest.TestCase):
    def test_installer_copies_verified_tools_to_stable_directory(self):
        with tempfile.TemporaryDirectory(prefix="中文 path ") as temporary:
            stable = pathlib.Path(temporary) / "Application Support" / "Maintenance"
            environment = os.environ.copy()
            environment["QIANNIU_MAINTENANCE_HOME"] = str(stable)
            result = subprocess.run(
                [str(PACKAGING / "安装自动清理.command")],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            for name in [
                "检查并安全清理.command",
                "qianniu_safe_cleanup.py",
                "qianniu_diagnostic_export.py",
                "自动清理规则.md",
                "manifest.sha256",
            ]:
                self.assertTrue((stable / name).is_file(), name)
            self.assertTrue(os.access(stable / "检查并安全清理.command", os.X_OK))
            verify = subprocess.run(
                ["shasum", "-a", "256", "-c", "manifest.sha256"],
                cwd=stable,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(verify.returncode, 0, verify.stderr)


if __name__ == "__main__":
    unittest.main()
