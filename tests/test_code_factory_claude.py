"""Claude Code routing, auth isolation, and structured result handling."""
from __future__ import annotations

import io
import json
import tempfile
import unittest
from pathlib import Path

from herdr_harness.code_factory.claude import ClaudeRunner, RoutedRunner


class RecordingStdin(io.StringIO):
    value = ""

    def close(self):
        self.value = self.getvalue()
        super().close()


class FakeProcess:
    def __init__(self, events, exit_code=0):
        self.stdin = RecordingStdin()
        self.stdout = io.StringIO("".join(json.dumps(event) + "\n" for event in events))
        self.stderr = io.StringIO("")
        self.returncode = None
        self.exit_code = exit_code

    def wait(self, timeout=None):
        self.returncode = self.exit_code
        return self.returncode

    def poll(self):
        return self.returncode


class ClaudeRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.calls = []
        self.events = [
            {"type": "assistant", "message": {"content": [
                {"type": "tool_use", "name": "Read"}, {"type": "text", "text": "draft"}]}},
            {"type": "result", "subtype": "success", "is_error": False,
             "result": '{"ok":true}', "total_cost_usd": 0.25},
        ]

    def popen(self, command, **kwargs):
        self.calls.append((command, kwargs))
        self.process = FakeProcess(self.events)
        return self.process

    def runner(self):
        return ClaudeRunner("/opt/claude/bin/claude", popen=self.popen, environ={
            "PATH": "/usr/bin", "ANTHROPIC_API_KEY": "wrong-provider",
            "ANTHROPIC_AUTH_TOKEN": "wrong-token", "GH_TOKEN": "github-secret",
            "CLAUDE_CODE_OAUTH_TOKEN": "different-login",
            "HERDR_HARNESS_API_TOKEN": "control-secret",
        })

    def run_claude(self, runner=None, attachments=()):
        runner = runner or self.runner()
        return runner.run(
            prompt="Plan synthetic issue", cwd=self.root, model="anthropic/claude-fable-5-1",
            thinking="high", session_dir=self.root / "sessions", session_id="session-1",
            name="synthetic plan", charter="Read-only planner.", tools="read,bash,grep,find,ls",
            attachments=attachments, timeout_seconds=60, log_path=self.root / "run.jsonl",
        )

    def test_subscription_command_stream_result_and_environment(self):
        image = self.root / "image.png"
        image.write_bytes(b"synthetic")
        result = self.run_claude(attachments=[image])
        command, options = self.calls[0]
        self.assertTrue(result.ok)
        self.assertEqual(result.text, '{"ok":true}')
        self.assertEqual(result.cost_usd, 0.25)
        self.assertEqual(result.tool_steps, 1)
        self.assertIn("--restricted", command)
        self.assertIn("--strict-mcp-config", command)
        self.assertIn("--no-session-persistence", command)
        self.assertEqual(command[command.index("--model") + 1], "claude-fable-5-1")
        self.assertEqual(command[command.index("--effort") + 1], "high")
        self.assertEqual(command[command.index("--permission-mode") + 1], "plan")
        self.assertEqual(command[command.index("--tools") + 1], "Read,Bash,Grep,Glob")
        self.assertEqual(command[command.index("--add-dir") + 1], str(image.parent))
        self.assertIn(str(image), self.process.stdin.value)
        self.assertNotIn("ANTHROPIC_API_KEY", options["env"])
        self.assertNotIn("ANTHROPIC_AUTH_TOKEN", options["env"])
        self.assertNotIn("CLAUDE_CODE_OAUTH_TOKEN", options["env"])
        self.assertNotIn("GH_TOKEN", options["env"])
        self.assertFalse([key for key in options["env"] if key.startswith("HERDR_")])

    def test_result_error_is_not_treated_as_success(self):
        self.events = [{"type": "result", "subtype": "error_during_execution", "is_error": True,
                        "result": "usage exhausted", "total_cost_usd": 0}]
        result = self.run_claude()
        self.assertFalse(result.ok)
        self.assertEqual(result.error, "usage exhausted")

    def test_missing_result_is_an_error(self):
        self.events = [{"type": "system", "subtype": "init"}]
        self.assertEqual(self.run_claude().error, "Claude Code did not emit a result")

    def test_routes_only_anthropic_models_to_claude(self):
        class Spy:
            def __init__(self): self.models = []
            def run(self, *, model, **kwargs):
                self.models.append(model)
            def environment(self): return {}
        pi, claude = Spy(), Spy()
        router = RoutedRunner(pi, claude, anthropic_runner="claude")
        router.run(model="anthropic/claude-opus-5-5")
        router.run(model="openai-codex/gpt-6-sol")
        self.assertEqual(claude.models, ["anthropic/claude-opus-5-5"])
        self.assertEqual(pi.models, ["openai-codex/gpt-6-sol"])
        RoutedRunner(pi, claude, anthropic_runner="pi").run(model="anthropic/claude-fable-5-1")
        self.assertEqual(pi.models[-1], "anthropic/claude-fable-5-1")


if __name__ == "__main__":
    unittest.main()
