"""SQLite ledger for the Code Factory: issues, events, sessions, releases and daemon state.

All public methods return plain dicts with camelCase keys so the dashboard and the
pipeline share one JSON-ready shape (see ``snapshot()``). Writes are serialized by a
re-entrant lock; the connection is opened with ``check_same_thread=False`` and WAL
journaling so the poller thread, the worker pool and the dashboard can share it.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping

from .errors import CodeFactoryError

SCHEMA_VERSION = 1

STATUSES = ("active", "blocked", "failed", "done", "skipped")
STAGE_ORDER = [
    "intake", "worktree", "plan", "implement", "pull_request", "verify",
    "review", "revise", "merge", "release", "done",
]
STAGE_LABELS = {
    "intake": "Picked up",
    "worktree": "Preparing worktree",
    "plan": "Planning (Astra)",
    "implement": "Implementing (DeepSeek)",
    "pull_request": "Opening PR",
    "verify": "Waiting for CI",
    "review": "Reviewing (Astra)",
    "revise": "Revising (DeepSeek)",
    "merge": "Merging",
    "release": "Releasing",
    "done": "Done",
}
EVENT_KINDS = ("info", "warning", "error", "success")
KINDS = ("bug", "feature")

MAX_TEXT_CHARS = 200_000
MAX_JSON_BYTES = 2 * 1024 * 1024

ISSUE_COLUMNS = (
    "number", "title", "kind", "author", "url", "labels_json", "status", "stage",
    "attempts", "review_round", "ci_failures", "ci_rerun_requested", "branch", "worktree_path",
    "worktree_cleaned", "rebase_attempts", "failure_retries",
    "pr_number", "pr_url", "head_sha", "ci_status", "merge_sha", "release_tag",
    "release_version", "release_url", "error", "blocked_reason", "plan_summary",
    "plan_json", "created_at", "updated_at", "claimed_at", "finished_at",
)
ISSUE_INTEGER_COLUMNS = frozenset({
    "number", "attempts", "review_round", "ci_failures", "pr_number", "rebase_attempts", "failure_retries",
})
RELEASE_COLUMNS = (
    "tag", "version", "channel", "status", "source_sha", "url", "notes_path",
    "output_dir", "issues_json", "error", "started_at", "finished_at",
)
SESSION_COLUMNS = (
    "id", "issue_number", "role", "model", "thinking", "session_file", "log_path",
    "started_at", "finished_at", "exit_code", "cost_usd", "summary",
)
DAEMON_KEYS = ("started_at", "last_poll_at", "dashboard_url")

SCHEMA = """
CREATE TABLE IF NOT EXISTS cf_schema(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS issues(
 number INTEGER PRIMARY KEY, title TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT 'bug',
 author TEXT, url TEXT, labels_json TEXT NOT NULL DEFAULT '[]',
 status TEXT NOT NULL DEFAULT 'active', stage TEXT NOT NULL DEFAULT 'intake',
 attempts INTEGER NOT NULL DEFAULT 0, review_round INTEGER NOT NULL DEFAULT 0,
 ci_failures INTEGER NOT NULL DEFAULT 0, ci_rerun_requested TEXT,
 branch TEXT, worktree_path TEXT, worktree_cleaned INTEGER NOT NULL DEFAULT 0,
 rebase_attempts INTEGER NOT NULL DEFAULT 0, failure_retries INTEGER NOT NULL DEFAULT 0,
 pr_number INTEGER, pr_url TEXT, head_sha TEXT, ci_status TEXT, merge_sha TEXT,
 release_tag TEXT, release_version TEXT, release_url TEXT, error TEXT, blocked_reason TEXT,
 plan_summary TEXT, plan_json TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 claimed_at TEXT, finished_at TEXT);
CREATE TABLE IF NOT EXISTS events(
 id INTEGER PRIMARY KEY AUTOINCREMENT, issue_number INTEGER NOT NULL, at TEXT NOT NULL,
 stage TEXT NOT NULL, kind TEXT NOT NULL, message TEXT NOT NULL, detail_json TEXT);
CREATE TABLE IF NOT EXISTS sessions(
 id TEXT PRIMARY KEY, issue_number INTEGER, role TEXT NOT NULL, model TEXT NOT NULL,
 thinking TEXT NOT NULL, session_file TEXT, log_path TEXT, started_at TEXT NOT NULL,
 finished_at TEXT, exit_code INTEGER, cost_usd REAL, summary TEXT);
CREATE TABLE IF NOT EXISTS releases(
 tag TEXT PRIMARY KEY, version TEXT, channel TEXT, status TEXT NOT NULL DEFAULT 'pending',
 source_sha TEXT, url TEXT, notes_path TEXT, output_dir TEXT, issues_json TEXT NOT NULL DEFAULT '[]',
 error TEXT, started_at TEXT NOT NULL, finished_at TEXT);
CREATE TABLE IF NOT EXISTS daemon(key TEXT PRIMARY KEY, value TEXT);
CREATE INDEX IF NOT EXISTS events_issue ON events(issue_number, id);
CREATE INDEX IF NOT EXISTS sessions_issue ON sessions(issue_number, started_at);
CREATE INDEX IF NOT EXISTS issues_status ON issues(status, stage);
"""

_CAMEL_BOUNDARY = re.compile(r"(?<!^)(?=[A-Z])")


def utc_now() -> str:
    """UTC timestamp with a trailing ``Z`` (second precision keeps SQL ordering stable)."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _camel(name: str) -> str:
    head, *rest = name.split("_")
    return head + "".join(part.capitalize() for part in rest)


def _snake(name: str) -> str:
    if "_" in name:
        return name.lower()
    return _CAMEL_BOUNDARY.sub("_", name).lower()


def _dump_json(value: Any) -> str:
    text = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    if len(text.encode("utf-8")) > MAX_JSON_BYTES:
        raise CodeFactoryError("JSON payload exceeds 2 MiB", code="invalid_request")
    return text


def _load_json(text: Any, default: Any) -> Any:
    if not isinstance(text, str) or not text:
        return default
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return default


def _invalid(message: str) -> CodeFactoryError:
    return CodeFactoryError(message, code="invalid_request")


def _check_number(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise _invalid("issue number must be a positive integer")
    return value


def _check_text(value: Any, name: str, *, maximum: int = MAX_TEXT_CHARS, optional: bool = True) -> str | None:
    if value is None:
        if optional:
            return None
        raise _invalid(f"{name} is required")
    if not isinstance(value, str) or len(value) > maximum or "\x00" in value:
        raise _invalid(f"{name} must be a string of at most {maximum} characters")
    if not optional and not value.strip():
        raise _invalid(f"{name} must not be empty")
    return value


def _check_optional_int(value: Any, name: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise _invalid(f"{name} must be a non-negative integer")
    return value


def _check_labels(value: Any) -> str:
    if value is None:
        return "[]"
    if not isinstance(value, (list, tuple)) or len(value) > 100:
        raise _invalid("labels must be a list of at most 100 strings")
    labels: list[str] = []
    for item in value:
        text = _check_text(item, "label", maximum=100, optional=False)
        assert text is not None
        labels.append(text)
    return _dump_json(labels)


class CodeFactoryStore:
    """Durable, thread-safe ledger with one shared SQLite connection."""

    def __init__(self, path: str | Path, *, clock: Callable[[], str] | None = None):
        self._clock = clock or utc_now
        self.path: Path | None = Path(path).expanduser() if str(path) != ":memory:" else None
        if self.path is not None:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
            os.close(descriptor)
            os.chmod(self.path, 0o600)
        self._lock = threading.RLock()
        self._db = sqlite3.connect(
            str(self.path) if self.path is not None else ":memory:",
            timeout=15,
            isolation_level=None,
            check_same_thread=False,
        )
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA busy_timeout=15000")
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA synchronous=NORMAL")
        self._db.executescript(SCHEMA)
        self._migrate_issue_columns()
        self._db.execute("INSERT OR IGNORE INTO cf_schema VALUES(?, ?)", (SCHEMA_VERSION, self._clock()))

    def _migrate_issue_columns(self) -> None:
        """Add issue fields introduced after the original ledger schema."""
        columns = {str(row["name"]) for row in self._db.execute("PRAGMA table_info(issues)")}
        migrations = (
            ("ci_failures", "ALTER TABLE issues ADD COLUMN ci_failures INTEGER NOT NULL DEFAULT 0"),
            ("ci_rerun_requested", "ALTER TABLE issues ADD COLUMN ci_rerun_requested TEXT"),
            ("rebase_attempts", "ALTER TABLE issues ADD COLUMN rebase_attempts INTEGER NOT NULL DEFAULT 0"),
            ("failure_retries", "ALTER TABLE issues ADD COLUMN failure_retries INTEGER NOT NULL DEFAULT 0"),
        )
        for name, statement in migrations:
            if name not in columns:
                self._db.execute(statement)

    # -- infrastructure -----------------------------------------------------------

    def close(self) -> None:
        with self._lock:
            self._db.close()

    @property
    def schema_version(self) -> int:
        with self._lock:
            row = self._db.execute("SELECT MAX(version) FROM cf_schema").fetchone()
            return int(row[0] or 0)

    @contextmanager
    def _transaction(self) -> Iterator[None]:
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                yield
                self._db.execute("COMMIT")
            except BaseException:
                self._db.execute("ROLLBACK")
                raise

    def _now(self) -> str:
        return self._clock()

    # -- record projections -------------------------------------------------------

    @staticmethod
    def _issue_record(row: sqlite3.Row) -> dict[str, Any]:
        data = dict(row)
        stage = str(data.get("stage") or "intake")
        record: dict[str, Any] = {}
        for column in ISSUE_COLUMNS:
            if column == "labels_json":
                record["labels"] = _load_json(data.get(column), [])
            elif column == "plan_json":
                record["planJson"] = _load_json(data.get(column), None)
            elif column == "worktree_cleaned":
                record["worktreeCleaned"] = bool(data.get(column))
            else:
                record[_camel(column)] = data.get(column)
        record["stageLabel"] = STAGE_LABELS.get(stage, stage)
        record["stageIndex"] = STAGE_ORDER.index(stage) if stage in STAGE_ORDER else -1
        return record

    @staticmethod
    def _event_record(row: sqlite3.Row) -> dict[str, Any]:
        data = dict(row)
        return {
            "id": data["id"],
            "issueNumber": data["issue_number"],
            "at": data["at"],
            "stage": data["stage"],
            "kind": data["kind"],
            "message": data["message"],
            "detail": _load_json(data.get("detail_json"), None),
        }

    @staticmethod
    def _session_record(row: sqlite3.Row) -> dict[str, Any]:
        data = dict(row)
        record = {_camel(column): data.get(column) for column in SESSION_COLUMNS}
        record["costUSD"] = record.pop("costUsd")
        return record

    @staticmethod
    def _release_record(row: sqlite3.Row) -> dict[str, Any]:
        data = dict(row)
        record: dict[str, Any] = {}
        for column in RELEASE_COLUMNS:
            if column == "issues_json":
                record["issueNumbers"] = _load_json(data.get(column), [])
            else:
                record[_camel(column)] = data.get(column)
        return record

    # -- issues -------------------------------------------------------------------

    def _normalize_issue_fields(self, fields: Mapping[str, Any]) -> dict[str, Any]:
        """Map camelCase/snake_case field names to validated column values."""
        columns: dict[str, Any] = {}
        for name, value in fields.items():
            if name in ("labels", "labels_json"):
                columns["labels_json"] = _check_labels(value)
                continue
            if name in ("planJson", "plan_json"):
                if value is None:
                    columns["plan_json"] = None
                elif isinstance(value, dict):
                    columns["plan_json"] = _dump_json(value)
                else:
                    raise _invalid("planJson must be an object")
                continue
            column = _snake(name)
            if column not in ISSUE_COLUMNS or column == "number":
                raise _invalid(f"unknown issue field: {name}")
            if column == "status":
                if value not in STATUSES:
                    raise _invalid(f"status must be one of {', '.join(STATUSES)}")
            elif column == "stage":
                if value not in STAGE_ORDER:
                    raise _invalid(f"stage must be one of {', '.join(STAGE_ORDER)}")
            elif column == "kind":
                if value not in KINDS:
                    raise _invalid("kind must be bug or feature")
            elif column == "worktree_cleaned":
                if isinstance(value, bool) or value in (0, 1):
                    value = 1 if value else 0
                else:
                    raise _invalid("worktreeCleaned must be a boolean")
            elif column in ISSUE_INTEGER_COLUMNS:
                value = _check_optional_int(value, name)
            else:
                value = _check_text(value, name)
            columns[column] = value
        return columns

    def upsert_issue(self, record: Mapping[str, Any]) -> dict[str, Any]:
        """Insert a new issue or update the provided fields of an existing one."""
        if not isinstance(record, Mapping):
            raise _invalid("issue record must be a mapping")
        number = _check_number(record.get("number"))
        columns = self._normalize_issue_fields({k: v for k, v in record.items() if k != "number"})
        with self._transaction():
            now = self._now()
            exists = self._db.execute("SELECT 1 FROM issues WHERE number=?", (number,)).fetchone()
            if exists:
                if columns:
                    columns["updated_at"] = now
                    assignments = ", ".join(f"{name}=?" for name in columns)
                    self._db.execute(f"UPDATE issues SET {assignments} WHERE number=?", (*columns.values(), number))
            else:
                columns.setdefault("status", "active")
                columns.setdefault("stage", "intake")
                columns.setdefault("kind", "bug")
                columns.setdefault("title", "")
                columns["created_at"] = now
                columns["updated_at"] = now
                names = ", ".join(("number", *columns))
                marks = ", ".join("?" for _ in range(len(columns) + 1))
                self._db.execute(f"INSERT INTO issues({names}) VALUES({marks})", (number, *columns.values()))
            result = self._fetch_issue(number)
        assert result is not None
        return result

    def _fetch_issue(self, number: int) -> dict[str, Any] | None:
        row = self._db.execute("SELECT * FROM issues WHERE number=?", (number,)).fetchone()
        return self._issue_record(row) if row is not None else None

    def get_issue(self, number: int) -> dict[str, Any] | None:
        """Return one issue (including ``planJson``) or ``None`` when unknown."""
        number = _check_number(number)
        with self._lock:
            return self._fetch_issue(number)

    def list_issues(self, status: str | None = None) -> list[dict[str, Any]]:
        """Issues newest-updated first, optionally filtered by status."""
        if status is not None and status not in STATUSES:
            raise _invalid(f"status must be one of {', '.join(STATUSES)}")
        with self._lock:
            if status is None:
                rows = self._db.execute("SELECT * FROM issues ORDER BY updated_at DESC, number DESC").fetchall()
            else:
                rows = self._db.execute(
                    "SELECT * FROM issues WHERE status=? ORDER BY updated_at DESC, number DESC", (status,)
                ).fetchall()
            return [self._issue_record(row) for row in rows]

    def update_issue(self, number: int, **fields: Any) -> dict[str, Any]:
        """Update the given camelCase or snake_case fields and bump ``updatedAt``."""
        number = _check_number(number)
        columns = self._normalize_issue_fields(fields)
        with self._transaction():
            if self._db.execute("SELECT 1 FROM issues WHERE number=?", (number,)).fetchone() is None:
                raise CodeFactoryError(f"issue #{number} is not tracked", code="not_found")
            columns["updated_at"] = self._now()
            assignments = ", ".join(f"{name}=?" for name in columns)
            self._db.execute(f"UPDATE issues SET {assignments} WHERE number=?", (*columns.values(), number))
            result = self._fetch_issue(number)
        assert result is not None
        return result

    # -- events -------------------------------------------------------------------

    def add_event(
        self,
        number: int,
        stage: str,
        kind: str,
        message: str,
        detail: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Append a log line for an issue; also bumps the issue's ``updatedAt``."""
        number = _check_number(number)
        if stage not in STAGE_ORDER:
            raise _invalid(f"stage must be one of {', '.join(STAGE_ORDER)}")
        if kind not in EVENT_KINDS:
            raise _invalid(f"event kind must be one of {', '.join(EVENT_KINDS)}")
        text = _check_text(message, "message", maximum=20_000, optional=False)
        if detail is not None and not isinstance(detail, Mapping):
            raise _invalid("event detail must be an object")
        detail_json = _dump_json(dict(detail)) if detail is not None else None
        with self._transaction():
            now = self._now()
            cursor = self._db.execute(
                "INSERT INTO events(issue_number, at, stage, kind, message, detail_json) VALUES(?,?,?,?,?,?)",
                (number, now, stage, kind, text, detail_json),
            )
            self._db.execute("UPDATE issues SET updated_at=? WHERE number=?", (now, number))
            row = self._db.execute("SELECT * FROM events WHERE id=?", (cursor.lastrowid,)).fetchone()
        return self._event_record(row)

    def list_events(self, number: int, limit: int = 200) -> list[dict[str, Any]]:
        """The most recent ``limit`` events for an issue, newest first."""
        number = _check_number(number)
        limit = max(1, min(int(limit), 5000))
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM events WHERE issue_number=? ORDER BY id DESC LIMIT ?", (number, limit)
            ).fetchall()
            return [self._event_record(row) for row in rows]

    # -- sessions -----------------------------------------------------------------

    def add_session(
        self,
        id: str,
        issue_number: int | None,
        role: str,
        model: str,
        thinking: str,
        session_file: str | None = None,
        log_path: str | None = None,
        started_at: str | None = None,
    ) -> dict[str, Any]:
        """Record the start of a Pi session (``issue_number`` may be ``None`` for releases)."""
        session_id = _check_text(id, "session id", maximum=128, optional=False)
        if issue_number is not None:
            issue_number = _check_number(issue_number)
        role_text = _check_text(role, "role", maximum=64, optional=False)
        model_text = _check_text(model, "model", maximum=200, optional=False)
        thinking_text = _check_text(thinking, "thinking", maximum=32, optional=False)
        with self._transaction():
            self._db.execute(
                "INSERT OR REPLACE INTO sessions(id, issue_number, role, model, thinking, session_file, "
                "log_path, started_at) VALUES(?,?,?,?,?,?,?,?)",
                (
                    session_id, issue_number, role_text, model_text, thinking_text,
                    _check_text(session_file, "session_file"), _check_text(log_path, "log_path"),
                    started_at or self._now(),
                ),
            )
            row = self._db.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
        return self._session_record(row)

    def finish_session(
        self,
        id: str,
        exit_code: int | None,
        cost_usd: float | None,
        summary: str | None,
        *,
        session_file: str | None = None,
    ) -> dict[str, Any]:
        """Mark a session finished; ``session_file`` may be filled in once Pi wrote it."""
        session_id = _check_text(id, "session id", maximum=128, optional=False)
        if exit_code is not None and (isinstance(exit_code, bool) or not isinstance(exit_code, int)):
            raise _invalid("exit_code must be an integer")
        if cost_usd is not None and (isinstance(cost_usd, bool) or not isinstance(cost_usd, (int, float))):
            raise _invalid("cost_usd must be a number")
        summary_text = _check_text(summary, "summary", maximum=20_000)
        with self._transaction():
            if self._db.execute("SELECT 1 FROM sessions WHERE id=?", (session_id,)).fetchone() is None:
                raise CodeFactoryError(f"session {session_id} is unknown", code="not_found")
            self._db.execute(
                "UPDATE sessions SET finished_at=?, exit_code=?, cost_usd=?, summary=?, "
                "session_file=COALESCE(?, session_file) WHERE id=?",
                (self._now(), exit_code, float(cost_usd) if cost_usd is not None else None,
                 summary_text, _check_text(session_file, "session_file"), session_id),
            )
            row = self._db.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
        return self._session_record(row)

    def list_sessions(self, number: int | None) -> list[dict[str, Any]]:
        """Sessions for an issue in start order (``None`` lists release sessions)."""
        with self._lock:
            if number is None:
                rows = self._db.execute(
                    "SELECT * FROM sessions WHERE issue_number IS NULL ORDER BY started_at, id"
                ).fetchall()
            else:
                rows = self._db.execute(
                    "SELECT * FROM sessions WHERE issue_number=? ORDER BY started_at, id", (_check_number(number),)
                ).fetchall()
            return [self._session_record(row) for row in rows]

    # -- releases -----------------------------------------------------------------

    def _normalize_release_fields(self, fields: Mapping[str, Any]) -> dict[str, Any]:
        columns: dict[str, Any] = {}
        for name, value in fields.items():
            if name in ("issueNumbers", "issue_numbers", "issues_json"):
                if value is None:
                    value = []
                if not isinstance(value, (list, tuple)) or any(
                    isinstance(item, bool) or not isinstance(item, int) for item in value
                ):
                    raise _invalid("issueNumbers must be a list of integers")
                columns["issues_json"] = _dump_json(list(value))
                continue
            column = _snake(name)
            if column not in RELEASE_COLUMNS or column == "tag":
                raise _invalid(f"unknown release field: {name}")
            columns[column] = _check_text(value, name)
        return columns

    def upsert_release(self, tag: str, **fields: Any) -> dict[str, Any]:
        """Create or update a release row keyed by its git tag."""
        tag_text = _check_text(tag, "tag", maximum=200, optional=False)
        assert tag_text is not None
        columns = self._normalize_release_fields(fields)
        with self._transaction():
            now = self._now()
            exists = self._db.execute("SELECT 1 FROM releases WHERE tag=?", (tag_text,)).fetchone()
            if exists:
                if columns:
                    assignments = ", ".join(f"{name}=?" for name in columns)
                    self._db.execute(f"UPDATE releases SET {assignments} WHERE tag=?", (*columns.values(), tag_text))
            else:
                columns.setdefault("status", "pending")
                columns.setdefault("started_at", now)
                names = ", ".join(("tag", *columns))
                marks = ", ".join("?" for _ in range(len(columns) + 1))
                self._db.execute(f"INSERT INTO releases({names}) VALUES({marks})", (tag_text, *columns.values()))
            row = self._db.execute("SELECT * FROM releases WHERE tag=?", (tag_text,)).fetchone()
        return self._release_record(row)

    def update_release(self, tag: str, **fields: Any) -> dict[str, Any]:
        tag_text = _check_text(tag, "tag", maximum=200, optional=False)
        columns = self._normalize_release_fields(fields)
        with self._transaction():
            if self._db.execute("SELECT 1 FROM releases WHERE tag=?", (tag_text,)).fetchone() is None:
                raise CodeFactoryError(f"release {tag_text} is unknown", code="not_found")
            if columns:
                assignments = ", ".join(f"{name}=?" for name in columns)
                self._db.execute(f"UPDATE releases SET {assignments} WHERE tag=?", (*columns.values(), tag_text))
            row = self._db.execute("SELECT * FROM releases WHERE tag=?", (tag_text,)).fetchone()
        return self._release_record(row)

    def get_release(self, tag: str) -> dict[str, Any] | None:
        tag_text = _check_text(tag, "tag", maximum=200, optional=False)
        with self._lock:
            row = self._db.execute("SELECT * FROM releases WHERE tag=?", (tag_text,)).fetchone()
            return self._release_record(row) if row is not None else None

    def list_releases(self) -> list[dict[str, Any]]:
        """Releases newest first."""
        with self._lock:
            rows = self._db.execute("SELECT * FROM releases ORDER BY started_at DESC, tag DESC").fetchall()
            return [self._release_record(row) for row in rows]

    # -- daemon -------------------------------------------------------------------

    def set_daemon(self, key: str, value: str | None) -> None:
        key_text = _check_text(key, "key", maximum=64, optional=False)
        value_text = _check_text(value, "value", maximum=4096)
        with self._transaction():
            self._db.execute("INSERT OR REPLACE INTO daemon(key, value) VALUES(?, ?)", (key_text, value_text))

    def daemon_info(self) -> dict[str, Any]:
        with self._lock:
            stored = {row["key"]: row["value"] for row in self._db.execute("SELECT key, value FROM daemon")}
        info: dict[str, Any] = {_camel(key): stored.get(key) for key in DAEMON_KEYS}
        for key, value in stored.items():
            if key not in DAEMON_KEYS:
                info[_camel(key)] = value
        info["version"] = SCHEMA_VERSION
        return info

    # -- aggregates ---------------------------------------------------------------

    def stats(self) -> dict[str, int]:
        with self._lock:
            counts = {status: 0 for status in STATUSES}
            for row in self._db.execute("SELECT status, COUNT(*) AS n FROM issues GROUP BY status"):
                if row["status"] in counts:
                    counts[row["status"]] = int(row["n"])
            released = self._db.execute("SELECT COUNT(*) FROM issues WHERE release_tag IS NOT NULL").fetchone()[0]
            pending = self._db.execute(
                "SELECT COUNT(*) FROM issues WHERE worktree_path IS NOT NULL AND worktree_cleaned=0"
            ).fetchone()[0]
        return {**counts, "released": int(released), "worktreesPending": int(pending)}

    def snapshot(self, events_per_issue: int = 20) -> dict[str, Any]:
        """The dashboard document: stats, every issue with sessions and recent events, releases, daemon."""
        limit = max(0, min(int(events_per_issue), 1000))
        with self._lock:
            issues = []
            for issue in self.list_issues():
                issue.pop("planJson", None)
                number = issue["number"]
                issue["sessions"] = self.list_sessions(number)
                issue["events"] = self.list_events(number, limit) if limit else []
                issues.append(issue)
            return {
                "ok": True,
                "generatedAt": self._now(),
                "stats": self.stats(),
                "issues": issues,
                "releases": self.list_releases(),
                "daemon": self.daemon_info(),
            }

    def issue_detail(self, number: int) -> dict[str, Any] | None:
        """One issue with every event (newest first) and every session, or ``None``."""
        with self._lock:
            issue = self.get_issue(number)
            if issue is None:
                return None
            issue["sessions"] = self.list_sessions(number)
            issue["events"] = self.list_events(number, 5000)
            return issue
