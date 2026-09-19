"""Headless Pi runner: argv, environment, event parsing, errors and timeouts with a fake Popen."""
from __future__ import annotations

import io
import json
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path

from herdr_harness.code_factory.errors import CodeFactoryError
from herdr_harness.code_factory.pi import PiResult, PiRunner, find_session_file


def event(kind: str, **payload) -> str:
    return json.dumps({"type": kind, **payload})


def assistant_end(text: str, cost: float = 0.0, stop_reason: str = "stop", error: str | None = None) -> str:
    message = {
        "role": "assistant",
        "content": [{"type": "text", "text": text}],
        "usage": {"cost": {"total": cost}},
        "stopReason": stop_reason,
    }
    if error is not None:
        message["errorMessage"] = error
    return event("message_end", message=message)


class RecordingStdin(io.StringIO):
    """Keeps what was written so tests can inspect it after the runner closes the pipe."""

    value = ""

    def close(self):
        self.value = self.getvalue()
        super().close()


class FakeProcess:
    """Scripted child process: stdout lines, stderr text, exit code, optional hang."""

    def __init__(self, stdout_lines, *, returncode=0, stderr="", hang=False):
        self.stdin = RecordingStdin()
        self.stdout = io.StringIO("".join(line if line.endswith("\n") else line + "\n" for line in stdout_lines))
        self.stderr = io.StringIO(stderr)
        self._exit = returncode
        self.hang = hang
        self.returncode = None
        self.terminated = 0
        self.killed = 0
        self.wait_calls = 0

    def wait(self, timeout=None):
        self.wait_calls += 1
        if self.hang and not self.terminated:
            raise subprocess.TimeoutExpired(cmd="pi", timeout=timeout or 0)
        self.returncode = self._exit
        return self.returncode

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated += 1
        self._exit = -15

    def kill(self):
        self.killed += 1
        self._exit = -9


class StubbornProcess(FakeProcess):
    """A child that ignores SIGTERM and only exits once killed."""

    def wait(self, timeout=None):
        self.wait_calls += 1
        if self.hang and not self.killed:
            raise subprocess.TimeoutExpired(cmd="pi", timeout=timeout or 0)
        self.returncode = self._exit
        return self.returncode


class FakePopen:
    def __init__(self, process: FakeProcess | None = None, *, error: OSError | None = None):
        self.process = process
        self.error = error
        self.calls: list[dict] = []

    def __call__(self, command, **kwargs):
        self.calls.append({"command": list(command), **kwargs})
        if self.error is not None:
            raise self.error
        assert self.process is not None
        return self.process


class FakeClock:
    def __init__(self, step: float = 0.0):
        self.now = 1000.0
        self.step = step

    def __call__(self) -> float:
        self.now += self.step
        return self.now


class PiRunnerTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cwd = self.root / "worktree"
        self.cwd.mkdir()
        self.sessions = self.root / "sessions"
        self.log = self.root / "logs" / "plan.jsonl"
        self.environ = {
            "OLLAMA_API_KEY": "provider-secret", "HERDR_HARNESS_API_TOKEN": "control-secret",
            "HERDR_CODE_FACTORY_REPOSITORY": "owner/repo", "PATH": "/usr/bin",
            "GH_TOKEN": "gh-secret", "GITHUB_TOKEN": "gh-secret",
        }

    def run_session(self, process: FakeProcess | None, *, popen: FakePopen | None = None, clock=None,
                    timeout=600, binary="pi", attachments=(), on_event=None, killpg=None,
                    cancel=None) -> tuple[PiResult, FakePopen]:
        popen = popen or FakePopen(process)
        runner = PiRunner(binary, popen=popen, environ=self.environ, clock=clock or FakeClock(), killpg=killpg)
        result = runner.run(
            prompt="Plan issue #12", cwd=self.cwd, model="openai-codex/gpt-6-astra", thinking="xhigh",
            session_dir=self.sessions, session_id="sess-12-plan", name="issue-12 plan",
            charter="You are Astra.", tools="read,bash,grep,find,ls", attachments=attachments,
            timeout_seconds=timeout, log_path=self.log, on_event=on_event, cancel=cancel,
        )
        return result, popen


