"""Execute production scripts with external OS commands replaced by test boundaries."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

PROJECT = pathlib.Path(__file__).resolve().parents[1]
LAUNCHER = pathlib.Path(os.environ.get("AUDIT_SUITE_LAUNCHER", str(PROJECT.parents[1] / "versions/copy-experiment/suite-wrapper/Packaging/launcher.zsh")))

class PackagingTests(unittest.TestCase):
    def test_launcher_reuses_existing_instance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory).resolve()
            script = root / "Suite.app/Contents/MacOS/Launcher"
            script.parent.mkdir(parents=True)
            capture = root / "arguments"
            shim = root / "open-shim"
            shim.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > ' + str(capture) + '\n')
            shim.chmod(0o755)
            script.write_text(LAUNCHER.read_text().replace("/usr/bin/open", str(shim)))
            subprocess.run(["/bin/zsh", str(script)], check=True)
            args = capture.read_text().splitlines()
            self.assertNotIn("-n", args, "repeat launch must reuse the existing OCR")
            self.assertEqual(args, [str(root / "Suite.app/Contents/Resources/Components/千牛主聊天区OCR-通用复制实验版.app")])

    def test_build_refuses_running_process_without_overwriting_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "scripts").mkdir()
            shutil.copy(PROJECT / "scripts/build-app.sh", root / "scripts/build-app.sh")
            shutil.copytree(PROJECT / "Packaging", root / "Packaging")
            app = root / "output/千牛未读助手.app/Contents"
            (app / "MacOS").mkdir(parents=True)
            shutil.copy(PROJECT / "Packaging/Info.plist", app / "Info.plist")
            binary = app / "MacOS/UnreadApp"
            binary.write_bytes(b"running-original")
            (root / "bin").mkdir()
            (root / "bin/UnreadApp").write_bytes(b"replacement")
            commands = root / "commands"
            commands.mkdir()
            bodies = {
                "pgrep": 'echo 12345; exit 0',
                "security": 'echo "Apple Development: Chu Ye Shi (6Q9HFP6LJJ)"',
                "swift": 'case "$*" in *--show-bin-path*) echo "' + str(root / "bin") + '";; esac',
                "codesign": 'exit 0',
            }
            for name, body in bodies.items():
                path = commands / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            result = subprocess.run(["/bin/bash", str(root / "scripts/build-app.sh")], env={**os.environ, "PATH": str(commands) + ":" + os.environ["PATH"]}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, "must refuse a live executable")
            self.assertEqual(binary.read_bytes(), b"running-original")

if __name__ == "__main__":
    unittest.main()
