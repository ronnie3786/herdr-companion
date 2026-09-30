"""First Mate simulator checkpoints and previews, backed by SimPortal.

Ownership (docs/first-mate/simulator-previews.md):

- The project's build workflow compiles. A managed First Mate agent hands the
  finished simulator ``.app`` to ``fm_register_simulator_build``; the companion
  derives the feature, stage, assignment and session itself.
- SimPortal owns the saved build bytes, each owned simulator's lifecycle, its
  readiness receipt and the viewer stream.
- This service owns the connection and credential, feature/build associations,
  a durable request outbox, the idle and capacity policy, and a stream relay
  scoped to one exact simulator.
- First Mate owns workflow verdicts. A ready preview is never verification.

Every SimPortal mutation is persisted here with its request ID and exact body
before it is sent, and a lost response is resolved by replaying that body, so a
retry never creates a second build or simulator. The pinned SimPortal server ID
fences every mutation: a changed server is reported, never adopted.
"""
from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import shutil
import socket
import sqlite3
import stat
import subprocess
import threading
import time
import uuid
from concurrent.futures import Future, ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping
from urllib.parse import urlsplit

from . import websocket_relay as ws
from .simportal import (
    PROTOCOL_VERSION,
    TERMINAL_OPERATION_STATUSES,
    SimPortalClient,
    SimPortalError,
    is_loopback_host,
    is_scope_id,
    is_uuid,
    load_token,
    validate_origin,
)

CAPABILITY = "first-mate-simulator-previews-v1"
SCHEMA_VERSION = 1
DEFAULT_PROJECT_ID = "herdr"
DEFAULT_IDLE_MINUTES = 20
DEFAULT_MAX_RUNNING = 2
PREFERRED_DEVICE_TYPES = (
    "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
    "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
    "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
    "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
)
START_STEPS = ("validating", "staging_app", "creating_simulator", "booting", "installing", "launching",
               "checking_stream")
# A simulator is up from the moment its boot step is done, even while the app
# is still installing: the window can show it that early.
STREAMABLE_STATUSES = frozenset({"installing", "launching", "checking_stream", "ready", "stream_released"})
RUNNING_STATUSES = frozenset({"ready", "stream_released"})
# Anything else is still being registered and keeps being observed until it settles.
BUILD_SETTLED_STATUSES = frozenset({"ready", "failed", "cancelled", "interrupted", "outcome_unknown", "conflict",
                                    "unavailable", "delete_queued", "deleting_build", "deleted"})
CAPABILITY_TTL = 300.0
ADMISSION_TTL = 30.0
REAP_INTERVAL = 60.0
OBSERVATION_TTL = 5.0
REGISTRATION_WAIT = 120.0
STALE_PREPARATION_SECONDS = 1800.0
MAX_STREAMS = 8
STREAM_IDLE_TIMEOUT = 90.0
MAX_STREAM_MESSAGE = 32 * 1024 * 1024
MAX_CLIENT_MESSAGE = 1024 * 1024
MAX_TEXT_INPUT = 64 * 1024
MAX_APP_ENTRIES = 20_000
_LABEL_MAX = 160
_NAME_MAX = 100
_HUB_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_CONFIGURATION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$")


