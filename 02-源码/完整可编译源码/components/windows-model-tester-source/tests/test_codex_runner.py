import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from app.codex_runner import CodexCommand, CodexRunner, build_arguments, sanitized_environment


class CodexRunnerTests(unittest.TestCase):
    def test_new_and_resume_arguments_preserve_contract(self):
        schema = Path(r"C:\app\schema.json"); result = Path(r"C:\tmp\result.json")
        images = [Path(r"C:\图\一.png"), Path(r"C:\图\二.jpg")]
        args = build_arguments(schema, result, images, None)
        self.assertEqual(["-a", "never", "exec"], args[:3])
        self.assertIn("gpt-5.6-sol", args); self.assertIn('model_reasoning_effort="medium"', args)
        self.assertEqual(2, args.count("-i")); self.assertEqual("-", args[-1]); self.assertIn("read-only", args)
        resumed = build_arguments(schema, result, [], "thread-123")
        self.assertEqual(["-a", "never", "exec", "resume"], resumed[:4])
        self.assertIn("thread-123", resumed); self.assertNotIn("read-only", resumed)

    def test_api_credentials_are_removed(self):
        env = sanitized_environment({"OPENAI_API_KEY":"secret", "CODEX_API_KEY":"secret2", "PATH":"x"})
        self.assertEqual({"PATH":"x"}, env)

    def test_cmd_command_uses_comspec_without_shell_string(self):
        command = CodexCommand(Path(r"C:\Users\u\AppData\Roaming\npm\codex.cmd"))
        executable, prefix = command.process_command({"COMSPEC": r"C:\Windows\System32\cmd.exe"})
        self.assertEqual(Path(r"C:\Windows\System32\cmd.exe"), executable)
        self.assertEqual(["/d", "/s", "/c", str(command.path)], prefix)

    def test_parse_result_returns_reply_and_transfer_decision(self):
        value = CodexRunner.parse_result({
            "action": "reply_then_transfer",
            "reply_text": "好的亲亲，我帮您转人工处理～",
            "transfer_reason": "customer_explicitly_requested_human",
            "reason": "客户明确要求人工客服",
        })
        self.assertEqual("reply_then_transfer", value.action)
        self.assertEqual("好的亲亲，我帮您转人工处理～", value.reply_text)
        self.assertEqual("customer_explicitly_requested_human", value.transfer_reason)

    def test_parse_result_rejects_unknown_action(self):
        with self.assertRaisesRegex(RuntimeError, "不支持的模型动作"):
            CodexRunner.parse_result({
                "action": "silent",
                "reply_text": "",
                "transfer_reason": "none",
                "reason": "",
            })
