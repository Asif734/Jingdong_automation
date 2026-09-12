import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]


class LauncherBuildTests(unittest.TestCase):
    def test_launcher_captures_backend_stderr_before_waiting_for_ready(self):
        source = (ROOT / "launcher" / "Program.cs").read_text(encoding="utf-8")
        capture = source.index("DrainAsync(child.StandardError, logPath)")
        wait_for_ready = source.index("child.StandardOutput.ReadLineAsync()")
        self.assertLess(capture, wait_for_ready)

    def test_cross_publishes_single_windows_executable(self):
        dotnet = REPO / ".toolcache" / "dotnet" / "dotnet"
        if not dotnet.exists(): self.skipTest("local dotnet SDK unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            run = subprocess.run([
                str(dotnet), "publish", str(ROOT / "launcher" / "GrozziieModelTesterLauncher.csproj"),
                "-c", "Release", "-r", "win-x64", "--self-contained", "true",
                "-p:PublishSingleFile=true", "-o", tmp,
            ], text=True, capture_output=True)
            self.assertEqual(0, run.returncode, run.stderr)
            exe = Path(tmp) / "格志客服模型测试器.exe"
            self.assertTrue(exe.exists())
            self.assertEqual(b"MZ", exe.read_bytes()[:2])


if __name__ == "__main__": unittest.main()
