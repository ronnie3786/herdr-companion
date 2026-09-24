"""Durable major-stage notifications through an operator-configured Message Hub.

Message Hub does not document an idempotent create operation. After an ambiguous
send, preserve an unknown receipt instead of producing duplicate phone alerts.
The in-app checkpoint remains authoritative regardless of external delivery.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path
import sqlite3
import threading
import urllib.error
import urllib.parse
import urllib.request

from .alerts import utc_now
from .secret_file import load_private_bearer_token_file, validate_bearer_token

_LOG = logging.getLogger(__name__)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class FirstMateNotifications:
    def __init__(self, store, environ, *, path=None, transport=None):
        self.store = store
        self.environ = dict(environ)
        self.url = self.environ.get("HERDR_FIRST_MATE_MESSAGE_HUB_URL", "")
        self.link = self.environ.get("HERDR_FIRST_MATE_APP_URL", "")
        self._transport = transport or self._send
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = None
        self._db = None
        if not self.url:
            return
        parsed = urllib.parse.urlsplit(self.url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
            raise ValueError("First Mate Message Hub URL must be an HTTP(S) endpoint without embedded credentials")
        root = Path(self.environ.get("HERDR_STATE_DIR") or Path.home() / ".local/share/herdr-companion")
        destination = Path(path or root / "first-mate-notifications.sqlite3")
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if destination.is_symlink():
            raise ValueError("First Mate notification database must not be a symbolic link")
        descriptor = os.open(destination, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
        self._db = sqlite3.connect(destination, check_same_thread=False)
        destination.chmod(0o600)
        self._db.row_factory = sqlite3.Row
        self._db.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS cursors(feature_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS deliveries(event_id TEXT PRIMARY KEY,feature_id TEXT NOT NULL,
          payload TEXT NOT NULL,status TEXT NOT NULL,receipt TEXT,updated_at TEXT NOT NULL);
        """)
        if "logged" not in {row[1] for row in self._db.execute("PRAGMA table_info(deliveries)")}:
            self._db.execute("ALTER TABLE deliveries ADD COLUMN logged INTEGER NOT NULL DEFAULT 0")
        self._db.execute("UPDATE deliveries SET status='unknown',receipt=? WHERE status='sending'",
                         (json.dumps({"reason": "Service restarted before delivery was confirmed. Automatic resend suppressed."}),))
        self._db.commit()

    @property
    def configured(self):
        return self._db is not None

    def start(self):
        if not self.configured or self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="first-mate-notifications", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=12)
        if self._db and not (self._thread and self._thread.is_alive()):
            self._db.close()
            self._db = None

    def _run(self):
        while not self._stop.is_set():
            try:
                self.process()
            except Exception:
                # The checkpoint remains visible; one provider failure cannot
                # stop orchestration or trigger an unbounded notification loop.
                _LOG.exception("First Mate notification processing failed")
            self._stop.wait(2)

    def process(self):
        if not self.configured or not self._lock.acquire(blocking=False):
            return
        try:
            for feature in self.store.list_features():
                row = self._db.execute("SELECT sequence FROM cursors WHERE feature_id=?", (feature["id"],)).fetchone()
                events = self.store.get_events(feature["id"], after=row[0] if row else 0)
                with self._db:
                    for event in events["events"]:
                        if event["type"] not in {"visit.awaiting_direction", "assignment.dispatch_unknown", "assignment.recovery_exhausted", "reliability.blocked", "coordinator.interrupted"}:
                            continue
                        payload = {"title": feature["title"], "sender": "Herdr · First Mate", "text": event["summary"],
                                   "notify": True, "urgency": "active", "metadata": {"feature_id": feature["id"], "event_id": event["id"]}}
                        if self.link:
                            parsed = urllib.parse.urlsplit(self.link)
                            params = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
                            params = [(k, v) for k, v in params if k != "feature"] + [("feature", feature["id"])]
                            payload["link"] = urllib.parse.urlunsplit(parsed._replace(query=urllib.parse.urlencode(params)))
                        self._db.execute("INSERT OR IGNORE INTO deliveries(event_id,feature_id,payload,status,receipt,updated_at) VALUES(?,?,?,'pending',NULL,?)",
                                         (event["id"], feature["id"], json.dumps(payload), utc_now()))
                    self._db.execute("INSERT INTO cursors VALUES(?,?) ON CONFLICT(feature_id) DO UPDATE SET sequence=excluded.sequence",
                                     (feature["id"], events["cursor"]))
            rows = self._db.execute("SELECT * FROM deliveries WHERE status='pending' ORDER BY updated_at").fetchall()
            for row in rows:
                if self._stop.is_set():
                    break
                with self._db:
                    self._db.execute("UPDATE deliveries SET status='sending',updated_at=? WHERE event_id=?", (utc_now(), row["event_id"]))
                try:
                    receipt = self._transport(json.loads(row["payload"]))
                    delivered = receipt.get("notification", {}).get("delivered") is True
                    status = "delivered" if delivered else "mac_only"
                    safe_receipt = {"message_id": receipt.get("id"), "phone_delivered": delivered}
                except urllib.error.HTTPError as error:
                    status, safe_receipt = "failed", {"http_status": error.code}
                except Exception:
                    status, safe_receipt = "unknown", {"reason": "Delivery could not be confirmed. Automatic resend suppressed."}
                with self._db:
                    self._db.execute("UPDATE deliveries SET status=?,receipt=?,updated_at=? WHERE event_id=?",
                                     (status, json.dumps(safe_receipt), utc_now(), row["event_id"]))
            # Work-log publication is independently replayable if the service
            # stops after saving a provider receipt but before logging it.
            for row in self._db.execute("SELECT * FROM deliveries WHERE logged=0 AND status NOT IN ('pending','sending')").fetchall():
                status = row["status"]
                self.store.append_event(row["feature_id"], "notification." + status,
                                        {"delivered": "First Mate notification delivered", "mac_only": "First Mate message saved; phone delivery unconfirmed",
                                         "failed": "First Mate notification rejected", "unknown": "First Mate notification delivery unknown"}[status],
                                        {"checkpoint_event_id": row["event_id"], **json.loads(row["receipt"] or "{}")}, request_id="notification:" + row["event_id"])
                with self._db:
                    self._db.execute("UPDATE deliveries SET logged=1 WHERE event_id=?", (row["event_id"],))
        finally:
            self._lock.release()

    def _send(self, payload):
        headers = {"Content-Type": "application/json"}
        token = self.environ.get("HERDR_FIRST_MATE_MESSAGE_HUB_TOKEN", "")
        token_file = self.environ.get("HERDR_FIRST_MATE_MESSAGE_HUB_TOKEN_FILE")
        if token:
            token = validate_bearer_token(token, field="Message Hub token")
        elif token_file:
            token = load_private_bearer_token_file(token_file, field="Message Hub token")
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(self.url, data=json.dumps(payload).encode(), headers=headers)
        with urllib.request.build_opener(_NoRedirect()).open(request, timeout=8) as response:
            return json.loads(response.read(65536))
