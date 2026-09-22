"""Transactional First Mate work ledger, independent of agent processes and UI.

An execution receipt is persisted before launch. A missing process outcome is
never interpreted as success, and expired or missing owners are never silently
reassigned. The runtime must establish that a predecessor stopped before recovery.
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping


class FirstMateError(RuntimeError):
    def __init__(self, message: str, *, code: str = "first_mate_conflict", status: int = 409):
        super().__init__(message)
        self.code, self.status = code, status


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


def _json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def _text(value: Any, name: str, maximum: int = 200000, optional: bool = False) -> str:
    if not isinstance(value, str) or (not optional and not value.strip()) or len(value) > maximum or "\x00" in value:
        raise FirstMateError(f"Invalid {name}", code="invalid_request", status=400)
    return value


ARCHIVE_REASONS = {"test/synthetic", "duplicate", "no longer relevant", "superseded", "other"}


SCHEMA = """
CREATE TABLE IF NOT EXISTS fm_schema(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS fm_features(
 id TEXT PRIMARY KEY, title TEXT NOT NULL, goal TEXT NOT NULL, cwd TEXT NOT NULL,
 status TEXT NOT NULL, current_visit_id TEXT, revision INTEGER NOT NULL,
 work_item_id TEXT, coordinator_owner TEXT, native_session_id TEXT, session_file TEXT,
 archived_at TEXT, archive_reason TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS fm_visits(
 id TEXT PRIMARY KEY, feature_id TEXT NOT NULL REFERENCES fm_features(id),
 stage_key TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL, revision INTEGER NOT NULL,
 authorization_message_id TEXT NOT NULL UNIQUE, summary TEXT NOT NULL DEFAULT '',
 recommendation TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS fm_assignments(
 id TEXT PRIMARY KEY, feature_id TEXT NOT NULL REFERENCES fm_features(id),
 visit_id TEXT NOT NULL REFERENCES fm_visits(id), title TEXT NOT NULL, role TEXT NOT NULL,
 prompt TEXT NOT NULL, model TEXT NOT NULL DEFAULT '', status TEXT NOT NULL, verdict TEXT,
 native_session_id TEXT, session_file TEXT, run_id TEXT, attempt INTEGER NOT NULL DEFAULT 0,
 generation INTEGER NOT NULL DEFAULT 0, input_revision INTEGER NOT NULL,
 dispatch_id TEXT, owner TEXT, recovery_count INTEGER NOT NULL DEFAULT 0,
 summary TEXT NOT NULL DEFAULT '', metadata_json TEXT NOT NULL DEFAULT '{}',
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS fm_attempts(
 id TEXT PRIMARY KEY, assignment_id TEXT NOT NULL REFERENCES fm_assignments(id),
 attempt INTEGER NOT NULL, generation INTEGER NOT NULL, input_revision INTEGER NOT NULL,
 dispatch_id TEXT NOT NULL UNIQUE, owner TEXT NOT NULL, status TEXT NOT NULL,
 native_session_id TEXT, session_file TEXT, run_id TEXT, verdict TEXT, summary TEXT, code_revision TEXT,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE(assignment_id,generation));
CREATE TABLE IF NOT EXISTS fm_assignment_memberships(
 visit_id TEXT NOT NULL REFERENCES fm_visits(id), assignment_id TEXT NOT NULL REFERENCES fm_assignments(id),
 revision INTEGER NOT NULL, authorization_message_id TEXT NOT NULL, carried_from_visit_id TEXT,
 created_at TEXT NOT NULL, PRIMARY KEY(visit_id,assignment_id));
CREATE TABLE IF NOT EXISTS fm_messages(
 id TEXT PRIMARY KEY, feature_id TEXT NOT NULL REFERENCES fm_features(id),
 role TEXT NOT NULL, text TEXT NOT NULL, status TEXT NOT NULL, owner TEXT,
 metadata_json TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS fm_documents(
 id TEXT PRIMARY KEY, feature_id TEXT NOT NULL REFERENCES fm_features(id),
 visit_id TEXT NOT NULL REFERENCES fm_visits(id), assignment_id TEXT NOT NULL REFERENCES fm_assignments(id),
 native_session_id TEXT NOT NULL, generation INTEGER NOT NULL, input_revision INTEGER NOT NULL,
 title TEXT NOT NULL, media_type TEXT NOT NULL, content TEXT NOT NULL,
 content_hash TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS fm_events(
 sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
 feature_id TEXT NOT NULL REFERENCES fm_features(id), type TEXT NOT NULL,
 summary TEXT NOT NULL, created_at TEXT NOT NULL, payload_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS fm_receipts(
 scope TEXT NOT NULL, request_id TEXT NOT NULL, payload_hash TEXT NOT NULL,
 result_json TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(scope, request_id));
CREATE TABLE IF NOT EXISTS fm_sessions(
 native_session_id TEXT PRIMARY KEY, feature_id TEXT NOT NULL REFERENCES fm_features(id),
 assignment_id TEXT, generation INTEGER NOT NULL, owner TEXT NOT NULL, status TEXT NOT NULL,
 session_file TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS fm_handoffs(
 id TEXT PRIMARY KEY, assignment_id TEXT NOT NULL REFERENCES fm_assignments(id),
 feature_id TEXT NOT NULL, predecessor_generation INTEGER NOT NULL,
 predecessor_session_id TEXT NOT NULL, successor_session_id TEXT,
 successor_session_file TEXT, successor_owner TEXT, summary TEXT NOT NULL,
 document_id TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS fm_sessions_file ON fm_sessions(session_file);
CREATE INDEX IF NOT EXISTS fm_events_feature ON fm_events(feature_id,sequence);
CREATE INDEX IF NOT EXISTS fm_assignments_status ON fm_assignments(status,feature_id);
CREATE INDEX IF NOT EXISTS fm_messages_pending ON fm_messages(status,feature_id,created_at);
CREATE INDEX IF NOT EXISTS fm_visits_feature ON fm_visits(feature_id,created_at);
"""


class FirstMateStore:
    """One connection per store, serialized writes and cross-process SQLite fencing."""
    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser() if str(path) != ":memory:" else None
        if self.path:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
            os.close(descriptor)
            os.chmod(self.path, 0o600)
        self._lock = threading.RLock()
        self._db = sqlite3.connect(str(self.path) if self.path else ":memory:", timeout=15, isolation_level=None, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA foreign_keys=ON")
        self._db.execute("PRAGMA busy_timeout=15000")
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA synchronous=FULL")
        self._db.executescript(SCHEMA)
        if "code_revision" not in {row[1] for row in self._db.execute("PRAGMA table_info(fm_attempts)")}:
            self._db.execute("ALTER TABLE fm_attempts ADD COLUMN code_revision TEXT")
        self._db.execute("INSERT OR IGNORE INTO fm_assignment_memberships SELECT a.visit_id,a.id,a.input_revision,v.authorization_message_id,NULL,a.created_at FROM fm_assignments a JOIN fm_visits v ON v.id=a.visit_id")
        self._db.execute("INSERT OR IGNORE INTO fm_schema VALUES(1,?)", (_now(),))
        self._db.execute("INSERT OR IGNORE INTO fm_schema VALUES(2,?)", (_now(),))
        columns = {row[1] for row in self._db.execute("PRAGMA table_info(fm_features)")}
        for name, definition in (("coordinator_model", "TEXT NOT NULL DEFAULT ''"),
                                 ("coordinator_thinking", "TEXT NOT NULL DEFAULT ''"),
                                 ("model_settings_revision", "INTEGER NOT NULL DEFAULT 0")):
            if name not in columns:
                self._db.execute(f"ALTER TABLE fm_features ADD COLUMN {name} {definition}")
        self._db.execute("INSERT OR IGNORE INTO fm_schema VALUES(3,?)", (_now(),))
        columns = {row[1] for row in self._db.execute("PRAGMA table_info(fm_features)")}
        for name in ("archived_at", "archive_reason"):
            if name not in columns:
                self._db.execute(f"ALTER TABLE fm_features ADD COLUMN {name} TEXT")
        self._db.execute("INSERT OR IGNORE INTO fm_schema VALUES(4,?)", (_now(),))

    def close(self) -> None:
        with self._lock:
            self._db.close()

    @contextmanager
    def _transaction(self):
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                yield
                self._db.execute("COMMIT")
            except BaseException:
                self._db.execute("ROLLBACK")
                raise

    @staticmethod
    def _decode(row) -> dict | None:
        if row is None:
            return None
        result = dict(row)
        for name in ("metadata_json", "payload_json"):
            if name in result:
                result[name[:-5]] = json.loads(result.pop(name))
        return result

    def _one(self, table: str, identity: str) -> dict:
        row = self._db.execute(f"SELECT * FROM {table} WHERE id=?", (identity,)).fetchone()
        if row is None:
            raise FirstMateError("First Mate record not found", code="not_found", status=404)
        result = self._decode(row)
        return self._assignment_projection(result) if table == "fm_assignments" else result

    def _assignment_projection(self, result: dict) -> dict:
        result["visit_ids"] = [row[0] for row in self._db.execute("SELECT visit_id FROM fm_assignment_memberships WHERE assignment_id=? ORDER BY revision,visit_id", (result["id"],))]
        attempt = self._db.execute("SELECT code_revision FROM fm_attempts WHERE assignment_id=? AND generation=?", (result["id"], result["generation"])).fetchone()
        result["code_revision"] = attempt["code_revision"] if attempt else None
        return result

    def assignment_is_in_current_visit(self, assignment_id: str) -> bool:
        with self._lock:
            return self._db.execute("SELECT 1 FROM fm_assignments a JOIN fm_features f ON f.id=a.feature_id JOIN fm_assignment_memberships m ON m.assignment_id=a.id AND m.visit_id=f.current_visit_id AND m.revision=f.revision WHERE a.id=?", (assignment_id,)).fetchone() is not None

    def _assignment_revision(self, feature: dict, assignment: dict) -> None:
        if assignment["input_revision"] != feature["revision"] and not self.assignment_is_in_current_visit(assignment["id"]):
            raise FirstMateError("Assignment was not carried into the current plan revision", code="stale_revision")

    def _event(self, feature_id: str, kind: str, summary: str, payload: dict | None = None) -> None:
        self._db.execute("INSERT INTO fm_events(id,feature_id,type,summary,created_at,payload_json) VALUES(?,?,?,?,?,?)",
                         (_id("fme"), feature_id, kind, summary, _now(), _json(payload or {})))
        self._db.execute("UPDATE fm_features SET updated_at=? WHERE id=?", (_now(), feature_id))

    def _receipt(self, scope: str, request_id: str, payload: Any) -> dict | None:
        _text(request_id, "request_id", 200)
        row = self._db.execute("SELECT * FROM fm_receipts WHERE scope=? AND request_id=?", (scope, request_id)).fetchone()
        if row:
            if row["payload_hash"] != hashlib.sha256(_json(payload).encode()).hexdigest():
                raise FirstMateError("request_id was already used with different content", code="idempotency_conflict")
            return json.loads(row["result_json"])
        return None

    def _save_receipt(self, scope: str, request_id: str, payload: Any, result: dict) -> dict:
        self._db.execute("INSERT INTO fm_receipts VALUES(?,?,?,?,?)", (scope, request_id, hashlib.sha256(_json(payload).encode()).hexdigest(), _json(result), _now()))
        return result

    def _revision(self, feature: dict, expected_revision: int) -> None:
        if isinstance(expected_revision, bool) or expected_revision != feature["revision"]:
            raise FirstMateError("Feature plan revision changed", code="stale_revision")

    def _message(self, feature_id: str, role: str, text: str, *, status: str = "queued", metadata: dict | None = None) -> dict:
        message_id, now = _id("fmm"), _now()
        self._db.execute("INSERT INTO fm_messages(id,feature_id,role,text,status,metadata_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                         (message_id, feature_id, role, _text(text, "text"), status, _json(metadata or {}), now, now))
        return self._one("fm_messages", message_id)

    def create_feature(self, payload: Mapping[str, Any]) -> dict:
        body = dict(payload)
        title = _text(body.get("title"), "title", 300)
        goal = _text(body.get("goal"), "goal")
        cwd = _text(body.get("cwd"), "cwd", 4096)
        if not Path(cwd).is_absolute():
            raise FirstMateError("cwd must be absolute", code="invalid_request", status=400)
        if body.get("work_item_id") is not None:
            _text(body["work_item_id"], "work_item_id", 200)
        request_id = body.get("request_id")
        with self._transaction():
            cached = self._receipt("create_feature", request_id, body)
            if cached is not None:
                return cached
            feature_id, now = _id("fmf"), _now()
            self._db.execute("INSERT INTO fm_features(id,title,goal,cwd,status,revision,work_item_id,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)",
                             (feature_id, title, goal, cwd, "ready", 1, body.get("work_item_id"), now, now))
            message = self._message(feature_id, "user", goal, metadata={"initial": True})
            self._event(feature_id, "feature.created", "Feature created", {"message_id": message["id"]})
            return self._save_receipt("create_feature", request_id, body, self._one("fm_features", feature_id))

    def set_model_settings(self, feature_id: str, body: dict) -> dict:
        # A separate revision avoids invalidating running assignments or human gates.
        if set(body) != {"model", "thinking", "expected_settings_revision", "request_id"}:
            raise FirstMateError("Invalid model settings fields", code="invalid_request", status=400)
        model = _text(body.get("model"), "model", 300, optional=True)
        thinking = _text(body.get("thinking"), "thinking", 20, optional=True)
        if model and ("/" not in model or any(c.isspace() or ord(c) < 32 for c in model)):
            raise FirstMateError("Use a full provider/model identifier", code="invalid_request", status=400)
        if thinking not in {"", "off", "minimal", "low", "medium", "high", "xhigh", "max"}:
            raise FirstMateError("Invalid thinking effort", code="invalid_request", status=400)
        revision = body.get("expected_settings_revision")
        if type(revision) is not int or revision < 0:
            raise FirstMateError("Invalid model settings revision", code="invalid_request", status=400)
        with self._transaction():
            scope = "model_settings:" + feature_id
            cached = self._receipt(scope, body.get("request_id"), body)
            if cached is not None:
                return cached
            feature = self._one("fm_features", feature_id)
            if feature["model_settings_revision"] != revision:
                raise FirstMateError("Model settings changed. Reload them before saving.", code="stale_model_settings")
            if feature["status"] in {"completed", "cancelled"}:
                raise FirstMateError("This feature is closed", code="feature_closed")
            self._db.execute("UPDATE fm_features SET coordinator_model=?,coordinator_thinking=?,model_settings_revision=model_settings_revision+1 WHERE id=?", (model, thinking, feature_id))
            self._event(feature_id, "feature.model_settings_changed", "First Mate model settings updated for the next turn", {
                "model": model, "thinking": thinking, "settings_revision": revision + 1,
                "previous_model": feature["coordinator_model"], "previous_thinking": feature["coordinator_thinking"]})
            return self._save_receipt(scope, body["request_id"], body, self._one("fm_features", feature_id))

    def get_feature(self, feature_id: str) -> dict:
        with self._lock:
            return self._one("fm_features", feature_id)

    def list_features(self, view: str = "active") -> list[dict]:
        if view not in {"active", "archived", "all"}:
            raise FirstMateError("Invalid feature view", code="invalid_request", status=400)
        where = {
            "active": "WHERE archived_at IS NULL",
            "archived": "WHERE archived_at IS NOT NULL",
            "all": "",
        }[view]
        with self._lock:
            return [self._decode(r) for r in self._db.execute(
                f"SELECT * FROM fm_features {where} ORDER BY updated_at DESC,id"
            )]

    def set_archived(self, feature_id: str, archived: bool, payload: Mapping[str, Any]) -> dict:
        body = dict(payload)
        allowed = {"request_id", "reason"} if archived else {"request_id"}
        if set(body) != allowed and not (archived and set(body) == {"request_id"}):
            raise FirstMateError("Invalid archive fields", code="invalid_request", status=400)
        request_id = _text(body.get("request_id"), "request_id", 200)
        reason = body.get("reason") if archived else None
        if reason is not None and (not isinstance(reason, str) or reason not in ARCHIVE_REASONS):
            raise FirstMateError("Invalid archive reason", code="invalid_request", status=400)
        scope = ("archive:" if archived else "unarchive:") + feature_id
        with self._transaction():
            cached = self._receipt(scope, request_id, body)
            if cached is not None:
                return cached
            feature = self._one("fm_features", feature_id)
            if archived and feature["archived_at"] is None:
                archived_at = _now()
                self._db.execute(
                    "UPDATE fm_features SET archived_at=?,archive_reason=? WHERE id=?",
                    (archived_at, reason, feature_id),
                )
                self._event(feature_id, "feature.archived", "Feature archived", {"reason": reason})
            elif not archived and feature["archived_at"] is not None:
                previous_reason = feature["archive_reason"]
                self._db.execute(
                    "UPDATE fm_features SET archived_at=NULL,archive_reason=NULL WHERE id=?",
                    (feature_id,),
                )
                self._event(feature_id, "feature.unarchived", "Feature unarchived", {"previous_reason": previous_reason})
            return self._save_receipt(scope, request_id, body, self._one("fm_features", feature_id))

    def list_session_records(self, feature_id: str | None = None) -> list[dict]:
        """Return the complete managed session ledger for internal accounting.

        Public snapshots remain capped independently.  The private session path is
        included here so trusted runtime code can read only explicitly owned files.
        """
        with self._lock:
            where = "WHERE s.feature_id=?" if feature_id is not None else ""
            args = (feature_id,) if feature_id is not None else ()
            rows = self._db.execute(f"""SELECT s.native_session_id,s.feature_id,s.assignment_id,
                COALESCE(a.title,'First Mate') AS title,COALESCE(a.role,'first_mate') AS role,
                COALESCE(x.status,s.status) AS status,s.generation,x.attempt,x.input_revision,
                s.created_at,s.updated_at,s.status AS ownership_status,s.session_file
                FROM fm_sessions s LEFT JOIN fm_assignments a ON a.id=s.assignment_id
                LEFT JOIN fm_attempts x ON x.assignment_id=s.assignment_id AND x.generation=s.generation
                {where} ORDER BY s.created_at DESC,s.native_session_id""", args).fetchall()
            return [dict(row) for row in rows]

    def snapshot(self, feature_id: str) -> dict:
        with self._transaction():
            result = {"feature": self._one("fm_features", feature_id)}
            for key in ("visits", "assignments", "documents", "messages", "events", "handoffs"):
                ordering = "sequence" if key == "events" else "created_at,id"
                projection = "*" if key != "documents" else "id,feature_id,visit_id,assignment_id,native_session_id,generation,input_revision,title,media_type,content_hash,created_at"
                rows = [self._decode(r) for r in self._db.execute(f"SELECT {projection} FROM fm_{key} WHERE feature_id=? ORDER BY {ordering}", (feature_id,))]
                result[key] = [self._assignment_projection(row) for row in rows] if key == "assignments" else rows
            result["memberships"] = [dict(row) for row in self._db.execute("SELECT m.* FROM fm_assignment_memberships m JOIN fm_visits v ON v.id=m.visit_id WHERE v.feature_id=? ORDER BY m.revision,m.created_at,m.assignment_id", (feature_id,))]
            session_rows = self._db.execute("""SELECT s.native_session_id,s.feature_id,s.assignment_id,
                COALESCE(a.title,'First Mate') AS title,COALESCE(a.role,'first_mate') AS role,
                COALESCE(x.status,s.status) AS status,s.generation,x.attempt,x.input_revision,
                s.created_at,s.updated_at,s.status AS ownership_status
                FROM fm_sessions s LEFT JOIN fm_assignments a ON a.id=s.assignment_id
                LEFT JOIN fm_attempts x ON x.assignment_id=s.assignment_id AND x.generation=s.generation
                WHERE s.feature_id=? ORDER BY s.created_at DESC,s.native_session_id LIMIT 1001""", (feature_id,)).fetchall()
            result["sessions"] = [dict(row) for row in session_rows[:1000]]
            result["sessions_truncated"] = len(session_rows) > 1000
            return result

    def get_events(self, feature_id: str, after: int = 0, limit: int = 1000) -> dict:
        if isinstance(after, bool) or not isinstance(after, int) or after < 0:
            raise FirstMateError("Invalid event cursor", code="invalid_request", status=400)
        with self._lock:
            self._one("fm_features", feature_id)
            events = [self._decode(r) for r in self._db.execute("SELECT * FROM fm_events WHERE feature_id=? AND sequence>? ORDER BY sequence LIMIT ?", (feature_id, after, max(1, min(limit, 5000))))]
            return {"events": events, "cursor": events[-1]["sequence"] if events else after}

    def get_document(self, document_id: str) -> dict:
        with self._lock:
            return self._one("fm_documents", document_id)

    def append_human_message(self, feature_id: str, text: str, request_id: str) -> dict:
        payload = {"text": _text(text, "text")}
        with self._transaction():
            feature = self._one("fm_features", feature_id)
            cached = self._receipt(f"message:{feature_id}", request_id, payload)
            if cached is not None:
                return cached
            if feature["status"] in {"cancelled", "completed"}:
                raise FirstMateError("Feature is closed", code="feature_closed")
            message = self._message(feature_id, "user", text)
            self._event(feature_id, "message.queued", "Human direction queued", {"message_id": message["id"]})
            return self._save_receipt(f"message:{feature_id}", request_id, payload, message)

    def claim_message(self, feature_id: str, owner: str) -> dict | None:
        _text(owner, "owner", 200)
        with self._transaction():
            feature = self._one("fm_features", feature_id)
            if feature["coordinator_owner"] or feature["status"] in {"cancelled", "completed"}:
                return None
            row = self._db.execute("SELECT * FROM fm_messages WHERE feature_id=? AND status='queued' ORDER BY CASE role WHEN 'user' THEN 0 ELSE 1 END,created_at,id LIMIT 1", (feature_id,)).fetchone()
            if row is None:
                return None
            self._db.execute("UPDATE fm_messages SET status='processing',owner=?,updated_at=? WHERE id=?", (owner, _now(), row["id"]))
            self._db.execute("UPDATE fm_features SET coordinator_owner=? WHERE id=?", (owner, feature_id))
            self._event(feature_id, "message.claimed", "First Mate is processing an update", {"message_id": row["id"], "owner": owner})
            return self._one("fm_messages", row["id"])

    def finish_message(self, message_id: str, owner: str, reply: str | None = None) -> dict:
        with self._transaction():
            message = self._one("fm_messages", message_id)
            if message["status"] == "done" and message["owner"] == owner:
                return message
            feature = self._one("fm_features", message["feature_id"])
            if message["status"] != "processing" or message["owner"] != owner or feature["coordinator_owner"] != owner:
                raise FirstMateError("Coordinator ownership changed", code="stale_owner")
            if reply:
                self._message(message["feature_id"], "assistant", reply, status="done", metadata={"in_reply_to": message_id})
            self._db.execute("UPDATE fm_messages SET status='done',updated_at=? WHERE id=?", (_now(), message_id))
            self._db.execute("UPDATE fm_features SET coordinator_owner=NULL WHERE id=?", (message["feature_id"],))
            self._event(message["feature_id"], "message.processed", "First Mate processed an update", {"message_id": message_id})
            return self._one("fm_messages", message_id)

    def release_message(self, message_id: str, owner: str, reason: str, *, verified_stopped: bool = False, request_id: str | None = None) -> dict:
        if not verified_stopped:
            raise FirstMateError("Verify the coordinator stopped before releasing its message", code="writer_not_stopped")
        payload = {"owner": owner, "reason": reason, "verified_stopped": verified_stopped}
        with self._transaction():
            if request_id:
                cached = self._receipt(f"release_message:{message_id}", request_id, payload)
                if cached is not None:
                    return cached
            message = self._one("fm_messages", message_id)
            if message["owner"] != owner or message["status"] != "processing":
                raise FirstMateError("Coordinator ownership changed", code="stale_owner")
            self._db.execute("UPDATE fm_messages SET owner=NULL,status='queued',updated_at=? WHERE id=?", (_now(), message_id))
            self._db.execute("UPDATE fm_features SET coordinator_owner=NULL WHERE id=? AND coordinator_owner=?", (message["feature_id"], owner))
            self._event(message["feature_id"], "message.requeued", reason, {"message_id": message_id})
            result = self._one("fm_messages", message_id)
            return self._save_receipt(f"release_message:{message_id}", request_id, payload, result) if request_id else result

    def start_visit(self, feature_id: str, stage_key: str, title: str, request_id: str, expected_revision: int, authorization_message_id: str) -> dict:
        payload = {"stage_key": _text(stage_key, "stage_key", 100), "title": _text(title, "title", 300), "expected_revision": expected_revision, "authorization_message_id": authorization_message_id}
        with self._transaction():
            cached = self._receipt(f"visit:{feature_id}", request_id, payload)
            if cached is not None:
                return cached
            feature = self._one("fm_features", feature_id)
            self._revision(feature, expected_revision)
            if feature["status"] in {"paused", "cancelled", "completed", "recovering"}:
                raise FirstMateError("Feature is not available for a new stage")
            if feature["current_visit_id"]:
                current = self._one("fm_visits", feature["current_visit_id"])
                if current["status"] not in {"completed", "cancelled", "superseded"}:
                    raise FirstMateError("Current stage must finish or be explicitly superseded")
            authorization = self._one("fm_messages", authorization_message_id)
            if authorization["feature_id"] != feature_id or authorization["role"] != "user" or authorization["status"] not in {"processing", "done"}:
                raise FirstMateError("A processed human direction is required", code="human_direction_required")
            if feature["current_visit_id"] and current["status"] == "completed" and authorization["created_at"] <= current["updated_at"]:
                raise FirstMateError("The next stage needs direction after the completed checkpoint", code="human_direction_required")
            if self._db.execute("SELECT id FROM fm_visits WHERE authorization_message_id=?", (authorization_message_id,)).fetchone():
                raise FirstMateError("Human direction already authorized a stage", code="human_direction_required")
            visit_id, now = _id("fmv"), _now()
            self._db.execute("INSERT INTO fm_visits(id,feature_id,stage_key,title,status,revision,authorization_message_id,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)", (visit_id, feature_id, stage_key, title, "running", expected_revision, authorization_message_id, now, now))
            self._db.execute("UPDATE fm_features SET status='running',current_visit_id=? WHERE id=?", (visit_id, feature_id))
            self._event(feature_id, "visit.started", f"{title} started", {"visit_id": visit_id, "authorization_message_id": authorization_message_id, "revision": expected_revision})
            return self._save_receipt(f"visit:{feature_id}", request_id, payload, self._one("fm_visits", visit_id))

    def create_assignment(self, visit_id: str, payload: Mapping[str, Any]) -> dict:
        body = dict(payload)
        title, role = _text(body.get("title"), "title", 300), _text(body.get("role"), "role", 100)
        prompt = _text(body.get("prompt"), "prompt")
        _text(body.get("model", ""), "model", 300, optional=True)
        if not isinstance(body.get("metadata", {}), dict):
            raise FirstMateError("Invalid metadata", code="invalid_request", status=400)
        request_id = body.get("request_id")
        with self._transaction():
            cached = self._receipt(f"assignment:{visit_id}", request_id, body)
            if cached is not None:
                return cached
            visit = self._one("fm_visits", visit_id)
            feature = self._one("fm_features", visit["feature_id"])
            revision = body.get("input_revision", feature["revision"])
            self._revision(feature, revision)
            if visit["status"] != "running" or visit["revision"] != revision or feature["status"] != "running":
                raise FirstMateError("Stage is not running at the requested revision")
            parent_id = body.get("metadata", {}).get("parent_assignment_id")
            if parent_id is not None:
                parent = self._one("fm_assignments", _text(parent_id, "parent_assignment_id", 200))
                if parent["feature_id"] != feature["id"] or not self.assignment_is_in_current_visit(parent_id) or parent["status"] != "running":
                    raise FirstMateError("Parent assignment does not own this active stage", code="assignment_scope_mismatch")
            assignment_id, now = _id("fma"), _now()
            self._db.execute("INSERT INTO fm_assignments(id,feature_id,visit_id,title,role,prompt,model,status,input_revision,metadata_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", (assignment_id, feature["id"], visit_id, title, role, prompt, body.get("model", ""), "queued", revision, _json(body.get("metadata", {})), now, now))
            self._db.execute("INSERT INTO fm_assignment_memberships VALUES(?,?,?,?,?,?)", (visit_id, assignment_id, revision, visit["authorization_message_id"], None, now))
            self._event(feature["id"], "assignment.queued", f"{title} queued", {"assignment_id": assignment_id, "visit_id": visit_id})
            return self._save_receipt(f"assignment:{visit_id}", request_id, body, self._one("fm_assignments", assignment_id))

    def get_assignment(self, assignment_id: str) -> dict:
        with self._lock:
            return self._one("fm_assignments", assignment_id)

    def list_assignments(self, statuses: list[str] | tuple[str, ...] | None = None, feature_id: str | None = None) -> list[dict]:
        with self._lock:
            clauses, args = [], []
            if statuses:
                clauses.append("status IN (" + ",".join("?" for _ in statuses) + ")")
                args.extend(statuses)
            if feature_id:
                clauses.append("feature_id=?")
                args.append(feature_id)
            where = " WHERE " + " AND ".join(clauses) if clauses else ""
            return [self._assignment_projection(self._decode(r)) for r in self._db.execute("SELECT * FROM fm_assignments" + where + " ORDER BY created_at,id", args)]

    def claim_assignment(self, assignment_id: str, owner: str) -> dict:
        _text(owner, "owner", 200)
        with self._transaction():
            assignment = self._one("fm_assignments", assignment_id)
            feature = self._one("fm_features", assignment["feature_id"])
            self._assignment_revision(feature, assignment)
            if assignment["status"] != "queued" or feature["status"] != "running":
                raise FirstMateError("Assignment is not dispatchable", code="not_dispatchable")
            generation, attempt = assignment["generation"] + 1, assignment["attempt"] + 1
            dispatch_id, now = _id("fmd"), _now()
            self._db.execute("UPDATE fm_assignments SET status='dispatching',owner=?,generation=?,attempt=?,dispatch_id=?,native_session_id=NULL,session_file=NULL,run_id=NULL,updated_at=? WHERE id=?", (owner, generation, attempt, dispatch_id, now, assignment_id))
            self._db.execute("INSERT INTO fm_attempts(id,assignment_id,attempt,generation,input_revision,dispatch_id,owner,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)", (_id("fmx"), assignment_id, attempt, generation, assignment["input_revision"], dispatch_id, owner, "dispatching", now, now))
            self._event(feature["id"], "assignment.dispatch_claimed", "Execution claimed before launch", {"assignment_id": assignment_id, "generation": generation, "dispatch_id": dispatch_id})
            return self._one("fm_assignments", assignment_id)

    def _execution(self, assignment_id: str, generation: int, native_session_id: str | None = None, input_revision: int | None = None, owner: str | None = None) -> dict:
        assignment = self._one("fm_assignments", assignment_id)
        if assignment["generation"] != generation:
            raise FirstMateError("Execution generation changed", code="stale_generation")
        if native_session_id is not None and assignment["native_session_id"] != native_session_id:
            raise FirstMateError("Outcome belongs to another native session", code="session_mismatch")
        if owner is not None and assignment["owner"] != owner:
            raise FirstMateError("Execution ownership changed", code="stale_owner")
        if input_revision is not None and assignment["input_revision"] != input_revision:
            raise FirstMateError("Outcome revision does not match its assignment", code="stale_revision")
        self._assignment_revision(self._one("fm_features", assignment["feature_id"]), assignment)
        return assignment

    def _register_session(self, session_id: str, feature_id: str, assignment_id: str | None, generation: int, owner: str, session_file: str) -> None:
        _text(session_id, "native_session_id", 500)
        _text(session_file, "session_file", 4096)
        if not Path(session_file).is_absolute():
            raise FirstMateError("Session file must be absolute", code="invalid_request", status=400)
        file_owner = self._db.execute("SELECT native_session_id FROM fm_sessions WHERE session_file=?", (session_file,)).fetchone()
        if file_owner and file_owner["native_session_id"] != session_id:
            raise FirstMateError("Session file is already bound to another native session", code="session_owned")
        existing = self._db.execute("SELECT * FROM fm_sessions WHERE native_session_id=?", (session_id,)).fetchone()
        if existing:
            if (existing["feature_id"], existing["assignment_id"], existing["generation"], existing["owner"], existing["session_file"], existing["status"]) != (feature_id, assignment_id, generation, owner, session_file, "active"):
                raise FirstMateError("Native session already has an owner or retained history", code="session_owned")
            return
        now = _now()
        self._db.execute("INSERT INTO fm_sessions VALUES(?,?,?,?,?,?,?,?,?)", (session_id, feature_id, assignment_id, generation, owner, "active", session_file, now, now))

    def bind_session(self, assignment_id: str, generation: int, owner: str, native_session_id: str, session_file: str, run_id: str = "") -> dict:
        with self._transaction():
            assignment = self._execution(assignment_id, generation, owner=owner)
            if assignment["status"] == "waiting_children" and any(child["status"] not in {"completed", "blocked", "failed", "cancelled", "superseded"} for child in self._children(assignment_id)):
                raise FirstMateError("Direct child assignments have not all settled", code="children_incomplete")
            if assignment["status"] not in {"dispatching", "running", "recovering", "waiting_children"}:
                raise FirstMateError("Execution is not awaiting session binding")
            if assignment["native_session_id"] and assignment["native_session_id"] != native_session_id:
                raise FirstMateError("An execution cannot change its native session", code="session_mismatch")
            self._register_session(native_session_id, assignment["feature_id"], assignment_id, generation, owner, session_file)
            self._db.execute("UPDATE fm_assignments SET status='running',native_session_id=?,session_file=?,run_id=?,updated_at=? WHERE id=?", (native_session_id, session_file, run_id, _now(), assignment_id))
            self._db.execute("UPDATE fm_attempts SET status='running',native_session_id=?,session_file=?,run_id=?,updated_at=? WHERE assignment_id=? AND generation=?", (native_session_id, session_file, run_id, _now(), assignment_id, generation))
            self._db.execute("UPDATE fm_features SET status='running' WHERE id=? AND status='recovering' AND NOT EXISTS (SELECT 1 FROM fm_assignments WHERE feature_id=? AND status='recovering')", (assignment["feature_id"], assignment["feature_id"]))
            if not assignment["native_session_id"]:
                self._event(assignment["feature_id"], "assignment.session_bound", "Native session attached to execution", {"assignment_id": assignment_id, "generation": generation, "native_session_id": native_session_id})
            return self._one("fm_assignments", assignment_id)


    def _children(self, assignment_id: str) -> list[dict]:
        assignment = self._one("fm_assignments", assignment_id)
        return [self._decode(row) for row in self._db.execute("SELECT * FROM fm_assignments WHERE feature_id=?", (assignment["feature_id"],)) if json.loads(row["metadata_json"]).get("parent_assignment_id") == assignment_id]

    def wait_for_children(self, assignment_id: str, generation: int, native_session_id: str, summary: str, request_id: str) -> dict:
        """Park the parent process while ordinary code waits for its children."""
        payload = {"generation": generation, "native_session_id": native_session_id, "summary": _text(summary, "summary")}
        with self._transaction():
            cached = self._receipt(f"wait_children:{assignment_id}", request_id, payload)
            if cached is not None:
                return cached
            assignment = self._execution(assignment_id, generation, native_session_id)
            children = self._children(assignment_id)
            if assignment["status"] != "running" or not children:
                raise FirstMateError("A running parent with direct children is required")
            self._db.execute("UPDATE fm_assignments SET status='waiting_children',summary=?,updated_at=? WHERE id=?", (summary, _now(), assignment_id))
            self._db.execute("UPDATE fm_attempts SET status='waiting_children',summary=?,updated_at=? WHERE assignment_id=? AND generation=?", (summary, _now(), assignment_id, generation))
            self._event(assignment["feature_id"], "assignment.waiting_children", summary, {"assignment_id": assignment_id, "generation": generation, "native_session_id": native_session_id, "child_assignment_ids": [child["id"] for child in children]})
            return self._save_receipt(f"wait_children:{assignment_id}", request_id, payload, self._one("fm_assignments", assignment_id))

    def get_session(self, native_session_id: str) -> dict:
        with self._lock:
            row = self._db.execute("SELECT * FROM fm_sessions WHERE native_session_id=?", (native_session_id,)).fetchone()
            if row is None:
                raise FirstMateError("Session is not owned by First Mate", code="not_found", status=404)
            return dict(row)

    def _document(self, assignment: dict, title: str, content: str, media_type: str = "text/markdown") -> dict:
        _text(title, "document title", 300)
        _text(content, "document content", 2 * 1024 * 1024, optional=True)
        _text(media_type, "media_type", 100)
        if not assignment["native_session_id"]:
            raise FirstMateError("A document must have a native producer session")
        document_id = _id("fma_doc")
        self._db.execute("INSERT INTO fm_documents VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", (document_id, assignment["feature_id"], assignment["visit_id"], assignment["id"], assignment["native_session_id"], assignment["generation"], assignment["input_revision"], title, media_type, content, hashlib.sha256(content.encode()).hexdigest(), _now()))
        return self._one("fm_documents", document_id)

    def record_outcome(self, assignment_id: str, generation: int, native_session_id: str, input_revision: int, verdict: str, summary: str, request_id: str, documents: list[dict] | None = None, code_revision: str | None = None) -> dict:
        if verdict not in {"success", "passed", "needs_changes", "blocked", "failed", "cancelled"}:
            raise FirstMateError("Invalid outcome verdict", code="invalid_request", status=400)
        _text(summary, "summary")
        if documents is not None and (not isinstance(documents, list) or len(documents) > 100 or not all(isinstance(d, dict) for d in documents)):
            raise FirstMateError("Invalid documents", code="invalid_request", status=400)
        payload = {"generation": generation, "native_session_id": native_session_id, "input_revision": input_revision, "verdict": verdict, "summary": summary, "documents": documents or [], "code_revision": code_revision}
        with self._transaction():
            cached = self._receipt(f"outcome:{assignment_id}", request_id, payload)
            if cached is not None:
                return cached
            assignment = self._execution(assignment_id, generation, native_session_id, input_revision)
            if verdict in {"success", "passed"} and any(child["status"] != "completed" for child in self._children(assignment_id)):
                raise FirstMateError("A parent cannot succeed before all direct children succeed", code="children_incomplete")
            expected_code_revision = assignment["metadata"].get("expected_code_revision")
            if expected_code_revision and code_revision != expected_code_revision:
                raise FirstMateError("Outcome does not review the assigned code revision", code="stale_code_revision")
            if assignment["status"] not in {"running", "paused"}:
                raise FirstMateError("Execution is not accepting an outcome", code="outcome_already_settled")
            session = self._db.execute("SELECT * FROM fm_sessions WHERE native_session_id=?", (native_session_id,)).fetchone()
            if not session or session["status"] != "active" or session["generation"] != generation or session["assignment_id"] != assignment_id:
                raise FirstMateError("Session ownership is no longer active", code="stale_owner")
            retained = [self._document(assignment, d.get("title"), d.get("content"), d.get("media_type", "text/markdown")) for d in documents or []]
            status = "completed" if verdict in {"success", "passed"} else ("blocked" if verdict in {"blocked", "needs_changes"} else verdict)
            self._db.execute("UPDATE fm_assignments SET status=?,verdict=?,summary=?,updated_at=? WHERE id=?", (status, verdict, summary, _now(), assignment_id))
            self._db.execute("UPDATE fm_attempts SET status=?,verdict=?,summary=?,code_revision=?,updated_at=? WHERE assignment_id=? AND generation=?", (status, verdict, summary, code_revision, _now(), assignment_id, generation))
            self._db.execute("UPDATE fm_sessions SET status='retained',updated_at=? WHERE native_session_id=?", (_now(), native_session_id))
            event_payload = {"assignment_id": assignment_id, "generation": generation, "native_session_id": native_session_id, "input_revision": input_revision, "verdict": verdict, "code_revision": code_revision, "document_ids": [d["id"] for d in retained]}
            self._event(assignment["feature_id"], "assignment.outcome", summary, event_payload)
            # The owning lead resumes from durable child state and synthesizes its
            # findings. Only its top-level outcome needs a First Mate turn.
            if not assignment["metadata"].get("parent_assignment_id"):
                self._message(assignment["feature_id"], "system", f"{assignment['title']}: {summary}", metadata=event_payload)
            return self._save_receipt(f"outcome:{assignment_id}", request_id, payload, self._one("fm_assignments", assignment_id))

    def complete_visit(self, visit_id: str, summary: str, recommendation: str, request_id: str) -> dict:
        payload = {"summary": _text(summary, "summary"), "recommendation": _text(recommendation, "recommendation", optional=True)}
        with self._transaction():
            cached = self._receipt(f"complete:{visit_id}", request_id, payload)
            if cached is not None:
                return cached
            visit = self._one("fm_visits", visit_id)
            feature = self._one("fm_features", visit["feature_id"])
            self._revision(feature, visit["revision"])
            assignments = self._db.execute("SELECT a.status,a.input_revision,m.revision FROM fm_assignments a JOIN fm_assignment_memberships m ON m.assignment_id=a.id WHERE m.visit_id=?", (visit_id,)).fetchall()
            if visit["status"] != "running" or feature["status"] != "running" or not assignments or any(a["status"] != "completed" or a["revision"] != visit["revision"] for a in assignments):
                raise FirstMateError("All current-revision assignments must complete before the stage", code="stage_incomplete")
            self._db.execute("UPDATE fm_visits SET status='completed',summary=?,recommendation=?,updated_at=? WHERE id=?", (summary, recommendation, _now(), visit_id))
            self._db.execute("UPDATE fm_features SET status='awaiting_direction' WHERE id=?", (feature["id"],))
            self._message(feature["id"], "assistant", summary + (f"\n\nSuggested next step: {recommendation}" if recommendation else "") + "\n\nAwaiting your direction.", status="done", metadata={"visit_id": visit_id, "checkpoint": True})
            self._event(feature["id"], "visit.awaiting_direction", f"{visit['title']} complete. Awaiting human direction.", {"visit_id": visit_id, "revision": visit["revision"], "recommendation": recommendation})
            return self._save_receipt(f"complete:{visit_id}", request_id, payload, self._one("fm_visits", visit_id))

    def queue_system_message(self, feature_id: str, text: str, request_id: str) -> dict:
        payload = {"text": _text(text, "text")}
        with self._transaction():
            self._one("fm_features", feature_id)
            cached = self._receipt(f"system_message:{feature_id}", request_id, payload)
            if cached is not None:
                return cached
            message = self._message(feature_id, "system", text)
            self._event(feature_id, "message.queued", "Background update queued", {"message_id": message["id"]})
            return self._save_receipt(f"system_message:{feature_id}", request_id, payload, message)

    def append_event(self, feature_id: str, type: str, summary: str, payload: dict | None = None, request_id: str | None = None) -> dict:
        _text(type, "event type", 100)
        _text(summary, "event summary")
        data = {"type": type, "summary": summary, "payload": payload or {}}
        with self._transaction():
            self._one("fm_features", feature_id)
            if request_id:
                cached = self._receipt(f"event:{feature_id}", request_id, data)
                if cached is not None:
                    return cached
            self._event(feature_id, type, summary, payload)
            result = self._decode(self._db.execute("SELECT * FROM fm_events WHERE feature_id=? ORDER BY sequence DESC LIMIT 1", (feature_id,)).fetchone())
            return self._save_receipt(f"event:{feature_id}", request_id, data, result) if request_id else result

    def bind_coordinator_session(self, feature_id: str, owner: str, native_session_id: str, session_file: str) -> dict:
        with self._transaction():
            feature = self._one("fm_features", feature_id)
            if feature["coordinator_owner"] != owner:
                raise FirstMateError("Coordinator ownership changed", code="stale_owner")
            if feature["native_session_id"] and feature["native_session_id"] != native_session_id:
                raise FirstMateError("Coordinator replacement requires an explicit reset", code="session_mismatch")
            existing = self._db.execute("SELECT * FROM fm_sessions WHERE native_session_id=?", (native_session_id,)).fetchone()
            if existing:
                if existing["assignment_id"] is not None or existing["feature_id"] != feature_id or existing["session_file"] != session_file:
                    raise FirstMateError("Native session belongs to another execution", code="session_owned")
                # claim_message already fences writers across connections and processes.
                self._db.execute("UPDATE fm_sessions SET owner=?,status='active',updated_at=? WHERE native_session_id=?", (owner, _now(), native_session_id))
            else:
                self._register_session(native_session_id, feature_id, None, 0, owner, session_file)
            self._db.execute("UPDATE fm_features SET native_session_id=?,session_file=? WHERE id=?", (native_session_id, session_file, feature_id))
            if not feature["native_session_id"]:
                self._event(feature_id, "coordinator.session_bound", "First Mate conversation attached", {"native_session_id": native_session_id})
            return self._one("fm_features", feature_id)


    def rotate_coordinator_session(self, feature_id: str, previous_native_session_id: str, request_id: str, verified_stopped: bool = False) -> dict:
        """Retire a completed coordinator context without deleting its history."""
        payload = {"previous_native_session_id": previous_native_session_id, "verified_stopped": verified_stopped}
        with self._transaction():
            cached = self._receipt(f"coordinator_rotation:{feature_id}", request_id, payload)
            if cached is not None:
                return cached
            feature = self._one("fm_features", feature_id)
            if not verified_stopped or feature["coordinator_owner"]:
                raise FirstMateError("Finish and stop the coordinator before rotating context", code="writer_not_stopped")
            if feature["native_session_id"] != previous_native_session_id or not previous_native_session_id:
                raise FirstMateError("Coordinator session identity changed", code="session_mismatch")
            self._db.execute("UPDATE fm_sessions SET status='retained',updated_at=? WHERE native_session_id=? AND feature_id=? AND assignment_id IS NULL", (_now(), previous_native_session_id, feature_id))
            self._db.execute("UPDATE fm_features SET native_session_id=NULL,session_file=NULL,updated_at=? WHERE id=?", (_now(), feature_id))
            self._event(feature_id, "coordinator.context_rotated", "First Mate context retired; feature decisions and session history retained", {"predecessor_session_id": previous_native_session_id, "revision": feature["revision"], "previous_session_file": feature["session_file"]})
            return self._save_receipt(f"coordinator_rotation:{feature_id}", request_id, payload, self._one("fm_features", feature_id))

    def feature_action(self, feature_id: str, action: str, request_id: str, expected_revision: int | None = None) -> dict:
        if action not in {"pause", "resume", "cancel", "complete"}:
            raise FirstMateError("Unsupported feature action", code="invalid_request", status=400)
        payload = {"action": action, "expected_revision": expected_revision}
        with self._transaction():
            cached = self._receipt(f"action:{feature_id}", request_id, payload)
            if cached is not None:
                return cached
            feature = self._one("fm_features", feature_id)
            if expected_revision is not None:
                self._revision(feature, expected_revision)
            if feature["status"] in {"completed", "cancelled"}:
                raise FirstMateError("Feature is closed", code="feature_closed")
            status = {"pause": "paused", "cancel": "cancelled", "complete": "completed"}.get(action)
            if action == "resume":
                if feature["status"] not in {"paused", "blocked", "recovering"}:
                    raise FirstMateError("Feature is not paused")
                visit = self._one("fm_visits", feature["current_visit_id"]) if feature["current_visit_id"] else None
                status = "running" if visit and visit["status"] == "running" else ("awaiting_direction" if visit else "ready")
                paused = self._db.execute("SELECT * FROM fm_assignments WHERE feature_id=? AND status='paused'", (feature_id,)).fetchall()
                pending_gate = False
                for row in paused:
                    assignment = self._decode(row)
                    if assignment["metadata"].get("human_gate", {}).get("status") == "pending":
                        pending_gate = True
                        continue
                    live_session = self._db.execute("SELECT 1 FROM fm_sessions WHERE assignment_id=? AND status='active'", (assignment["id"],)).fetchone()
                    if not live_session:
                        self._db.execute("UPDATE fm_assignments SET status='queued',updated_at=? WHERE id=?", (_now(), assignment["id"]))
                if pending_gate:
                    status = "awaiting_direction"
            if action in {"cancel", "complete"}:
                active = self._db.execute("SELECT id FROM fm_assignments WHERE feature_id=? AND status IN ('dispatching','running','handoff_pending','awaiting_ack','recovering','waiting_children')", (feature_id,)).fetchone()
                live_session = self._db.execute("SELECT 1 FROM fm_sessions WHERE feature_id=? AND assignment_id IS NOT NULL AND status='active'", (feature_id,)).fetchone()
                if active or live_session:
                    raise FirstMateError("Active executors must be stopped before closing the feature", code="writer_not_stopped")
                self._db.execute("UPDATE fm_assignments SET status='cancelled',updated_at=? WHERE feature_id=? AND status IN ('queued','paused')", (_now(), feature_id))
                if action == "cancel" and feature["current_visit_id"]:
                    self._db.execute("UPDATE fm_visits SET status='cancelled',updated_at=? WHERE id=? AND status<>'completed'", (_now(), feature["current_visit_id"]))
            # Pause is an execution-control request. Running workers remain visible
            # until the runtime establishes a safe boundary and acknowledges it.
            self._db.execute("UPDATE fm_features SET status=?,updated_at=? WHERE id=?", (status, _now(), feature_id))
            self._event(feature_id, f"feature.{action}", f"Feature {status}", {"action": action, "revision": feature["revision"]})
            return self._save_receipt(f"action:{feature_id}", request_id, payload, self._one("fm_features", feature_id))

    def revise_feature(self, feature_id: str, goal: str, expected_revision: int, request_id: str, authorization_message_id: str, verified_stopped: bool = False, affected_assignment_ids: list[str] | None = None, carry_forward_evidence: dict | None = None) -> dict:
        if affected_assignment_ids is not None and (not isinstance(affected_assignment_ids, list) or not all(isinstance(value, str) for value in affected_assignment_ids) or len(set(affected_assignment_ids)) != len(affected_assignment_ids)):
            raise FirstMateError("Affected assignments must be unique explicit IDs", code="invalid_request", status=400)
        payload = {"goal": _text(goal, "goal"), "expected_revision": expected_revision, "authorization_message_id": authorization_message_id, "verified_stopped": verified_stopped, "affected_assignment_ids": affected_assignment_ids, "carry_forward_evidence": carry_forward_evidence or {}}
        with self._transaction():
            cached = self._receipt(f"revision:{feature_id}", request_id, payload)
            if cached is not None:
                return cached
            feature = self._one("fm_features", feature_id)
            self._revision(feature, expected_revision)
            authorization = self._one("fm_messages", authorization_message_id)
            if authorization["feature_id"] != feature_id or authorization["role"] != "user" or authorization["status"] not in {"processing", "done"}:
                raise FirstMateError("A processed human direction is required", code="human_direction_required")
            if feature["status"] in {"completed", "cancelled"}:
                raise FirstMateError("Feature is closed", code="feature_closed")
            if affected_assignment_ids is not None:
                return self._revise_selected(feature, goal, expected_revision, request_id, authorization_message_id, verified_stopped, affected_assignment_ids, carry_forward_evidence or {}, payload)
            active = self._db.execute("SELECT id FROM fm_assignments WHERE feature_id=? AND status IN ('dispatching','running','handoff_pending','awaiting_ack','recovering','waiting_children')", (feature_id,)).fetchall()
            if active and not verified_stopped:
                raise FirstMateError("Pause affected writers before replacing their plan", code="writer_not_stopped")
            # Initial implementation treats a changed feature goal as affecting the
            # whole current visit. It never moves old evidence to a newer revision.
            self._db.execute("UPDATE fm_assignments SET status='superseded',updated_at=? WHERE feature_id=? AND status NOT IN ('completed','failed','cancelled','superseded')", (_now(), feature_id))
            self._db.execute("UPDATE fm_sessions SET status='retained',updated_at=? WHERE feature_id=? AND assignment_id IS NOT NULL AND status IN ('active','quiesced')", (_now(), feature_id))
            self._db.execute("UPDATE fm_attempts SET status='superseded',updated_at=? WHERE assignment_id IN (SELECT id FROM fm_assignments WHERE feature_id=? AND status='superseded') AND status IN ('dispatching','running','handoff_pending','awaiting_ack')", (_now(), feature_id))
            self._db.execute("UPDATE fm_handoffs SET status='superseded',updated_at=? WHERE feature_id=? AND status NOT IN ('completed','failed')", (_now(), feature_id))
            if feature["current_visit_id"]:
                self._db.execute("UPDATE fm_visits SET status='superseded',updated_at=? WHERE id=? AND status<>'completed'", (_now(), feature["current_visit_id"]))
            self._db.execute("UPDATE fm_features SET goal=?,revision=revision+1,status='awaiting_direction',updated_at=? WHERE id=?", (goal, _now(), feature_id))
            self._event(feature_id, "feature.revised", "Human direction revised the feature plan", {"previous_revision": expected_revision, "revision": expected_revision + 1, "previous_goal": feature["goal"], "goal": goal, "authorization_message_id": authorization_message_id})
            return self._save_receipt(f"revision:{feature_id}", request_id, payload, self._one("fm_features", feature_id))




    def _revise_selected(self, feature: dict, goal: str, expected_revision: int, request_id: str, authorization_message_id: str, verified_stopped: bool, affected_assignment_ids: list[str], carry_forward_evidence: dict, payload: dict) -> dict:
        """Create a revised visit with explicit carry-forward execution membership.

        The execution's producer visit, input revision and documents are never
        rewritten. Membership is a separate human-authorized adoption of work.
        """
        if not feature["current_visit_id"]:
            raise FirstMateError("Selective revision requires an existing stage")
        if not isinstance(carry_forward_evidence, dict):
            raise FirstMateError("Invalid carry-forward evidence", code="invalid_request", status=400)
        previous_visit = self._one("fm_visits", feature["current_visit_id"])
        members = [self._one("fm_assignments", row[0]) for row in self._db.execute("SELECT assignment_id FROM fm_assignment_memberships WHERE visit_id=?", (previous_visit["id"],)).fetchall()]
        identities = {assignment["id"] for assignment in members}
        affected = set(affected_assignment_ids)
        if not affected.issubset(identities):
            raise FirstMateError("Affected assignment is outside the current visit", code="assignment_scope_mismatch")
        if self._db.execute("SELECT 1 FROM fm_visits WHERE authorization_message_id=?", (authorization_message_id,)).fetchone():
            raise FirstMateError("Human direction already authorized a visit", code="human_direction_required")
        for assignment in members:
            if assignment["id"] in affected:
                active_session = self._db.execute("SELECT 1 FROM fm_sessions WHERE assignment_id=? AND status='active'", (assignment["id"],)).fetchone()
                if not verified_stopped and (active_session or assignment["status"] in {"dispatching", "running", "handoff_pending", "awaiting_ack", "recovering", "waiting_children"}):
                    raise FirstMateError("Stop affected writers before revising their scope", code="writer_not_stopped")
            elif assignment["status"] == "completed":
                recorded_revision = assignment.get("code_revision") or assignment["metadata"].get("expected_code_revision")
                if recorded_revision and carry_forward_evidence.get(assignment["id"]) != recorded_revision:
                    raise FirstMateError("Completed work needs fresh matching code evidence before carry-forward", code="stale_code_revision")
        revision, visit_id, now = expected_revision + 1, _id("fmv"), _now()
        self._db.execute("INSERT INTO fm_visits(id,feature_id,stage_key,title,status,revision,authorization_message_id,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)", (visit_id, feature["id"], previous_visit["stage_key"], previous_visit["title"], "running", revision, authorization_message_id, now, now))
        carried = []
        for assignment in members:
            if assignment["id"] in affected:
                if assignment["status"] not in {"completed", "failed", "cancelled", "superseded"}:
                    self._db.execute("UPDATE fm_assignments SET status='superseded',updated_at=? WHERE id=?", (now, assignment["id"]))
                self._db.execute("UPDATE fm_sessions SET status='retained',updated_at=? WHERE assignment_id=? AND status IN ('active','quiesced')", (now, assignment["id"]))
                self._db.execute("UPDATE fm_attempts SET status='superseded',updated_at=? WHERE assignment_id=? AND status IN ('dispatching','running','handoff_pending','awaiting_ack','paused')", (now, assignment["id"]))
                self._db.execute("UPDATE fm_handoffs SET status='superseded',updated_at=? WHERE assignment_id=? AND status NOT IN ('completed','failed')", (now, assignment["id"]))
            else:
                self._db.execute("INSERT INTO fm_assignment_memberships VALUES(?,?,?,?,?,?)", (visit_id, assignment["id"], revision, authorization_message_id, previous_visit["id"], now))
                carried.append(assignment)
        self._db.execute("UPDATE fm_visits SET status='superseded',updated_at=? WHERE id=? AND status<>'completed'", (now, previous_visit["id"]))
        pending_gate = any(assignment["metadata"].get("human_gate", {}).get("status") == "pending" for assignment in carried)
        status = "awaiting_direction" if pending_gate else "running"
        self._db.execute("UPDATE fm_features SET goal=?,revision=?,status=?,current_visit_id=?,updated_at=? WHERE id=?", (goal, revision, status, visit_id, now, feature["id"]))
        self._event(feature["id"], "feature.revised_selectively", "Affected work revised; explicitly unaffected assignments continue", {"previous_revision": expected_revision, "revision": revision, "previous_goal": feature["goal"], "goal": goal, "authorization_message_id": authorization_message_id, "previous_visit_id": previous_visit["id"], "visit_id": visit_id, "affected_assignment_ids": affected_assignment_ids, "carried_assignment_ids": [assignment["id"] for assignment in carried], "carry_forward_evidence": carry_forward_evidence})
        return self._save_receipt(f"revision:{feature['id']}", request_id, payload, self._one("fm_features", feature["id"]))

    def request_human_gate(self, assignment_id: str, generation: int, native_session_id: str, reason: str, request_id: str) -> dict:
        """Pause an internal checkpoint without claiming the major stage is done."""
        payload = {"generation": generation, "native_session_id": native_session_id, "reason": _text(reason, "reason")}
        with self._transaction():
            cached = self._receipt(f"human_gate:{assignment_id}", request_id, payload)
            if cached is not None:
                return cached
            assignment = self._execution(assignment_id, generation, native_session_id)
            if assignment["status"] != "running":
                raise FirstMateError("Only a running assignment can request a human checkpoint")
            now = _now()
            gate = {"id": _id("fmg"), "status": "pending", "reason": reason, "created_at": now, "generation": generation, "native_session_id": native_session_id}
            metadata = {**assignment["metadata"], "human_gate": gate}
            self._db.execute("UPDATE fm_assignments SET status='paused',summary=?,metadata_json=?,updated_at=? WHERE id=?", (reason, _json(metadata), now, assignment_id))
            self._db.execute("UPDATE fm_attempts SET status='human_checkpoint',summary=?,updated_at=? WHERE assignment_id=? AND generation=?", (reason, now, assignment_id, generation))
            # The executor remains active until its observed stop is acknowledged.
            self._db.execute("UPDATE fm_features SET status='awaiting_direction' WHERE id=?", (assignment["feature_id"],))
            self._message(assignment["feature_id"], "system", "Human checkpoint: " + reason, metadata={"assignment_id": assignment_id, "human_gate": gate})
            self._event(assignment["feature_id"], "assignment.awaiting_human", reason, {"assignment_id": assignment_id, "human_gate": gate})
            return self._save_receipt(f"human_gate:{assignment_id}", request_id, payload, self._one("fm_assignments", assignment_id))

    def resolve_human_gate(self, assignment_id: str, authorization_message_id: str, instruction: str, request_id: str, verified_stopped: bool = False) -> dict:
        payload = {"authorization_message_id": authorization_message_id, "instruction": _text(instruction, "instruction"), "verified_stopped": verified_stopped}
        with self._transaction():
            cached = self._receipt(f"resolve_gate:{assignment_id}", request_id, payload)
            if cached is not None:
                return cached
            assignment = self._one("fm_assignments", assignment_id)
            feature = self._one("fm_features", assignment["feature_id"])
            self._assignment_revision(feature, assignment)
            gate = assignment["metadata"].get("human_gate", {})
            authorization = self._one("fm_messages", authorization_message_id)
            if gate.get("status") != "pending" or assignment["status"] != "paused":
                raise FirstMateError("Assignment has no pending human checkpoint")
            if authorization["feature_id"] != feature["id"] or authorization["role"] != "user" or authorization["status"] not in {"processing", "done"} or authorization["created_at"] <= gate["created_at"]:
                raise FirstMateError("This checkpoint requires subsequent human direction", code="human_direction_required")
            if not verified_stopped:
                raise FirstMateError("Verify the checkpoint worker stopped before continuation", code="writer_not_stopped")
            if feature["status"] in {"cancelled", "completed", "paused"}:
                raise FirstMateError("Feature cannot continue this checkpoint")
            gate = {**gate, "status": "resolved", "instruction": instruction, "authorization_message_id": authorization_message_id, "resolved_at": _now()}
            metadata = {**assignment["metadata"], "human_gate": gate}
            self._db.execute("UPDATE fm_sessions SET status='retained',updated_at=? WHERE assignment_id=? AND generation=?", (_now(), assignment_id, assignment["generation"]))
            self._db.execute("UPDATE fm_assignments SET status='queued',owner=NULL,prompt=?,metadata_json=?,updated_at=? WHERE id=?", (assignment["prompt"] + "\n\nHuman checkpoint direction:\n" + instruction, _json(metadata), _now(), assignment_id))
            other_gates = self._db.execute("SELECT metadata_json FROM fm_assignments WHERE feature_id=? AND id<>?", (feature["id"], assignment_id)).fetchall()
            if not any(json.loads(row["metadata_json"]).get("human_gate", {}).get("status") == "pending" for row in other_gates):
                self._db.execute("UPDATE fm_features SET status='running' WHERE id=?", (feature["id"],))
            self._event(feature["id"], "assignment.human_direction", "Human direction recorded for the internal checkpoint", {"assignment_id": assignment_id, "human_gate": gate})
            return self._save_receipt(f"resolve_gate:{assignment_id}", request_id, payload, self._one("fm_assignments", assignment_id))

    def retry_assignment(self, assignment_id: str, prompt: str, request_id: str, metadata: dict | None = None, verified_stopped: bool = False) -> dict:
        """Retry a reported review/fix result within its authorized stage.

        Repair attempts are separate from process recovery, but bounded by the
        default two attempts or a stricter recipe limit. Old attempt evidence is
        immutable. A successful retry replaces only the assignment's projection.
        """
        if metadata is not None and not isinstance(metadata, dict):
            raise FirstMateError("Invalid metadata", code="invalid_request", status=400)
        payload = {"prompt": _text(prompt, "prompt"), "metadata": metadata, "verified_stopped": verified_stopped}
        with self._transaction():
            cached = self._receipt(f"retry:{assignment_id}", request_id, payload)
            if cached is not None:
                return cached
            assignment = self._one("fm_assignments", assignment_id)
            feature = self._one("fm_features", assignment["feature_id"])
            self._assignment_revision(feature, assignment)
            if not verified_stopped:
                raise FirstMateError("Verify the prior worker stopped before retrying", code="writer_not_stopped")
            if assignment["status"] not in {"blocked", "failed"} or feature["status"] != "running":
                raise FirstMateError("Assignment is not available for an internal retry")
            previous_metadata = assignment["metadata"]
            if previous_metadata.get("human_gate", {}).get("status") == "pending":
                raise FirstMateError("The internal checkpoint requires human direction", code="human_direction_required")
            if metadata is not None and metadata.get("parent_assignment_id", previous_metadata.get("parent_assignment_id")) != previous_metadata.get("parent_assignment_id"):
                raise FirstMateError("Parent assignment identity cannot change", code="assignment_scope_mismatch")
            merged = {**previous_metadata, **(metadata or {})}
            repair_count = int(previous_metadata.get("repair_count", 0)) + 1
            requested_limit = previous_metadata.get("max_repair_attempts", 2)
            if isinstance(requested_limit, bool) or not isinstance(requested_limit, int) or requested_limit < 0:
                raise FirstMateError("Invalid repair limit", code="invalid_request", status=400)
            limit = min(2, requested_limit)
            merged["repair_count"] = repair_count
            merged["max_repair_attempts"] = limit
            status = "queued" if repair_count <= limit else "blocked"
            self._db.execute("UPDATE fm_sessions SET status='retained',updated_at=? WHERE assignment_id=? AND generation=?", (_now(), assignment_id, assignment["generation"]))
            self._db.execute("UPDATE fm_assignments SET status=?,owner=NULL,prompt=?,verdict=NULL,metadata_json=?,updated_at=? WHERE id=?", (status, prompt, _json(merged), _now(), assignment_id))
            if status == "blocked":
                self._db.execute("UPDATE fm_features SET status='blocked' WHERE id=?", (feature["id"],))
                self._message(feature["id"], "system", "Internal repair limit reached. Awaiting human direction.", metadata={"assignment_id": assignment_id, "repair_count": repair_count})
            self._event(feature["id"], "assignment.retry_queued" if status == "queued" else "assignment.repair_exhausted", "Internal repair queued" if status == "queued" else "Internal repair limit reached", {"assignment_id": assignment_id, "repair_count": repair_count, "previous_verdict": assignment["verdict"], "metadata": merged})
            return self._save_receipt(f"retry:{assignment_id}", request_id, payload, self._one("fm_assignments", assignment_id))

    def recover_assignment(self, assignment_id: str, generation: int, reason: str, request_id: str, verified_stopped: bool = False) -> dict:
        payload = {"generation": generation, "reason": _text(reason, "reason"), "verified_stopped": verified_stopped}
        with self._transaction():
            cached = self._receipt(f"recover:{assignment_id}", request_id, payload)
            if cached is not None:
                return cached
            assignment = self._execution(assignment_id, generation)
            if not verified_stopped:
                raise FirstMateError("Verify execution stopped before recovery", code="writer_not_stopped")
            if assignment["status"] in {"completed", "cancelled", "superseded", "queued"}:
                raise FirstMateError("Execution is not recoverable")
            count = assignment["recovery_count"] + 1
            status = "queued" if count <= 2 else "blocked"
            self._db.execute("UPDATE fm_attempts SET status='interrupted',summary=?,updated_at=? WHERE assignment_id=? AND generation=?", (reason, _now(), assignment_id, generation))
            self._db.execute("UPDATE fm_sessions SET status='retained',updated_at=? WHERE assignment_id=? AND generation=?", (_now(), assignment_id, generation))
            self._db.execute("UPDATE fm_assignments SET status=?,owner=NULL,recovery_count=?,summary=?,verdict=NULL,updated_at=? WHERE id=?", (status, count, reason, _now(), assignment_id))
            self._db.execute("UPDATE fm_handoffs SET status='failed',updated_at=? WHERE assignment_id=? AND status<>'completed'", (_now(), assignment_id))
            if status == "queued":
                self._db.execute("UPDATE fm_features SET status='running' WHERE id=? AND status='recovering' AND NOT EXISTS (SELECT 1 FROM fm_assignments WHERE feature_id=? AND status='recovering')", (assignment["feature_id"], assignment["feature_id"]))
            if status == "blocked":
                self._db.execute("UPDATE fm_features SET status='blocked' WHERE id=?", (assignment["feature_id"],))
                self._message(assignment["feature_id"], "system", "Recovery limit reached: " + reason, metadata={"assignment_id": assignment_id, "recovery_count": count})
            self._event(assignment["feature_id"], "assignment.recovery_queued" if status == "queued" else "assignment.recovery_exhausted", reason, {"assignment_id": assignment_id, "generation": generation, "recovery_count": count})
            return self._save_receipt(f"recover:{assignment_id}", request_id, payload, self._one("fm_assignments", assignment_id))

    def begin_handoff(self, assignment_id: str, generation: int, request_id: str, summary: str) -> dict:
        payload = {"generation": generation, "summary": _text(summary, "summary")}
        with self._transaction():
            cached = self._receipt(f"handoff:{assignment_id}", request_id, payload)
            if cached is not None:
                return cached
            assignment = self._execution(assignment_id, generation)
            if assignment["status"] != "running" or not assignment["native_session_id"]:
                raise FirstMateError("Only a running session can hand off")
            document = self._document(assignment, "Session handoff", summary)
            handoff_id, now = _id("fmh"), _now()
            self._db.execute("INSERT INTO fm_handoffs(id,assignment_id,feature_id,predecessor_generation,predecessor_session_id,summary,document_id,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)", (handoff_id, assignment_id, assignment["feature_id"], generation, assignment["native_session_id"], summary, document["id"], "checkpointed", now, now))
            self._db.execute("UPDATE fm_assignments SET status='handoff_pending',updated_at=? WHERE id=?", (now, assignment_id))
            self._db.execute("UPDATE fm_attempts SET status='handoff_pending',updated_at=? WHERE assignment_id=? AND generation=?", (now, assignment_id, generation))
            self._event(assignment["feature_id"], "handoff.checkpointed", "Handoff document retained; awaiting successor", {"handoff_id": handoff_id, "document_id": document["id"], "native_session_id": assignment["native_session_id"]})
            return self._save_receipt(f"handoff:{assignment_id}", request_id, payload, self._one("fm_handoffs", handoff_id))

    def bind_handoff_successor(self, handoff_id: str, native_session_id: str, session_file: str, owner: str, request_id: str, verified_predecessor_stopped: bool = False) -> dict:
        payload = {"native_session_id": native_session_id, "session_file": session_file, "owner": owner, "verified_predecessor_stopped": verified_predecessor_stopped}
        with self._transaction():
            cached = self._receipt(f"handoff_successor:{handoff_id}", request_id, payload)
            if cached is not None:
                return cached
            if not verified_predecessor_stopped:
                raise FirstMateError("Predecessor writer must be quiescent before successor starts", code="writer_not_stopped")
            handoff = self._one("fm_handoffs", handoff_id)
            assignment = self._execution(handoff["assignment_id"], handoff["predecessor_generation"])
            if handoff["status"] != "checkpointed" or assignment["status"] != "handoff_pending":
                raise FirstMateError("Handoff is not awaiting a successor")
            generation, attempt = assignment["generation"] + 1, assignment["attempt"] + 1
            dispatch_id, now = _id("fmd"), _now()
            self._register_session(native_session_id, assignment["feature_id"], assignment["id"], generation, owner, session_file)
            self._db.execute("UPDATE fm_sessions SET status='quiesced',updated_at=? WHERE native_session_id=?", (now, handoff["predecessor_session_id"]))
            self._db.execute("UPDATE fm_assignments SET status='awaiting_ack',generation=?,attempt=?,dispatch_id=?,owner=?,native_session_id=?,session_file=?,run_id=NULL,updated_at=? WHERE id=?", (generation, attempt, dispatch_id, owner, native_session_id, session_file, now, assignment["id"]))
            self._db.execute("INSERT INTO fm_attempts(id,assignment_id,attempt,generation,input_revision,dispatch_id,owner,status,native_session_id,session_file,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", (_id("fmx"), assignment["id"], attempt, generation, assignment["input_revision"], dispatch_id, owner, "awaiting_ack", native_session_id, session_file, now, now))
            self._db.execute("UPDATE fm_handoffs SET successor_session_id=?,successor_session_file=?,successor_owner=?,status='awaiting_ack',updated_at=? WHERE id=?", (native_session_id, session_file, owner, now, handoff_id))
            self._event(assignment["feature_id"], "handoff.successor_started", "Successor must acknowledge the handoff before taking ownership", {"handoff_id": handoff_id, "generation": generation, "native_session_id": native_session_id, "predecessor_session_id": handoff["predecessor_session_id"]})
            return self._save_receipt(f"handoff_successor:{handoff_id}", request_id, payload, self._one("fm_assignments", assignment["id"]))

    def acknowledge_handoff(self, handoff_id: str, native_session_id: str, generation: int, request_id: str) -> dict:
        payload = {"native_session_id": native_session_id, "generation": generation}
        with self._transaction():
            cached = self._receipt(f"handoff_ack:{handoff_id}", request_id, payload)
            if cached is not None:
                return cached
            handoff = self._one("fm_handoffs", handoff_id)
            assignment = self._execution(handoff["assignment_id"], generation, native_session_id)
            if handoff["status"] != "awaiting_ack" or assignment["status"] != "awaiting_ack" or handoff["successor_session_id"] != native_session_id:
                raise FirstMateError("Handoff acknowledgement does not match its successor", code="session_mismatch")
            now = _now()
            self._db.execute("UPDATE fm_handoffs SET status='completed',updated_at=? WHERE id=?", (now, handoff_id))
            self._db.execute("UPDATE fm_assignments SET status='running',updated_at=? WHERE id=?", (now, assignment["id"]))
            self._db.execute("UPDATE fm_attempts SET status='running',updated_at=? WHERE assignment_id=? AND generation=?", (now, assignment["id"], generation))
            self._db.execute("UPDATE fm_attempts SET status='handed_off',updated_at=? WHERE assignment_id=? AND generation=?", (now, assignment["id"], handoff["predecessor_generation"]))
            self._db.execute("UPDATE fm_sessions SET status='retained',updated_at=? WHERE native_session_id=?", (now, handoff["predecessor_session_id"]))
            self._event(assignment["feature_id"], "handoff.acknowledged", "Successor verified the handoff; predecessor can be retired", {"handoff_id": handoff_id, "native_session_id": native_session_id, "predecessor_session_id": handoff["predecessor_session_id"]})
            return self._save_receipt(f"handoff_ack:{handoff_id}", request_id, payload, self._one("fm_assignments", assignment["id"]))


    def acknowledge_stopped(self, assignment_id: str, generation: int, request_id: str, status: str = "paused", reason: str = "Execution stopped") -> dict:
        """Record the runtime's verified process-stop acknowledgement, never a timer."""
        if status not in {"paused", "cancelled"}:
            raise FirstMateError("Invalid stopped status", code="invalid_request", status=400)
        payload = {"generation": generation, "status": status, "reason": _text(reason, "reason")}
        with self._transaction():
            cached = self._receipt(f"stopped:{assignment_id}", request_id, payload)
            if cached is not None:
                return cached
            assignment = self._execution(assignment_id, generation)
            if assignment["status"] in {"completed", "cancelled", "superseded"}:
                raise FirstMateError("Execution already settled", code="outcome_already_settled")
            now = _now()
            self._db.execute("UPDATE fm_assignments SET status=?,owner=NULL,summary=?,updated_at=? WHERE id=?", (status, reason, now, assignment_id))
            self._db.execute("UPDATE fm_attempts SET status=?,summary=?,updated_at=? WHERE assignment_id=? AND generation=?", (status, reason, now, assignment_id, generation))
            self._db.execute("UPDATE fm_sessions SET status='retained',updated_at=? WHERE assignment_id=? AND generation=?", (now, assignment_id, generation))
            self._db.execute("UPDATE fm_handoffs SET status='failed',updated_at=? WHERE assignment_id=? AND status NOT IN ('completed','failed')", (now, assignment_id))
            self._event(assignment["feature_id"], "assignment.stopped", reason, {"assignment_id": assignment_id, "generation": generation, "status": status})
            return self._save_receipt(f"stopped:{assignment_id}", request_id, payload, self._one("fm_assignments", assignment_id))

    def mark_dispatch_unknown(self, assignment_id: str, generation: int, reason: str, request_id: str) -> dict:
        payload = {"generation": generation, "reason": _text(reason, "reason")}
        with self._transaction():
            cached = self._receipt(f"dispatch_unknown:{assignment_id}", request_id, payload)
            if cached is not None:
                return cached
            assignment = self._execution(assignment_id, generation)
            if assignment["status"] not in {"dispatching", "running", "recovering", "awaiting_ack", "handoff_pending"}:
                raise FirstMateError("Execution is not unresolved")
            self._db.execute("UPDATE fm_assignments SET status='recovering',summary=?,updated_at=? WHERE id=?", (reason, _now(), assignment_id))
            self._db.execute("UPDATE fm_features SET status='recovering' WHERE id=? AND status NOT IN ('paused','cancelled','completed')", (assignment["feature_id"],))
            self._event(assignment["feature_id"], "assignment.dispatch_unknown", reason, {"assignment_id": assignment_id, "generation": generation, "dispatch_id": assignment["dispatch_id"], "replay_allowed": False})
            return self._save_receipt(f"dispatch_unknown:{assignment_id}", request_id, payload, self._one("fm_assignments", assignment_id))

    def list_attempts(self, assignment_id: str) -> list[dict]:
        with self._lock:
            self._one("fm_assignments", assignment_id)
            return [self._decode(row) for row in self._db.execute("SELECT * FROM fm_attempts WHERE assignment_id=? ORDER BY generation", (assignment_id,))]

    def pending_messages(self, feature_id: str | None = None) -> list[dict]:
        with self._lock:
            sql = "SELECT * FROM fm_messages WHERE status IN ('queued','processing')"
            args = ()
            if feature_id:
                sql += " AND feature_id=?"
                args = (feature_id,)
            return [self._decode(row) for row in self._db.execute(sql + " ORDER BY created_at,id", args)]


# Repository alias keeps service code consistent with other durable stores.
FirstMateRepository = FirstMateStore
