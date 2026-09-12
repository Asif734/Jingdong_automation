import json
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.build_windows_package import _download, audit_tree, assemble_package, write_manifest


class PackageBuilderTests(unittest.TestCase):
    def test_windows_only_runtime_dependencies_are_explicitly_pinned(self):
        requirements = (ROOT / "requirements-windows.lock").read_text(encoding="utf-8").splitlines()
        self.assertIn("win32-setctime==1.2.0", requirements)
        self.assertIn("colorama==0.4.6", requirements)

    def test_download_uses_tls_validating_system_curl(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); curl = root / "curl"
            curl.write_text("#!/bin/sh\nprintf downloaded > \"$4\"\n", encoding="utf-8"); curl.chmod(0o755)
            old = os.environ.get("PATH", "")
            try:
                os.environ["PATH"] = str(root)
                target = _download("https://invalid.example/artifact", root / "artifact.zip")
            finally: os.environ["PATH"] = old
            self.assertEqual(b"downloaded", target.read_bytes())

    def test_audit_rejects_macos_and_auth_payloads(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / "bad.app").mkdir(); (root / "auth.json").write_text("secret")
            findings = audit_tree(root)
            self.assertTrue(any(".app" in x for x in findings)); self.assertTrue(any("auth.json" in x for x in findings))

    def test_manifest_has_frozen_contract_and_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); kb = root / "kb.zip"; kb.write_bytes(b"knowledge")
            path = write_manifest(root, kb)
            value = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual("gpt-5.6-sol", value["model"]); self.assertEqual("medium", value["reasoning_effort"])
            self.assertEqual("v2-top12", value["retriever"]); self.assertEqual(64, len(value["knowledge_base_sha256"]))

    def test_assemble_package_has_required_portable_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / "source"; destination = root / "package"
            for folder in ("app", "web", "resources"): (source / folder).mkdir(parents=True, exist_ok=True)
            (source / "app" / "server.py").write_text("print('server')", encoding="utf-8")
            (source / "web" / "index.html").write_text("tester", encoding="utf-8")
            (source / "resources" / "reply-output.schema.json").write_text("{}")
            launcher = root / "launcher.exe"; launcher.write_bytes(b"MZlauncher")
            python = root / "python"; python.mkdir(); (python / "python.exe").write_bytes(b"MZpython")
            (python / "python312._pth").write_text("python312.zip\n.\nLib/site-packages\nimport site\n", encoding="utf-8")
            kb = root / "kb.zip"; kb.write_bytes(b"kb")
            v2 = root / "v2"; (v2 / "cache").mkdir(parents=True); (v2 / "retrieve_top12.py").write_text("pass")
            assemble_package(destination, source, launcher, python, kb, v2)
            self.assertTrue((destination / "格志客服模型测试器.exe").exists())
            self.assertTrue((destination / "runtime" / "python.exe").exists())
            self.assertIn("..", (destination / "runtime" / "python312._pth").read_text(encoding="utf-8").splitlines())
            self.assertTrue((destination / "resources" / "KnowledgeBase" / "Grozziie-China-KB.zip").exists())
            self.assertTrue((destination / "resources" / "V2Knowledge" / "retrieve_top12.py").exists())
            self.assertEqual([], audit_tree(destination))


if __name__ == "__main__": unittest.main()