class SimulatorPreviewError(Exception):
    """A request the companion refuses, with a stable code for clients."""

    def __init__(self, message: str, *, code: str, status: int = 409, details: Mapping[str, Any] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.status = status
        self.details = dict(details or {})


class RegistrationPending(Exception):
    """The registration is still in progress; the runtime keeps its spool request open."""


@dataclass(frozen=True)
class Settings:
    url: str | None
    intake_root: Path | None
    project_id: str
    device_type: str | None
    runtime: str | None
    idle_minutes: int
    max_running: int
    store_path: Path
    expected_server_id: str | None
    app_roots: tuple[Path, ...]

    @classmethod
    def from_environ(cls, environ: Mapping[str, str]) -> "Settings":
        state = Path(environ.get("HERDR_STATE_DIR") or Path.home() / ".local/share/herdr-companion").expanduser()
        intake = environ.get("HERDR_SIMPORTAL_INTAKE_ROOT")
        roots = tuple(Path(part).expanduser() for part in (environ.get("HERDR_SIMPORTAL_APP_ROOTS") or "").split(os.pathsep)
                      if part.strip())
        project = (environ.get("HERDR_SIMPORTAL_PROJECT_ID") or DEFAULT_PROJECT_ID).strip()
        expected = (environ.get("HERDR_SIMPORTAL_SERVER_ID") or "").strip().lower() or None
        return cls(
            url=(environ.get("HERDR_SIMPORTAL_URL") or "").strip() or None,
            intake_root=Path(intake).expanduser() if intake else None,
            project_id=project if is_scope_id(project) else DEFAULT_PROJECT_ID,
            device_type=(environ.get("HERDR_SIMPORTAL_DEVICE_TYPE") or "").strip() or None,
            runtime=(environ.get("HERDR_SIMPORTAL_RUNTIME") or "").strip() or None,
            idle_minutes=_bounded_int(environ.get("HERDR_SIMPORTAL_IDLE_SHUTDOWN_MINUTES"), DEFAULT_IDLE_MINUTES, 0, 24 * 60),
            max_running=_bounded_int(environ.get("HERDR_SIMPORTAL_MAX_RUNNING_PREVIEWS"), DEFAULT_MAX_RUNNING, 1, 8),
            store_path=Path(environ.get("HERDR_SIMPORTAL_STORE_PATH") or state / "simulator-previews.sqlite3").expanduser(),
            expected_server_id=expected if expected and is_uuid(expected) else None,
            app_roots=roots,
        )

    @property
    def configured(self) -> bool:
        return bool(self.url)


@dataclass(frozen=True)
class CheckpointContext:
    """Identity the runtime derived from a validated managed execution."""

    feature_id: str
    feature_title: str
    visit_id: str | None
    visit_title: str | None
    assignment_id: str | None
    assignment_title: str | None
    native_session_id: str | None
    workspace: str
    role: str
    extra_roots: tuple[str, ...] = ()


@dataclass
class _Discovery:
    at: float
    state: str
    reason: str | None
    capabilities: dict[str, Any] | None = None
    server_id: str | None = None
    pinned_server_id: str | None = None
    registration_reason: str | None = None


def _bounded_int(value: Any, default: int, minimum: int, maximum: int) -> int:
    try:
        number = int(str(value).strip()) if value not in (None, "") else default
    except (TypeError, ValueError):
        return default
    return max(minimum, min(maximum, number))


def _iso(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _epoch(value: Any) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _loads(value: Any, default: Any = None) -> Any:
    if not isinstance(value, str) or not value:
        return default
    try:
        return json.loads(value)
    except ValueError:
        return default


def _clip(text: Any, maximum: int) -> str:
    cleaned = " ".join(str(text or "").replace("\x00", "").split())
    cleaned = "".join(ch for ch in cleaned if ch >= " " and ch != "\x7f")
    return cleaned if len(cleaned) <= maximum else cleaned[: maximum - 1].rstrip() + "…"


def _version_tuple(value: Any) -> tuple[int, ...]:
    parts = []
    for piece in str(value or "").split("."):
        match = re.match(r"\d+", piece)
        parts.append(int(match.group()) if match else 0)
    return tuple(parts) or (0,)


def _scope_session(native_session_id: str | None) -> str:
    if native_session_id and is_scope_id(native_session_id):
        return native_session_id
    if native_session_id:
        # A retained, collision-resistant mapping: never truncate or strip.
        return "pi-" + hashlib.sha256(native_session_id.encode("utf-8")).hexdigest()[:40]
    return "unknown-session"


def _safe_error(value: Any) -> dict[str, str] | None:
    if not isinstance(value, Mapping):
        return None
    code = str(value.get("code") or "error")
    code = code if re.fullmatch(r"[a-z][a-z0-9_]{0,63}", code) else "error"
    return {"code": code, "message": _clip(value.get("message") or "SimPortal reported an error", 300)}


def _operation_snapshot(operation: Any) -> dict[str, Any] | None:
    """The bounded part of a SimPortal operation this service keeps."""

    if not isinstance(operation, Mapping) or not is_uuid(operation.get("id")):
        return None
    steps = []
    for step in operation.get("steps") or []:
        if isinstance(step, Mapping) and isinstance(step.get("name"), str):
            steps.append({"name": step["name"][:64], "state": str(step.get("state") or "pending")[:32]})
    resources = operation.get("resources") if isinstance(operation.get("resources"), Mapping) else {}
    return {
        "id": operation["id"],
        "kind": str(operation.get("kind") or "")[:32],
        "status": str(operation.get("status") or "")[:32],
        "step": str(operation.get("step"))[:64] if operation.get("step") else None,
        "steps": steps[:16],
        "error": _safe_error(operation.get("error")),
        "sequence": operation.get("sequence") if isinstance(operation.get("sequence"), int) else None,
        "updated_at": str(operation.get("updatedAt") or "")[:40] or None,
        "udid": resources.get("udid") if isinstance(resources.get("udid"), str) else None,
    }


_SCHEMA = (
    """CREATE TABLE IF NOT EXISTS sim_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS sim_servers(
        origin TEXT PRIMARY KEY, server_id TEXT NOT NULL, pinned_at TEXT NOT NULL,
        observed_server_id TEXT, observed_at TEXT)""",
    """CREATE TABLE IF NOT EXISTS sim_builds(
        build_id TEXT PRIMARY KEY, server_id TEXT NOT NULL, origin TEXT NOT NULL, project_id TEXT NOT NULL,
        feature_id TEXT NOT NULL, visit_id TEXT, assignment_id TEXT, native_session_id TEXT,
        scope_session_id TEXT NOT NULL, checkpoint_id TEXT NOT NULL, checkpoint_label TEXT NOT NULL,
        stage_title TEXT, name TEXT NOT NULL, origin_kind TEXT NOT NULL DEFAULT 'agent', hub_build_id TEXT,
        app_json TEXT NOT NULL DEFAULT '{}', source_json TEXT NOT NULL DEFAULT '{}',
        intake_dir TEXT, intake_state TEXT NOT NULL DEFAULT 'none',
        register_request_id TEXT UNIQUE, spool_request_id TEXT UNIQUE, operation_id TEXT,
        status TEXT NOT NULL, operation_json TEXT, artifact_json TEXT, error_json TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL, observed_at TEXT)""",
    """CREATE INDEX IF NOT EXISTS sim_builds_feature ON sim_builds(feature_id, created_at)""",
    """CREATE TABLE IF NOT EXISTS sim_previews(
        id TEXT PRIMARY KEY, server_id TEXT NOT NULL, origin TEXT NOT NULL,
        feature_id TEXT NOT NULL, build_id TEXT NOT NULL, portal_id TEXT UNIQUE,
        start_request_id TEXT NOT NULL UNIQUE, start_operation_id TEXT, latest_operation_id TEXT,
        udid TEXT, viewer_path TEXT, links_json TEXT, device_type TEXT NOT NULL, runtime TEXT NOT NULL,
        device_json TEXT NOT NULL DEFAULT '{}', status TEXT NOT NULL, operation_json TEXT,
        observation_json TEXT, observed_at TEXT, last_active_at TEXT, pending_stop TEXT,
        stop_reason TEXT, error_json TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)""",
    """CREATE INDEX IF NOT EXISTS sim_previews_build ON sim_previews(build_id, created_at)""",
    """CREATE TABLE IF NOT EXISTS sim_outbox(
        request_id TEXT PRIMARY KEY, server_id TEXT NOT NULL, origin TEXT NOT NULL, method TEXT NOT NULL,
        path TEXT NOT NULL, body_json TEXT NOT NULL, action TEXT NOT NULL, feature_id TEXT, build_id TEXT,
        preview_id TEXT, state TEXT NOT NULL, operation_id TEXT, attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT, next_attempt_at REAL NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)""",
    """CREATE INDEX IF NOT EXISTS sim_outbox_pending ON sim_outbox(state, next_attempt_at)""",
    """CREATE TABLE IF NOT EXISTS sim_receipts(scope TEXT NOT NULL, request_id TEXT NOT NULL,
        payload_hash TEXT NOT NULL, result_json TEXT NOT NULL, created_at TEXT NOT NULL,
        PRIMARY KEY(scope, request_id))""",
    """CREATE TABLE IF NOT EXISTS sim_selection(feature_id TEXT PRIMARY KEY, build_id TEXT NOT NULL,
        selected_at TEXT NOT NULL)""",
)


class SimulatorPreviews:
    """The companion's SimPortal adapter. Thread-safe; one per service."""

    def __init__(
        self,
        environ: Mapping[str, str],
        *,
        first_mate_store: Any = None,
        notify: Callable[[str], None] | None = None,
        client_factory: Callable[[str, str], SimPortalClient] | None = None,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
        dial: Callable[..., ws.FrameSocket] = ws.dial,
    ) -> None:
        self.environ = environ
        self.settings = Settings.from_environ(environ)
        self.store = first_mate_store
        self._notify = notify
        self._client_factory = client_factory or (lambda origin, token: SimPortalClient(origin, token))
        self._clock = clock
        self._sleep = sleep
        self._dial = dial
        self._lock = threading.RLock()
        self._discovery_lock = threading.Lock()
        self._discovery: _Discovery | None = None
        self._db: sqlite3.Connection | None = None
        self._wake = threading.Event()
        self._stopping = threading.Event()
        self._thread: threading.Thread | None = None
        self._pool: ThreadPoolExecutor | None = None
        self._registrations: dict[str, Future] = {}
        self._relay_lock = threading.Lock()
        self._relays: dict[str, int] = {}
        self._stream_slots = threading.BoundedSemaphore(MAX_STREAMS)
        self._open_lock = threading.Lock()
        self._synced: dict[str, float] = {}
        self._last_reap = 0.0
        self._last_error: str | None = None
        self._origin: str | None = None
        if self.settings.configured:
            try:
                self._origin = validate_origin(self.settings.url)
            except SimPortalError:
                self._origin = None

    # Lifecycle -------------------------------------------------------------------

    @property
    def configured(self) -> bool:
        return self.settings.configured

    def start(self) -> None:
        if not self.configured or self._thread is not None:
            return
        self._stopping.clear()
        self._thread = threading.Thread(target=self._run, name="simulator-previews", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stopping.set()
        self._wake.set()
        thread, self._thread = self._thread, None
        if thread is not None:
            thread.join(timeout=5)
        with self._lock:
            pool, self._pool = self._pool, None
        if pool is not None:
            pool.shutdown(wait=False, cancel_futures=True)
        with self._lock:
            if self._db is not None:
                self._db.close()
                self._db = None

    def wake(self) -> None:
        self._wake.set()

    def _require_configured(self) -> None:
        if not self.configured:
            raise SimulatorPreviewError("SimPortal is not configured on this machine", code="simulator_unconfigured", status=503)

    def _run(self) -> None:
        while not self._stopping.is_set():
            busy = False
            try:
                busy = self.tick()
                self._last_error = None
            except Exception as exc:  # noqa: BLE001 - the loop must survive any single failure
                self._last_error = type(exc).__name__
            self._wake.wait(1.0 if busy else 20.0)
            self._wake.clear()

    # Ledger ------------------------------------------------------------------------

    def _connection(self) -> sqlite3.Connection:
        if self._db is None:
            path = self.settings.store_path
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            db = sqlite3.connect(str(path), isolation_level=None, check_same_thread=False, timeout=15)
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA synchronous=FULL")
            db.execute("PRAGMA busy_timeout=15000")
            for statement in _SCHEMA:
                db.execute(statement)
            db.execute("INSERT OR IGNORE INTO sim_meta VALUES('schema_version', ?)", (str(SCHEMA_VERSION),))
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass
            self._db = db
        return self._db

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            db = self._connection()
            db.execute("BEGIN IMMEDIATE")
            try:
                yield db
            except BaseException:
                db.execute("ROLLBACK")
                raise
            db.execute("COMMIT")

    def _rows(self, sql: str, args: tuple = ()) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(row) for row in self._connection().execute(sql, args).fetchall()]

    def _row(self, sql: str, args: tuple = ()) -> dict[str, Any] | None:
        rows = self._rows(sql, args)
        return rows[0] if rows else None

    def _now(self) -> float:
        return self._clock()

    # Connection and discovery -----------------------------------------------------

    def _client(self) -> SimPortalClient:
        if not self.configured:
            raise SimPortalError("SimPortal is not configured on this machine", code="simulator_unconfigured")
        origin = validate_origin(self.settings.url)
        return self._client_factory(origin, load_token(self.environ))

    def _discover(self, *, max_age: float = CAPABILITY_TTL) -> _Discovery:
        now = self._now()
        with self._discovery_lock:
            cached = self._discovery
            if cached is not None and now - cached.at < max_age:
                return cached
        if not self.configured:
            discovery = _Discovery(now, "unconfigured", "SimPortal is not configured on this machine.")
        else:
            try:
                capabilities = self._client().capabilities()
            except SimPortalError as exc:
                discovery = self._failed_discovery(now, exc)
            else:
                discovery = self._evaluate(now, capabilities)
        with self._discovery_lock:
            self._discovery = discovery
        return discovery

    def _failed_discovery(self, now: float, exc: SimPortalError) -> _Discovery:
        pinned = self._pinned_server()
        if exc.code in {"simulator_unconfigured"}:
            return _Discovery(now, "unconfigured", str(exc), pinned_server_id=pinned)
        if exc.code in {"simulator_misconfigured", "simulator_auth"}:
            return _Discovery(now, "misconfigured", str(exc), pinned_server_id=pinned)
        return _Discovery(now, "unavailable", "SimPortal is not reachable from this machine's companion.",
                          pinned_server_id=pinned)

    def _reachable_server(self) -> str | None:
        """The pinned server, unless SimPortal now answers as a different one."""

        with self._discovery_lock:
            cached = self._discovery
        if cached is not None and cached.state == "server_changed":
            return None
        return self._pinned_server()

    def _pinned_server(self) -> str | None:
        if not self._origin:
            return None
        row = self._row("SELECT server_id FROM sim_servers WHERE origin=?", (self._origin,))
        return row["server_id"] if row else None

    def _evaluate(self, now: float, capabilities: Mapping[str, Any]) -> _Discovery:
        server_id = capabilities.get("serverId")
        if not is_uuid(server_id):
            return _Discovery(now, "unsupported", "SimPortal did not report a server identity.")
        server_id = str(server_id).lower()
        pinned = self._pin(server_id)
        caps = dict(capabilities)
        if pinned != server_id:
            return _Discovery(now, "server_changed", "SimPortal on this machine reports a different server than the "
                              "one Herdr's previews came from. Herdr will not reuse or change them automatically.",
                              capabilities=caps, server_id=server_id, pinned_server_id=pinned)
        catalog = caps.get("buildCatalog") if isinstance(caps.get("buildCatalog"), Mapping) else {}
        lifecycle = caps.get("lifecycle") if isinstance(caps.get("lifecycle"), Mapping) else {}
        if caps.get("protocolVersion") != PROTOCOL_VERSION or catalog.get("version") != 1:
            return _Discovery(now, "unsupported", "This SimPortal version is not supported by Herdr.",
                              capabilities=caps, server_id=server_id, pinned_server_id=pinned)
        if catalog.get("enabled") is not True or lifecycle.get("enabled") is not True:
            return _Discovery(now, "unavailable", "SimPortal's build catalog or previews are disabled.",
                              capabilities=caps, server_id=server_id, pinned_server_id=pinned)
        if not caps.get("toolchain"):
            return _Discovery(now, "unavailable", "SimPortal cannot use Xcode on its machine right now.",
                              capabilities=caps, server_id=server_id, pinned_server_id=pinned)
        storage = caps.get("storage") if isinstance(caps.get("storage"), Mapping) else None
        registration_reason = self._registration_blocker(caps)
        if storage is not None and storage.get("admissionAllowed") is False:
            free, floor = storage.get("freeBytes"), storage.get("minFreeBytes")
            reason = "SimPortal's Mac is low on disk space"
            if isinstance(free, int) and isinstance(floor, int):
                reason += f": {free / 1e9:.1f} GB free, {floor / 1e9:.0f} GB required"
            return _Discovery(now, "storage_low", reason + ". Running previews still work.", capabilities=caps,
                              server_id=server_id, pinned_server_id=pinned,
                              registration_reason=registration_reason or reason + ".")
        return _Discovery(now, "ready", None, capabilities=caps, server_id=server_id, pinned_server_id=pinned,
                          registration_reason=registration_reason)

    def _pin(self, observed: str) -> str:
        """The pinned server ID for this origin, pinning on first contact.

        An operator can accept a replacement explicitly with [simportal]
        server_id; nothing else ever moves the pin.
        """

        origin = self._origin or ""
        stamp = _iso(self._now())
        with self._transaction() as db:
            row = db.execute("SELECT server_id FROM sim_servers WHERE origin=?", (origin,)).fetchone()
            expected = self.settings.expected_server_id
            if row is None:
                pinned = expected or observed
                db.execute("INSERT INTO sim_servers(origin,server_id,pinned_at,observed_server_id,observed_at) "
                           "VALUES(?,?,?,?,?)", (origin, pinned, stamp, observed, stamp))
                return pinned
            pinned = row["server_id"]
            if expected and expected != pinned:
                db.execute("UPDATE sim_servers SET server_id=?,pinned_at=? WHERE origin=?", (expected, stamp, origin))
                pinned = expected
            db.execute("UPDATE sim_servers SET observed_server_id=?,observed_at=? WHERE origin=?", (observed, stamp, origin))
            return pinned

    def _registration_blocker(self, caps: Mapping[str, Any]) -> str | None:
        """Why this machine cannot hand a build to SimPortal, or None."""

        catalog = caps.get("buildCatalog") if isinstance(caps.get("buildCatalog"), Mapping) else {}
        handoff = catalog.get("handoff") if isinstance(catalog.get("handoff"), Mapping) else {}
        roots = [str(root) for root in handoff.get("artifactRoots") or [] if isinstance(root, str)]
        intake = self.settings.intake_root
        try:
            host = validate_origin(self.settings.url or "")
        except SimPortalError:
            return "SimPortal's URL is invalid."
        if not is_loopback_host(urlsplit(host).hostname):
            return ("SimPortal runs on another machine. Builds can only be saved to a SimPortal on the machine that "
                    "compiled them.")
        if intake is None:
            return "No intake folder is configured ([simportal] intake_root)."
        try:
            resolved = intake.resolve()
        except OSError:
            return "The configured intake folder is unavailable."
        if not any(_same_path(resolved, Path(root)) for root in roots):
            return "The configured intake folder is not one of SimPortal's approved artifact roots."
        if not resolved.is_dir() or not os.access(resolved, os.W_OK):
            return "The configured intake folder does not exist or is not writable."
        return None

    def status(self, *, fresh: bool = False) -> dict[str, Any]:
        discovery = self._discover(max_age=0 if fresh else CAPABILITY_TTL)
        caps = discovery.capabilities or {}
        storage = caps.get("storage") if isinstance(caps.get("storage"), Mapping) else None
        toolchain = caps.get("toolchain") if isinstance(caps.get("toolchain"), Mapping) else None
        device = None
        if caps:
            try:
                device = self._choose_device(caps, minimum_os=None)
            except SimulatorPreviewError:
                device = None
        running = [p for p in self._previews_on(discovery.pinned_server_id) if self._phase(p) in {"starting", "running"}]
        return {
            "configured": self.configured,
            "state": discovery.state,
            "reason": discovery.reason,
            "server_id": discovery.server_id,
            "pinned_server_id": discovery.pinned_server_id,
            "registration_available": discovery.state == "ready" and discovery.registration_reason is None,
            "registration_reason": discovery.registration_reason if discovery.state == "ready" else discovery.reason,
            "preview_available": discovery.state == "ready",
            "storage": {
                "free_bytes": storage.get("freeBytes"), "min_free_bytes": storage.get("minFreeBytes"),
                "admission_allowed": storage.get("admissionAllowed"), "observed_at": storage.get("observedAt"),
            } if storage else None,
            "toolchain": {"xcode": toolchain.get("xcode")} if toolchain else None,
            "default_device": device,
            "policy": {"idle_shutdown_minutes": self.settings.idle_minutes,
                       "max_running_previews": self.settings.max_running},
            "running_previews": len(running),
            "checked_at": _iso(discovery.at),
        }

    def _require(self, *, allowed: set[str], action: str) -> _Discovery:
        discovery = self._discover(max_age=ADMISSION_TTL)
        if discovery.state in allowed:
            return discovery
        codes = {"unconfigured": ("simulator_unconfigured", 503), "misconfigured": ("simulator_misconfigured", 503),
                 "unavailable": ("simulator_unavailable", 503), "unsupported": ("simulator_unsupported", 503),
                 "server_changed": ("simulator_server_changed", 409), "storage_low": ("simulator_storage_low", 409)}
        code, status = codes.get(discovery.state, ("simulator_unavailable", 503))
        raise SimulatorPreviewError(f"Cannot {action}: {discovery.reason or 'SimPortal is unavailable.'}",
                                    code=code, status=status)

    # Device selection ---------------------------------------------------------------

    def _choose_device(self, caps: Mapping[str, Any], *, minimum_os: str | None,
                       device_type: str | None = None, runtime: str | None = None) -> dict[str, Any]:
        types = {t["id"]: t for t in caps.get("deviceTypes") or [] if isinstance(t, Mapping) and isinstance(t.get("id"), str)}
        runtimes = [r for r in caps.get("runtimes") or [] if isinstance(r, Mapping) and isinstance(r.get("id"), str)
                    and r.get("platform") == "iOS" and isinstance(r.get("supportedDeviceTypes"), list)]
        wanted = device_type or self.settings.device_type
        if wanted is None:
            wanted = next((candidate for candidate in PREFERRED_DEVICE_TYPES if candidate in types), None)
            if wanted is None:
                wanted = next((tid for tid, t in types.items() if str(t.get("family") or "").lower() == "iphone"
                               and any(tid in r["supportedDeviceTypes"] for r in runtimes)), None)
        if wanted is None or wanted not in types:
            raise SimulatorPreviewError("That simulator device type is not installed on SimPortal's Mac.",
                                        code="simulator_device_unavailable", status=400)
        candidates = [r for r in runtimes if wanted in r["supportedDeviceTypes"]]
        pinned_runtime = runtime or self.settings.runtime
        if pinned_runtime is not None:
            candidates = [r for r in candidates if r["id"] == pinned_runtime]
        if minimum_os:
            candidates = [r for r in candidates if _version_tuple(r.get("version")) >= _version_tuple(minimum_os)]
        if not candidates:
            raise SimulatorPreviewError("No installed iOS runtime on SimPortal's Mac runs this app on that device.",
                                        code="simulator_device_unavailable", status=400)
        chosen = max(candidates, key=lambda r: _version_tuple(r.get("version")))
        return {"device_type": wanted, "device_type_name": _clip(types[wanted].get("name") or wanted, 80),
                "runtime": chosen["id"], "runtime_name": _clip(chosen.get("name") or chosen.get("version") or chosen["id"], 80)}

    # Checkpoint registration -----------------------------------------------------------

    def submit_registration(self, spool_request_id: str, context: CheckpointContext,
                            params: Mapping[str, Any], *, on_done: Callable[[], None] | None = None) -> Future:
        """Start (or resume) registering one tool call's build; keyed by its spool request."""

        self._require_configured()
        with self._lock:
            future = self._registrations.get(spool_request_id)
            if future is not None:
                return future
            if self._pool is None:
                self._pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="simulator-registration")
            future = self._pool.submit(self._register, spool_request_id, context, dict(params))
            self._registrations[spool_request_id] = future
            if on_done is not None:
                future.add_done_callback(lambda _: on_done())
            return future

    def registration(self, spool_request_id: str) -> Future | None:
        """The in-flight registration for a tool call, if this process started one."""

        with self._lock:
            return self._registrations.get(spool_request_id)

    def release_registration(self, spool_request_id: str) -> None:
        """The runtime answered the tool call; a replay after restart resumes from the ledger."""

        with self._lock:
            self._registrations.pop(spool_request_id, None)

    def _register(self, spool_request_id: str, context: CheckpointContext, params: dict[str, Any]) -> dict[str, Any]:
        row = self._row("SELECT * FROM sim_builds WHERE spool_request_id=?", (spool_request_id,))
        if row is None:
            row = self._prepare_registration(spool_request_id, context, params)
        build_id = row["build_id"]
        if row["intake_state"] == "pending":
            self._copy_intake(build_id)
        self._flush_outbox(build_id=build_id)
        deadline = self._now() + REGISTRATION_WAIT
        while True:
            row = self._row("SELECT * FROM sim_builds WHERE build_id=?", (build_id,))
            if row is None or row["status"] in BUILD_SETTLED_STATUSES or self._now() >= deadline:
                break
            self._observe_build(row)
            row = self._row("SELECT * FROM sim_builds WHERE build_id=?", (build_id,))
            if row is None or row["status"] in BUILD_SETTLED_STATUSES:
                break
            self._sleep(1.0)
            self._flush_outbox(build_id=build_id)
        assert row is not None
        projection = self._project_build(row, previews=[])
        result = {"build_id": build_id, "status": projection["status"], "checkpoint": {
            "id": row["checkpoint_id"], "label": row["checkpoint_label"]}, "app": projection["app"],
            "error": projection["error"]}
        if projection["status"] == "ready":
            result["note"] = ("Saved as a simulator checkpoint the human can open from First Mate. "
                              "A saved build is not verification evidence.")
        elif projection["status"] == "registering":
            result["note"] = "SimPortal is still saving the build; it appears in First Mate when ready."
        return result

    def _prepare_registration(self, spool_request_id: str, context: CheckpointContext,
                              params: dict[str, Any]) -> dict[str, Any]:
        unknown = set(params) - {"app_path", "label", "configuration", "scheme", "hub_build_id"}
        if unknown:
            raise SimulatorPreviewError("Unsupported field: " + ", ".join(sorted(unknown)), code="invalid_request", status=400)
        discovery = self._require(allowed={"ready"}, action="save this simulator build")
        if discovery.registration_reason:
            raise SimulatorPreviewError(discovery.registration_reason, code="simulator_registration_unavailable")
        caps = discovery.capabilities or {}
        app = self._validated_app(params.get("app_path"), context, caps)
        label = _clip(params.get("label") or context.assignment_title or context.visit_title or "Checkpoint", _LABEL_MAX)
        if not label:
            label = "Checkpoint"
        configuration = params.get("configuration")
        if configuration is not None and (not isinstance(configuration, str) or not _CONFIGURATION_RE.fullmatch(configuration)):
            raise SimulatorPreviewError("configuration must be a short build configuration name", code="invalid_request", status=400)
        configuration = configuration or app["configuration"]
        scheme = params.get("scheme")
        if scheme is not None and (not isinstance(scheme, str) or not scheme.strip() or len(scheme) > 128):
            raise SimulatorPreviewError("scheme must be a short scheme or target name", code="invalid_request", status=400)
        hub_build_id = params.get("hub_build_id")
        if hub_build_id is not None and (not isinstance(hub_build_id, str) or not _HUB_ID_RE.fullmatch(hub_build_id)):
            raise SimulatorPreviewError("hub_build_id must be a Mobile App Hub build ID", code="invalid_request", status=400)
        revision, working_tree = _git_state(context.workspace)
        build_id, request_id = str(uuid.uuid4()), str(uuid.uuid4())
        checkpoint_id = context.assignment_id or context.visit_id or context.feature_id
        feature_scope = context.feature_id if is_scope_id(context.feature_id) else "fm-" + hashlib.sha256(
            context.feature_id.encode("utf-8")).hexdigest()[:40]
        if not is_scope_id(checkpoint_id):
            checkpoint_id = "cp-" + hashlib.sha256(checkpoint_id.encode("utf-8")).hexdigest()[:40]
        assert self.settings.intake_root is not None
        intake_dir = self.settings.intake_root.resolve() / self.settings.project_id / feature_scope / build_id
        source: dict[str, Any] = {"workingTree": working_tree}
        if revision:
            source["revision"] = revision
        if configuration:
            source["configuration"] = configuration
        target = scheme.strip() if isinstance(scheme, str) else app["executable"]
        if target:
            source["target"] = _clip(target, 128)
        body = {
            "requestId": request_id, "buildId": build_id,
            "name": _clip(f"{app['name']} · {label}", _NAME_MAX),
            "appPath": str(intake_dir / app["bundle_name"]),
            "scope": {"projectId": self.settings.project_id, "featureId": feature_scope,
                      "sessionId": _scope_session(context.native_session_id), "checkpointId": checkpoint_id,
                      "checkpointLabel": label},
            "source": source,
        }
        stamp = _iso(self._now())
        app_record = {k: app[k] for k in ("name", "bundle_id", "version", "build", "minimum_os", "bundle_name", "bytes")}
        app_record["source_path"] = app["path"]
        with self._transaction() as db:
            existing = db.execute("SELECT * FROM sim_builds WHERE spool_request_id=?", (spool_request_id,)).fetchone()
            if existing is not None:
                return dict(existing)
            db.execute(
                "INSERT INTO sim_builds(build_id,server_id,origin,project_id,feature_id,visit_id,assignment_id,"
                "native_session_id,scope_session_id,checkpoint_id,checkpoint_label,stage_title,name,origin_kind,"
                "hub_build_id,app_json,source_json,intake_dir,intake_state,register_request_id,spool_request_id,"
                "status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (build_id, discovery.server_id, self._origin, self.settings.project_id, context.feature_id,
                 context.visit_id, context.assignment_id, context.native_session_id, body["scope"]["sessionId"],
                 checkpoint_id, label, _clip(context.visit_title or "", 160) or None, body["name"],
                 "agent", hub_build_id, _dumps(app_record), _dumps(source), str(intake_dir), "pending", request_id,
                 spool_request_id, "preparing", stamp, stamp))
            db.execute(
                "INSERT INTO sim_outbox(request_id,server_id,origin,method,path,body_json,action,feature_id,build_id,"
                "state,next_attempt_at,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (request_id, discovery.server_id, self._origin, "POST", "/api/builds", _dumps(body), "register_build",
                 context.feature_id, build_id, "held", 0, stamp, stamp))
            row = db.execute("SELECT * FROM sim_builds WHERE build_id=?", (build_id,)).fetchone()
        return dict(row)

    def _validated_app(self, value: Any, context: CheckpointContext, caps: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(value, str) or not value.strip() or "\x00" in value or len(value) > 4096:
            raise SimulatorPreviewError("app_path must be the absolute path of a built simulator .app",
                                        code="invalid_request", status=400)
        path = Path(value)
        if not path.is_absolute() or path.suffix != ".app":
            raise SimulatorPreviewError("app_path must be an absolute path ending in .app", code="invalid_request", status=400)
        try:
            info = path.lstat()
        except OSError:
            raise SimulatorPreviewError("app_path does not exist", code="simulator_app_invalid", status=400) from None
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise SimulatorPreviewError("app_path must be a real .app directory, not a symlink or file",
                                        code="simulator_app_invalid", status=400)
        resolved = path.resolve()
        allowed = self._allowed_app_roots(context)
        if not any(_is_within(resolved, root) for root in allowed):
            raise SimulatorPreviewError(
                "app_path must be inside this assignment's workspace, Xcode DerivedData, or a temporary build folder",
                code="simulator_app_outside_roots", status=400)
        if self.settings.intake_root and _is_within(resolved, self.settings.intake_root.resolve()):
            raise SimulatorPreviewError("app_path is already inside SimPortal's intake folder", code="invalid_request", status=400)
        limits = ((caps.get("lifecycle") or {}).get("limits") or {}) if isinstance(caps.get("lifecycle"), Mapping) else {}
        max_bytes = limits.get("maxAppBytes") if isinstance(limits.get("maxAppBytes"), int) else 2_000_000_000
        total, entries = 0, 0
        for root, directories, files in os.walk(resolved, followlinks=False):
            for name in directories + files:
                entries += 1
                candidate = Path(root) / name
                mode = candidate.lstat().st_mode
                if stat.S_ISLNK(mode):
                    raise SimulatorPreviewError("The app bundle contains a symbolic link; SimPortal accepts regular files only",
                                                code="simulator_app_invalid", status=400)
                if stat.S_ISREG(mode):
                    total += candidate.lstat().st_size
                elif not stat.S_ISDIR(mode):
                    raise SimulatorPreviewError("The app bundle contains a special file", code="simulator_app_invalid", status=400)
            if entries > MAX_APP_ENTRIES or total > max_bytes:
                raise SimulatorPreviewError("The app bundle is larger than SimPortal accepts", code="simulator_app_invalid", status=400)
        try:
            with (resolved / "Info.plist").open("rb") as handle:
                plist = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException, ValueError):
            raise SimulatorPreviewError("The app bundle has no readable Info.plist", code="simulator_app_invalid", status=400) from None
        if not isinstance(plist, dict):
            raise SimulatorPreviewError("The app's Info.plist is invalid", code="simulator_app_invalid", status=400)
        platforms = plist.get("CFBundleSupportedPlatforms") or []
        platform = str(plist.get("DTPlatformName") or "")
        if "iPhoneSimulator" not in platforms and platform != "iphonesimulator":
            raise SimulatorPreviewError("This is not an iOS Simulator build. Build for an iOS Simulator destination "
                                        "(for example -sdk iphonesimulator) and register that .app.",
                                        code="simulator_app_invalid", status=400)
        bundle_id = plist.get("CFBundleIdentifier")
        if not isinstance(bundle_id, str) or not bundle_id:
            raise SimulatorPreviewError("The app's Info.plist has no bundle identifier", code="simulator_app_invalid", status=400)
        configuration = None
        match = re.fullmatch(r"(.+)-iphonesimulator", resolved.parent.name)
        if match and _CONFIGURATION_RE.fullmatch(match.group(1)):
            configuration = match.group(1)
        return {
            "path": str(resolved), "bundle_name": resolved.name,
            "name": _clip(plist.get("CFBundleDisplayName") or plist.get("CFBundleName") or resolved.stem, 60),
            "bundle_id": bundle_id[:200], "version": _clip(plist.get("CFBundleShortVersionString") or "", 40) or None,
            "build": _clip(plist.get("CFBundleVersion") or "", 40) or None,
            "minimum_os": _clip(plist.get("MinimumOSVersion") or "", 20) or None,
            "executable": _clip(plist.get("CFBundleExecutable") or "", 128) or None,
            "configuration": configuration, "bytes": total,
        }

    def _allowed_app_roots(self, context: CheckpointContext) -> list[Path]:
        roots: list[Path] = []
        for candidate in [context.workspace, _git_toplevel(context.workspace) if context.workspace else None,
                          *context.extra_roots,
                          str(Path.home() / "Library/Developer/Xcode/DerivedData"), "/tmp", "/private/tmp",
                          os.environ.get("TMPDIR")]:
            if candidate:
                try:
                    roots.append(Path(candidate).resolve())
                except OSError:
                    continue
        roots.extend(root.resolve() for root in self.settings.app_roots)
        return roots

    def _copy_intake(self, build_id: str) -> None:
        """Materialize the app under the intake folder, then release the held registration."""

        row = self._row("SELECT * FROM sim_builds WHERE build_id=?", (build_id,))
        if row is None or row["intake_state"] != "pending":
            return
        app = _loads(row["app_json"], {})
        source = Path(app.get("source_path") or "")
        intake_dir = Path(row["intake_dir"])
        root = self.settings.intake_root.resolve() if self.settings.intake_root else None
        if root is None or not _is_within(intake_dir, root) or intake_dir.name != build_id:
            self._fail_build(build_id, "simulator_intake_invalid", "The intake folder is not under SimPortal's approved root.")
            return
        destination = intake_dir / app.get("bundle_name", "App.app")
        partial = intake_dir / (".partial-" + uuid.uuid4().hex)
        # The intake copy must leave SimPortal's own free-space floor intact. Its
        # report describes the volume it stages to; fall back to this volume.
        discovery = self._discover(max_age=ADMISSION_TTL)
        storage = (discovery.capabilities or {}).get("storage") or {}
        floor = storage.get("minFreeBytes") if isinstance(storage.get("minFreeBytes"), int) else 20_000_000_000
        try:
            intake_dir.mkdir(parents=True, exist_ok=True, mode=0o755)
            reported = storage.get("freeBytes")
            free = (reported if isinstance(reported, int) and not isinstance(reported, bool)
                    else shutil.disk_usage(intake_dir).free)
            if free - int(app.get("bytes") or 0) < floor:
                self._fail_build(build_id, "simulator_storage_low",
                                 f"Not enough disk space to save this build ({free / 1e9:.1f} GB free, {floor / 1e9:.0f} GB must remain).")
                shutil.rmtree(intake_dir, ignore_errors=True)
                return
            for leftover in intake_dir.glob(".partial-*"):
                shutil.rmtree(leftover, ignore_errors=True)
            if destination.exists():
                shutil.rmtree(destination)
            _copy_tree(source, partial)
            os.rename(partial, destination)
        except (OSError, subprocess.SubprocessError, shutil.Error):
            shutil.rmtree(partial, ignore_errors=True)
            self._fail_build(build_id, "simulator_intake_failed", "Could not copy the app into SimPortal's intake folder.")
            return
        stamp = _iso(self._now())
        with self._transaction() as db:
            db.execute("UPDATE sim_builds SET intake_state='copied',status='queued',updated_at=? WHERE build_id=? "
                       "AND intake_state='pending'", (stamp, build_id))
            db.execute("UPDATE sim_outbox SET state='pending',next_attempt_at=0,updated_at=? WHERE build_id=? "
                       "AND action='register_build' AND state='held'", (stamp, build_id))
        self.wake()

    def _fail_build(self, build_id: str, code: str, message: str) -> None:
        stamp = _iso(self._now())
        with self._transaction() as db:
            db.execute("UPDATE sim_builds SET status='failed',intake_state=CASE WHEN intake_state='pending' THEN "
                       "'failed' ELSE intake_state END,error_json=?,updated_at=? WHERE build_id=?",
                       (_dumps({"code": code, "message": message}), stamp, build_id))
            db.execute("UPDATE sim_outbox SET state='rejected',last_error=?,updated_at=? WHERE build_id=? AND "
                       "action='register_build' AND state IN ('held','pending')", (code, stamp, build_id))
        row = self._row("SELECT feature_id FROM sim_builds WHERE build_id=?", (build_id,))
        if row:
            self._record_event(row["feature_id"], build_id, "failed")

    # Outbox ---------------------------------------------------------------------------

    def _flush_outbox(self, *, build_id: str | None = None, preview_id: str | None = None) -> bool:
        """Send due entries exactly as persisted. Returns True while any remain pending."""

        discovery = self._discover(max_age=CAPABILITY_TTL)
        if discovery.state not in {"ready", "storage_low"}:
            return bool(self._rows("SELECT 1 FROM sim_outbox WHERE state='pending' LIMIT 1"))
        clauses, args = ["state='pending'", "next_attempt_at<=?"], [self._now()]
        if build_id:
            clauses.append("build_id=?")
            args.append(build_id)
        if preview_id:
            clauses.append("preview_id=?")
            args.append(preview_id)
        entries = self._rows(f"SELECT * FROM sim_outbox WHERE {' AND '.join(clauses)} ORDER BY created_at", tuple(args))
        for entry in entries:
            if entry["server_id"] != discovery.pinned_server_id or entry["origin"] != self._origin:
                self._outbox_result(entry, state="rejected", error="simulator_server_changed")
                continue
            try:
                client = self._client()
                response = client.send(entry["method"], entry["path"], _loads(entry["body_json"], {}))
            except SimPortalError as exc:
                if exc.retryable or exc.code in {"simulator_auth", "simulator_misconfigured", "ledger_unavailable"}:
                    attempts = int(entry["attempts"]) + 1
                    delay = min(300.0, 2.0 ** min(attempts, 8))
                    self._outbox_retry(entry, attempts, self._now() + delay, exc.code)
                    if exc.transport:
                        with self._discovery_lock:
                            self._discovery = None
                    continue
                state = "conflict" if exc.code in {"request_conflict", "build_conflict"} else "rejected"
                self._outbox_result(entry, state=state, error=exc.code, message=str(exc))
                continue
            self._accept(entry, response)
        return bool(self._rows("SELECT 1 FROM sim_outbox WHERE state='pending' LIMIT 1"))

    def _outbox_retry(self, entry: Mapping[str, Any], attempts: int, when: float, error: str) -> None:
        with self._transaction() as db:
            db.execute("UPDATE sim_outbox SET attempts=?,next_attempt_at=?,last_error=?,updated_at=? WHERE request_id=?",
                       (attempts, when, error, _iso(self._now()), entry["request_id"]))

    def _outbox_result(self, entry: Mapping[str, Any], *, state: str, error: str, message: str | None = None) -> None:
        stamp = _iso(self._now())
        failure = _dumps({"code": error, "message": _clip(message or "SimPortal did not accept the request", 300)})
        with self._transaction() as db:
            db.execute("UPDATE sim_outbox SET state=?,last_error=?,updated_at=? WHERE request_id=?",
                       (state, error, stamp, entry["request_id"]))
            if entry["action"] == "register_build":
                db.execute("UPDATE sim_builds SET status=?,error_json=?,updated_at=? WHERE build_id=?",
                           ("failed" if state == "rejected" else "conflict", failure, stamp, entry["build_id"]))
            elif entry["action"] == "start":
                db.execute("UPDATE sim_previews SET status=?,error_json=?,updated_at=? WHERE id=?",
                           ("failed" if state == "rejected" else "conflict", failure, stamp, entry["preview_id"]))
            elif entry["action"] in {"stop", "cancel"}:
                db.execute("UPDATE sim_previews SET error_json=?,pending_stop=NULL,updated_at=? WHERE id=?",
                           (failure, stamp, entry["preview_id"]))
        if entry["action"] == "register_build" and entry.get("feature_id"):
            self._record_event(entry["feature_id"], entry["build_id"], "failed")

    def _accept(self, entry: Mapping[str, Any], response: Mapping[str, Any]) -> None:
        operation = _operation_snapshot(response.get("operation"))
        operation_id = response.get("operationId")
        raw_operation = response.get("operation") if isinstance(response.get("operation"), Mapping) else {}
        if str(raw_operation.get("serverId") or "").lower() != entry["server_id"]:
            self._outbox_result(entry, state="conflict", error="simulator_server_changed",
                                message="SimPortal answered as a different server")
            return
        if operation is None or not is_uuid(operation_id) or operation["id"] != operation_id:
            self._outbox_result(entry, state="rejected", error="simulator_invalid_response",
                                message="SimPortal's acknowledgement was incomplete")
            return
        stamp = _iso(self._now())
        with self._transaction() as db:
            db.execute("UPDATE sim_outbox SET state='accepted',operation_id=?,updated_at=? WHERE request_id=?",
                       (operation_id, stamp, entry["request_id"]))
            if entry["action"] == "register_build":
                build = response.get("build") if isinstance(response.get("build"), Mapping) else {}
                if build.get("id") not in {None, entry["build_id"]} or response.get("buildId") != entry["build_id"]:
                    db.execute("UPDATE sim_builds SET status='conflict',error_json=?,updated_at=? WHERE build_id=?",
                               (_dumps({"code": "simulator_identity_mismatch", "message": "SimPortal returned a different build"}),
                                stamp, entry["build_id"]))
                    return
                # Settled statuses are only accepted from observation, which also checks scope,
                # records the artifact, and releases the intake copy.
                pending = str(build.get("status") or operation["status"])[:40]
                if pending in BUILD_SETTLED_STATUSES or operation["status"] in TERMINAL_OPERATION_STATUSES:
                    pending = "queued"
                db.execute("UPDATE sim_builds SET operation_id=?,operation_json=?,status=?,updated_at=? WHERE build_id=?",
                           (operation_id, _dumps(operation), pending, stamp, entry["build_id"]))
            elif entry["action"] == "start":
                portal = response.get("portal") if isinstance(response.get("portal"), Mapping) else {}
                portal_id = response.get("portalId")
                if not is_uuid(portal_id) or portal.get("id") not in {None, portal_id}:
                    db.execute("UPDATE sim_previews SET status='conflict',error_json=?,updated_at=? WHERE id=?",
                               (_dumps({"code": "simulator_identity_mismatch", "message": "SimPortal returned an invalid preview"}),
                                stamp, entry["preview_id"]))
                    return
                links = portal.get("links") if isinstance(portal.get("links"), Mapping) else None
                db.execute("UPDATE sim_previews SET portal_id=?,start_operation_id=?,latest_operation_id=?,operation_json=?,"
                           "status=?,udid=COALESCE(?,udid),viewer_path=COALESCE(?,viewer_path),"
                           "links_json=COALESCE(?,links_json),updated_at=? WHERE id=?",
                           (portal_id, operation_id, operation_id, _dumps(operation),
                            str(portal.get("status") or "queued")[:40],
                            portal.get("udid") if isinstance(portal.get("udid"), str) else None,
                            str(portal["viewerPath"])[:200] if isinstance(portal.get("viewerPath"), str) else None,
                            _dumps({k: links.get(k) for k in ("path", "local", "tailnet")}) if links else None,
                            stamp, entry["preview_id"]))
            elif entry["action"] == "stop":
                db.execute("UPDATE sim_previews SET latest_operation_id=?,operation_json=?,status='stopping',updated_at=? "
                           "WHERE id=?", (operation_id, _dumps(operation), stamp, entry["preview_id"]))
            elif entry["action"] == "cancel":
                db.execute("UPDATE sim_previews SET operation_json=?,updated_at=? WHERE id=?",
                           (_dumps(operation), stamp, entry["preview_id"]))
        self.wake()

    # Observation ---------------------------------------------------------------------------

    def tick(self) -> bool:
        if not self.configured:
            return False
        busy = self._flush_outbox()
        self._expire_stale_preparations()
        settled = ",".join("'" + status + "'" for status in sorted(BUILD_SETTLED_STATUSES))
        for row in self._rows("SELECT * FROM sim_builds WHERE operation_id IS NOT NULL AND status NOT IN "
                              f"({settled},'preparing')"):
            self._observe_build(row)
            busy = True
        for row in self._rows("SELECT * FROM sim_previews WHERE latest_operation_id IS NOT NULL"):
            operation = _loads(row["operation_json"], {}) or {}
            if operation.get("status") not in TERMINAL_OPERATION_STATUSES or row["pending_stop"]:
                self._observe_preview(row, refresh_portal=False)
                busy = True
        if self._now() - self._last_reap >= REAP_INTERVAL:
            self._last_reap = self._now()
            self._discover(max_age=CAPABILITY_TTL)
            self._reap()
        return busy

    def _expire_stale_preparations(self) -> None:
        """A registration whose agent vanished before handoff never reached SimPortal."""

        cutoff = self._now() - STALE_PREPARATION_SECONDS
        for row in self._rows("SELECT build_id,created_at,spool_request_id FROM sim_builds WHERE status='preparing'"):
            created = _epoch(row["created_at"]) or 0
            if created < cutoff and row["spool_request_id"] not in self._registrations:
                self._fail_build(row["build_id"], "simulator_registration_interrupted",
                                 "The registration stopped before the build was handed to SimPortal.")
                intake = self._row("SELECT intake_dir FROM sim_builds WHERE build_id=?", (row["build_id"],))
                if intake:
                    self._remove_intake(row["build_id"], intake["intake_dir"])

    def _observe_build(self, row: Mapping[str, Any]) -> None:
        operation_id = row.get("operation_id")
        if not operation_id:
            return
        try:
            client = self._client()
            operation = _operation_snapshot(client.operation(operation_id).get("operation"))
            build = None
            if operation and operation["status"] in TERMINAL_OPERATION_STATUSES:
                build = client.build(row["build_id"]).get("build")
        except SimPortalError:
            return
        if operation is None:
            return
        stamp = _iso(self._now())
        status = (operation.get("step") or operation["status"]) if operation["status"] not in TERMINAL_OPERATION_STATUSES else None
        artifact = None
        error = operation.get("error")
        if isinstance(build, Mapping):
            scope = build.get("scope") if isinstance(build.get("scope"), Mapping) else {}
            server_ok = str(build.get("serverId") or "").lower() == row["server_id"]
            scope_ok = (scope.get("projectId") == row["project_id"] and scope.get("checkpointId") == row["checkpoint_id"])
            if build.get("id") != row["build_id"] or not server_ok or not scope_ok:
                status, error = "conflict", {"code": "simulator_identity_mismatch",
                                             "message": "SimPortal's build does not match what Herdr registered"}
            else:
                status = str(build.get("status") or "unknown")[:40]
                artifact = build.get("artifact") if isinstance(build.get("artifact"), Mapping) else None
        elif status is None:
            status = operation["status"]
        with self._transaction() as db:
            db.execute("UPDATE sim_builds SET status=?,operation_json=?,artifact_json=COALESCE(?,artifact_json),"
                       "error_json=?,observed_at=?,updated_at=? WHERE build_id=?",
                       (status, _dumps(operation), _dumps(_artifact_record(artifact)) if artifact else None,
                        _dumps(error) if error else None, stamp, stamp, row["build_id"]))
        if status in {"ready", "failed", "cancelled"} or (status == "conflict"):
            if status in {"ready", "failed", "cancelled"}:
                self._remove_intake(row["build_id"], row.get("intake_dir"))
            self._record_event(row["feature_id"], row["build_id"], "ready" if status == "ready" else "failed")

    def _remove_intake(self, build_id: str, intake_dir: Any) -> None:
        """Drop Herdr's own intake copy once SimPortal settled; its private copy is authoritative."""

        root = self.settings.intake_root
        if not isinstance(intake_dir, str) or root is None:
            return
        path = Path(intake_dir)
        try:
            if path.name == build_id and _is_within(path, root.resolve()) and path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
        except OSError:
            return
        with self._transaction() as db:
            db.execute("UPDATE sim_builds SET intake_state='removed' WHERE build_id=? AND intake_state='copied'", (build_id,))

    def _record_event(self, feature_id: str, build_id: str, outcome: str) -> None:
        row = self._row("SELECT checkpoint_label,assignment_id,visit_id,status FROM sim_builds WHERE build_id=?", (build_id,))
        if row is None or self.store is None:
            return
        label = row["checkpoint_label"]
        summary = (f"Simulator build ready: {label}" if outcome == "ready" else f"Simulator build not saved: {label}")
        try:
            self.store.append_event(feature_id, "simulator.build_" + outcome, _clip(summary, 300),
                                    {"build_id": build_id, "assignment_id": row["assignment_id"],
                                     "visit_id": row["visit_id"], "status": row["status"]},
                                    request_id=f"simulator-build:{build_id}:{outcome}")
        except Exception:  # noqa: BLE001 - a journal note must never fail the registration
            pass
        if self._notify is not None:
            try:
                self._notify(feature_id)
            except Exception:  # noqa: BLE001
                pass

    def _observe_preview(self, row: Mapping[str, Any], *, refresh_portal: bool) -> dict[str, Any]:
        """Refresh one preview's operation (and portal when useful) from SimPortal."""

        operation_id = row.get("latest_operation_id")
        portal_id = row.get("portal_id")
        if not operation_id or not portal_id:
            return dict(row)
        try:
            client = self._client()
            operation = _operation_snapshot(client.operation(operation_id).get("operation"))
            previous = _loads(row.get("operation_json"), {}) or {}
            fetch_portal = refresh_portal or (operation and (operation.get("step") != previous.get("step")
                                                             or operation.get("status") != previous.get("status")))
            detail = client.portal(portal_id) if fetch_portal else None
        except SimPortalError:
            return dict(row)
        self._apply_preview_observation(row, operation, detail)
        fresh = self._row("SELECT * FROM sim_previews WHERE id=?", (row["id"],)) or dict(row)
        if fresh.get("pending_stop") and operation:
            if operation["status"] in TERMINAL_OPERATION_STATUSES:
                self._issue_pending_stop(fresh)
            elif operation.get("kind") == "start":
                self._ensure_cancel(fresh, operation)
            fresh = self._row("SELECT * FROM sim_previews WHERE id=?", (row["id"],)) or fresh
        return fresh

    def _ensure_cancel(self, row: Mapping[str, Any], operation: Mapping[str, Any]) -> None:
        """One persisted cancellation per start the user asked to stop."""

        if operation.get("status") in {"cancel_requested"} | TERMINAL_OPERATION_STATUSES:
            return
        stamp = _iso(self._now())
        request_id = str(uuid.uuid4())
        with self._transaction() as db:
            if db.execute("SELECT 1 FROM sim_outbox WHERE preview_id=? AND action='cancel' AND path=?",
                          (row["id"], f"/api/operations/{operation['id']}/cancel")).fetchone():
                return
            db.execute("INSERT INTO sim_outbox(request_id,server_id,origin,method,path,body_json,action,feature_id,"
                       "build_id,preview_id,state,next_attempt_at,created_at,updated_at) "
                       "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       (request_id, row["server_id"], row["origin"], "POST", f"/api/operations/{operation['id']}/cancel",
                        _dumps({"requestId": request_id}), "cancel", row["feature_id"], row["build_id"], row["id"],
                        "pending", 0, stamp, stamp))
        self._flush_outbox(preview_id=row["id"])

    def _apply_preview_observation(self, row: Mapping[str, Any], operation: dict[str, Any] | None,
                                   detail: Mapping[str, Any] | None) -> None:
        stamp = _iso(self._now())
        updates: dict[str, Any] = {"updated_at": stamp}
        if operation:
            updates["operation_json"] = _dumps(operation)
            if operation.get("udid") and not row.get("udid"):
                updates["udid"] = operation["udid"]
        if isinstance(detail, Mapping):
            portal = detail.get("portal") if isinstance(detail.get("portal"), Mapping) else {}
            if portal.get("id") == row.get("portal_id") and str(portal.get("serverId") or "").lower() == row["server_id"]:
                updates["status"] = str(portal.get("status") or row["status"])[:40]
                if isinstance(portal.get("udid"), str):
                    updates["udid"] = portal["udid"]
                if isinstance(portal.get("viewerPath"), str):
                    updates["viewer_path"] = portal["viewerPath"][:200]
                links = portal.get("links") if isinstance(portal.get("links"), Mapping) else None
                if links is not None:
                    updates["links_json"] = _dumps({k: links.get(k) for k in ("path", "local", "tailnet")})
                if portal.get("status") in RUNNING_STATUSES and not row.get("last_active_at"):
                    updates["last_active_at"] = stamp
                observation = detail.get("observation") if isinstance(detail.get("observation"), Mapping) else None
                if observation is not None:
                    updates["observation_json"] = _dumps({
                        "device_state": observation.get("deviceState"), "viewer_count": observation.get("viewerCount"),
                        "helper_ready": observation.get("helperReady"), "last_frame_at": observation.get("lastFrameAt"),
                        "observed_at": observation.get("observedAt")})
                    updates["observed_at"] = stamp
                    viewers = observation.get("viewerCount")
                    if isinstance(viewers, int) and viewers > 0:
                        updates["last_active_at"] = stamp
            error = operation.get("error") if operation else None
            updates["error_json"] = _dumps(error) if error else None
        elif operation and operation["status"] in TERMINAL_OPERATION_STATUSES and operation.get("error"):
            updates["error_json"] = _dumps(operation["error"])
        columns = ",".join(f"{name}=?" for name in updates)
        with self._transaction() as db:
            db.execute(f"UPDATE sim_previews SET {columns} WHERE id=?", (*updates.values(), row["id"]))

    def _issue_pending_stop(self, row: Mapping[str, Any]) -> None:
        mode = row.get("pending_stop")
        if mode not in {"stream", "shutdown"}:
            return
        status = row.get("status")
        if status == "stopped" or (not row.get("udid") and status in {"failed", "cancelled"}):
            with self._transaction() as db:
                db.execute("UPDATE sim_previews SET pending_stop=NULL WHERE id=?", (row["id"],))
            return
        self._enqueue_stop(row, mode=mode, reason=row.get("stop_reason") or "user")

    # Previews --------------------------------------------------------------------------------

    def _previews_on(self, server_id: str | None) -> list[dict[str, Any]]:
        if not server_id:
            return []
        return self._rows("SELECT * FROM sim_previews WHERE server_id=? ORDER BY created_at", (server_id,))

    def _phase(self, row: Mapping[str, Any]) -> str:
        operation = _loads(row.get("operation_json"), {}) or {}
        status = row.get("status")
        op_status = operation.get("status")
        op_kind = operation.get("kind")
        if status in {"submitting", "queued"} or (op_kind == "start" and op_status not in TERMINAL_OPERATION_STATUSES
                                                   and status not in {"failed", "conflict"}):
            return "stopping" if row.get("pending_stop") and op_status == "cancel_requested" else "starting"
        if status in {"stopping", "releasing_stream", "shutting_down"} or (op_kind == "stop" and op_status not in TERMINAL_OPERATION_STATUSES):
            return "stopping"
        if row.get("pending_stop"):
            return "stopping"
        if status in RUNNING_STATUSES:
            observation = _loads(row.get("observation_json"), {}) or {}
            if observation.get("device_state") and observation.get("device_state") != "Booted":
                return "stopped"
            return "running"
        if status == "stopped":
            return "stopped"
        if status == "cancelled":
            return "cancelled"
        if status in {"interrupted", "outcome_unknown"}:
            return "uncertain"
        if status in {"failed", "conflict"}:
            return "failed"
        if status in START_STEPS:
            return "starting"
        return "unknown"

    def open_preview(self, feature_id: str, build_id: str, *, request_id: str, device_type: str | None = None,
                     runtime: str | None = None) -> dict[str, Any]:
        """Show this build in a simulator: reuse one already starting or running, else start one."""

        self._require_configured()
        payload = {"build_id": build_id, "device_type": device_type, "runtime": runtime}
        with self._open_lock:
            cached = self._receipt(f"open:{feature_id}", request_id, payload)
            if cached is not None:
                preview = self._row("SELECT * FROM sim_previews WHERE id=?", (cached.get("preview_id"),))
                if preview is not None:
                    return {"preview": self._project_preview(preview), "reused": bool(cached.get("reused")),
                            "stopped_to_make_room": []}
            build = self._row("SELECT * FROM sim_builds WHERE build_id=? AND feature_id=?", (build_id, feature_id))
            if build is None:
                raise SimulatorPreviewError("That simulator build does not belong to this feature", code="not_found", status=404)
            discovery = self._require(allowed={"ready", "storage_low"}, action="open this simulator build")
            if build["server_id"] != discovery.pinned_server_id:
                raise SimulatorPreviewError("That build belongs to a previous SimPortal server", code="simulator_server_changed")
            for preview in reversed(self._rows("SELECT * FROM sim_previews WHERE build_id=? AND server_id=? ORDER BY created_at",
                                               (build_id, discovery.pinned_server_id))):
                if (device_type and preview["device_type"] != device_type) or (runtime and preview["runtime"] != runtime):
                    continue
                if self._phase(preview) == "running":
                    preview = self._observe_preview(preview, refresh_portal=True)
                if self._phase(preview) in {"starting", "running"}:
                    self._touch(preview["id"])
                    self._select(feature_id, build_id)
                    self._save_receipt(f"open:{feature_id}", request_id, payload, {"preview_id": preview["id"], "reused": True})
                    fresh = self._row("SELECT * FROM sim_previews WHERE id=?", (preview["id"],)) or preview
                    return {"preview": self._project_preview(fresh), "reused": True, "stopped_to_make_room": []}
            if discovery.state != "ready":
                self._require(allowed={"ready"}, action="start a new simulator")
            try:
                detail = self._client().build(build_id)
            except SimPortalError as exc:
                raise SimulatorPreviewError("SimPortal could not confirm this build: " + str(exc),
                                            code="simulator_unavailable", status=503) from None
            remote = detail.get("build") if isinstance(detail.get("build"), Mapping) else {}
            scope = remote.get("scope") if isinstance(remote.get("scope"), Mapping) else {}
            if (remote.get("id") != build_id or str(remote.get("serverId") or "").lower() != build["server_id"]
                    or scope.get("projectId") != build["project_id"] or scope.get("checkpointId") != build["checkpoint_id"]):
                raise SimulatorPreviewError("SimPortal's copy of this build does not match Herdr's record",
                                            code="simulator_identity_mismatch")
            if remote.get("status") != "ready":
                raise SimulatorPreviewError(f"This build is not ready in SimPortal (it is {remote.get('status')}).",
                                            code="simulator_build_not_ready")
            artifact = remote.get("artifact") if isinstance(remote.get("artifact"), Mapping) else {}
            device = self._choose_device(discovery.capabilities or {}, minimum_os=artifact.get("minimumOS"),
                                         device_type=device_type, runtime=runtime)
            evicted = self._make_room(discovery.pinned_server_id)
            preview_id = "fmsp_" + uuid.uuid4().hex
            start_request = str(uuid.uuid4())
            body = {"requestId": start_request, "name": _clip("Herdr · " + build["checkpoint_label"], _NAME_MAX),
                    "buildId": build_id, "deviceType": device["device_type"], "runtime": device["runtime"]}
            stamp = _iso(self._now())
            with self._transaction() as db:
                db.execute("INSERT INTO sim_previews(id,server_id,origin,feature_id,build_id,start_request_id,device_type,"
                           "runtime,device_json,status,last_active_at,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                           (preview_id, build["server_id"], self._origin, feature_id, build_id, start_request,
                            device["device_type"], device["runtime"], _dumps(device), "submitting", stamp, stamp, stamp))
                db.execute("INSERT INTO sim_outbox(request_id,server_id,origin,method,path,body_json,action,feature_id,"
                           "build_id,preview_id,state,next_attempt_at,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                           (start_request, build["server_id"], self._origin, "POST", "/api/portals", _dumps(body), "start",
                            feature_id, build_id, preview_id, "pending", 0, stamp, stamp))
                self._select_in(db, feature_id, build_id, stamp)
                self._save_receipt_in(db, f"open:{feature_id}", request_id, payload,
                                      {"preview_id": preview_id, "reused": False})
        self._flush_outbox(preview_id=preview_id)
        self.wake()
        row = self._row("SELECT * FROM sim_previews WHERE id=?", (preview_id,))
        assert row is not None
        return {"preview": self._project_preview(row), "reused": False, "stopped_to_make_room": evicted}

    def _make_room(self, server_id: str | None) -> list[dict[str, Any]]:
        """Keep Herdr's running simulators within the cap by shutting down the least recently watched idle one."""

        active = [p for p in self._previews_on(server_id) if self._phase(p) in {"starting", "running"}]
        if len(active) < self.settings.max_running:
            return []
        candidates = []
        for preview in active:
            if self._phase(preview) != "running" or self._relay_count(preview["id"]) > 0:
                continue
            fresh = self._observe_preview(preview, refresh_portal=True)
            observation = _loads(fresh.get("observation_json"), {}) or {}
            if isinstance(observation.get("viewer_count"), int) and observation["viewer_count"] > 0:
                continue
            if self._phase(fresh) == "running":
                candidates.append(fresh)
        needed = len(active) - self.settings.max_running + 1
        if needed > len(candidates):
            details = {"running": [self._project_preview(p, brief=True) for p in active],
                       "max_running_previews": self.settings.max_running}
            raise SimulatorPreviewError(
                f"{len(active)} Herdr simulators are running and in use. Stop one to open another.",
                code="simulator_capacity", details=details)
        evicted = []
        for victim in sorted(candidates, key=lambda p: _epoch(p.get("last_active_at")) or 0)[:needed]:
            self._enqueue_stop(victim, mode="shutdown", reason="capacity")
            evicted.append(self._project_preview(victim, brief=True))
        return evicted

    def _enqueue_stop(self, row: Mapping[str, Any], *, mode: str, reason: str) -> None:
        if not row.get("portal_id"):
            with self._transaction() as db:
                db.execute("UPDATE sim_previews SET pending_stop=?,stop_reason=? WHERE id=?", (mode, reason, row["id"]))
            return
        request_id = str(uuid.uuid4())
        stamp = _iso(self._now())
        with self._transaction() as db:
            db.execute("INSERT INTO sim_outbox(request_id,server_id,origin,method,path,body_json,action,feature_id,build_id,"
                       "preview_id,state,next_attempt_at,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       (request_id, row["server_id"], row["origin"], "POST", f"/api/portals/{row['portal_id']}/stop",
                        _dumps({"requestId": request_id, "mode": mode}), "stop", row["feature_id"], row["build_id"],
                        row["id"], "pending", 0, stamp, stamp))
            db.execute("UPDATE sim_previews SET pending_stop=NULL,stop_reason=?,status=CASE WHEN status IN "
                       "('ready','stream_released') THEN 'stopping' ELSE status END,updated_at=? WHERE id=?",
                       (reason, stamp, row["id"]))
        self._flush_outbox(preview_id=row["id"])

    def stop_preview(self, feature_id: str, preview_id: str, *, request_id: str, mode: str = "shutdown") -> dict[str, Any]:
        """The user's explicit stop. A start in progress is cancelled first, then stopped once it settles."""

        self._require_configured()
        if mode not in {"shutdown", "stream"}:
            raise SimulatorPreviewError("mode must be shutdown or stream", code="invalid_request", status=400)
        payload = {"preview_id": preview_id, "mode": mode}
        row = self._row("SELECT * FROM sim_previews WHERE id=? AND feature_id=?", (preview_id, feature_id))
        if row is None:
            raise SimulatorPreviewError("That preview does not belong to this feature", code="not_found", status=404)
        if self._receipt(f"stop:{feature_id}", request_id, payload) is not None:
            return {"preview": self._project_preview(row)}
        discovery = self._require(allowed={"ready", "storage_low"}, action="stop this simulator")
        if row["server_id"] != discovery.pinned_server_id:
            raise SimulatorPreviewError("That preview belongs to a previous SimPortal server", code="simulator_server_changed")
        if row.get("portal_id"):
            row = self._observe_preview(row, refresh_portal=True)
        phase = self._phase(row)
        operation = _loads(row.get("operation_json"), {}) or {}
        observation = _loads(row.get("observation_json"), {}) or {}
        booted = observation.get("device_state") == "Booted"
        if not row.get("portal_id"):
            with self._transaction() as db:
                db.execute("UPDATE sim_previews SET pending_stop=?,stop_reason='user' WHERE id=?", (mode, preview_id))
        elif operation.get("kind") == "start" and operation.get("status") not in TERMINAL_OPERATION_STATUSES:
            with self._transaction() as db:
                db.execute("UPDATE sim_previews SET pending_stop=?,stop_reason='user',updated_at=? WHERE id=?",
                           (mode, _iso(self._now()), preview_id))
            self._ensure_cancel(row, operation)
        elif phase == "running" or (phase in {"failed", "cancelled", "uncertain"} and row.get("udid") and booted):
            # A failed or uncertain start can leave its owned simulator booted; an observed Booted state
            # is the reconciliation that makes the user's explicit shutdown safe.
            self._enqueue_stop(row, mode=mode, reason="user")
        self._save_receipt(f"stop:{feature_id}", request_id, payload, {"preview_id": preview_id})
        self.wake()
        fresh = self._row("SELECT * FROM sim_previews WHERE id=?", (preview_id,))
        assert fresh is not None
        return {"preview": self._project_preview(fresh)}

    def preview_detail(self, feature_id: str, preview_id: str) -> dict[str, Any]:
        self._require_configured()
        row = self._row("SELECT * FROM sim_previews WHERE id=? AND feature_id=?", (preview_id, feature_id))
        if row is None:
            raise SimulatorPreviewError("That preview does not belong to this feature", code="not_found", status=404)
        if row.get("status") == "submitting":
            self._flush_outbox(preview_id=preview_id)
            row = self._row("SELECT * FROM sim_previews WHERE id=?", (preview_id,)) or row
        discovery = self._discover(max_age=CAPABILITY_TTL)
        if row["server_id"] == discovery.pinned_server_id and discovery.state in {"ready", "storage_low"}:
            observed = _epoch(row.get("observed_at")) or 0
            operation = _loads(row.get("operation_json"), {}) or {}
            active = operation.get("status") not in TERMINAL_OPERATION_STATUSES
            if active or self._now() - observed >= OBSERVATION_TTL:
                row = self._observe_preview(row, refresh_portal=not active or self._now() - observed >= OBSERVATION_TTL)
        build = self._row("SELECT * FROM sim_builds WHERE build_id=?", (row["build_id"],))
        return {"preview": self._project_preview(row),
                "build": self._project_build(build, previews=[]) if build else None,
                "feature": self._feature_summary(feature_id),
                "simulator": self.status()}

    def feature_builds(self, feature_id: str) -> dict[str, Any]:
        status = self.status()
        if not self.configured:
            return {"feature_id": feature_id, "simulator": status, "builds": [], "selected_build_id": None,
                    "generated_at": _iso(self._now())}
        if self.configured and status["state"] in {"ready", "storage_low"}:
            last = self._synced.get(feature_id, 0.0)
            if self._now() - last >= 10:
                self._synced[feature_id] = self._now()
                self._sync_feature_builds(feature_id)
        builds = self._rows("SELECT * FROM sim_builds WHERE feature_id=? ORDER BY created_at DESC, build_id", (feature_id,))
        previews = self._rows("SELECT * FROM sim_previews WHERE feature_id=? ORDER BY created_at DESC", (feature_id,))
        by_build: dict[str, list[dict[str, Any]]] = {}
        for preview in previews:
            by_build.setdefault(preview["build_id"], []).append(preview)
        selection = self._row("SELECT build_id,selected_at FROM sim_selection WHERE feature_id=?", (feature_id,))
        return {"feature_id": feature_id, "simulator": status,
                "builds": [self._project_build(build, previews=by_build.get(build["build_id"], [])) for build in builds],
                "selected_build_id": selection["build_id"] if selection else None,
                "generated_at": _iso(self._now())}

    def _sync_feature_builds(self, feature_id: str) -> None:
        """Pick up SimPortal-side changes (such as cleanup) and builds registered for this feature elsewhere."""

        feature_scope = feature_id if is_scope_id(feature_id) else None
        if feature_scope is None:
            return
        cursor = None
        seen = 0
        try:
            client = self._client()
            while seen < 500:
                page = client.builds(project_id=self.settings.project_id, feature_id=feature_scope, after=cursor)
                builds = page.get("builds") if isinstance(page.get("builds"), list) else []
                seen += len(builds)
                for remote in builds:
                    if isinstance(remote, Mapping):
                        self._merge_remote_build(feature_id, remote)
                cursor = page.get("nextCursor")
                if not isinstance(cursor, str) or not cursor:
                    break
        except SimPortalError:
            return

    def _merge_remote_build(self, feature_id: str, remote: Mapping[str, Any]) -> None:
        build_id = remote.get("id")
        scope = remote.get("scope") if isinstance(remote.get("scope"), Mapping) else {}
        server_id = str(remote.get("serverId") or "").lower()
        if not is_uuid(build_id) or scope.get("featureId") != feature_id or scope.get("projectId") != self.settings.project_id:
            return
        status = str(remote.get("status") or "unknown")[:40]
        artifact = remote.get("artifact") if isinstance(remote.get("artifact"), Mapping) else None
        stamp = _iso(self._now())
        with self._transaction() as db:
            row = db.execute("SELECT build_id,server_id,status FROM sim_builds WHERE build_id=?", (build_id,)).fetchone()
            if row is None:
                source = remote.get("source") if isinstance(remote.get("source"), Mapping) else {}
                db.execute(
                    "INSERT INTO sim_builds(build_id,server_id,origin,project_id,feature_id,scope_session_id,checkpoint_id,"
                    "checkpoint_label,name,origin_kind,source_json,status,artifact_json,created_at,updated_at,observed_at) "
                    "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (build_id, server_id, self._origin, self.settings.project_id, feature_id,
                     str(scope.get("sessionId") or "unknown")[:128], str(scope.get("checkpointId") or "checkpoint")[:128],
                     _clip(scope.get("checkpointLabel") or scope.get("checkpointId") or "Checkpoint", _LABEL_MAX),
                     _clip(remote.get("name") or "Simulator build", _NAME_MAX), "external",
                     _dumps({k: source.get(k) for k in ("revision", "workingTree", "configuration", "target") if source.get(k)}),
                     status, _dumps(_artifact_record(artifact)) if artifact else None,
                     str(remote.get("createdAt") or stamp)[:40], stamp, stamp))
            elif (row["server_id"] == server_id and row["status"] in BUILD_SETTLED_STATUSES
                  and row["status"] not in {"conflict", status}):
                db.execute("UPDATE sim_builds SET status=?,artifact_json=COALESCE(?,artifact_json),observed_at=?,updated_at=? "
                           "WHERE build_id=?", (status, _dumps(_artifact_record(artifact)) if artifact else None,
                                                stamp, stamp, build_id))

    # Idle policy ---------------------------------------------------------------------------------

    def _reap(self) -> None:
        """Shut down Herdr's own previews that nobody has watched for the idle window."""

        idle_seconds = self.settings.idle_minutes * 60
        discovery = self._discover(max_age=CAPABILITY_TTL)
        if discovery.state not in {"ready", "storage_low"}:
            return
        for row in self._previews_on(discovery.pinned_server_id):
            if self._phase(row) != "running":
                continue
            row = self._observe_preview(row, refresh_portal=True)
            if self._phase(row) != "running":
                continue
            observation = _loads(row.get("observation_json"), {}) or {}
            if self._relay_count(row["id"]) > 0 or (isinstance(observation.get("viewer_count"), int)
                                                    and observation["viewer_count"] > 0):
                self._touch(row["id"])
                continue
            if idle_seconds <= 0:
                continue
            last = _epoch(row.get("last_active_at")) or _epoch(row.get("created_at")) or self._now()
            if self._now() - last >= idle_seconds:
                self._enqueue_stop(row, mode="shutdown", reason="idle")

    def _touch(self, preview_id: str) -> None:
        with self._transaction() as db:
            db.execute("UPDATE sim_previews SET last_active_at=? WHERE id=?", (_iso(self._now()), preview_id))

    def _relay_count(self, preview_id: str) -> int:
        with self._relay_lock:
            return self._relays.get(preview_id, 0)

    # Receipts and selection ---------------------------------------------------------------------

    def _receipt(self, scope: str, request_id: str, payload: Mapping[str, Any]) -> dict[str, Any] | None:
        digest = hashlib.sha256(_dumps(payload).encode("utf-8")).hexdigest()
        row = self._row("SELECT payload_hash,result_json FROM sim_receipts WHERE scope=? AND request_id=?", (scope, request_id))
        if row is None:
            return None
        if row["payload_hash"] != digest:
            raise SimulatorPreviewError("request_id was already used for a different request", code="idempotency_conflict")
        return _loads(row["result_json"], {})

    def _save_receipt(self, scope: str, request_id: str, payload: Mapping[str, Any], result: Mapping[str, Any]) -> None:
        with self._transaction() as db:
            self._save_receipt_in(db, scope, request_id, payload, result)

    def _save_receipt_in(self, db: sqlite3.Connection, scope: str, request_id: str, payload: Mapping[str, Any],
                         result: Mapping[str, Any]) -> None:
        digest = hashlib.sha256(_dumps(payload).encode("utf-8")).hexdigest()
        db.execute("INSERT OR IGNORE INTO sim_receipts VALUES(?,?,?,?,?)",
                   (scope, request_id, digest, _dumps(result), _iso(self._now())))

    def _select(self, feature_id: str, build_id: str) -> None:
        with self._transaction() as db:
            self._select_in(db, feature_id, build_id, _iso(self._now()))

    @staticmethod
    def _select_in(db: sqlite3.Connection, feature_id: str, build_id: str, stamp: str) -> None:
        db.execute("INSERT INTO sim_selection VALUES(?,?,?) ON CONFLICT(feature_id) DO UPDATE SET "
                   "build_id=excluded.build_id,selected_at=excluded.selected_at", (feature_id, build_id, stamp))

    # Projections --------------------------------------------------------------------------------

    def _feature_summary(self, feature_id: str) -> dict[str, Any] | None:
        if self.store is None:
            return None
        try:
            from . import first_mate_fleet
            rows = self.store.fleet_rows("all", feature_id=feature_id)
            if rows:
                entry = first_mate_fleet.entry(rows[0])
                return {"id": feature_id, "title": entry.get("title"), "label": entry.get("label"),
                        "emoji": entry.get("emoji")}
            feature = self.store.get_feature(feature_id)
            return {"id": feature_id, "title": feature.get("title"), "label": None, "emoji": None}
        except Exception:  # noqa: BLE001 - presentation only
            return None

    def _project_build(self, row: Mapping[str, Any], *, previews: list[Mapping[str, Any]]) -> dict[str, Any]:
        pinned = self._reachable_server()
        artifact = _loads(row.get("artifact_json"), None) or {}
        reported = _loads(row.get("app_json"), {}) or {}
        source = _loads(row.get("source_json"), {}) or {}
        status = row["status"]
        shown = status if status in BUILD_SETTLED_STATUSES else "registering"
        app = None
        if artifact or reported:
            app = {"name": reported.get("name") or None,
                   "bundle_id": artifact.get("bundle_id") or reported.get("bundle_id"),
                   "version": artifact.get("version") or reported.get("version"),
                   "build": artifact.get("build") or reported.get("build"),
                   "minimum_os": artifact.get("minimum_os") or reported.get("minimum_os")}
        available = row["server_id"] == pinned
        return {
            "id": row["build_id"], "feature_id": row["feature_id"], "server_id": row["server_id"],
            "name": row["name"], "checkpoint_id": row["checkpoint_id"], "checkpoint_label": row["checkpoint_label"],
            "stage_title": row.get("stage_title"), "visit_id": row.get("visit_id"),
            "assignment_id": row.get("assignment_id"), "native_session_id": row.get("native_session_id"),
            "hub_build_id": row.get("hub_build_id"), "origin": row.get("origin_kind") or "agent",
            "status": shown if available else "unavailable",
            "status_detail": None if available else "SimPortal on this machine is not the server that saved this build",
            "app": app, "digest": artifact.get("digest"), "bytes": artifact.get("bytes") or reported.get("bytes"),
            "source": {"revision": source.get("revision"), "working_tree": source.get("workingTree"),
                       "configuration": source.get("configuration"), "target": source.get("target")},
            "error": _loads(row.get("error_json"), None),
            "launchable": available and status == "ready",
            "created_at": row["created_at"], "updated_at": row["updated_at"],
            "previews": [self._project_preview(p, brief=True) for p in previews[:5]],
        }

    def _project_preview(self, row: Mapping[str, Any], *, brief: bool = False) -> dict[str, Any]:
        operation = _loads(row.get("operation_json"), None)
        observation = _loads(row.get("observation_json"), None)
        device = _loads(row.get("device_json"), {}) or {}
        phase = self._phase(row) if row["server_id"] == self._reachable_server() else "unavailable"
        status = row["status"]
        steps = (operation or {}).get("steps") or []
        booted = any(step.get("name") == "booting" and step.get("state") == "succeeded" for step in steps)
        stream_available = bool(row.get("udid")) and phase in {"starting", "running"} and (
            status in STREAMABLE_STATUSES or booted)
        idle_at = None
        last_active = _epoch(row.get("last_active_at"))
        if phase == "running" and self.settings.idle_minutes > 0 and last_active and self._relay_count(row["id"]) == 0:
            idle_at = _iso(last_active + self.settings.idle_minutes * 60)
        projection: dict[str, Any] = {
            "id": row["id"], "feature_id": row["feature_id"], "build_id": row["build_id"],
            "portal_id": row.get("portal_id"), "phase": phase, "status": status,
            "device": {"device_type": row["device_type"], "runtime": row["runtime"],
                       "device_type_name": device.get("device_type_name"), "runtime_name": device.get("runtime_name")},
            "stop_reason": row.get("stop_reason"), "last_active_at": row.get("last_active_at"),
            "created_at": row["created_at"], "updated_at": row["updated_at"],
        }
        if brief:
            return projection
        links = _loads(row.get("links_json"), {}) or {}
        projection.update({
            "udid": row.get("udid"),
            "stream_available": stream_available,
            "operation": operation,
            "observation": observation,
            "error": _loads(row.get("error_json"), None),
            "browser_links": _browser_links(links, row.get("udid")),
            "idle": {"shutdown_after_minutes": self.settings.idle_minutes, "shutdown_at": idle_at,
                     "watchers": self._relay_count(row["id"])},
        })
        return projection

    # Stream relay ------------------------------------------------------------------------------------

    def open_stream(self, feature_id: str, preview_id: str) -> "PreviewStream":
        """Validate and dial SimPortal's viewer socket before the client is upgraded."""

        self._require_configured()
        row = self._row("SELECT * FROM sim_previews WHERE id=? AND feature_id=?", (preview_id, feature_id))
        if row is None:
            raise SimulatorPreviewError("That preview does not belong to this feature", code="not_found", status=404)
        discovery = self._require(allowed={"ready", "storage_low"}, action="stream this simulator")
        if row["server_id"] != discovery.pinned_server_id or row.get("origin") != self._origin:
            raise SimulatorPreviewError("That preview belongs to a previous SimPortal server", code="simulator_server_changed")
        udid = row.get("udid")
        phase = self._phase(row)
        if not isinstance(udid, str) or not udid or not re.fullmatch(r"[A-Fa-f0-9-]{36}", udid) or phase not in {"starting", "running"}:
            raise SimulatorPreviewError("This preview is not running", code="simulator_preview_not_running", status=409)
        if not self._stream_slots.acquire(blocking=False):
            raise SimulatorPreviewError("Too many simulator streams are open on this companion", code="simulator_stream_limit", status=503)
        try:
            client = self._client()
            upstream = self._dial(client.origin, "/ws/devices/" + udid,
                                  headers={"Authorization": "Bearer " + client.token, "User-Agent": "herdr-companion-simportal/1"},
                                  timeout=10, max_message=MAX_STREAM_MESSAGE)
        except (SimPortalError, OSError, ws.WebSocketProtocolError) as exc:
            self._stream_slots.release()
            if isinstance(exc, SimPortalError) and exc.code in {"simulator_unconfigured", "simulator_misconfigured"}:
                raise SimulatorPreviewError(str(exc), code=exc.code, status=503) from None
            raise SimulatorPreviewError("SimPortal's viewer is not reachable", code="simulator_unavailable", status=503) from None
        return PreviewStream(self, preview_id, upstream)

    def _relay_opened(self, preview_id: str) -> None:
        with self._relay_lock:
            self._relays[preview_id] = self._relays.get(preview_id, 0) + 1
        self._touch(preview_id)

    def _relay_closed(self, preview_id: str) -> None:
        with self._relay_lock:
            remaining = self._relays.get(preview_id, 0) - 1
            if remaining > 0:
                self._relays[preview_id] = remaining
            else:
                self._relays.pop(preview_id, None)
        self._touch(preview_id)
        self._stream_slots.release()