class CommandTests(PiRunnerTestCase):
    def test_argv_environment_and_stdin(self):
        process = FakeProcess([assistant_end("Plan ready", cost=0.25)])
        shot = self.root / "shot.png"
        shot.write_bytes(b"png")
        result, popen = self.run_session(process, binary="/opt/pi/bin/pi", attachments=[shot])
        call = popen.calls[0]
        self.assertEqual(call["command"], [
            "/opt/pi/bin/pi", "-p", "--mode", "json", "--tools", "read,bash,grep,find,ls",
            "--session-dir", str(self.sessions), "--session-id", "sess-12-plan", "--name", "issue-12 plan",
            "--append-system-prompt", "You are Astra.", "--no-extensions", "--no-skills", "--no-prompt-templates",
            "--no-approve", "--model", "openai-codex/gpt-6-astra", "--thinking", "xhigh", "@" + str(shot),
        ])
        self.assertNotIn("--no-context-files", call["command"])
        self.assertEqual(call["cwd"], str(self.cwd))
        self.assertEqual(call["env"]["PI_SKIP_VERSION_CHECK"], "1")
        self.assertEqual(call["env"]["OLLAMA_API_KEY"], "provider-secret")
        self.assertFalse([key for key in call["env"] if key.startswith("HERDR_")])
        self.assertNotIn("GH_TOKEN", call["env"], "sessions never receive GitHub tokens; the daemon pushes and merges")
        self.assertNotIn("GITHUB_TOKEN", call["env"])
        self.assertTrue(call["env"]["PATH"].startswith("/opt/pi/bin"))
        self.assertIs(call["stdin"], subprocess.PIPE)
        self.assertTrue(call["text"])
        self.assertTrue(call["start_new_session"], "each session owns a process group the timeout path can signal")
        self.assertEqual(process.stdin.value, "Plan issue #12")
        self.assertTrue(process.stdin.closed)
        self.assertTrue(result.ok)
        self.assertTrue(self.sessions.is_dir())

    def test_invalid_arguments_raise_before_launch(self):
        popen = FakePopen(FakeProcess([]))
        runner = PiRunner("pi", popen=popen, environ=self.environ)
        base = dict(prompt="x", cwd=self.cwd, model="m", thinking="high", session_dir=self.sessions,
                    session_id="s1", name="n", charter="c", tools="read", timeout_seconds=60, log_path=self.log)
        for override in (
            {"model": "bad model"}, {"thinking": "ultra"}, {"session_id": "has space"}, {"tools": "read;rm"},
            {"prompt": " "}, {"timeout_seconds": 0}, {"cwd": self.root / "missing"}, {"charter": ""},
            {"attachments": [self.root / "missing.png"]}, {"attachments": ["relative.png"]}, {"name": "a\nb"},
        ):
            with self.subTest(override=override), self.assertRaises(CodeFactoryError) as caught:
                runner.run(**{**base, **override})
            self.assertEqual(caught.exception.code, "invalid_request")
        self.assertEqual(popen.calls, [])

    def test_launch_failure_is_reported_not_raised(self):
        result, popen = self.run_session(None, popen=FakePopen(error=OSError("pi not found")))
        self.assertEqual(result.exit_code, -1)
        self.assertIn("Pi could not start", result.error or "")
        self.assertEqual(result.text, "")
        lines = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual([line["type"] for line in lines], ["herdr_runner_start", "herdr_runner_end"])


