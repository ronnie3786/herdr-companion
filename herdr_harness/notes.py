"""Revisioned, machine-local HUD notes shared by native clients and agents."""

from __future__ import annotations

import copy
import json
import math
import os
import sqlite3
import stat
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Optional

MAX_NOTES = 100
MAX_NOTE_BYTES = 256 * 1024
MAX_BODY_CHARS = 20_000
SWIFT_EPOCH = 978307200
COLORS = {"yellow", "peach", "pink", "green", "blue", "lavender"}
MUTABLE_FIELDS = {"title", "body", "richBody", "color", "updatedAt", "previousVersion",
                  "aiSummary", "actions", "links", "lastCleanedAt"}


class NotesError(ValueError):
    def __init__(self, message: str, *, code: str = "invalid_note", status: int = 400,
                 current_note: Optional[dict] = None):
        super().__init__(message)
        self.code, self.status, self.current_note = code, status, current_note


def note_id(value: Any) -> str:
    try:
        return str(uuid.UUID(value)) if isinstance(value, str) else _invalid_id()
    except (ValueError, AttributeError):
        return _invalid_id()


def _invalid_id() -> str:
    raise NotesError("A note ID must be a UUID")


def _text(value: Any, field: str, maximum: int) -> str:
    if not isinstance(value, str) or len(value) > maximum:
        raise NotesError(f"{field} must be text of at most {maximum} characters")
    return value


def _date(value: Any, field: str) -> None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise NotesError(f"{field} must be finite seconds since January 1, 2001")


def _validated(note: Any, *, now: float) -> dict:
    if not isinstance(note, dict):
        raise NotesError("note must be an object")
    value = copy.deepcopy(note)
    value.pop("revision", None)
    value["id"] = note_id(value["id"] if "id" in value else str(uuid.uuid4()))
    value.setdefault("title", "")
    value.setdefault("body", "")
    value.setdefault("color", "yellow")
    value.setdefault("createdAt", now)
    value.setdefault("updatedAt", now)
    value.setdefault("actions", [])
    value.setdefault("links", [])
    _text(value["title"], "title", 500)
    _text(value["body"], "body", MAX_BODY_CHARS)
    if not isinstance(value["color"], str) or value["color"] not in COLORS:
        raise NotesError("color must be yellow, peach, pink, green, blue, or lavender")
    for key in ("createdAt", "updatedAt"):
        _date(value[key], key)
    if value.get("lastCleanedAt") is not None:
        _date(value["lastCleanedAt"], "lastCleanedAt")
    if value.get("aiSummary") is not None:
        _text(value["aiSummary"], "aiSummary", MAX_BODY_CHARS)
    previous = value.get("previousVersion")
    if previous is not None:
        if not isinstance(previous, dict):
            raise NotesError("previousVersion must be an object")
        _text(previous.get("title"), "previousVersion.title", 500)
        _text(previous.get("body", ""), "previousVersion.body", MAX_BODY_CHARS)
        _date(previous.get("replacedAt"), "previousVersion.replacedAt")
    for field in ("actions", "links"):
        entries = value[field]
        if not isinstance(entries, list) or len(entries) > 100:
            raise NotesError(f"{field} must contain at most 100 objects")
        for item in entries:
            if not isinstance(item, dict):
                raise NotesError(f"{field} must contain objects")
            note_id(item.get("id"))
            _text(item.get("title"), f"{field}.title", 500)
            if field == "actions":
                _text(item.get("prompt"), "actions.prompt", MAX_BODY_CHARS)
                status = item.get("status", "ready")
                if not isinstance(status, str) or status not in {"ready", "starting", "started", "failed"}:
                    raise NotesError("action status is invalid")
                if item.get("error") is not None:
                    _text(item["error"], "actions.error", MAX_BODY_CHARS)
                if item.get("linkID") is not None:
                    note_id(item["linkID"])
                if item.get("startedAt") is not None:
                    _date(item["startedAt"], "actions.startedAt")
            else:
                _text(item.get("paneID"), "links.paneID", 256)
                _text(item.get("machineID"), "links.machineID", 256)
                _date(item.get("createdAt"), "links.createdAt")
                if item.get("actionTitle") is not None:
                    _text(item["actionTitle"], "links.actionTitle", 500)
    try:
        encoded = json.dumps(value, allow_nan=False, ensure_ascii=False).encode("utf-8")
    except (TypeError, ValueError, RecursionError) as exc:
        raise NotesError("note must contain finite JSON data") from exc
    if len(encoded) > MAX_NOTE_BYTES:
        raise NotesError("Note exceeds the 256 KB rich-content limit", code="note_too_large", status=413)
    return value


