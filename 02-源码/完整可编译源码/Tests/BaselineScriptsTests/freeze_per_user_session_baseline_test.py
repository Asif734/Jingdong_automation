from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "freeze-per-user-session-baseline.py"


def load_script():
    spec = importlib.util.spec_from_file_location("freeze_per_user_session_baseline", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FreezePerUserSessionBaselineTests(unittest.TestCase):
    def test_freeze_copies_and_hashes_source_and_app(self):
        module = load_script()
        with tempfile.TemporaryDirectory(prefix="session-baseline-test-") as temporary:
            root = Path(temporary)
            source = root / "source"
            app = root / "Current.app"
            destination = root / "frozen"
            (source / "Sources").mkdir(parents=True)
            (app / "Contents" / "MacOS").mkdir(parents=True)
            (source / "Sources" / "a.swift").write_text("let a = 1\n", encoding="utf-8")
            (app / "Contents" / "MacOS" / "App").write_bytes(b"binary")

            manifest = module.freeze(
                source_root=source,
                installed_app=app,
                destination=destination,
                verify_signature=False,
            )

            self.assertTrue((destination / "source" / "Sources" / "a.swift").is_file())
            self.assertTrue((destination / "app" / "Current.app" / "Contents" / "MacOS" / "App").is_file())
            self.assertEqual(
                set(manifest["files"]),
                {
                    "app/Current.app/Contents/MacOS/App",
                    "source/Sources/a.swift",
                },
            )
            self.assertTrue((destination / "manifest.json").is_file())

    def test_freeze_refuses_to_overwrite_destination(self):
        module = load_script()
        with tempfile.TemporaryDirectory(prefix="session-baseline-test-") as temporary:
            root = Path(temporary)
            source = root / "source"
            app = root / "Current.app"
            destination = root / "frozen"
            source.mkdir()
            app.mkdir()
            destination.mkdir()

            with self.assertRaises(FileExistsError):
                module.freeze(source, app, destination, verify_signature=False)

    def test_generated_and_live_data_directories_are_excluded(self):
        module = load_script()
        with tempfile.TemporaryDirectory(prefix="session-baseline-test-") as temporary:
            root = Path(temporary)
            source = root / "source"
            app = root / "Current.app"
            destination = root / "frozen"
            (source / ".build" / "cache").mkdir(parents=True)
            (source / "output").mkdir(parents=True)
            (source / "Sources").mkdir(parents=True)
            app.mkdir()
            (source / ".build" / "cache" / "large.bin").write_bytes(b"x")
            (source / "output" / "old.app").write_bytes(b"x")
            (source / "Sources" / "kept.swift").write_text("let kept = true\n", encoding="utf-8")

            module.freeze(source, app, destination, verify_signature=False)

            self.assertFalse((destination / "source" / ".build").exists())
            self.assertFalse((destination / "source" / "output").exists())
            self.assertTrue((destination / "source" / "Sources" / "kept.swift").is_file())


if __name__ == "__main__":
    unittest.main()
