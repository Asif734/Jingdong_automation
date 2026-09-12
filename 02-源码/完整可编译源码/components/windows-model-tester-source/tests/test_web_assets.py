import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class WebAssetTests(unittest.TestCase):
    def test_ui_is_offline_and_supports_multiple_images(self):
        html = (ROOT / "web" / "index.html").read_text(encoding="utf-8")
        js = (ROOT / "web" / "app.js").read_text(encoding="utf-8")
        self.assertNotIn("https://", html); self.assertNotIn("http://", html)
        self.assertIn('accept="image/*"', html); self.assertIn("multiple", html)
        self.assertIn("dragover", js); self.assertIn("drop", js)
        self.assertIn("expected_version", js)
        self.assertIn("catch(e){await refresh();", js)
        self.assertIn("gpt-5.6-sol", html); self.assertIn("medium", html)

    def test_ui_displays_model_reply_action_and_transfer_reason(self):
        html = (ROOT / "web" / "index.html").read_text(encoding="utf-8")
        js = (ROOT / "web" / "app.js").read_text(encoding="utf-8")
        self.assertIn('id="decision"', html)
        self.assertIn('id="transferReason"', html)
        self.assertIn("value.action", js)
        self.assertIn("value.transfer_reason", js)


if __name__ == "__main__": unittest.main()
