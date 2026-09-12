#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
import zipfile


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD_SCRIPT = PROJECT_ROOT / "scripts" / "build-developer-handoff.sh"


class DeveloperHandoffContractTests(unittest.TestCase):
    def test_package_contains_recoverable_git_history_and_no_runtime_data(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = pathlib.Path(temporary_directory)
            fake_dmg = temporary_root / "千牛全自动客服-版本B.dmg"
            fake_dmg.write_bytes(b"fixture-dmg")
            output_directory = temporary_root / "output"

            environment = os.environ.copy()
            environment["AUTOREPLY_HANDOFF_ALLOW_DIRTY_FOR_TESTS"] = "1"
            result = subprocess.run(
                [
                    str(BUILD_SCRIPT),
                    "--dmg",
                    str(fake_dmg),
                    "--output",
                    str(output_directory),
                ],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            package_path = self._reported_path(result.stdout, "HANDOFF_DIR")
            zip_path = self._reported_path(result.stdout, "HANDOFF_ZIP")
            self.assertTrue(package_path.is_dir())
            self.assertTrue(zip_path.is_file())

            bundle_path = package_path / "03-Git完整历史" / "千牛全自动客服.bundle"
            snapshot_path = package_path / "02-源码" / "源码快照.zip"
            manifest_path = package_path / "06-校验" / "manifest.json"
            checksums_path = package_path / "06-校验" / "SHA256SUMS.txt"
            self.assertTrue(bundle_path.is_file())
            self.assertTrue(snapshot_path.is_file())
            self.assertTrue(manifest_path.is_file())
            self.assertTrue(checksums_path.is_file())
            self.assertTrue((package_path / "02-源码" / "完整可编译源码" / "Package.swift").is_file())
            self.assertTrue((package_path / "02-源码" / "工程师构建与Debug说明.md").is_file())
            self.assertTrue((package_path / "04-自动维护" / "安装自动清理.command").is_file())
            self.assertTrue((package_path / "05-故障处理" / "一键导出诊断包.command").is_file())

            subprocess.run(
                ["git", "bundle", "verify", str(bundle_path)],
                text=True,
                capture_output=True,
                check=True,
            )
            clone_path = temporary_root / "clone"
            subprocess.run(
                ["git", "clone", "--quiet", str(bundle_path), str(clone_path)],
                text=True,
                capture_output=True,
                check=True,
            )
            expected_head = subprocess.check_output(
                ["git", "-C", str(PROJECT_ROOT), "rev-parse", "HEAD"], text=True
            ).strip()
            cloned_head = subprocess.check_output(
                ["git", "-C", str(clone_path), "rev-parse", "HEAD"], text=True
            ).strip()
            self.assertEqual(cloned_head, expected_head)

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(manifest["gitCommit"], expected_head)
            self.assertTrue(manifest["gitBundleVerified"])
            self.assertTrue(manifest["gitCloneVerified"])
            self.assertEqual(manifest["distribution"]["file"], fake_dmg.name)
            self.assertEqual(
                manifest["distribution"]["sha256"],
                hashlib.sha256(fake_dmg.read_bytes()).hexdigest(),
            )

            packaged_paths = {
                path.relative_to(package_path).as_posix()
                for path in package_path.rglob("*")
                if path.is_file()
            }
            forbidden_fragments = {
                "auth.json",
                "history.jsonl",
                "processed-events.json",
                "图片指纹",
                "conversations/",
                "Application Support/",
            }
            for packaged_path in packaged_paths:
                self.assertFalse(
                    any(fragment in packaged_path for fragment in forbidden_fragments),
                    packaged_path,
                )

            with zipfile.ZipFile(zip_path) as archive:
                zip_names = set(archive.namelist())
            self.assertTrue(any(name.endswith("千牛全自动客服.bundle") for name in zip_names))
            self.assertTrue(any(name.endswith("manifest.json") for name in zip_names))

    @staticmethod
    def _reported_path(output: str, key: str) -> pathlib.Path:
        prefix = f"{key}="
        for line in output.splitlines():
            if line.startswith(prefix):
                return pathlib.Path(line.removeprefix(prefix))
        raise AssertionError(f"missing {key} in output:\n{output}")


if __name__ == "__main__":
    unittest.main()
