"""Claude Code subscription runner for Code Factory's read-only Anthropic roles.

The daemon keeps Pi for other providers. Claude Code owns its own claude.ai login;
Pi's Anthropic OAuth entry is a separate credential with separate usage behavior.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from ..agent_runs import MAX_EVENT_LINE_BYTES, MODEL_PATTERN, THINKING_LEVELS
from .pi import PiResult, PiRunner, _StreamState, _invalid

CLAUDE_TOOLS = {"read": "Read", "bash": "Bash", "grep": "Grep", "find": "Glob", "ls": "Glob"}
CLAUDE_EFFORTS = {"low", "medium", "high", "xhigh", "max"}
CLAUDE_AUTH_OVERRIDES = frozenset({
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_PROFILE", "ANTHROPIC_BASE_URL",
    "ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_ORGANIZATION_ID", "ANTHROPIC_IDENTITY_TOKEN_FILE",
    "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
})


class ClaudeRunner(PiRunner):
    """Reuse Pi's bounded process handling, but speak Claude Code's JSON event format."""

    runner_name = "Claude Code"

    def environment(self) -> dict[str, str]:
        env = super().environment()
        for name in CLAUDE_AUTH_OVERRIDES:
            env.pop(name, None)
        return env

    def command(
        self, *, model: str, thinking: str, session_dir: str | Path, session_id: str,
        name: str, charter: str, tools: str, attachments: Sequence[str | Path] = (),
    ) -> list[str]:
        # The base command validates the shared pipeline arguments and file paths.
        super().command(model=model, thinking=thinking, session_dir=session_dir,
                        session_id=session_id, name=name, charter=charter, tools=tools,
                        attachments=attachments)
        if not model.startswith("anthropic/") or not MODEL_PATTERN.match(model):
            raise _invalid("Claude Code requires an anthropic/model identifier")
        if thinking not in CLAUDE_EFFORTS:
            raise _invalid("Claude Code thinking must be low, medium, high, xhigh, or max")
        requested = tools.split(",")
        if any(tool not in CLAUDE_TOOLS for tool in requested):
            raise _invalid("Claude Code supports only read-only planning and review tools")
        allowed = ",".join(dict.fromkeys(CLAUDE_TOOLS[tool] for tool in requested))
        model_name = model.removeprefix("anthropic/")
        # Pi accepts a model:effort suffix. Claude Code receives effort separately.
        if ":" in model_name and model_name.rsplit(":", 1)[1] in THINKING_LEVELS:
            model_name = model_name.rsplit(":", 1)[0]
        command = [
            self.binary, "-p", "--output-format", "stream-json", "--verbose",
            "--model", model_name, "--effort", thinking,
            "--tools", allowed, "--permission-mode", "plan", "--permission-prompts", "none",
            "--safe-mode", "--restricted", "--strict-mcp-config", "--disable-slash-commands", "--no-chrome",
            "--no-session-persistence", "--name", name, "--append-system-prompt", charter,
        ]
        for directory in dict.fromkeys(str(Path(item).parent) for item in attachments):
            command.extend(("--add-dir", directory))
        return command

    def run(self, *, prompt: str, attachments: Sequence[str | Path] = (), **kwargs: Any) -> PiResult:
        if attachments:
            prompt += "\n\nAttached image files. Use the Read tool to inspect each image as evidence:\n"
            prompt += "\n".join(str(Path(item)) for item in attachments)
        return super().run(prompt=prompt, attachments=attachments, **kwargs)

    @staticmethod
    def _consume_stdout(
        process: Any, log: Any, state: _StreamState,
        on_event: Callable[[dict[str, Any]], None] | None,
    ) -> None:
        stdout = process.stdout
        if stdout is None:
            state.error = "Claude Code produced no output"
            return
        found_result = False
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
                except (ValueError, TypeError):
                    continue
                if not isinstance(event, dict):
                    continue
                state.events += 1
                kind = event.get("type")
                if kind == "assistant":
                    message = event.get("message")
                    if isinstance(message, dict):
                        content = message.get("content")
                        if isinstance(content, list):
                            texts = [item.get("text") for item in content
                                     if isinstance(item, dict) and item.get("type") == "text"
                                     and isinstance(item.get("text"), str)]
                            if texts:
                                state.text = "\n".join(texts)
                            state.tool_steps += sum(isinstance(item, dict) and item.get("type") == "tool_use"
                                                    for item in content)
                elif kind == "result":
                    found_result = True
                    if isinstance(event.get("result"), str):
                        state.text = event["result"]
                    cost = event.get("total_cost_usd")
                    if isinstance(cost, (int, float)) and not isinstance(cost, bool) and cost >= 0:
                        state.cost = float(cost)
                    if event.get("is_error") or event.get("subtype") != "success":
                        state.error = (state.text or "Claude Code reported an error")[:4000]
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
        if not found_result and state.error is None:
            state.error = "Claude Code did not emit a result"


class RoutedRunner:
    """Send Anthropic sessions to Claude Code when configured; keep Pi for the rest."""

    def __init__(self, pi: PiRunner, claude: ClaudeRunner, *, anthropic_runner: str):
        self.pi = pi
        self.claude = claude
        self.anthropic_runner = anthropic_runner

    @property
    def binary(self) -> str:
        return self.pi.binary

    def environment(self) -> dict[str, str]:
        return self.pi.environment()

    def run(self, *, model: str, **kwargs: Any) -> PiResult:
        runner = self.claude if self.anthropic_runner == "claude" and model.startswith("anthropic/") else self.pi
        return runner.run(model=model, **kwargs)
