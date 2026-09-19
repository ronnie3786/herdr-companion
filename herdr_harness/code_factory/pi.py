"""Headless Pi session runner for the Code Factory.

Mirrors the command line and stream parsing of ``herdr_harness.agent_runs`` (prompt over
stdin, ``--mode json`` events on stdout) but keeps AGENTS.md context files enabled and
returns a ``PiResult`` instead of raising: a provider or agent error, a non-zero exit or
a timeout are all reported through ``PiResult.error`` so the pipeline can record them.

Sessions run unsandboxed as the operator with ``--no-approve`` and a shell tool, so the
child environment drops GitHub tokens (the daemon does every push, ``gh`` call and merge
itself) and each session gets its own process group, which the timeout path signals as
a whole so tool subprocesses cannot outlive the session.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from ..agent_runs import (
    MAX_EVENT_LINE_BYTES,
    MODEL_PATTERN,
    THINKING_LEVELS,
    _assistant_error,
    _assistant_text,
    _message_cost,
)
from ..child_environment import agent_environment
from .errors import CodeFactoryError

MAX_PROMPT_BYTES = 4 * 1024 * 1024
MAX_CHARTER_CHARS = 20_000
MAX_NAME_CHARS = 200
MAX_STDERR_CHARS = 4000
MAX_TEXT_CHARS = 200_000
KILL_GRACE_SECONDS = 10.0
SESSION_ENVIRONMENT_DENYLIST = frozenset({
    "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
})
SESSION_ID_CHARS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
TOOL_NAME_CHARS = frozenset("abcdefghijklmnopqrstuvwxyz0123456789_,")


@dataclass
class PiResult:
    """Outcome of one headless session."""

    text: str
    exit_code: int
    cost_usd: float
    session_id: str
    session_file: str | None
    log_path: Path
    error: str | None
    tool_steps: int

    @property
    def ok(self) -> bool:
        return self.error is None and self.exit_code == 0


def _invalid(message: str) -> CodeFactoryError:
    return CodeFactoryError(message, code="invalid_request")


def _dump(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False, sort_keys=True, default=str)


def find_session_file(session_dir: str | Path, session_id: str) -> Path | None:
    """Locate the ``*_<session_id>.jsonl`` transcript Pi wrote for this session, if exactly one exists."""
    directory = Path(session_dir)
    if not directory.is_dir() or not session_id:
        return None
    matches = sorted(directory.glob(f"*_{session_id}.jsonl"))
    if len(matches) != 1:
        return None
    path = matches[0].resolve()
    try:
        path.relative_to(directory.resolve())
    except ValueError:
        return None
    if not path.is_file():
        return None
    try:
        with path.open("r", encoding="utf-8") as handle:
            header = json.loads(handle.readline(256 * 1024))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(header, dict) or header.get("type") != "session" or str(header.get("id") or "") != session_id:
        return None
    return path


class _StreamState:
    """Mutable accumulator shared between the stdout reader thread and the runner."""

    def __init__(self) -> None:
        self.text = ""
        self.cost = 0.0
        self.tool_steps = 0
        self.error: str | None = None
        self.events = 0


class PiRunner:
    """Run one ``pi -p --mode json`` session to completion (or timeout) and summarize it."""

    def __init__(
        self,
        binary: str = "pi",
        *,
        popen: Callable[..., Any] = subprocess.Popen,
        environ: Mapping[str, str] | None = None,
        clock: Callable[[], float] = time.monotonic,
        killpg: Callable[[int, int], None] | None = None,
    ):
        if not isinstance(binary, str) or not binary.strip() or "\x00" in binary:
            raise _invalid("pi binary must be a non-empty string")
        self.binary = binary
        self._popen = popen
        self._environ = dict(environ) if environ is not None else {}
        self._clock = clock
        self._killpg = killpg if killpg is not None else getattr(os, "killpg", None)

    # -- command construction -----------------------------------------------------

    def command(
        self,
        *,
        model: str,
        thinking: str,
        session_dir: str | Path,
        session_id: str,
        name: str,
        charter: str,
        tools: str,
        attachments: Sequence[str | Path] = (),
    ) -> list[str]:
        """The argv for a session (validated); exposed so tests and callers can inspect it."""
        if not isinstance(model, str) or not MODEL_PATTERN.match(model):
            raise _invalid("invalid model identifier")
        if thinking not in THINKING_LEVELS:
            raise _invalid("invalid thinking level")
        if not isinstance(session_id, str) or not 1 <= len(session_id) <= 128 or set(session_id) - SESSION_ID_CHARS:
            raise _invalid("invalid session id")
        if not isinstance(name, str) or not name.strip() or len(name) > MAX_NAME_CHARS or "\n" in name:
            raise _invalid("invalid session name")
        if not isinstance(charter, str) or not charter.strip() or len(charter) > MAX_CHARTER_CHARS:
            raise _invalid("charter must be a non-empty string of at most 20000 characters")
        if not isinstance(tools, str) or not tools or set(tools) - TOOL_NAME_CHARS or ",," in tools:
            raise _invalid("tools must be a comma-separated list of tool names")
        paths: list[str] = []
        for item in attachments:
            path = Path(item)
            if not path.is_absolute() or not path.is_file():
                raise _invalid("attachments must be absolute paths to existing files")
            paths.append(str(path))
        return [
            self.binary, "-p", "--mode", "json", "--tools", tools,
            "--session-dir", str(session_dir), "--session-id", session_id,
            "--name", name, "--append-system-prompt", charter,
            "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-approve",
            "--model", model, "--thinking", thinking,
            *["@" + path for path in paths],
        ]

    def environment(self) -> dict[str, str]:
        """The session environment: ``HERDR_*`` settings and GitHub tokens stripped, provider keys kept."""
        env = agent_environment({**os.environ, **self._environ}, integration=False)
        for name in SESSION_ENVIRONMENT_DENYLIST:
            env.pop(name, None)
        env["PI_SKIP_VERSION_CHECK"] = "1"
        binary_dir = os.path.dirname(self.binary)
        if binary_dir:
            existing = env.get("PATH") or ""
            parts = [part for part in existing.split(os.pathsep) if part]
            if binary_dir not in parts:
                env["PATH"] = os.pathsep.join([binary_dir, *parts])
        return env

    # -- execution ----------------------------------------------------------------

    def run(
        self,
        *,
        prompt: str,
        cwd: str | Path,
        model: str,
        thinking: str,
        session_dir: str | Path,
        session_id: str,
        name: str,
        charter: str,
        tools: str,
        attachments: Sequence[str | Path] = (),
        timeout_seconds: int,
        log_path: str | Path,
        on_event: Callable[[dict[str, Any]], None] | None = None,
        cancel: Callable[[], bool] | None = None,
    ) -> PiResult:
        """Run the session; ``cancel`` is polled about once a second and ends it with ``error="cancelled"``."""
        if not isinstance(prompt, str) or not prompt.strip():
            raise _invalid("prompt must be a non-empty string")
        if len(prompt.encode("utf-8")) > MAX_PROMPT_BYTES:
            raise _invalid("prompt exceeds 4 MiB")
        if isinstance(timeout_seconds, bool) or not isinstance(timeout_seconds, int) or timeout_seconds <= 0:
            raise _invalid("timeout_seconds must be a positive integer")
        working = Path(cwd)
        if not working.is_dir():
            raise _invalid("cwd must be an existing directory")
        command = self.command(
            model=model, thinking=thinking, session_dir=session_dir, session_id=session_id,
            name=name, charter=charter, tools=tools, attachments=attachments,
        )
        Path(session_dir).mkdir(parents=True, exist_ok=True)
        log_file = Path(log_path)
        log_file.parent.mkdir(parents=True, exist_ok=True)
        state = _StreamState()
        stderr_parts: list[str] = []
        started = self._clock()

        with open(log_file, "a", encoding="utf-8") as log:
            log.write(_dump({
                "type": "herdr_runner_start", "sessionId": session_id, "name": name, "model": model,
                "thinking": thinking, "tools": tools, "cwd": str(working), "attachments": len(attachments),
            }) + "\n")
            log.flush()
            try:
                process = self._popen(
                    command,
                    cwd=str(working),
                    env=self.environment(),
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    bufsize=1,
                    start_new_session=True,
                )
            except OSError as exc:
                message = f"Pi could not start: {str(exc)[:240]}"
                log.write(_dump({"type": "herdr_runner_end", "exitCode": -1, "error": message}) + "\n")
                return PiResult(
                    text="", exit_code=-1, cost_usd=0.0, session_id=session_id, session_file=None,
                    log_path=log_file, error=message, tool_steps=0,
                )

            stdin_thread = threading.Thread(target=self._feed_stdin, args=(process, prompt), daemon=True)
            stdout_thread = threading.Thread(
                target=self._consume_stdout, args=(process, log, state, on_event), daemon=True,
            )
            stderr_thread = threading.Thread(target=self._consume_stderr, args=(process, stderr_parts), daemon=True)
            stdin_thread.start()
            stdout_thread.start()
            stderr_thread.start()

            stopped = self._wait(process, started, float(timeout_seconds), cancel)
            timed_out = stopped == "timeout"
            stdin_thread.join(timeout=2)
            stdout_thread.join(timeout=5)
            stderr_thread.join(timeout=2)

            exit_code = process.returncode if isinstance(process.returncode, int) else -1
            stderr_text = "".join(stderr_parts)[-MAX_STDERR_CHARS:]
            if stopped is not None:
                error: str | None = stopped
            elif state.error is not None:
                error = state.error or "model reported an error"
            elif exit_code != 0:
                error = f"pi exited with status {exit_code}"
                if stderr_text.strip():
                    error += ": " + stderr_text.strip()[-300:]
            else:
                error = None
            session_file = find_session_file(session_dir, session_id)
            log.write(_dump({
                "type": "herdr_runner_end", "exitCode": exit_code, "error": error, "timedOut": timed_out,
                "cancelled": stopped == "cancelled",
                "costUSD": round(state.cost, 6), "toolSteps": state.tool_steps, "events": state.events,
                "durationSeconds": round(max(0.0, self._clock() - started), 3),
                "sessionFile": str(session_file) if session_file else None,
                "stderr": stderr_text[-1000:],
            }) + "\n")
        return PiResult(
            text=state.text[:MAX_TEXT_CHARS],
            exit_code=exit_code,
            cost_usd=round(state.cost, 6),
            session_id=session_id,
            session_file=str(session_file) if session_file else None,
            log_path=log_file,
            error=error,
            tool_steps=state.tool_steps,
        )

    # -- helpers ------------------------------------------------------------------

    def _wait(
        self, process: Any, started: float, timeout_seconds: float, cancel: Callable[[], bool] | None = None,
    ) -> str | None:
        """Block until the process exits; returns ``None``, ``"timeout"`` or ``"cancelled"``.

        On timeout, or once ``cancel()`` reports that the caller no longer wants the
        session (a skipped issue, a stopping daemon), terminate then kill after a grace
        period. Both signals go to the session's process group so tool subprocesses
        (builds, dev servers, hung tests) die with it and release the stdout pipe.
        """
        deadline = started + timeout_seconds
        reason = "timeout"
        while True:
            if cancel is not None and cancel():
                reason = "cancelled"
                break
            remaining = deadline - self._clock()
            if remaining <= 0:
                break
            try:
                process.wait(timeout=min(remaining, 1.0))
                return None
            except subprocess.TimeoutExpired:
                continue
        if process.poll() is not None:
            return None
        self._signal_group(process, signal.SIGTERM, process.terminate)
        try:
            process.wait(timeout=KILL_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            self._signal_group(process, signal.SIGKILL, process.kill)
            try:
                process.wait(timeout=KILL_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                pass
        return reason

    def _signal_group(self, process: Any, signum: int, fallback: Callable[[], Any]) -> None:
        """Signal the whole process group; fall back to the pi process alone when that is impossible."""
        pid = getattr(process, "pid", None)
        if self._killpg is not None and isinstance(pid, int) and not isinstance(pid, bool) and pid > 0:
            try:
                self._killpg(pid, signum)
                return
            except OSError:
                pass
        try:
            fallback()
        except OSError:
            pass

    @staticmethod
    def _feed_stdin(process: Any, prompt: str) -> None:
        stdin = process.stdin
        if stdin is None:
            return
        try:
            stdin.write(prompt)
            stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            pass
        finally:
            try:
                stdin.close()
            except (BrokenPipeError, OSError, ValueError):
                pass

    @staticmethod
    def _consume_stdout(
        process: Any,
        log: Any,
        state: _StreamState,
        on_event: Callable[[dict[str, Any]], None] | None,
    ) -> None:
        stdout = process.stdout
        if stdout is None:
            return
        try:
            while True:
                line = stdout.readline(MAX_EVENT_LINE_BYTES + 1)
                if not line:
                    break
                if len(line) > MAX_EVENT_LINE_BYTES:
                    while line and not line.endswith("\n"):
                        line = stdout.readline(MAX_EVENT_LINE_BYTES + 1)
                    continue
                try:
                    log.write(line if line.endswith("\n") else line + "\n")
                    log.flush()
                except (OSError, ValueError):
                    pass
                try:
                    event = json.loads(line)
                except Exception:
                    continue
                if not isinstance(event, dict):
                    continue
                nested = event.get("event")
                if isinstance(nested, dict):
                    event = nested
                kind = event.get("type")
                if kind == "tool_execution_update":
                    continue
                state.events += 1
                if kind == "message_end":
                    message = event.get("message")
                    text = _assistant_text(message)
                    if text:
                        state.text = text
                    state.cost += _message_cost(message)
                    failure = _assistant_error(message)
                    if failure is not None:
                        state.error = failure or "model reported an error"
                elif kind == "agent_end":
                    messages = event.get("messages")
                    if isinstance(messages, list):
                        for message in messages:
                            failure = _assistant_error(message)
                            if failure is not None:
                                state.error = failure or "model reported an error"
                elif kind == "tool_execution_start":
                    state.tool_steps += 1
                if on_event is not None:
                    try:
                        on_event(event)
                    except Exception:
                        pass
        finally:
            try:
                stdout.close()
            except (OSError, ValueError):
                pass

    @staticmethod
    def _consume_stderr(process: Any, parts: list[str]) -> None:
        stderr = process.stderr
        if stderr is None:
            return
        try:
            while True:
                line = stderr.readline(2001)
                if not line:
                    break
                parts.append(line)
                while sum(len(item) for item in parts) > MAX_STDERR_CHARS and len(parts) > 1:
                    parts.pop(0)
        finally:
            try:
                stderr.close()
            except (OSError, ValueError):
                pass
