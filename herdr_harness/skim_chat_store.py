"""Private, bounded cache for on-demand Mac chat skims."""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
import sqlite3
import threading
import time

from .agent_runs import AgentRunError


class ChatSkimStore:
    def __init__(self, path: str = ":memory:") -> None:
        if path != ":memory:":
            directory = Path(path).parent
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._db = sqlite3.connect(path, check_same_thread=False)
        if path != ":memory:":
            os.chmod(path, 0o600)
        self._lock = threading.RLock()
        self._db.execute("CREATE TABLE IF NOT EXISTS chat_skims (id TEXT PRIMARY KEY, state TEXT NOT NULL, source TEXT, touched REAL NOT NULL)")
        self._db.commit()

    def get(self, identifier: str) -> dict | None:
        with self._lock:
            row = self._db.execute("SELECT state FROM chat_skims WHERE id = ?", (identifier,)).fetchone()
            return json.loads(row[0]) if row else None

    def create(self, identifier: str, state: dict, question: str | None, reply: str) -> dict:
        with self._lock:
            existing = self.get(identifier)
            if existing is not None:
                return existing
            pending = self._db.execute("SELECT COUNT(*) FROM chat_skims WHERE source IS NOT NULL").fetchone()[0]
            if pending >= 32:
                raise AgentRunError("The skim queue is full.", code="skim_busy", status=429)
            # Keep at most 256 records. Never evict work that is still queued.
            self._db.execute("DELETE FROM chat_skims WHERE id IN (SELECT id FROM chat_skims WHERE source IS NULL ORDER BY touched DESC LIMIT -1 OFFSET ?)", (max(0, 255 - pending),))
            self._db.execute("INSERT INTO chat_skims VALUES (?, ?, ?, ?)",
                             (identifier, json.dumps(state), json.dumps([question, reply]), time.time()))
            self._db.commit()
            return state

    def begin(self, identifier: str) -> tuple[dict, str | None, str] | None:
        with self._lock:
            row = self._db.execute("SELECT state, source FROM chat_skims WHERE id = ?", (identifier,)).fetchone()
            if not row or not row[1]:
                return None
            state = json.loads(row[0])
            if state["status"] != "pending":
                return None
            if state.get("attempts", 0) >= 2:
                self.finish(identifier, {"status": "failed"})
                return None
            state["attempts"] = state.get("attempts", 0) + 1
            state["updated_at"] = datetime.now(timezone.utc).isoformat()
            self._db.execute("UPDATE chat_skims SET state = ? WHERE id = ?", (json.dumps(state), identifier))
            self._db.commit()
            question, reply = json.loads(row[1])
            return state, question, reply

    def finish(self, identifier: str, outcome: dict) -> None:
        with self._lock:
            state = self.get(identifier)
            if state is None or state["status"] != "pending":
                return
            # Retain only the validated presentation, never raw model output.
            state.update({key: value for key, value in outcome.items()
                          if key in {"status", "document", "segments"}})
            self._db.execute("UPDATE chat_skims SET state = ?, source = NULL, touched = ? WHERE id = ?",
                             (json.dumps(state), time.time(), identifier))
            self._db.commit()

    def pending(self) -> list[str]:
        with self._lock:
            return [row[0] for row in self._db.execute("SELECT id FROM chat_skims WHERE source IS NOT NULL")]
