"""Environment-driven configuration for the Code Factory daemon.

Every value is read from the ``HERDR_CODE_FACTORY_*`` environment variables that
``herdr_harness.config`` derives from the ``[code_factory]`` TOML table. Defaults are
rooted at ``HERDR_STATE_DIR`` so a freshly configured machine needs nothing but a
repository and a checkout.
"""

from __future__ import annotations

import os
import re
import sys
import urllib.parse
from dataclasses import dataclass, fields
from pathlib import Path
from typing import Mapping

from .errors import CodeFactoryError

ENV_PREFIX = "HERDR_CODE_FACTORY_"
REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
MODEL_PATTERN = re.compile(r"^[A-Za-z0-9._/:-]{1,200}$")
LABEL_PATTERN = re.compile(r"^[^\x00-\x1f\x7f,]{1,50}$")
AUTHOR_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\[\]-]{0,63}$")
BRANCH_PATTERN = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
THINKING_LEVELS = ("off", "minimal", "low", "medium", "high", "xhigh", "max")
RELEASE_CHANNELS = ("stable", "preview")
TRUE_WORDS = frozenset({"true", "1", "yes"})
FALSE_WORDS = frozenset({"false", "0", "no"})
DEFAULT_STATE_DIR = "~/.local/share/herdr-companion"

INTEGER_RANGES: dict[str, tuple[int, int]] = {
    "poll_seconds": (10, 3600),
    "max_parallel_issues": (1, 8),
    "max_review_rounds": (0, 10),
    "max_ci_failures": (0, 10),
    "session_timeout_seconds": (60, 86400),
    "reviser_session_timeout_seconds": (60, 86400),
    "max_rebase_attempts": (0, 10),
    "max_transient_retries": (0, 5),
    "verify_wait_seconds": (60, 86400),
    "dashboard_port": (1, 65535),
}


def _invalid(message: str) -> CodeFactoryError:
    return CodeFactoryError(message, code="invalid_settings")


def _field(key: str) -> str:
    """The ``[code_factory]`` field name for an environment suffix (for error messages)."""
    return "code_factory." + ("pi_binary" if key == "PI_BIN" else key.lower())


def _expand_path(value: str, home: str | None) -> Path:
    """Expand ``~`` against the configured ``HOME`` (not the process user) and make absolute.

    Symlinks are deliberately not resolved so configured paths round-trip unchanged.
    """
    text = value.strip()
    if text == "~" or text.startswith("~/"):
        base = home or str(Path.home())
        text = base.rstrip("/") + text[1:]
    path = Path(text).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    return Path(os.path.normpath(str(path)))


def _string(environ: Mapping[str, str], key: str, default: str, *, maximum: int = 4096) -> str:
    raw = environ.get(ENV_PREFIX + key)
    if raw is None:
        return default
    value = raw.strip()
    if not value:
        return default
    if len(value) > maximum or any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise _invalid(f"{_field(key)} must be printable and at most {maximum} characters")
    return value


def _integer(environ: Mapping[str, str], key: str, default: int) -> int:
    raw = environ.get(ENV_PREFIX + key)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw.strip(), 10)
    except ValueError as exc:
        raise _invalid(f"{_field(key)} must be an integer") from exc
    low, high = INTEGER_RANGES[key.lower()]
    if not low <= value <= high:
        raise _invalid(f"{_field(key)} must be between {low} and {high}")
    return value


def _boolean(environ: Mapping[str, str], key: str, default: bool) -> bool:
    raw = environ.get(ENV_PREFIX + key)
    if raw is None or not raw.strip():
        return default
    value = raw.strip().lower()
    if value in TRUE_WORDS:
        return True
    if value in FALSE_WORDS:
        return False
    raise _invalid(f"{_field(key)} must be one of true/false/1/0/yes/no")


def _choice(environ: Mapping[str, str], key: str, default: str, choices: tuple[str, ...]) -> str:
    value = _string(environ, key, default).lower()
    if value not in choices:
        raise _invalid(f"{_field(key)} must be one of {', '.join(choices)}")
    return value


def _model(environ: Mapping[str, str], key: str, default: str) -> str:
    value = _string(environ, key, default, maximum=200)
    if not MODEL_PATTERN.match(value):
        raise _invalid(f"{_field(key)} is not a valid model identifier")
    return value


def _dashboard_link(environ: Mapping[str, str]) -> str:
    """An optional private dashboard URL used only in operator notifications."""
    value = _string(environ, "DASHBOARD_LINK", "", maximum=2048)
    if not value:
        return ""
    try:
        parsed = urllib.parse.urlsplit(value)
        valid = parsed.scheme in {"http", "https"} and bool(parsed.hostname) and not (
            parsed.username or parsed.password or parsed.query or parsed.fragment
        )
    except ValueError:
        valid = False
    if not valid:
        raise _invalid("code_factory.dashboard_link must be an HTTP(S) URL without credentials, query, or fragment")
    return value.rstrip("/") + "/"


