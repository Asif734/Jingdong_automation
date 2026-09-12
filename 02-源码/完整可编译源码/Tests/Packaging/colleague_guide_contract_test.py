#!/usr/bin/env python3
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class ColleagueGuideContractTests(unittest.TestCase):
    def test_codex_handoff_contains_mandatory_first_run_contract(self):
        text = (ROOT / "docs" / "把这个文件交给Codex-项目完整接管与Debug手册.md").read_text(encoding="utf-8")
        required = [
            "版本 B",
            "/Applications/千牛全自动客服-版本B.app",
            "设置 → 系统设置 → 接待设置 → 会话窗口 → 文本模式",
            "气泡模式不受支持",
            "客服名称/ID",
            "辅助功能",
            "屏幕与系统音频录制",
            "语音识别",
            "本机自适应校准",
            "预热",
            "开始",
            "停止",
            "一键导出诊断包.command",
            "每天检查千牛全自动客服版本 B",
            "不得自行编写删除命令",
        ]
        for phrase in required:
            self.assertIn(phrase, text, phrase)

    def test_install_guide_is_beginner_facing(self):
        text = (ROOT / "Packaging" / "首次安装说明.txt").read_text(encoding="utf-8")
        for phrase in [
            "把整个解压后的文件夹交给 Codex",
            "仍要打开",
            "文本模式",
            "自己的客服名称/ID",
            "不要同时运行",
        ]:
            self.assertIn(phrase, text, phrase)

    def test_engineering_guide_contains_rebuild_and_history_steps(self):
        text = (ROOT / "docs" / "工程师构建与Debug说明.md").read_text(encoding="utf-8")
        for phrase in ["git bundle verify", "git clone", "swift test", "build-distribution-dmg.sh", "arm64"]:
            self.assertIn(phrase, text, phrase)


if __name__ == "__main__":
    unittest.main()