class NotesStore:
    def __init__(self, path: str | Path = ":memory:", *, callback: Optional[Callable[[dict], None]] = None,
                 clock: Callable[[], float] = time.time):
        self._lock = threading.RLock()
        self._callback, self._clock = callback, clock
        if str(path) != ":memory:":
            path = Path(path).expanduser().absolute()
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
            try:
                metadata = os.fstat(descriptor)
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
                    raise NotesError("Notes database must be an owned regular file", code="notes_store_unsafe", status=500)
                os.fchmod(descriptor, 0o600)
            finally:
                os.close(descriptor)
        self._db = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA synchronous=FULL")
        self._db.execute("CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload TEXT, deleted INTEGER NOT NULL DEFAULT 0)")
        self._db.execute("CREATE TABLE IF NOT EXISTS notes_state (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL)")
        self._db.execute("INSERT OR IGNORE INTO notes_state VALUES (1,0)")

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

    def _revision(self) -> int:
        return self._db.execute("SELECT revision FROM notes_state WHERE id=1").fetchone()[0]

    def _next_revision(self) -> int:
        self._db.execute("UPDATE notes_state SET revision=revision+1 WHERE id=1")
        return self._revision()

    @staticmethod
    def _note(row) -> Optional[dict]:
        return {**json.loads(row["payload"]), "revision": row["revision"]} if row and not row["deleted"] else None

    def _publish(self, revision: int, identifier: Optional[str] = None) -> None:
        if self._callback:
            try:
                self._callback({"revision": revision, **({"id": identifier} if identifier else {})})
            except Exception:
                pass

    def list(self, query: str = "") -> dict:
        _text(query, "q", 500)
        with self._lock:
            owns_transaction = not self._db.in_transaction
            if owns_transaction:
                self._db.execute("BEGIN")
            try:
                rows = self._db.execute("SELECT * FROM notes ORDER BY revision DESC").fetchall()
                notes = [self._note(row) for row in rows if not row["deleted"]]
                if query:
                    notes = [note for note in notes if query.casefold() in (note["title"] + "\n" + note["body"]).casefold()]
                return {"ok": True, "revision": self._revision(), "notes": notes,
                        "deletedIDs": [row["id"] for row in rows if row["deleted"]]}
            finally:
                if owns_transaction:
                    self._db.execute("COMMIT")

    def get(self, identifier: str) -> dict:
        with self._lock:
            row = self._db.execute("SELECT * FROM notes WHERE id=?", (note_id(identifier),)).fetchone()
            if row is None:
                raise NotesError("Note was not found", code="note_not_found", status=404)
            if row["deleted"]:
                raise NotesError("This note was deleted", code="note_deleted", status=410)
            return {"ok": True, "note": self._note(row)}

    def import_notes(self, values: Any) -> dict:
        if not isinstance(values, list) or len(values) > MAX_NOTES:
            raise NotesError("Import must contain at most 100 notes")
        for value in values:
            note_id(value.get("id") if isinstance(value, dict) else None)
        notes = [_validated(value, now=self._clock() - SWIFT_EPOCH) for value in values]
        if len({note["id"] for note in notes}) != len(notes):
            raise NotesError("Import contains duplicate note IDs")
        with self._transaction():
            present = {row["id"] for row in self._db.execute("SELECT id FROM notes")}
            additions = [note for note in notes if note["id"] not in present]
            count = self._db.execute("SELECT COUNT(*) FROM notes WHERE deleted=0").fetchone()[0]
            if count + len(additions) > MAX_NOTES:
                raise NotesError("The notes collection is full (100 notes)", code="notes_limit", status=409)
            for note in additions:
                revision = self._next_revision()
                self._db.execute("INSERT INTO notes VALUES (?,?,?,0)", (note["id"], revision, json.dumps(note, ensure_ascii=False)))
            result = self.list()
            result.update(createdCount=len(additions), existingCount=len(notes)-len(additions))
        if additions:
            self._publish(result["revision"])
        return result

    def create(self, value: Any) -> dict:
        note = _validated(value, now=self._clock() - SWIFT_EPOCH)
        result = self.import_notes([note])
        canonical = next((item for item in result["notes"] if item["id"] == note["id"]), None)
        if canonical is None:
            raise NotesError("This note was deleted; create a new note ID to restore its text", code="note_deleted", status=409)
        return {"ok": True, "note": canonical, "created": bool(result["createdCount"]), "revision": result["revision"]}

    def mutate(self, identifier: str, expected_revision: Any, *, changes: Optional[dict] = None, delete: bool = False) -> dict:
        identifier = note_id(identifier)
        if isinstance(expected_revision, bool) or not isinstance(expected_revision, int) or expected_revision < 1:
            raise NotesError("expectedRevision must be a positive integer", code="note_revision_required", status=428)
        if not delete and (not isinstance(changes, dict) or set(changes) - MUTABLE_FIELDS):
            raise NotesError("changes contains an unsupported or immutable note field")
        changed = False
        with self._transaction():
            row = self._db.execute("SELECT * FROM notes WHERE id=?", (identifier,)).fetchone()
            current = self._note(row)
            if delete and row is not None and row["deleted"]:
                return {"ok": True, "id": identifier, "deleted": True, "revision": self._revision()}
            if row is None or row["deleted"] or row["revision"] != expected_revision:
                raise NotesError("The note changed on another client. Reload it before applying your edit.",
                                 code="note_conflict", status=409, current_note=current)
            if delete:
                revision = self._next_revision()
                self._db.execute("UPDATE notes SET payload=NULL,deleted=1,revision=? WHERE id=?", (revision, identifier))
                result = {"ok": True, "id": identifier, "deleted": True, "revision": revision}
                changed = True
            else:
                updated = {**current, **changes}
                updated.pop("revision", None)
                if "body" in changes and changes["body"] != current["body"] and "richBody" not in changes:
                    updated.pop("richBody", None)
                # A title/color edit must not flatten a formatted note.
                updated["updatedAt"] = current["updatedAt"]
                updated = _validated(updated, now=self._clock() - SWIFT_EPOCH)
                original = {key: value for key, value in current.items() if key != "revision"}
                revision = row["revision"]
                if updated != original:
                    updated["updatedAt"] = self._clock() - SWIFT_EPOCH
                    revision = self._next_revision()
                    self._db.execute("UPDATE notes SET payload=?,revision=? WHERE id=?", (json.dumps(updated, ensure_ascii=False), revision, identifier))
                    changed = True
                result = {"ok": True, "note": {**updated, "revision": revision}, "revision": self._revision()}
        if changed:
            self._publish(result["revision"], identifier)
        return result