def _authors(environ: Mapping[str, str]) -> tuple[str, ...]:
    raw = environ.get(ENV_PREFIX + "ALLOWED_AUTHORS") or ""
    if len(raw) > 4096:
        raise _invalid("code_factory.allowed_authors is too long")
    result: list[str] = []
    for item in raw.split(","):
        login = item.strip()
        if not login:
            continue
        if not AUTHOR_PATTERN.match(login):
            raise _invalid(f"code_factory.allowed_authors contains an invalid GitHub login: {login[:64]!r}")
        if login.lower() not in {existing.lower() for existing in result}:
            result.append(login)
    return tuple(result)


def _repository(environ: Mapping[str, str]) -> str:
    raw = environ.get(ENV_PREFIX + "REPOSITORY") or ""
    value = raw.strip()
    if not value:
        raise _invalid("code_factory.repository is not configured; set [code_factory] repository to OWNER/NAME")
    if len(value) > 200 or not REPOSITORY_PATTERN.match(value) or ".." in value:
        raise _invalid("code_factory.repository must look like OWNER/NAME")
    return value


def _branch(environ: Mapping[str, str], key: str, default: str) -> str:
    value = _string(environ, key, default, maximum=200)
    if not BRANCH_PATTERN.match(value) or ".." in value or value.startswith("-") or value.endswith("/"):
        raise _invalid(f"{_field(key)} is not a valid branch name")
    return value