class StreamTests(PiRunnerTestCase):
    def test_text_cost_tools_and_log(self):
        seen: list[str] = []
        process = FakeProcess([
            event("agent_start"),
            event("tool_execution_start", toolName="read"),
            event("tool_execution_update", toolName="read"),
            event("tool_execution_end", toolName="read"),
            json.dumps({"event": {"type": "tool_execution_start", "toolName": "bash"}}),
            assistant_end("First draft", cost=0.10),
            "this is not json",
            json.dumps(["not", "a", "dict"]),
            assistant_end("Final answer\n```json\n{\"ok\": true}\n```", cost=0.15),
            event("agent_end", messages=[{"role": "assistant", "stopReason": "stop"}]),
        ])
        result, _ = self.run_session(process, on_event=lambda item: seen.append(item["type"]))
        self.assertTrue(result.ok)
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.text, "Final answer\n```json\n{\"ok\": true}\n```")
        self.assertAlmostEqual(result.cost_usd, 0.25)
        self.assertEqual(result.tool_steps, 2)
        self.assertIsNone(result.error)
        self.assertEqual(result.session_id, "sess-12-plan")
        self.assertIsNone(result.session_file)
        self.assertEqual(result.log_path, self.log)
        self.assertNotIn("tool_execution_update", seen)
        self.assertEqual(seen.count("tool_execution_start"), 2)
        raw = self.log.read_text().splitlines()
        self.assertEqual(json.loads(raw[0])["type"], "herdr_runner_start")
        self.assertIn("this is not json", raw)
        tail = json.loads(raw[-1])
        self.assertEqual(tail["type"], "herdr_runner_end")
        self.assertEqual(tail["exitCode"], 0)
        self.assertEqual(tail["toolSteps"], 2)
        self.assertIsNone(tail["error"])
        self.assertEqual(len(raw), 12)

    def test_oversized_lines_are_skipped(self):
        huge = json.dumps({"type": "message_end", "message": {"role": "assistant", "text": "x" * (2 * 1024 * 1024 + 10)}})
        process = FakeProcess([huge, assistant_end("small")])
        result, _ = self.run_session(process)
        self.assertEqual(result.text, "small")
        self.assertNotIn("x" * 1000, self.log.read_text())

    def test_on_event_errors_are_ignored(self):
        def boom(item):
            raise RuntimeError("listener failure")

        result, _ = self.run_session(FakeProcess([assistant_end("ok")]), on_event=boom)
        self.assertEqual(result.text, "ok")


