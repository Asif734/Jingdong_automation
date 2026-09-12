#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime, timezone


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = PROJECT_ROOT / "scripts" / "maintenance" / "qianniu_diagnostic_export.py"


def load_module():
    spec = importlib.util.spec_from_file_location("qianniu_diagnostic_export", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class DiagnosticExportTests(unittest.TestCase):
    def test_export_contains_structure_but_no_customer_runtime_or_credentials(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            runtime = base / "AI客服记录-任务隔离候选版"
            automatic = runtime / "运行状态" / "自动配置"
            automatic.mkdir(parents=True)
            (automatic / "machine-compatibility.json").write_text(
                json.dumps({"level": "fallback", "home": str(pathlib.Path.home())}), encoding="utf-8"
            )
            (automatic / "operator.json").write_text('{"alias":"小甘"}', encoding="utf-8")
            (runtime / "用户" / "secret").mkdir(parents=True)
            (runtime / "用户" / "secret" / "history.jsonl").write_text("客户秘密", encoding="utf-8")
            (runtime / "运行状态" / "CodexHome").mkdir(parents=True)
            (runtime / "运行状态" / "CodexHome" / "auth.json").write_text("token", encoding="utf-8")
            desktop = base / "Desktop"
            desktop.mkdir()

            output = module.export_diagnostic(runtime, desktop, datetime(2026, 9, 4, tzinfo=timezone.utc))

            with zipfile.ZipFile(output) as archive:
                names = set(archive.namelist())
                combined = b"".join(archive.read(name) for name in names)
            self.assertIn("machine-compatibility.json", names)
            self.assertIn("system-summary.json", names)
            self.assertNotIn("operator.json", names)
            self.assertNotIn(b"history.jsonl", combined)
            self.assertNotIn("客户秘密".encode(), combined)
            self.assertNotIn(b"auth.json", combined)
            self.assertNotIn(str(pathlib.Path.home()).encode(), combined)


if __name__ == "__main__":
    unittest.main()