@dataclass(frozen=True)
class CodeFactorySettings:
    """Validated daemon configuration; construct through :meth:`from_environ`."""

    repository: str
    checkout: Path
    worktree_root: Path
    state_path: Path
    runs_root: Path
    release_output_root: Path
    poll_seconds: int = 60
    trigger_label: str = "herdr-autofix"
    allowed_authors: tuple[str, ...] = ()
    planner_model: str = "openai-codex/gpt-6-astra"
    planner_thinking: str = "xhigh"
    implementer_model: str = "ollama-cloud/deepseek-v4.1-flash:cloud"
    implementer_thinking: str = "max"
    max_parallel_issues: int = 2
    max_review_rounds: int = 3
    max_ci_failures: int = 3
    session_timeout_seconds: int = 3600
    reviser_session_timeout_seconds: int = 7200
    max_rebase_attempts: int = 2
    max_transient_retries: int = 2
    verify_wait_seconds: int = 3600
    dashboard_host: str = "tailscale"
    dashboard_port: int = 9097
    dashboard_token: str = ""
    dashboard_link: str = ""
    release_enabled: bool = True
    release_channel: str = "preview"
    comment_on_issues: bool = True
    base_branch: str = "main"
    pi_binary: str = "pi"
    python: str = sys.executable
    config_path: str | None = None
    machine: str | None = None

    @classmethod
    def from_environ(cls, environ: Mapping[str, str]) -> "CodeFactorySettings":
        """Build settings from ``HERDR_*`` variables, raising ``CodeFactoryError`` on bad values.

        A missing ``checkout`` is *not* an error here (the CLI reports it with
        :meth:`validate_checkout`), so ``status``-style commands work without one.
        """
        home = environ.get("HOME") or None
        state_dir = _expand_path(environ.get("HERDR_STATE_DIR") or DEFAULT_STATE_DIR, home)
        factory_dir = state_dir / "code-factory"

        def path_value(key: str, default: Path) -> Path:
            raw = environ.get(ENV_PREFIX + key)
            if raw is None or not raw.strip():
                return default
            if "\x00" in raw or len(raw) > 4096:
                raise _invalid(f"{_field(key)} is not a valid path")
            return _expand_path(raw, home)

        checkout_raw = environ.get(ENV_PREFIX + "CHECKOUT") or ""
        checkout = _expand_path(checkout_raw, home) if checkout_raw.strip() else Path("")
        planner_thinking = _choice(environ, "PLANNER_THINKING", cls.planner_thinking, THINKING_LEVELS)
        implementer_thinking = _choice(environ, "IMPLEMENTER_THINKING", cls.implementer_thinking, THINKING_LEVELS)
        trigger_label = _string(environ, "TRIGGER_LABEL", cls.trigger_label, maximum=50)
        if not LABEL_PATTERN.match(trigger_label):
            raise _invalid("code_factory.trigger_label must be 1-50 printable characters without commas")
        settings = cls(
            repository=_repository(environ),
            checkout=checkout,
            worktree_root=path_value("WORKTREE_ROOT", factory_dir / "worktrees"),
            state_path=path_value("STATE_PATH", factory_dir / "code-factory.sqlite3"),
            runs_root=path_value("RUNS_ROOT", factory_dir / "runs"),
            release_output_root=path_value("RELEASE_OUTPUT_ROOT", state_dir / "releases"),
            poll_seconds=_integer(environ, "POLL_SECONDS", cls.poll_seconds),
            trigger_label=trigger_label,
            allowed_authors=_authors(environ),
            planner_model=_model(environ, "PLANNER_MODEL", cls.planner_model),
            planner_thinking=planner_thinking,
            implementer_model=_model(environ, "IMPLEMENTER_MODEL", cls.implementer_model),
            implementer_thinking=implementer_thinking,
            max_parallel_issues=_integer(environ, "MAX_PARALLEL_ISSUES", cls.max_parallel_issues),
            max_review_rounds=_integer(environ, "MAX_REVIEW_ROUNDS", cls.max_review_rounds),
            max_ci_failures=_integer(environ, "MAX_CI_FAILURES", cls.max_ci_failures),
            session_timeout_seconds=_integer(environ, "SESSION_TIMEOUT_SECONDS", cls.session_timeout_seconds),
            reviser_session_timeout_seconds=_integer(
                environ, "REVISER_SESSION_TIMEOUT_SECONDS", cls.reviser_session_timeout_seconds
            ),
            max_rebase_attempts=_integer(environ, "MAX_REBASE_ATTEMPTS", cls.max_rebase_attempts),
            max_transient_retries=_integer(environ, "MAX_TRANSIENT_RETRIES", cls.max_transient_retries),
            verify_wait_seconds=_integer(environ, "VERIFY_WAIT_SECONDS", cls.verify_wait_seconds),
            dashboard_host=_string(environ, "DASHBOARD_HOST", cls.dashboard_host, maximum=253),
            dashboard_port=_integer(environ, "DASHBOARD_PORT", cls.dashboard_port),
            dashboard_token=_string(environ, "DASHBOARD_TOKEN", cls.dashboard_token, maximum=4096),
            dashboard_link=_dashboard_link(environ),
            release_enabled=_boolean(environ, "RELEASE_ENABLED", cls.release_enabled),
            release_channel=_choice(environ, "RELEASE_CHANNEL", cls.release_channel, RELEASE_CHANNELS),
            comment_on_issues=_boolean(environ, "COMMENT_ON_ISSUES", cls.comment_on_issues),
            base_branch=_branch(environ, "BASE_BRANCH", cls.base_branch),
            pi_binary=_string(environ, "PI_BIN", cls.pi_binary),
            python=_string(environ, "PYTHON", cls.python),
            config_path=(environ.get("HERDR_CONFIG") or "").strip() or None,
            machine=(environ.get("HERDR_MACHINE") or "").strip() or None,
        )
        return settings

    def session_timeout_for(self, role: str) -> int:
        """The timeout for one Pi role; long-form revision and rebase sessions get their own budget.

        Revision and conflict-resolution sessions legitimately run for tens of minutes
        (deep, multi-file fixes), while planners and reviewers finish in a few. One global
        timeout either starved them or gave every other role hours of slack.
        """
        if role in ("reviser", "rebase"):
            return self.reviser_session_timeout_seconds
        return self.session_timeout_seconds

    @property
    def checkout_configured(self) -> bool:
        """True when ``HERDR_CODE_FACTORY_CHECKOUT`` was provided."""
        return str(self.checkout) not in ("", ".")

    def validate_checkout(self) -> Path:
        """Return the checkout path, raising ``CodeFactoryError`` when missing or not a git repository."""
        if not self.checkout_configured:
            raise _invalid(
                "code_factory.checkout is not configured; set it to a git checkout whose "
                f"origin is {self.repository}"
            )
        if not self.checkout.is_dir():
            raise _invalid(f"code_factory.checkout does not exist: {self.checkout}")
        if not (self.checkout / ".git").exists():
            raise _invalid(f"code_factory.checkout is not a git repository: {self.checkout}")
        return self.checkout

    def public_summary(self) -> dict[str, object]:
        """Settings safe to expose on the dashboard (no token, no local paths)."""
        return {
            "repository": self.repository,
            "trigger_label": self.trigger_label,
            "planner_model": self.planner_model,
            "planner_thinking": self.planner_thinking,
            "implementer_model": self.implementer_model,
            "implementer_thinking": self.implementer_thinking,
            "release_enabled": self.release_enabled,
            "release_channel": self.release_channel,
            "max_review_rounds": self.max_review_rounds,
            "max_ci_failures": self.max_ci_failures,
            "reviser_session_timeout_seconds": self.reviser_session_timeout_seconds,
            "max_rebase_attempts": self.max_rebase_attempts,
            "max_parallel_issues": self.max_parallel_issues,
            "poll_seconds": self.poll_seconds,
            "base_branch": self.base_branch,
        }

    def as_dict(self) -> dict[str, object]:
        """Every field as a JSON-friendly dict (paths as strings, token redacted)."""
        result: dict[str, object] = {}
        for field in fields(self):
            value = getattr(self, field.name)
            if isinstance(value, Path):
                value = str(value)
            elif isinstance(value, tuple):
                value = list(value)
            if field.name == "dashboard_token":
                value = "***" if value else ""
            result[field.name] = value
        return result