class ErrorTests(PiRunnerTestCase):
    def test_message_end_error(self):
        process = FakeProcess([assistant_end("", stop_reason="error", error="Provider quota exceeded")])
        result, _ = self.run_session(process)
        self.assertEqual(result.error, "Provider quota exceeded")
        self.assertFalse(result.ok)
        self.assertEqual(result.exit_code, 0)

    def test_agent_end_error_and_stop_reason_without_message(self):
        process = FakeProcess([
            assistant_end("partial"),
            event("agent_end", messages=[{"role": "assistant", "stopReason": "error"}]),
        ])
        result, _ = self.run_session(process)
        self.assertEqual(result.error, "model reported an error")
        self.assertEqual(result.text, "partial")

    def test_non_zero_exit_without_agent_error(self):
        process = FakeProcess([assistant_end("half")], returncode=2, stderr="pi: unknown model\n")
        result, _ = self.run_session(process)
        self.assertEqual(result.exit_code, 2)
        self.assertEqual(result.error, "pi exited with status 2: pi: unknown model")
        self.assertEqual(result.text, "half")
        tail = json.loads(self.log.read_text().splitlines()[-1])
        self.assertIn("unknown model", tail["stderr"])

    def test_timeout_terminates_then_reports(self):
        process = FakeProcess([assistant_end("never finished")], hang=True)
        clock = FakeClock(step=45.0)
        result, _ = self.run_session(process, clock=clock, timeout=60)
        self.assertEqual(result.error, "timeout")
        self.assertEqual(process.terminated, 1)
        self.assertEqual(process.killed, 0)
        self.assertEqual(result.exit_code, -15)
        self.assertEqual(result.text, "never finished")
        tail = json.loads(self.log.read_text().splitlines()[-1])
        self.assertTrue(tail["timedOut"])

    def test_timeout_signals_the_whole_process_group(self):
        process = FakeProcess([assistant_end("never finished")], hang=True)
        process.pid = 4242
        signals: list[tuple[int, int]] = []

        def killpg(pid: int, signum: int) -> None:
            signals.append((pid, signum))
            process.terminate() if signum == signal.SIGTERM else process.kill()

        result, _ = self.run_session(process, clock=FakeClock(step=45.0), timeout=60, killpg=killpg)
        self.assertEqual(result.error, "timeout")
        self.assertEqual(signals, [(4242, signal.SIGTERM)], "SIGTERM goes to the group, not just the pi process")
        self.assertEqual(result.exit_code, -15)

    def test_timeout_escalates_to_sigkill_on_the_process_group(self):
        process = StubbornProcess([assistant_end("never finished")], hang=True)
        process.pid = 4243
        signals: list[tuple[int, int]] = []

        def killpg(pid: int, signum: int) -> None:
            signals.append((pid, signum))
            process.terminate() if signum == signal.SIGTERM else process.kill()

        result, _ = self.run_session(process, clock=FakeClock(step=45.0), timeout=60, killpg=killpg)
        self.assertEqual(result.error, "timeout")
        self.assertEqual(signals, [(4243, signal.SIGTERM), (4243, signal.SIGKILL)])
        self.assertEqual(result.exit_code, -9)

    def test_timeout_falls_back_to_the_pi_process_when_the_group_is_gone(self):
        process = FakeProcess([assistant_end("never finished")], hang=True)
        process.pid = 4244

        def killpg(pid: int, signum: int) -> None:
            raise ProcessLookupError(pid)

        result, _ = self.run_session(process, clock=FakeClock(step=45.0), timeout=60, killpg=killpg)
        self.assertEqual(result.error, "timeout")
        self.assertEqual(process.terminated, 1)
        self.assertEqual(process.killed, 0)

    def test_cancel_terminates_the_session_before_its_timeout(self):
        process = FakeProcess([assistant_end("never finished")], hang=True)
        process.pid = 4245
        signals: list[tuple[int, int]] = []
        polls = 0

        def cancel() -> bool:
            nonlocal polls
            polls += 1
            return polls >= 2

        def killpg(pid: int, signum: int) -> None:
            signals.append((pid, signum))
            process.terminate() if signum == signal.SIGTERM else process.kill()

        result, _ = self.run_session(process, clock=FakeClock(step=0.5), timeout=3600, killpg=killpg, cancel=cancel)
        self.assertEqual(result.error, "cancelled")
        self.assertEqual(signals, [(4245, signal.SIGTERM)], "a cancelled session is terminated like a timed-out one")
        self.assertEqual(result.exit_code, -15)
        self.assertEqual(polls, 2, "cancel is polled once per wait round")
        tail = json.loads(self.log.read_text().splitlines()[-1])
        self.assertTrue(tail["cancelled"])
        self.assertFalse(tail["timedOut"])
        finished, _ = self.run_session(FakeProcess([assistant_end("done")]), cancel=lambda: False)
        self.assertIsNone(finished.error, "a cancel hook that stays false changes nothing")


class SessionFileTests(PiRunnerTestCase):
    def write_session(self, session_id: str, header: dict | None = None) -> Path:
        self.sessions.mkdir(parents=True, exist_ok=True)
        path = self.sessions / f"2026-09-18T12-00-00_{session_id}.jsonl"
        header = header if header is not None else {"type": "session", "id": session_id}
        path.write_text(json.dumps(header) + "\n" + json.dumps({"type": "message"}) + "\n")
        return path

    def test_session_file_is_reported_when_pi_wrote_it(self):
        expected = self.write_session("sess-12-plan")
        result, _ = self.run_session(FakeProcess([assistant_end("ok")]))
        self.assertEqual(result.session_file, str(expected.resolve()))

    def test_find_session_file_validates_header(self):
        self.assertIsNone(find_session_file(self.sessions, "missing"))
        self.write_session("bad-header", header={"type": "other", "id": "bad-header"})
        self.assertIsNone(find_session_file(self.sessions, "bad-header"))
        self.write_session("mismatch", header={"type": "session", "id": "someone-else"})
        self.assertIsNone(find_session_file(self.sessions, "mismatch"))
        good = self.write_session("good")
        self.assertEqual(find_session_file(self.sessions, "good"), good.resolve())
        (self.sessions / "2026-09-18T13-00-00_good.jsonl").write_text(json.dumps({"type": "session", "id": "good"}) + "\n")
        self.assertIsNone(find_session_file(self.sessions, "good"), "ambiguous matches are rejected")


if __name__ == "__main__":
    unittest.main()
