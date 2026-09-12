#!/usr/bin/env python3
import importlib.util
import fcntl
import json
import os
import pathlib
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = PROJECT_ROOT / "scripts" / "maintenance" / "qianniu_safe_cleanup.py"


def load_module():
    spec = importlib.util.spec_from_file_location("qianniu_safe_cleanup", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class SafeCleanupTests(unittest.TestCase):
    now = datetime(2026, 9, 4, tzinfo=timezone.utc)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name) / "AI客服记录-任务隔离候选版"
        (self.root / "运行状态" / "媒体路由").mkdir(parents=True)

    def tearDown(self):
        self.temporary.cleanup()

    def write_state(self, entries):
        path = self.root / "运行状态" / "媒体路由" / "video-analysis-inbox.json"
        path.write_text(json.dumps({"schemaVersion": 1, "entries": entries}), encoding="utf-8")
        return path

    def entry(self, marker, phase="completed", age_days=31, completed=True):
        message_hash = marker * 64
        video = self.root / "收到的视频" / f"{message_hash}.mp4"
        video.parent.mkdir(parents=True, exist_ok=True)
        video.write_bytes(b"video")
        evidence = self.root / "收到的视频帧和音轨" / message_hash
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / "frame-01.jpg").write_bytes(b"frame")
        value = {
            "customerUID": "redacted",
            "messageHash": message_hash,
            "videoFilePath": str(video),
            "bytes": 5,
            "contentSHA256": "f" * 64,
            "phase": phase,
            "attempts": 1,
            "updatedAt": (self.now - timedelta(days=age_days)).isoformat().replace("+00:00", "Z"),
            "failure": None,
        }
        if completed:
            value["completedAt"] = value["updatedAt"]
        return value, video, evidence

    def test_age_cleanup_deletes_only_completed_older_than_30_days(self):
        module = load_module()
        old, old_video, old_evidence = self.entry("a", age_days=31)
        recent, recent_video, recent_evidence = self.entry("b", age_days=29)
        active, active_video, active_evidence = self.entry("c", phase="admitted", age_days=90)
        self.write_state([old, recent, active])

        report = module.run_cleanup(self.root, self.now, False)

        self.assertFalse(old_video.exists())
        self.assertFalse(old_evidence.exists())
        self.assertTrue(recent_video.exists())
        self.assertTrue(recent_evidence.exists())
        self.assertTrue(active_video.exists())
        self.assertTrue(active_evidence.exists())
        self.assertEqual(report.deleted_hashes, ["a" * 64])
        stored = json.loads((self.root / "运行状态/媒体路由/video-analysis-inbox.json").read_text())
        tombstone = next(item for item in stored["entries"] if item["messageHash"] == "a" * 64)
        self.assertEqual(tombstone["phase"], "completed")
        self.assertEqual(tombstone["videoFilePath"], "")
        self.assertEqual(tombstone["bytes"], 0)

    def test_capacity_cleanup_uses_oldest_completed_until_target(self):
        module = load_module()
        oldest, oldest_video, _ = self.entry("d", age_days=20)
        newer, newer_video, _ = self.entry("e", age_days=10)
        oldest_video.write_bytes(b"x" * 400_000)
        newer_video.write_bytes(b"y" * 400_000)
        self.write_state([newer, oldest])
        policy = module.CleanupPolicy(
            retention_days=30,
            high_watermark_bytes=700_000,
            target_bytes=500_000,
        )

        report = module.run_cleanup(self.root, self.now, False, policy=policy)

        self.assertFalse(oldest_video.exists())
        self.assertTrue(newer_video.exists())
        self.assertEqual(report.trigger, "capacity")

    def test_active_failed_unknown_and_legacy_undated_entries_are_preserved(self):
        module = load_module()
        active, active_video, _ = self.entry("1", phase="downloaded", age_days=90)
        failed, failed_video, _ = self.entry("2", phase="failed", age_days=90)
        legacy, legacy_video, _ = self.entry("3", phase="completed", age_days=90, completed=False)
        self.write_state([active, failed, legacy])

        report = module.run_cleanup(self.root, self.now, False)

        self.assertTrue(active_video.exists())
        self.assertTrue(failed_video.exists())
        self.assertTrue(legacy_video.exists())
        self.assertFalse(report.deleted_hashes)
        self.assertTrue(any(item["reason"] == "missingCompletedAt" for item in report.skipped))

    def test_symlink_and_outside_runtime_paths_are_rejected(self):
        module = load_module()
        item, video, evidence = self.entry("4", age_days=90)
        outside = pathlib.Path(self.temporary.name) / "outside.mp4"
        outside.write_bytes(b"outside")
        video.unlink()
        video.symlink_to(outside)
        item["videoFilePath"] = str(outside)
        self.write_state([item])

        report = module.run_cleanup(self.root, self.now, False)

        self.assertTrue(outside.exists())
        self.assertTrue(video.is_symlink())
        self.assertTrue(evidence.exists())
        self.assertFalse(report.deleted_hashes)
        self.assertTrue(report.skipped)

    def test_changed_file_identity_between_plan_and_delete_is_skipped(self):
        module = load_module()
        item, video, evidence = self.entry("5", age_days=90)
        self.write_state([item])

        def replace_candidate(_candidate):
            video.unlink()
            video.write_bytes(b"replacement")

        report = module.run_cleanup(self.root, self.now, False, before_delete=replace_candidate)

        self.assertTrue(video.exists())
        self.assertTrue(evidence.exists())
        self.assertFalse(report.deleted_hashes)
        self.assertTrue(any(item["reason"] == "identityChanged" for item in report.skipped))

    def test_second_run_is_idempotent(self):
        module = load_module()
        item, _, _ = self.entry("6", age_days=90)
        self.write_state([item])
        first = module.run_cleanup(self.root, self.now, False)
        second = module.run_cleanup(self.root, self.now + timedelta(days=1), False)
        self.assertEqual(first.deleted_hashes, ["6" * 64])
        self.assertEqual(second.deleted_hashes, [])

    def test_corrupt_state_returns_blocked_report_without_deleting(self):
        module = load_module()
        video = self.root / "收到的视频" / f"{'7' * 64}.mp4"
        video.parent.mkdir(parents=True)
        video.write_bytes(b"keep")
        state = self.root / "运行状态/媒体路由/video-analysis-inbox.json"
        state.write_text("{broken", encoding="utf-8")

        report = module.run_cleanup(self.root, self.now, False)

        self.assertTrue(video.exists())
        self.assertEqual(report.status, "blocked")
        self.assertTrue(report.errors)

    def test_concurrent_lock_returns_busy_without_deleting(self):
        module = load_module()
        item, video, _ = self.entry("8", age_days=90)
        self.write_state([item])
        lock_path = self.root / "Maintenance" / "cleanup.lock"
        lock_path.parent.mkdir(parents=True)
        with lock_path.open("a+") as lock_handle:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            report = module.run_cleanup(self.root, self.now, False)
        self.assertEqual(report.status, "busy")
        self.assertTrue(video.exists())

    def test_old_terminal_trace_is_removed_but_active_trace_is_kept(self):
        module = load_module()
        self.write_state([])
        traces = self.root / "运行状态" / "CLI轨迹"
        traces.mkdir(parents=True)
        terminal = traces / "terminal.jsonl"
        active = traces / "active.jsonl"
        terminal.write_text('{"event":"process.completed"}\n', encoding="utf-8")
        active.write_text('{"event":"process.started"}\n', encoding="utf-8")
        old = (self.now - timedelta(days=31)).timestamp()
        os.utime(terminal, (old, old))
        os.utime(active, (old, old))

        module.run_cleanup(self.root, self.now, False)

        self.assertFalse(terminal.exists())
        self.assertTrue(active.exists())

    def test_missing_video_state_is_safe_noop(self):
        module = load_module()
        report = module.run_cleanup(self.root, self.now, False)
        self.assertEqual(report.status, "ok")
        self.assertEqual(report.trigger, "none")


if __name__ == "__main__":
    unittest.main()