class PreviewStream:
    """One client's relay to one exact simulator's viewer socket."""

    ALLOWED = frozenset({"hello", "quality", "keyframe", "ping", "touch", "key", "button", "text", "paste"})
    INPUT = frozenset({"touch", "key", "button", "text", "paste"})

    def __init__(self, owner: SimulatorPreviews, preview_id: str, upstream: ws.FrameSocket) -> None:
        self.owner = owner
        self.preview_id = preview_id
        self.upstream = upstream
        self._last_touch = 0.0

    def abandon(self) -> None:
        """The client upgrade failed after dialing; release SimPortal's socket."""

        self.upstream.close()
        self.upstream.shutdown()
        try:
            self.upstream.sock.close()
        except OSError:
            pass
        self.owner._stream_slots.release()

    def run(self, client_sock: socket.socket, client_reader: Any) -> None:
        """Relay until either side closes. Blocks the calling (request) thread."""

        downstream = ws.FrameSocket(client_sock, client_reader, client=False, max_message=MAX_CLIENT_MESSAGE)
        client_sock.settimeout(STREAM_IDLE_TIMEOUT)
        self.upstream.sock.settimeout(STREAM_IDLE_TIMEOUT)
        self.owner._relay_opened(self.preview_id)
        pump = threading.Thread(target=self._pump_upstream, args=(downstream,), name="simulator-stream", daemon=True)
        pump.start()
        try:
            while True:
                opcode, payload = downstream.receive()
                if opcode != ws.OP_TEXT:
                    continue
                message = sanitize_client_message(payload)
                if message is None:
                    continue
                if message["type"] in self.INPUT:
                    now = self.owner._now()
                    if now - self._last_touch > 15:
                        self._last_touch = now
                        self.owner._touch(self.preview_id)
                self.upstream.send_text(_dumps(message))
        except (ws.WebSocketClosed, ws.WebSocketProtocolError, OSError):
            pass
        finally:
            downstream.close()
            self.upstream.close()
            downstream.shutdown()
            self.upstream.shutdown()
            pump.join(timeout=5)
            try:
                self.upstream.sock.close()
            except OSError:
                pass
            self.owner._relay_closed(self.preview_id)

    def _pump_upstream(self, downstream: ws.FrameSocket) -> None:
        try:
            while True:
                opcode, payload = self.upstream.receive()
                downstream.send(opcode, payload)
        except (ws.WebSocketClosed, ws.WebSocketProtocolError, OSError):
            pass
        finally:
            downstream.close()
            downstream.shutdown()


