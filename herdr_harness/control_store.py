"""Private durable state for agent control receivers and idempotent operations."""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import sqlite3
import stat
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional

from .chat_tab_colors import (
    CHAT_TAB_STALE_SECONDS,
    MAX_CHAT_TAB_PUBLISHERS,
    disable_relay_actions,
    disabled_action_reason,
)
from .control_validation import ControlError, canonical_json, validate_parameters


ONLINE_SECONDS = 15.0
RUNNING_DEADLINE_SECONDS = 5 * 60.0
RETENTION_SECONDS = 30 * 24 * 60 * 60.0
MAX_CLIENTS = 512
MAX_PENDING_PER_CLIENT = 64
MAX_PENDING_TOTAL = 4096
MAX_COMMANDS = 10_000
MAX_OPERATIONS = 10_000

_SCHEMA = """
CREATE TABLE IF NOT EXISTS control_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS control_clients (
 client_id TEXT PRIMARY KEY, name TEXT NOT NULL, receiver_hash TEXT NOT NULL,
 instance_id TEXT NOT NULL, state_json TEXT NOT NULL, actions_json TEXT NOT NULL,
 last_seen REAL NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS control_commands (
 request_id TEXT PRIMARY KEY, client_id TEXT NOT NULL, instance_id TEXT NOT NULL,
 payload_json TEXT NOT NULL, action TEXT NOT NULL, target_json TEXT,
 parameters_json TEXT NOT NULL, expected_revision INTEGER,
 status TEXT NOT NULL, created_at REAL NOT NULL, expires_at REAL NOT NULL,
 running_at REAL, updated_at REAL NOT NULL, result_json TEXT, error_json TEXT,
 ack_json TEXT
);
CREATE INDEX IF NOT EXISTS control_commands_client_status
 ON control_commands(client_id,status,created_at,request_id);
CREATE TABLE IF NOT EXISTS control_operations (
 request_id TEXT PRIMARY KEY, payload_json TEXT NOT NULL, action TEXT NOT NULL,
 status TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
 result_json TEXT, error_json TEXT
);
CREATE INDEX IF NOT EXISTS control_operations_status_updated
 ON control_operations(status,updated_at);
CREATE TABLE IF NOT EXISTS control_chat_tab_publishers (
 client_id TEXT PRIMARY KEY, server_id TEXT NOT NULL, publisher_hash TEXT NOT NULL,
 platform TEXT NOT NULL, client_name TEXT NOT NULL, enabled INTEGER NOT NULL,
 revision INTEGER NOT NULL, payload_json TEXT NOT NULL, tabs_json TEXT NOT NULL,
 published_at REAL NOT NULL, last_seen REAL NOT NULL, created_at REAL NOT NULL
);
"""


