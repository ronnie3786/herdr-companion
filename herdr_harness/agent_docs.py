"""Offline access to the reference guides bundled with Herdr Companion."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import TextIO

AWARENESS_MARKER = "<!-- herdr-companion-awareness:v1 -->"
RESTRICTED_AGENT_PROFILES = frozenset({
    "contextual-question-v1",
    "pr-review-question-v1",
    "response-brief-v1",
    "smart-rename-v1",
    "issue-report-draft-v1",
})

TOPICS = {
    "overview": ("Herdr, Pi, Companion, surfaces, limits, and upgrades", "overview.md"),
    "control": ("Capability-driven discovery and typed app/resource control", "control.md"),
    "first-mate": ("First Mate roles, typed self-management, and human gates", "first-mate.md"),
    "api": ("Authenticated Companion API families and transport rules", "api.md"),
}


def docs_root() -> Path:
    """Resolve installed resources first and the source tree second."""
    package = Path(__file__).resolve().parent
    candidates = (
        package / "_bundled" / "pi-semantic-bridge" / "agent-docs",
        package.parent / "pi-semantic-bridge" / "agent-docs",
    )
    for candidate in candidates:
        if all((candidate / filename).is_file() for _, filename in TOPICS.values()):
            return candidate.resolve()
    raise FileNotFoundError("Herdr agent reference guides are unavailable; reinstall the companion package")


def topic_path(topic: str) -> Path:
    """Return one closed-allowlist guide path; topic names are never paths."""
    entry = TOPICS.get(topic)
    if entry is None:
        allowed = ", ".join(TOPICS)
        raise ValueError(f"unknown topic {topic!r}; choose one of: {allowed}")
    path = docs_root() / entry[1]
    if not path.is_file():
        raise FileNotFoundError(f"Herdr agent reference topic {topic!r} is unavailable; reinstall the companion package")
    return path


def agent_run_bootstrap(environment: dict[str, str], profile: str | None) -> str | None:
    """Build compact headless identity without depending on Pi package discovery."""
    if profile in RESTRICTED_AGENT_PROFILES or not environment.get("HERDR_AGENT_RUN_ID", "").strip():
        return None
    try:
        root = docs_root()
    except FileNotFoundError:
        return None
    if profile == "hud-chat-v1":
        surface = (
            "This is an independent saved HUD chat outside terminal workspaces. It may be viewed "
            "through Companion native clients; do not describe it as a pane or claim to know the "
            "frontmost client or data host."
        )
    else:
        mode = environment.get("HERDR_AGENT_RUN_MODE", "").strip().upper()
        mode_text = f" Its {mode} charter remains authoritative." if mode in {"ASK", "ACT"} else " Its supplied ASK/ACT charter remains authoritative."
        surface = "This is a Companion agent run, not proof of a terminal pane or visible client." + mode_text
    return (
        f"{AWARENESS_MARKER}\n"
        f"You are a Pi agent running in Herdr Companion. {surface} Herdr Companion, upstream "
        "Herdr terminal, and Pi are separate components; clients and installed versions can differ.\n\n"
        "When the user asks what app this is, what Companion can do, which surfaces exist, or how "
        f"Pi/Herdr/Companion relate, read {root / 'overview.md'} (or run `herdr-docs read overview`). "
        "For app capability or management questions, follow its pointers, read "
        f"{root / 'first-mate.md'} when First Mate is relevant, then run the applicable installed "
        "CLI `--help` and live capability/action catalogs instead of inventing support. Do not "
        "eagerly load guide bodies for unrelated work.\n\n"
        "Discovery never authorizes action. Preserve the user’s current scope, human checkpoints, "
        "project trust, ASK/no-tool constraints, and existing charter. Never put credentials in "
        "argv or output. Do not infer machine identity, current UI focus, or available operations "
        "from labels or from this package being installed."
    )


def append_agent_run_bootstrap(charter: str, bootstrap: str | None) -> str:
    if not bootstrap or AWARENESS_MARKER in charter:
        return charter
    return f"{charter}\n\n{bootstrap}"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="herdr-docs",
        description="Read Herdr Companion agent references offline (no configuration or network required).",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="List allowlisted topics as JSON")
    for name, help_text in (("read", "Print one Markdown topic"), ("path", "Print its absolute path")):
        command = commands.add_parser(name, help=help_text)
        command.add_argument("topic", help="Topic name from `herdr-docs list` (not a file path)")
    return parser


def main(argv: list[str] | None = None, *, stdout: TextIO | None = None, stderr: TextIO | None = None) -> int:
    stdout = stdout or sys.stdout
    stderr = stderr or sys.stderr
    try:
        args = _parser().parse_args(argv)
        if args.command == "list":
            root = docs_root()
            result = [
                {"topic": topic, "summary": summary, "path": str(root / filename)}
                for topic, (summary, filename) in TOPICS.items()
            ]
            print(json.dumps({"topics": result}, ensure_ascii=False), file=stdout)
        elif args.command == "path":
            print(topic_path(args.topic), file=stdout)
        else:
            print(topic_path(args.topic).read_text(encoding="utf-8"), end="", file=stdout)
        return 0
    except (FileNotFoundError, OSError, UnicodeError, ValueError) as exc:
        print(f"herdr-docs: {exc}", file=stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