def sanitize_client_message(payload: bytes) -> dict[str, Any] | None:
    """Only viewer input and stream preferences pass; focus and boot never do.

    Hello always carries focus:false and observe:true, so attaching Herdr's
    window never changes SimPortal's shared focus.
    """

    try:
        message = json.loads(payload.decode("utf-8"))
    except (ValueError, UnicodeError):
        return None
    if not isinstance(message, dict) or message.get("type") not in PreviewStream.ALLOWED:
        return None
    kind = message["type"]

    def unit(value: Any) -> float | None:
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
            return None
        return max(0.0, min(1.0, float(value)))

    if kind == "hello":
        codec = message.get("codec") if message.get("codec") in {"h264", "jpeg"} else "h264"
        result: dict[str, Any] = {"type": "hello", "codec": codec, "observe": True, "focus": False}
        if message.get("quality") in {"high", "balanced", "low"}:
            result["quality"] = message["quality"]
        return result
    if kind == "quality":
        return {"type": "quality", "quality": message["quality"]} if message.get("quality") in {"high", "balanced", "low"} else None
    if kind == "keyframe":
        return {"type": "keyframe"}
    if kind == "ping":
        t = message.get("t")
        return {"type": "ping", "t": t} if isinstance(t, (int, float)) and not isinstance(t, bool) else {"type": "ping"}
    if kind == "touch":
        x, y = unit(message.get("x")), unit(message.get("y"))
        if message.get("phase") not in {"began", "moved", "ended", "cancelled"} or x is None or y is None:
            return None
        result = {"type": "touch", "phase": message["phase"], "x": x, "y": y}
        if "x2" in message or "y2" in message:
            x2, y2 = unit(message.get("x2")), unit(message.get("y2"))
            if x2 is None or y2 is None:
                return None
            result.update({"x2": x2, "y2": y2})
        return result
    if kind == "key":
        usage = message.get("usage")
        if isinstance(usage, bool) or not isinstance(usage, int) or not 0 < usage <= 0xFFFF:
            return None
        phase = message.get("phase") if message.get("phase") in {"down", "up", "press"} else "press"
        return {"type": "key", "usage": usage, "phase": phase}
    if kind == "button":
        if message.get("button") not in {"home", "lock", "siri", "side"}:
            return None
        result = {"type": "button", "button": message["button"]}
        if message.get("phase") in {"down", "up", "press"}:
            result["phase"] = message["phase"]
        return result
    text = message.get("text")
    if not isinstance(text, str) or not text or len(text) > MAX_TEXT_INPUT:
        return None
    return {"type": kind, "text": text}