def _iso(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace("+00:00", "Z")


def _loads(value: Optional[str]) -> Any:
    return json.loads(value) if value is not None else None


class ControlStore:
    """SQLite-backed relay. Receiver credentials are retained only as SHA-256 hashes."""

    def __init__(self, path: str | Path, *, clock: Callable[[], float] = time.time) -> None:
        self.path = self._prepare_path(path)
        self.clock = clock
        self._db = sqlite3.connect(self.path, check_same_thread=False, isolation_level=None)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.RLock()
        with self._lock:
            self._db.execute("PRAGMA busy_timeout=5000")
            if self.path != ":memory:":
                self._db.execute("PRAGMA journal_mode=WAL")
                self._db.execute("PRAGMA synchronous=FULL")
            self._db.executescript(_SCHEMA)
            self._secure_database_files()
            self._db.execute("BEGIN IMMEDIATE")
            try:
                row = self._db.execute("SELECT value FROM control_meta WHERE key='server_id'").fetchone()
                if row is None:
                    server_id = "srv_" + str(uuid.uuid4())
                    self._db.execute(
                        "INSERT INTO control_meta(key,value) VALUES('server_id',?)", (server_id,)
                    )
                now = self.clock()
                self._db.execute(
                    """UPDATE control_operations SET status='outcome_unknown',updated_at=?,
                       error_json=? WHERE status='reserved'""",
                    (
                        now,
                        canonical_json(
                            {
                                "code": "server_restarted",
                                "message": "The server restarted before the operation outcome was recorded",
                            }
                        ),
                    ),
                )
                self._db.execute("COMMIT")
                self._secure_database_files()
            except Exception:
                self._db.execute("ROLLBACK")
                raise

    @staticmethod
    def _prepare_path(path: str | Path) -> str:
        if str(path) == ":memory:":
            return ":memory:"
        destination = Path(os.path.abspath(os.path.expanduser(str(path))))
        parent = destination.parent
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            parent_metadata = os.lstat(parent)
        except OSError as exc:
            raise ControlError(
                "Control database directory could not be inspected",
                code="control_store_unsafe",
                status=500,
            ) from exc
        if stat.S_ISLNK(parent_metadata.st_mode) or not stat.S_ISDIR(parent_metadata.st_mode):
            raise ControlError(
                "Control database directory is unsafe", code="control_store_unsafe", status=500
            )
        if hasattr(os, "getuid") and parent_metadata.st_uid != os.getuid():
            raise ControlError(
                "Control database directory belongs to another user",
                code="control_store_unsafe",
                status=500,
            )
        try:
            os.chmod(parent, 0o700)
        except OSError as exc:
            raise ControlError(
                "Control database directory could not be secured",
                code="control_store_unsafe",
                status=500,
            ) from exc
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(destination, flags, 0o600)
        except OSError as exc:
            raise ControlError(
                "Control database path is unsafe", code="control_store_unsafe", status=500
            ) from exc
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise ControlError(
                    "Control database path is unsafe", code="control_store_unsafe", status=500
                )
            if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
                raise ControlError(
                    "Control database belongs to another user",
                    code="control_store_unsafe",
                    status=500,
                )
            os.fchmod(descriptor, 0o600)
        finally:
            os.close(descriptor)
        return str(destination)

    def _secure_database_files(self) -> None:
        if self.path == ":memory:":
            return
        for candidate in (self.path, f"{self.path}-wal", f"{self.path}-shm"):
            try:
                metadata = os.lstat(candidate)
                if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                    raise ControlError(
                        "Control database file is unsafe", code="control_store_unsafe", status=500
                    )
                if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
                    raise ControlError(
                        "Control database file belongs to another user",
                        code="control_store_unsafe",
                        status=500,
                    )
                os.chmod(candidate, 0o600)
                metadata = os.lstat(candidate)
            except FileNotFoundError:
                continue
            if stat.S_IMODE(metadata.st_mode) & 0o077:
                raise ControlError(
                    "Control database permissions are unsafe",
                    code="control_store_unsafe",
                    status=500,
                )

    @property
    def server_id(self) -> str:
        with self._lock:
            row = self._db.execute("SELECT value FROM control_meta WHERE key='server_id'").fetchone()
            return str(row["value"])

    def close(self) -> None:
        with self._lock:
            self._db.close()

    @staticmethod
    def _receiver_hash(token: str) -> str:
        return hashlib.sha256(token.encode("ascii")).hexdigest()

    @staticmethod
    def _publisher_hash(token: str) -> str:
        return hashlib.sha256(token.encode("ascii")).hexdigest()

    @staticmethod
    def _public_client(row: sqlite3.Row, now: float) -> dict:
        return {
            "clientId": row["client_id"],
            "name": row["name"],
            "instanceId": row["instance_id"],
            "online": now - float(row["last_seen"]) <= ONLINE_SECONDS,
            "lastSeenAt": _iso(float(row["last_seen"])),
            "state": _loads(row["state_json"]),
            "actions": disable_relay_actions(_loads(row["actions_json"])),
        }

    def _require_receiver(self, client_id: str, token: str, instance_id: str) -> sqlite3.Row:
        row = self._db.execute(
            "SELECT * FROM control_clients WHERE client_id=?", (client_id,)
        ).fetchone()
        digest = self._receiver_hash(token)
        if row is None or not hmac.compare_digest(str(row["receiver_hash"]), digest):
            raise ControlError(
                "Receiver credentials are invalid", code="receiver_unauthorized", status=401
            )
        if row["instance_id"] != instance_id:
            raise ControlError(
                "Receiver instance is stale", code="stale_receiver_instance", status=409
            )
        return row

    def _cleanup_locked(self, now: float) -> None:
        expired_error = canonical_json(
            {"code": "expired", "message": "The command expired before it was claimed"}
        )
        unknown_error = canonical_json(
            {
                "code": "receiver_timeout",
                "message": "The receiver did not report a terminal outcome before the deadline",
            }
        )
        self._db.execute(
            """UPDATE control_commands SET status='expired',error_json=?,updated_at=?
               WHERE status='accepted' AND expires_at<=?""",
            (expired_error, now, now),
        )
        self._db.execute(
            """UPDATE control_commands SET status='outcome_unknown',error_json=?,updated_at=?
               WHERE status='running' AND running_at<=?""",
            (unknown_error, now, now - RUNNING_DEADLINE_SECONDS),
        )
        cutoff = now - RETENTION_SECONDS
        self._db.execute(
            "DELETE FROM control_commands WHERE status IN ('completed','failed','expired','outcome_unknown') AND updated_at<?",
            (cutoff,),
        )
        self._db.execute(
            "DELETE FROM control_operations WHERE status IN ('completed','failed','outcome_unknown') AND updated_at<?",
            (cutoff,),
        )

    def register(
        self,
        *,
        client_id: str,
        name: str,
        receiver_token: str,
        instance_id: str,
        state: dict,
        actions: list[dict],
    ) -> dict:
        now = self.clock()
        digest = self._receiver_hash(receiver_token)
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                self._cleanup_locked(now)
                row = self._db.execute(
                    "SELECT * FROM control_clients WHERE client_id=?", (client_id,)
                ).fetchone()
                if row is None:
                    count = self._db.execute("SELECT COUNT(*) FROM control_clients").fetchone()[0]
                    if count >= MAX_CLIENTS:
                        self._db.execute(
                            """DELETE FROM control_clients WHERE client_id IN (
                                SELECT c.client_id FROM control_clients c
                                WHERE c.last_seen<? AND NOT EXISTS(
                                  SELECT 1 FROM control_commands q WHERE q.client_id=c.client_id
                                  AND q.status IN ('accepted','running'))
                                ORDER BY c.last_seen LIMIT ?)
                            """,
                            (now - RETENTION_SECONDS, max(1, count - MAX_CLIENTS + 1)),
                        )
                        count = self._db.execute("SELECT COUNT(*) FROM control_clients").fetchone()[0]
                    if count >= MAX_CLIENTS:
                        raise ControlError(
                            "The receiver registry is full", code="receiver_capacity", status=503
                        )
                    self._db.execute(
                        """INSERT INTO control_clients
                           (client_id,name,receiver_hash,instance_id,state_json,actions_json,last_seen,created_at,updated_at)
                           VALUES(?,?,?,?,?,?,?,?,?)""",
                        (
                            client_id,
                            name,
                            digest,
                            instance_id,
                            canonical_json(state),
                            canonical_json(actions),
                            now,
                            now,
                            now,
                        ),
                    )
                else:
                    if not hmac.compare_digest(str(row["receiver_hash"]), digest):
                        raise ControlError(
                            "Receiver credentials are invalid",
                            code="receiver_unauthorized",
                            status=401,
                        )
                    if row["instance_id"] != instance_id:
                        self._invalidate_instance_locked(client_id, str(row["instance_id"]), now)
                    self._db.execute(
                        """UPDATE control_clients SET name=?,instance_id=?,state_json=?,actions_json=?,
                           last_seen=?,updated_at=? WHERE client_id=?""",
                        (
                            name,
                            instance_id,
                            canonical_json(state),
                            canonical_json(actions),
                            now,
                            now,
                            client_id,
                        ),
                    )
                public = self._public_client(
                    self._db.execute(
                        "SELECT * FROM control_clients WHERE client_id=?", (client_id,)
                    ).fetchone(),
                    now,
                )
                self._db.execute("COMMIT")
                return public
            except Exception:
                self._db.execute("ROLLBACK")
                raise

    def _invalidate_instance_locked(self, client_id: str, instance_id: str, now: float) -> None:
        self._db.execute(
            """UPDATE control_commands SET status='expired',updated_at=?,error_json=?
               WHERE client_id=? AND instance_id=? AND status='accepted'""",
            (
                now,
                canonical_json(
                    {"code": "receiver_restarted", "message": "The receiver restarted before claiming the command"}
                ),
                client_id,
                instance_id,
            ),
        )
        self._db.execute(
            """UPDATE control_commands SET status='outcome_unknown',updated_at=?,error_json=?
               WHERE client_id=? AND instance_id=? AND status='running'""",
            (
                now,
                canonical_json(
                    {"code": "receiver_restarted", "message": "The receiver restarted while the command was running"}
                ),
                client_id,
                instance_id,
            ),
        )

    def clients(self) -> list[dict]:
        now = self.clock()
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                self._cleanup_locked(now)
                rows = self._db.execute(
                    "SELECT * FROM control_clients ORDER BY name,client_id"
                ).fetchall()
                result = [self._public_client(row, now) for row in rows]
                self._db.execute("COMMIT")
                return result
            except Exception:
                self._db.execute("ROLLBACK")
                raise

    def client(self, client_id: str) -> dict:
        now = self.clock()
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM control_clients WHERE client_id=?", (client_id,)
            ).fetchone()
            if row is None:
                raise ControlError("UI client not found", code="not_found", status=404)
            return self._public_client(row, now)

    @staticmethod
    def _command(row: sqlite3.Row) -> dict:
        result: dict[str, Any] = {
            "requestId": row["request_id"],
            "clientId": row["client_id"],
            "instanceId": row["instance_id"],
            "action": row["action"],
            "parameters": _loads(row["parameters_json"]),
            "status": row["status"],
            "createdAt": _iso(float(row["created_at"])),
            "expiresAt": _iso(float(row["expires_at"])),
        }
        if row["target_json"] is not None:
            result["target"] = _loads(row["target_json"])
        if row["expected_revision"] is not None:
            result["expectedRevision"] = int(row["expected_revision"])
        if row["result_json"] is not None:
            result["result"] = _loads(row["result_json"])
        if row["error_json"] is not None:
            result["error"] = _loads(row["error_json"])
        return result

    def enqueue(
        self,
        *,
        client_id: str,
        request_id: str,
        action: str,
        target: Optional[dict],
        parameters: dict,
        expected_revision: Optional[int],
        ttl_seconds: int,
        payload: dict,
    ) -> dict:
        now = self.clock()
        payload_json = canonical_json({"clientId": client_id, "command": payload})
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                self._cleanup_locked(now)
                existing = self._db.execute(
                    "SELECT * FROM control_commands WHERE request_id=?", (request_id,)
                ).fetchone()
                if existing is not None:
                    if existing["payload_json"] != payload_json:
                        raise ControlError(
                            "requestId was already used for a different command",
                            code="request_conflict",
                            status=409,
                        )
                    command = self._command(existing)
                    self._db.execute("COMMIT")
                    return command
                client = self._db.execute(
                    "SELECT * FROM control_clients WHERE client_id=?", (client_id,)
                ).fetchone()
                if client is None:
                    raise ControlError("UI client not found", code="not_found", status=404)
                relay_disabled = disabled_action_reason(action)
                if relay_disabled is not None:
                    raise ControlError(relay_disabled, code="action_disabled", status=409)
                public = self._public_client(client, now)
                state = public["state"]
                if state.get("enabled") is not True:
                    raise ControlError(
                        "Agent control is disabled by the UI client",
                        code="action_disabled",
                        status=409,
                    )
                descriptor = next(
                    (item for item in public["actions"] if item.get("id") == action), None
                )
                if descriptor is None:
                    raise ControlError(
                        "The UI client does not support this action",
                        code="unsupported_action",
                        status=409,
                    )
                if descriptor.get("enabled") is not True:
                    raise ControlError(
                        str(descriptor.get("disabledReason") or "The UI action is disabled"),
                        code="action_disabled",
                        status=409,
                    )
                validate_parameters(parameters, descriptor["parameters"])
                if target is not None and target.get("serverId") not in {None, self.server_id}:
                    raise ControlError(
                        "Target belongs to another server", code="stale_target", status=409
                    )
                target_kinds = descriptor.get("targetKinds") or []
                if target_kinds and (target is None or target.get("kind") not in target_kinds):
                    raise ControlError("Command target kind is invalid")
                if not target_kinds and target is not None:
                    raise ControlError("This command does not accept a target")
                selection = state.get("selection") if isinstance(state, dict) else None
                if target is not None and selection == target and expected_revision is None:
                    raise ControlError(
                        "A current-target command requires expectedRevision",
                        code="expected_revision_required",
                        status=409,
                    )
                if expected_revision is not None and expected_revision != state.get("revision"):
                    raise ControlError(
                        "UI state revision is stale", code="stale_revision", status=409
                    )
                if not public["online"]:
                    raise ControlError("UI client is offline", code="receiver_offline", status=409)
                pending = self._db.execute(
                    """SELECT COUNT(*) FROM control_commands
                       WHERE client_id=? AND status IN ('accepted','running')""",
                    (client_id,),
                ).fetchone()[0]
                total_pending = self._db.execute(
                    "SELECT COUNT(*) FROM control_commands WHERE status IN ('accepted','running')"
                ).fetchone()[0]
                total_commands = self._db.execute("SELECT COUNT(*) FROM control_commands").fetchone()[0]
                if (
                    pending >= MAX_PENDING_PER_CLIENT
                    or total_pending >= MAX_PENDING_TOTAL
                    or total_commands >= MAX_COMMANDS
                ):
                    raise ControlError(
                        "The UI command queue is full", code="command_queue_full", status=429
                    )
                expires_at = now + ttl_seconds
                self._db.execute(
                    """INSERT INTO control_commands
                       (request_id,client_id,instance_id,payload_json,action,target_json,parameters_json,
                        expected_revision,status,created_at,expires_at,updated_at)
                       VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (
                        request_id,
                        client_id,
                        client["instance_id"],
                        payload_json,
                        action,
                        canonical_json(target) if target is not None else None,
                        canonical_json(parameters),
                        expected_revision,
                        "accepted",
                        now,
                        expires_at,
                        now,
                    ),
                )
                row = self._db.execute(
                    "SELECT * FROM control_commands WHERE request_id=?", (request_id,)
                ).fetchone()
                self._db.execute("COMMIT")
                return self._command(row)
            except Exception:
                self._db.execute("ROLLBACK")
                raise

    def poll(
        self,
        *,
        client_id: str,
        receiver_token: str,
        instance_id: str,
        state: dict,
        actions: Optional[list[dict]],
    ) -> Optional[dict]:
        now = self.clock()
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                self._cleanup_locked(now)
                row = self._require_receiver(client_id, receiver_token, instance_id)
                self._db.execute(
                    """UPDATE control_clients SET state_json=?,actions_json=?,last_seen=?,updated_at=?
                       WHERE client_id=?""",
                    (
                        canonical_json(state),
                        canonical_json(actions) if actions is not None else row["actions_json"],
                        now,
                        now,
                        client_id,
                    ),
                )
                running = self._db.execute(
                    "SELECT 1 FROM control_commands WHERE client_id=? AND status='running' LIMIT 1",
                    (client_id,),
                ).fetchone()
                command = None
                if running is None and state.get("enabled") is True:
                    while True:
                        selected = self._db.execute(
                            """SELECT request_id,action FROM control_commands
                               WHERE client_id=? AND instance_id=? AND status='accepted'
                               ORDER BY created_at,request_id LIMIT 1""",
                            (client_id, instance_id),
                        ).fetchone()
                        if selected is None:
                            break
                        relay_disabled = disabled_action_reason(str(selected["action"]))
                        if relay_disabled is not None:
                            # Previously queued commands for an action that became
                            # read-only are terminally refused instead of claimed.
                            self._db.execute(
                                """UPDATE control_commands SET status='failed',error_json=?,updated_at=?
                                   WHERE request_id=? AND status='accepted'""",
                                (
                                    canonical_json(
                                        {"code": "action_disabled", "message": relay_disabled}
                                    ),
                                    now,
                                    selected["request_id"],
                                ),
                            )
                            continue
                        self._db.execute(
                            """UPDATE control_commands SET status='running',running_at=?,updated_at=?
                               WHERE request_id=? AND status='accepted'""",
                            (now, now, selected["request_id"]),
                        )
                        claimed = self._db.execute(
                            "SELECT * FROM control_commands WHERE request_id=?",
                            (selected["request_id"],),
                        ).fetchone()
                        command = self._command(claimed)
                        break
                self._db.execute("COMMIT")
                return command
            except Exception:
                self._db.execute("ROLLBACK")
                raise

    def command(self, request_id: str) -> dict:
        now = self.clock()
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                self._cleanup_locked(now)
                row = self._db.execute(
                    "SELECT * FROM control_commands WHERE request_id=?", (request_id,)
                ).fetchone()
                if row is None:
                    raise ControlError("Command not found", code="not_found", status=404)
                result = self._command(row)
                self._db.execute("COMMIT")
                return result
            except Exception:
                self._db.execute("ROLLBACK")
                raise

    def acknowledge(
        self,
        *,
        client_id: str,
        request_id: str,
        receiver_token: str,
        instance_id: str,
        status: str,
        result: Optional[dict],
        error: Optional[dict],
        state: dict,
        acknowledgement: dict,
    ) -> dict:
        now = self.clock()
        # The terminal outcome is immutable, but state is ephemeral heartbeat
        # metadata and may legitimately change when a lost acknowledgement is retried.
        ack_json = canonical_json(
            {
                "instanceId": instance_id,
                "status": status,
                **({"result": result} if result is not None else {}),
                **({"error": error} if error is not None else {}),
            }
        )
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                self._cleanup_locked(now)
                self._require_receiver(client_id, receiver_token, instance_id)
                row = self._db.execute(
                    "SELECT * FROM control_commands WHERE request_id=?", (request_id,)
                ).fetchone()
                if row is None or row["client_id"] != client_id:
                    raise ControlError("Command not found", code="not_found", status=404)
                if row["instance_id"] != instance_id:
                    raise ControlError("Command belongs to a stale receiver instance", code="stale_target", status=409)
                if row["status"] in {"completed", "failed"}:
                    if row["ack_json"] != ack_json:
                        raise ControlError(
                            "A terminal command receipt cannot be changed",
                            code="receipt_conflict",
                            status=409,
                        )
                    command = self._command(row)
                    self._db.execute("COMMIT")
                    return command
                if row["status"] != "running":
                    raise ControlError(
                        "Only a running command can be acknowledged",
                        code="command_not_running",
                        status=409,
                    )
                self._db.execute(
                    """UPDATE control_commands SET status=?,result_json=?,error_json=?,ack_json=?,updated_at=?
                       WHERE request_id=?""",
                    (
                        status,
                        canonical_json(result) if result is not None else None,
                        canonical_json(error) if error is not None else None,
                        ack_json,
                        now,
                        request_id,
                    ),
                )
                self._db.execute(
                    "UPDATE control_clients SET state_json=?,last_seen=?,updated_at=? WHERE client_id=?",
                    (canonical_json(state), now, now, client_id),
                )
                command = self._command(
                    self._db.execute(
                        "SELECT * FROM control_commands WHERE request_id=?", (request_id,)
                    ).fetchone()
                )
                self._db.execute("COMMIT")
                return command
            except Exception:
                self._db.execute("ROLLBACK")
                raise

    @staticmethod
    def _operation(row: sqlite3.Row) -> dict:
        result: dict[str, Any] = {
            "requestId": row["request_id"],
            "action": row["action"],
            "status": "outcome_unknown" if row["status"] == "reserved" else row["status"],
        }
        if row["result_json"] is not None:
            result["result"] = _loads(row["result_json"])
        if row["error_json"] is not None:
            result["error"] = _loads(row["error_json"])
        return result

    def reserve_operation(self, request_id: str, action: str, payload: dict) -> tuple[dict, bool]:
        now = self.clock()
        payload_json = canonical_json(payload)
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                self._cleanup_locked(now)
                row = self._db.execute(
                    "SELECT * FROM control_operations WHERE request_id=?", (request_id,)
                ).fetchone()
                if row is not None:
                    if row["payload_json"] != payload_json:
                        raise ControlError(
                            "requestId was already used for a different operation",
                            code="request_conflict",
                            status=409,
                        )
                    result = self._operation(row)
                    self._db.execute("COMMIT")
                    return result, False
                count = self._db.execute("SELECT COUNT(*) FROM control_operations").fetchone()[0]
                if count >= MAX_OPERATIONS:
                    raise ControlError(
                        "The resource operation store is full",
                        code="operation_capacity",
                        status=429,
                    )
                self._db.execute(
                    """INSERT INTO control_operations
                       (request_id,payload_json,action,status,created_at,updated_at)
                       VALUES(?,?,?,?,?,?)""",
                    (request_id, payload_json, action, "reserved", now, now),
                )
                row = self._db.execute(
                    "SELECT * FROM control_operations WHERE request_id=?", (request_id,)
                ).fetchone()
                self._db.execute("COMMIT")
                return self._operation(row), True
            except Exception:
                self._db.execute("ROLLBACK")
                raise

    def finish_operation(
        self,
        request_id: str,
        *,
        status: str,
        result: Optional[dict] = None,
        error: Optional[dict] = None,
    ) -> dict:
        if status not in {"completed", "failed", "outcome_unknown"}:
            raise ValueError("invalid terminal operation status")
        now = self.clock()
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                row = self._db.execute(
                    "SELECT * FROM control_operations WHERE request_id=?", (request_id,)
                ).fetchone()
                if row is None:
                    raise ControlError("Operation not found", code="not_found", status=404)
                if row["status"] != "reserved":
                    existing = self._operation(row)
                    desired = {"requestId": request_id, "action": row["action"], "status": status}
                    if result is not None:
                        desired["result"] = result
                    if error is not None:
                        desired["error"] = error
                    if canonical_json(existing) != canonical_json(desired):
                        raise ControlError(
                            "A terminal operation receipt cannot be changed",
                            code="receipt_conflict",
                            status=409,
                        )
                    self._db.execute("COMMIT")
                    return existing
                self._db.execute(
                    """UPDATE control_operations SET status=?,result_json=?,error_json=?,updated_at=?
                       WHERE request_id=?""",
                    (
                        status,
                        canonical_json(result) if result is not None else None,
                        canonical_json(error) if error is not None else None,
                        now,
                        request_id,
                    ),
                )
                finished = self._operation(
                    self._db.execute(
                        "SELECT * FROM control_operations WHERE request_id=?", (request_id,)
                    ).fetchone()
                )
                self._db.execute("COMMIT")
                return finished
            except Exception:
                self._db.execute("ROLLBACK")
                raise

    def operation(self, request_id: str) -> dict:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM control_operations WHERE request_id=?", (request_id,)
            ).fetchone()
            if row is None:
                raise ControlError("Operation not found", code="not_found", status=404)
            return self._operation(row)

    @staticmethod
    def _public_publication(row: sqlite3.Row, now: float) -> dict:
        tabs = _loads(row["tabs_json"])
        return {
            "clientId": row["client_id"],
            "platform": row["platform"],
            "clientName": row["client_name"],
            "enabled": bool(row["enabled"]),
            "revision": int(row["revision"]),
            "tabs": tabs if isinstance(tabs, list) else [],
            "updatedAt": _iso(float(row["published_at"])),
            "lastSeenAt": _iso(float(row["last_seen"])),
            "stale": now - float(row["last_seen"]) > CHAT_TAB_STALE_SECONDS,
        }

    def publish_chat_tab_colors(
        self,
        *,
        client_id: str,
        publisher_token: str,
        payload: dict,
    ) -> dict:
        """Atomically replace one client's published tab colors for this server.

        The first publication pins the publisher secret hash. Higher revisions
        replace that client's data; an identical equal-revision retry is a
        heartbeat; a lower revision or a conflicting equal revision is refused.
        A disabled publication clears values but keeps the binding so a delayed
        older request cannot restore them.
        """

        now = self.clock()
        digest = self._publisher_hash(publisher_token)
        if str(payload.get("serverId")) != self.server_id:
            raise ControlError("Publication belongs to another server", code="stale_target", status=409)
        enabled = bool(payload.get("enabled"))
        revision = int(payload["revision"])
        tabs = payload.get("tabs") if enabled else []
        if not isinstance(tabs, list):
            tabs = []
        payload_json = canonical_json(payload)
        tabs_json = canonical_json(tabs)
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                self._cleanup_locked(now)
                row = self._db.execute(
                    "SELECT * FROM control_chat_tab_publishers WHERE client_id=?", (client_id,)
                ).fetchone()
                if row is None:
                    count = self._db.execute(
                        "SELECT COUNT(*) FROM control_chat_tab_publishers"
                    ).fetchone()[0]
                    if count >= MAX_CHAT_TAB_PUBLISHERS:
                        raise ControlError(
                            "The tab color publisher registry is full",
                            code="publisher_capacity",
                            status=503,
                        )
                    self._db.execute(
                        """INSERT INTO control_chat_tab_publishers
                           (client_id,server_id,publisher_hash,platform,client_name,enabled,
                            revision,payload_json,tabs_json,published_at,last_seen,created_at)
                           VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
                        (
                            client_id,
                            str(payload["serverId"]),
                            digest,
                            str(payload["platform"]),
                            str(payload["clientName"]),
                            1 if enabled else 0,
                            revision,
                            payload_json,
                            tabs_json,
                            now,
                            now,
                            now,
                        ),
                    )
                else:
                    if not hmac.compare_digest(str(row["publisher_hash"]), digest):
                        raise ControlError(
                            "Publisher credentials are invalid",
                            code="publisher_unauthorized",
                            status=401,
                        )
                    stored_revision = int(row["revision"])
                    if revision < stored_revision:
                        raise ControlError(
                            "Publication revision is older than the stored revision",
                            code="stale_publication_revision",
                            status=409,
                        )
                    if revision == stored_revision:
                        if row["payload_json"] != payload_json:
                            raise ControlError(
                                "Publication conflicts with the stored revision",
                                code="publication_conflict",
                                status=409,
                            )
                        # Identical retry: refresh only the last confirmation.
                        self._db.execute(
                            "UPDATE control_chat_tab_publishers SET last_seen=? WHERE client_id=?",
                            (now, client_id),
                        )
                    else:
                        self._db.execute(
                            """UPDATE control_chat_tab_publishers SET server_id=?,platform=?,
                               client_name=?,enabled=?,revision=?,payload_json=?,tabs_json=?,
                               published_at=?,last_seen=? WHERE client_id=?""",
                            (
                                str(payload["serverId"]),
                                str(payload["platform"]),
                                str(payload["clientName"]),
                                1 if enabled else 0,
                                revision,
                                payload_json,
                                tabs_json,
                                now,
                                now,
                                client_id,
                            ),
                        )
                public = self._public_publication(
                    self._db.execute(
                        "SELECT * FROM control_chat_tab_publishers WHERE client_id=?", (client_id,)
                    ).fetchone(),
                    now,
                )
                self._db.execute("COMMIT")
                return public
            except Exception:
                self._db.execute("ROLLBACK")
                raise

    def chat_tab_color_publications(self) -> list[dict]:
        """Every publisher for this server in stable publication order."""

        now = self.clock()
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM control_chat_tab_publishers ORDER BY created_at,client_id"
            ).fetchall()
            return [self._public_publication(row, now) for row in rows]
