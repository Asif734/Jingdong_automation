import json
import pathlib
import unittest


FIXTURE_ROOT = pathlib.Path(__file__).parents[1] / "Fixtures" / "Compatibility"


class CompatibilityFixtureTest(unittest.TestCase):
    def test_all_fixtures_are_redacted_and_complete(self):
        expected_names = {"current", "colleague-a", "colleague-b"}
        self.assertEqual(
            {path.name for path in FIXTURE_ROOT.iterdir() if path.is_dir()},
            expected_names,
        )
        for name in expected_names:
            directory = FIXTURE_ROOT / name
            snapshot_path = directory / "snapshot.json"
            profile_path = directory / "expected-profile.json"
            self.assertTrue(snapshot_path.is_file())
            self.assertTrue(profile_path.is_file())
            snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
            expected = json.loads(profile_path.read_text(encoding="utf-8"))
            self.assertEqual(snapshot["schemaVersion"], 1)
            self.assertEqual(expected["schemaVersion"], 1)
            combined = json.dumps([snapshot, expected], ensure_ascii=False).lower()
            for forbidden in (
                "customeruid", "customernickname", "authtoken", "authorization",
                "chatmessage", "screenshot", "tb263", "stoneshishininger",
            ):
                self.assertNotIn(forbidden, combined)
            self.assertNotIn("raw-evidence", combined)


if __name__ == "__main__":
    unittest.main()