def _browser_links(links: Mapping[str, Any], udid: Any) -> dict[str, str | None]:
    """Credential-free exact-simulator viewer links SimPortal returned."""

    result: dict[str, str | None] = {"local": None, "tailnet": None}
    if not isinstance(udid, str) or not udid:
        return result
    for key in ("local", "tailnet"):
        value = links.get(key)
        if not isinstance(value, str):
            continue
        try:
            parsed = urlsplit(value)
        except ValueError:
            continue
        if (parsed.scheme in {"http", "https"} and parsed.hostname and not parsed.username and not parsed.password
                and not parsed.query and not parsed.fragment and parsed.path == "/d/" + udid
                and (parsed.scheme == "https" or is_loopback_host(parsed.hostname))):
            result[key] = value
    return result


def _artifact_record(artifact: Mapping[str, Any]) -> dict[str, Any]:
    return {"bundle_id": artifact.get("bundleId"), "version": artifact.get("version"), "build": artifact.get("build"),
            "minimum_os": artifact.get("minimumOS"), "digest": artifact.get("digest"), "bytes": artifact.get("bytes"),
            "architectures": artifact.get("architectures") if isinstance(artifact.get("architectures"), list) else None}


def _same_path(left: Path, right: Path) -> bool:
    try:
        return left.resolve() == right.resolve()
    except OSError:
        return False


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root)
        return True
    except (OSError, ValueError):
        return False


def _copy_tree(source: Path, destination: Path) -> None:
    ditto = shutil.which("ditto")
    if ditto:
        subprocess.run([ditto, "--noqtn", str(source), str(destination)], check=True, timeout=600,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        shutil.copytree(source, destination, symlinks=True)


def _git(workspace: str, *args: str) -> str | None:
    try:
        result = subprocess.run(["git", "-C", workspace, *args], capture_output=True, text=True, timeout=10,
                                env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout if result.returncode == 0 else None


def _git_toplevel(workspace: str) -> str | None:
    output = _git(workspace, "rev-parse", "--show-toplevel")
    return output.strip() if output else None


def _git_state(workspace: str) -> tuple[str | None, str]:
    """HEAD and cleanliness as the companion observes them (reported to SimPortal as caller metadata)."""

    head = _git(workspace, "rev-parse", "HEAD")
    revision = head.strip() if head and re.fullmatch(r"[0-9a-f]{40,64}", head.strip()) else None
    status = _git(workspace, "status", "--porcelain", "--untracked-files=normal")
    working_tree = "unknown" if status is None else ("dirty" if status.strip() else "clean")
    return revision, working_tree
