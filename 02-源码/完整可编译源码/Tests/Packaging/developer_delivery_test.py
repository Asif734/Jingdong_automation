#!/usr/bin/env python3
import os
import pathlib
import subprocess
import tempfile
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
REBUILD_SCRIPT = PROJECT_ROOT / "scripts" / "developer-package-rebuild.command"
BUILD_SCRIPT = PROJECT_ROOT / "scripts" / "build-app.sh"


class DeveloperDeliveryTests(unittest.TestCase):
    def test_preflight_accepts_self_contained_package_and_selects_ad_hoc_signing(self) -> None:
        """Catches a delivery that still requires the original developer certificate."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            package_root = pathlib.Path(temporary_directory)
            source_root = package_root / "02-完整源码"
            app_resources = (
                package_root
                / "01-可运行应用"
                / "千牛全自动客服-任务隔离候选版.app"
                / "Contents"
                / "Resources"
            )
            (source_root / "scripts").mkdir(parents=True)
            (source_root / "Package.swift").write_text("// fixture\n", encoding="utf-8")
            (source_root / "scripts" / "build-app.sh").write_text(
                "#!/bin/zsh\nexit 0\n", encoding="utf-8"
            )
            os.chmod(source_root / "scripts" / "build-app.sh", 0o755)
            (app_resources / "V2Knowledge" / "site-packages" / "fastembed").mkdir(
                parents=True
            )
            (app_resources / "V2Knowledge" / "cache" / "models").mkdir(parents=True)
            python_binary = (
                app_resources
                / "Python.framework"
                / "Versions"
                / "3.12"
                / "bin"
                / "python3.12"
            )
            python_binary.parent.mkdir(parents=True)
            python_binary.write_text("fixture\n", encoding="utf-8")
            os.chmod(python_binary, 0o755)
            knowledge_base = (
                app_resources / "KnowledgeBase" / "Grozziie-China-KB.zip"
            )
            knowledge_base.parent.mkdir(parents=True)
            knowledge_base.write_bytes(b"fixture knowledge base")
            build_resources = package_root / "03-构建资源"
            (build_resources / "V2Runtime" / ".venv" / "lib" / "python3.12").mkdir(
                parents=True
            )
            os.symlink(
                app_resources / "V2Knowledge" / "site-packages",
                build_resources
                / "V2Runtime"
                / ".venv"
                / "lib"
                / "python3.12"
                / "site-packages",
            )
            os.symlink(
                app_resources / "V2Knowledge" / "cache",
                build_resources / "V2Runtime" / "cache",
            )
            os.symlink(
                app_resources / "Python.framework",
                build_resources / "Python.framework",
            )
            os.symlink(
                knowledge_base,
                build_resources / "Grozziie-China-KB.zip",
            )

            fake_bin = package_root / "fake-bin"
            fake_bin.mkdir()
            fake_security = fake_bin / "security"
            fake_security.write_text("#!/bin/zsh\nexit 0\n", encoding="utf-8")
            os.chmod(fake_security, 0o755)

            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
            environment["QIANNIU_DEVELOPER_PACKAGE_ROOT"] = str(package_root)
            result = subprocess.run(
                [str(REBUILD_SCRIPT), "--preflight-only"],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PREFLIGHT_OK=1", result.stdout)
            self.assertIn("SIGNING_MODE=adhoc", result.stdout)
            self.assertIn(
                f"KNOWLEDGE_BASE={build_resources / 'Grozziie-China-KB.zip'}",
                result.stdout,
            )

    def test_build_script_accepts_ad_hoc_identity_without_certificate_lookup(self) -> None:
        """Catches the old hard dependency on one developer's signing certificate."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            fake_bin = pathlib.Path(temporary_directory)
            marker = fake_bin / "security-was-called"
            fake_security = fake_bin / "security"
            fake_security.write_text(
                f"#!/bin/zsh\ntouch {marker!s}\nexit 1\n", encoding="utf-8"
            )
            os.chmod(fake_security, 0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
            environment["AUTOREPLY_SIGNING_IDENTITY"] = "-"
            environment["AUTOREPLY_VALIDATE_SIGNING_ONLY"] = "1"
            result = subprocess.run(
                [str(BUILD_SCRIPT)],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("SIGNING_MODE=adhoc", result.stdout)
            self.assertFalse(marker.exists(), "ad-hoc signing must not query certificates")

    def test_ad_hoc_signing_does_not_enable_hardened_runtime_library_validation(self) -> None:
        """Catches ad-hoc Python binaries rejecting their bundled framework by Team ID."""
        environment = os.environ.copy()
        environment["AUTOREPLY_SIGNING_IDENTITY"] = "-"
        environment["AUTOREPLY_PRINT_SIGNING_OPTIONS_ONLY"] = "1"
        environment["AUTOREPLY_VALIDATE_SIGNING_ONLY"] = "1"

        result = subprocess.run(
            [str(BUILD_SCRIPT)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SIGNING_OPTIONS=", result.stdout)
        self.assertNotIn("--options runtime", result.stdout)

    def test_build_script_accepts_certificate_hash_selected_by_wrapper(self) -> None:
        """Catches rejecting a valid certificate when the wrapper passes its SHA-1 hash."""
        certificate_hash = "0123456789ABCDEF0123456789ABCDEF01234567"
        with tempfile.TemporaryDirectory() as temporary_directory:
            fake_bin = pathlib.Path(temporary_directory)
            fake_security = fake_bin / "security"
            fake_security.write_text(
                "#!/bin/zsh\n"
                f"print -- '  1) {certificate_hash} \"Apple Development: Test (TEAMID)\"'\n"
                "print -- '     1 valid identities found'\n",
                encoding="utf-8",
            )
            os.chmod(fake_security, 0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
            environment["AUTOREPLY_SIGNING_IDENTITY"] = certificate_hash
            environment["AUTOREPLY_VALIDATE_SIGNING_ONLY"] = "1"
            result = subprocess.run(
                [str(BUILD_SCRIPT)],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("SIGNING_MODE=certificate", result.stdout)


if __name__ == "__main__":
    unittest.main()
