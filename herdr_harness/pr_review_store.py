"""Durable ledger for PR-review state.

The runtime owns side effects.  This module deliberately owns every SQLite
operation so HTTP handlers and workers cannot bypass receipt semantics.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Mapping


class PRReviewError(RuntimeError):
    def __init__(self, message: str, *, code: str = "pr_review_conflict", status: int = 409) -> None:
        super().__init__(message)
        self.code = code
        self.status = status


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


def _json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def _text(value: object, name: str, maximum: int = 200_000, *, optional: bool = False) -> str:
    if not isinstance(value, str) or "\x00" in value or len(value) > maximum or (not optional and not value.strip()):
        raise PRReviewError(f"Invalid {name}", code="invalid_request", status=400)
    return value


BUILTIN_SKILLS = (
    ("ios-review-remote-pr", "iOS remote PR review", "review", "agent", "/ios-review-remote-pr {number}", None, ["PR_Review_*.md", "*.md", "*.html", "*.mp3", "*.wav", "*.m4a", "review*/**"]),
    ("comprehensive-pr-review", "Comprehensive PR review", "review", "agent", "/comprehensive-pr-review {number}", None, ["*.md", "*.html"]),
    ("github-pr-explainer-video", "GitHub PR explainer video", "explainer", "agent", "/github-pr-explainer-video {url}", None, ["artifacts/**/out/*.mp4", "artifacts/**/README.md"]),
    ("github-pr-explainer-video-v2", "GitHub PR explainer video v2", "explainer", "agent", "/github-pr-explainer-video-v2 {url}", None, ["artifacts/**/out/*.mp4", "artifacts/**/README.md"]),
    ("tech-explainer-video", "Technical explainer video", "explainer", "agent", "/tech-explainer-video {url}", None, ["**/out/*.mp4", "**/REFERENCES.md"]),
    ("pr-explainer-dev-manager", "PR explainer for dev manager", "explainer", "agent", "/pr-explainer-dev-manager {url}", None, ["artifacts/**/out/*.mp4", "artifacts/**/README.md"]),
    ("mark-generated-and-test-viewed-in-pull-request", "Mark generated and test viewed", "utility", "shell", None, "gh autoview {url} --apply", []),
)

SCHEMA = """
CREATE TABLE IF NOT EXISTS prr_reviews(id TEXT PRIMARY KEY,url TEXT,host TEXT,owner TEXT,repo TEXT,number INTEGER,title TEXT,body TEXT,author TEXT,base_ref TEXT,head_ref TEXT,base_sha TEXT,head_sha TEXT,merge_base_sha TEXT,github_state TEXT,is_draft INTEGER,status TEXT,error TEXT,checkout_path TEXT,workspace_id TEXT,tab_id TEXT,anchor_pane_id TEXT,workspace_error TEXT,additions INTEGER,deletions INTEGER,changed_files INTEGER,ranking_state TEXT,ranking_error TEXT,archived_at TEXT,created_at TEXT,updated_at TEXT,prepared_at TEXT,revision INTEGER);
CREATE TABLE IF NOT EXISTS prr_files(review_id TEXT,path TEXT,old_path TEXT,status TEXT,additions INTEGER,deletions INTEGER,impact TEXT,impact_reason TEXT,guided_order INTEGER,guided_reason TEXT,viewed INTEGER,viewed_at TEXT,viewed_source TEXT,PRIMARY KEY(review_id,path));
CREATE TABLE IF NOT EXISTS prr_skills(id TEXT PRIMARY KEY,title TEXT,kind TEXT,runner TEXT,prompt_template TEXT,command_template TEXT,outputs_json TEXT,description TEXT,builtin INTEGER,enabled INTEGER,created_at TEXT);
CREATE TABLE IF NOT EXISTS prr_skill_runs(id TEXT PRIMARY KEY,review_id TEXT,skill_id TEXT,skill_title TEXT,state TEXT,launch TEXT,command TEXT,workspace_id TEXT,tab_id TEXT,pane_id TEXT,actor TEXT,note TEXT,error TEXT,output_snapshot_json TEXT,created_at TEXT,started_at TEXT,finished_at TEXT);
CREATE TABLE IF NOT EXISTS prr_skill_marks(review_id TEXT,skill_id TEXT,state TEXT,actor TEXT,note TEXT,marked_at TEXT,PRIMARY KEY(review_id,skill_id));
CREATE TABLE IF NOT EXISTS prr_documents(id TEXT PRIMARY KEY,review_id TEXT,run_id TEXT,kind TEXT,title TEXT,media_type TEXT,filename TEXT,stored_path TEXT,url TEXT,byte_size INTEGER,content_hash TEXT,origin TEXT,origin_path TEXT,created_at TEXT);
CREATE TABLE IF NOT EXISTS prr_events(sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE,review_id TEXT,type TEXT,summary TEXT,payload_json TEXT,created_at TEXT);
CREATE TABLE IF NOT EXISTS prr_receipts(scope TEXT,request_id TEXT,payload_hash TEXT,result_json TEXT,created_at TEXT,PRIMARY KEY(scope,request_id));
CREATE TABLE IF NOT EXISTS prr_viewer_reviews(review_id TEXT PRIMARY KEY REFERENCES prr_reviews(id),summary_json TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS prr_skill_runs_summary ON prr_skill_runs(review_id,skill_id,created_at DESC);
"""


class PRReviewStore:
    def __init__(self, path: str | Path) -> None:
        self.path = Path(path).expanduser() if str(path) != ":memory:" else None
        if self.path is not None:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
            os.close(descriptor)
            os.chmod(self.path, 0o600)
        self._lock = threading.RLock()
        self._db = sqlite3.connect(str(self.path) if self.path else ":memory:", timeout=15, isolation_level=None, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA foreign_keys=ON")
        self._db.executescript(SCHEMA)
        self.seed_skills()

    def close(self) -> None:
        # The connection is shared with daemon worker threads (the runtime writes
        # from its shell/rank/prepare workers), so closing it without the same
        # lock that serializes every query can drop the pysqlite connection while
        # a worker is inside a statement, which crashes the interpreter. Waiting
        # on the lock first lets an in-flight statement finish; later calls fail
        # with the ordinary closed-database error instead of a process crash.
        with self._lock:
            self._db.close()

    @contextmanager
    def _transaction(self) -> Iterator[None]:
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                yield
            except BaseException:
                self._db.execute("ROLLBACK")
                raise
            else:
                self._db.execute("COMMIT")

    def _receipt(self, scope: str, request_id: str, payload: Any) -> Any | None:
        _text(request_id, "request_id", 200)
        row = self._db.execute("SELECT * FROM prr_receipts WHERE scope=? AND request_id=?", (scope, request_id)).fetchone()
        if row is None:
            return None
        if row["payload_hash"] != hashlib.sha256(_json(payload).encode()).hexdigest():
            raise PRReviewError("request_id was already used with different content", code="idempotency_conflict")
        return json.loads(row["result_json"])

    def _save(self, scope: str, request_id: str, payload: Any, result: Any) -> Any:
        self._db.execute("INSERT INTO prr_receipts VALUES(?,?,?,?,?)", (scope, request_id, hashlib.sha256(_json(payload).encode()).hexdigest(), _json(result), _now()))
        return result

    def receipt(self, scope: str, request_id: str, payload: Any) -> Any | None:
        with self._lock:
            return self._receipt(scope, request_id, payload)

    def save_receipt(self, scope: str, request_id: str, payload: Any, result: Any) -> Any:
        with self._transaction():
            cached = self._receipt(scope, request_id, payload)
            return cached if cached is not None else self._save(scope, request_id, payload, result)

    def _event(self, review_id: str, kind: str, summary: str, payload: Mapping[str, Any] | None = None) -> None:
        self._db.execute("INSERT INTO prr_events(id,review_id,type,summary,payload_json,created_at) VALUES(?,?,?,?,?,?)", (_id("prev"), review_id, kind, summary, _json(dict(payload or {})), _now()))

    def add_event(self, review_id: str, kind: str, summary: str, payload: Mapping[str, Any] | None = None) -> None:
        with self._transaction():
            self.get_review(review_id)
            self._event(review_id, kind, summary, payload)

    def seed_skills(self) -> None:
        with self._transaction():
            for skill_id, title, kind, runner, prompt, command, outputs in BUILTIN_SKILLS:
                self._db.execute("INSERT OR IGNORE INTO prr_skills VALUES(?,?,?,?,?,?,?,?,?,?,?)", (skill_id, title, kind, runner, prompt, command, _json(outputs), "", 1, 1, _now()))

    def _review(self, row: sqlite3.Row | None, full: bool = False) -> dict[str, Any]:
        if row is None:
            raise PRReviewError("PR review was not found", code="not_found", status=404)
        result = dict(row)
        result["is_draft"] = bool(result["is_draft"])
        result["running_runs"] = self._db.execute("SELECT count(*) FROM prr_skill_runs WHERE review_id=? AND state IN ('queued','running')", (result["id"],)).fetchone()[0]
        result["document_count"] = self._db.execute("SELECT count(*) FROM prr_documents WHERE review_id=?", (result["id"],)).fetchone()[0]
        result["skill_runs"] = [dict(item) for item in self._db.execute("""SELECT skill_id,skill_title AS title,state,
            COALESCE(finished_at,started_at,created_at) AS updated_at FROM (
                SELECT *,row_number() OVER (PARTITION BY skill_id ORDER BY created_at DESC,rowid DESC) AS position
                FROM prr_skill_runs WHERE review_id=?) WHERE position=1 ORDER BY title,skill_id""", (result["id"],))]
        result["viewer_review"] = self.viewer_review(result["id"])
        if not full:
            result.pop("body", None)
        return result

    def viewer_review(self, review_id: str) -> dict[str, Any]:
        """Cached GitHub viewer state. Listing never performs network requests."""
        with self._lock:
            row = self._db.execute("SELECT summary_json FROM prr_viewer_reviews WHERE review_id=?", (review_id,)).fetchone()
            return json.loads(row[0]) if row else {
                "state": "unknown", "pending_comment_count": 0, "needs_user": False,
                "is_own_pr": None, "reviewed_at": None, "reviewed_commit": None,
                "head_commit": None, "review_requested": False,
                "updated_at": None, "checked_at": None, "error": None,
            }

    def save_viewer_review(self, review_id: str, summary: Mapping[str, Any] | None = None, *, error: str | None = None) -> None:
        with self._transaction():
            if self._db.execute("SELECT id FROM prr_reviews WHERE id=?", (review_id,)).fetchone() is None:
                raise PRReviewError("PR review was not found", code="not_found", status=404)
            value = self.viewer_review(review_id)
            now = _now()
            if summary is not None:
                value.update(summary)
                value["updated_at"] = now
            value.update(checked_at=now, error=error)
            self._db.execute("INSERT INTO prr_viewer_reviews VALUES(?,?) ON CONFLICT(review_id) DO UPDATE SET summary_json=excluded.summary_json", (review_id, _json(value)))
            # Refreshing freshness must not reorder reviews or invalidate an
            # unchanged checkout's revision every minute.

    def get_review(self, review_id: str, full: bool = True) -> dict[str, Any]:
        with self._lock:
            return self._review(self._db.execute("SELECT * FROM prr_reviews WHERE id=?", (review_id,)).fetchone(), full)

    def create_review(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        for key in ("url", "host", "owner", "repo"):
            _text(payload.get(key), key, 4096)
        if type(payload.get("number")) is not int or payload["number"] < 1:
            raise PRReviewError("Invalid number", code="invalid_request", status=400)
        request_id = _text(payload.get("request_id"), "request_id", 200)
        canonical = dict(payload)
        with self._transaction():
            cached = self._receipt("create_review", request_id, canonical)
            if cached is not None:
                return cached
            existing = self._db.execute("SELECT * FROM prr_reviews WHERE host=? AND owner=? AND repo=? AND number=? AND archived_at IS NULL", (payload["host"], payload["owner"], payload["repo"], payload["number"])).fetchone()
            if existing is not None:
                return self._save("create_review", request_id, canonical, self._review(existing, True))
            now = _now()
            review_id = _id("prr")
            self._db.execute("INSERT INTO prr_reviews(id,url,host,owner,repo,number,title,body,author,status,is_draft,ranking_state,created_at,updated_at,revision) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (review_id, payload["url"], payload["host"], payload["owner"], payload["repo"], payload["number"], "", "", "", "preparing", 0, "idle", now, now, 1))
            self._event(review_id, "review.created", "PR review created")
            return self._save("create_review", request_id, canonical, self.get_review(review_id, True))

    def list_reviews(self, scope: str = "active") -> list[dict[str, Any]]:
        clauses = {"active": "archived_at IS NULL", "archived": "archived_at IS NOT NULL", "all": ""}
        if scope not in clauses:
            raise PRReviewError("Invalid review scope", code="invalid_request", status=400)
        query = "SELECT * FROM prr_reviews" + (f" WHERE {clauses[scope]}" if clauses[scope] else "") + " ORDER BY updated_at DESC"
        with self._lock:
            return [self._review(row) for row in self._db.execute(query)]

    def _touch(self, review_id: str) -> None:
        self._db.execute("UPDATE prr_reviews SET updated_at=?,revision=revision+1 WHERE id=?", (_now(), review_id))

    def update_review(self, review_id: str, **values: Any) -> dict[str, Any]:
        if not values:
            return self.get_review(review_id, True)
        with self._transaction():
            self.get_review(review_id)
            assignments = ",".join(f"{key}=?" for key in values)
            self._db.execute(f"UPDATE prr_reviews SET {assignments} WHERE id=?", (*values.values(), review_id))
            self._touch(review_id)
            return self.get_review(review_id, True)

    def archive(self, review_id: str, request_id: str, archived: bool = True) -> dict[str, Any]:
        scope = ("archive:" if archived else "unarchive:") + review_id
        payload = {"archived": archived}
        with self._transaction():
            cached = self._receipt(scope, request_id, payload)
            if cached is not None:
                return cached
            self.get_review(review_id)
            self._db.execute("UPDATE prr_reviews SET archived_at=? WHERE id=?", (_now() if archived else None, review_id))
            self._touch(review_id)
            self._event(review_id, "review.archived" if archived else "review.unarchived", "Review archived" if archived else "Review unarchived")
            return self._save(scope, request_id, payload, self.get_review(review_id, True))

    def files(self, review_id: str) -> list[dict[str, Any]]:
        with self._lock:
            self.get_review(review_id)
            return [dict(row) | {"viewed": bool(row["viewed"])} for row in self._db.execute("SELECT * FROM prr_files WHERE review_id=? ORDER BY path", (review_id,))]

    def complete_preparation(self, review_id: str, files: list[Mapping[str, Any]], *, changed_paths: list[str] | None = None, **values: Any) -> None:
        """Publish revision metadata and its file list as one readable snapshot."""
        with self._transaction():
            previous = self.get_review(review_id)
            self._upsert_files(review_id, files)
            if (previous.get("base_sha"), previous.get("head_sha")) != (values.get("base_sha"), values.get("head_sha")):
                self._db.execute("UPDATE prr_files SET impact=NULL,impact_reason=NULL,guided_order=NULL,guided_reason=NULL WHERE review_id=?", (review_id,))
                values.update(ranking_state="idle", ranking_error=None)
            for path in changed_paths or []:
                self._db.execute("UPDATE prr_files SET viewed=0,viewed_at=NULL,viewed_source=NULL WHERE review_id=? AND path=?", (review_id, path))
            assignments = ",".join(f"{key}=?" for key in values)
            self._db.execute(f"UPDATE prr_reviews SET {assignments} WHERE id=?", (*values.values(), review_id))
            self._touch(review_id)

    def upsert_files(self, review_id: str, files: list[Mapping[str, Any]]) -> None:
        with self._transaction():
            self._upsert_files(review_id, files)

    def _upsert_files(self, review_id: str, files: list[Mapping[str, Any]]) -> None:
        self.get_review(review_id)
        paths: list[str] = []
        for file in files:
            path = _text(file.get("path"), "path", 4096)
            paths.append(path)
            prior = self._db.execute("SELECT impact,impact_reason,guided_order,guided_reason,viewed,viewed_at,viewed_source FROM prr_files WHERE review_id=? AND path=?", (review_id, path)).fetchone()
            preserved = tuple(prior) if prior else (None, None, None, None, 0, None, None)
            values = (review_id, path, file.get("old_path"), file.get("status", "modified"), int(file.get("additions", 0)), int(file.get("deletions", 0)), *preserved)
            self._db.execute("INSERT INTO prr_files VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(review_id,path) DO UPDATE SET old_path=excluded.old_path,status=excluded.status,additions=excluded.additions,deletions=excluded.deletions", values)
        if paths:
            placeholders = ",".join("?" for _ in paths)
            self._db.execute(f"DELETE FROM prr_files WHERE review_id=? AND path NOT IN ({placeholders})", (review_id, *paths))
        else:
            self._db.execute("DELETE FROM prr_files WHERE review_id=?", (review_id,))
        self._touch(review_id)

    def _skill(self, item: dict[str, Any]) -> dict[str, Any]:
        item["outputs"] = json.loads(item.pop("outputs_json"))
        item["builtin"] = bool(item["builtin"])
        item["enabled"] = bool(item["enabled"])
        return item

    def skills(self) -> list[dict[str, Any]]:
        with self._lock:
            return [self._skill(dict(row)) for row in self._db.execute("SELECT * FROM prr_skills WHERE enabled=1 ORDER BY builtin DESC,id")]

    def skill(self, skill_id: str) -> dict[str, Any]:
        with self._lock:
            row = self._db.execute("SELECT * FROM prr_skills WHERE id=? AND enabled=1", (skill_id,)).fetchone()
            if row is None:
                raise PRReviewError("Skill was not found", code="skill_not_found", status=404)
            return self._skill(dict(row))

    def skill_states(self, review_id: str) -> list[dict[str, Any]]:
        with self._lock:
            self.get_review(review_id)
            states = []
            for skill in self.skills():
                runs = [dict(row) for row in self._db.execute("SELECT * FROM prr_skill_runs WHERE review_id=? AND skill_id=? ORDER BY created_at DESC", (review_id, skill["id"]))]
                row = self._db.execute("SELECT * FROM prr_skill_marks WHERE review_id=? AND skill_id=?", (review_id, skill["id"])).fetchone()
                mark = dict(row) if row else None
                finished = next((run for run in runs if run["state"] == "finished"), None)
                state = "ran" if finished or (mark and mark["state"] == "ran") else "not_run"
                if mark and mark["state"] == "not_run" and (not finished or mark["marked_at"] > finished["finished_at"]):
                    state = "not_run"
                states.append(skill | {"state": state, "mark": mark, "run_count": len(runs), "last_run_at": runs[0]["created_at"] if runs else None, "running": any(run["state"] in {"queued", "running"} for run in runs)})
            return states

    def snapshot(self, review_id: str) -> dict[str, Any]:
        with self._lock:
            return {"review": self.get_review(review_id, True), "files": self.files(review_id), "skills": self.skill_states(review_id), "runs": self.runs_for_review(review_id), "documents": self.documents(review_id), "events": self.events(review_id)["events"][-100:]}

    def events(self, review_id: str, after: int = 0) -> dict[str, Any]:
        with self._lock:
            self.get_review(review_id)
            events = []
            for row in self._db.execute("SELECT * FROM prr_events WHERE review_id=? AND sequence>? ORDER BY sequence", (review_id, after)):
                item = dict(row)
                item["payload"] = json.loads(item.pop("payload_json"))
                events.append(item)
            return {"events": events, "cursor": events[-1]["sequence"] if events else after}

    def _document(self, item: dict[str, Any]) -> dict[str, Any]:
        item["downloadable"] = bool(item.get("stored_path"))
        item.pop("stored_path", None)
        return item

    def documents(self, review_id: str) -> list[dict[str, Any]]:
        with self._lock:
            self.get_review(review_id)
            return [self._document(dict(row)) for row in self._db.execute("SELECT * FROM prr_documents WHERE review_id=? ORDER BY created_at DESC", (review_id,))]

    def document(self, review_id: str, document_id: str, *, include_storage: bool = False) -> dict[str, Any]:
        with self._lock:
            row = self._db.execute("SELECT * FROM prr_documents WHERE review_id=? AND id=?", (review_id, document_id)).fetchone()
            if row is None:
                raise PRReviewError("Document was not found", code="not_found", status=404)
            item = dict(row)
            return item if include_storage else self._document(item)

    def add_document(self, review_id: str, record: Mapping[str, Any]) -> dict[str, Any]:
        with self._transaction():
            self.get_review(review_id)
            request_id = record.get("request_id")
            payload = {key: value for key, value in record.items() if key not in {"id", "stored_path", "created_at"}}
            if isinstance(request_id, str):
                cached = self._receipt(f"document:{review_id}", request_id, payload)
                if cached is not None:
                    return cached
            document_id = str(record.get("id") or _id("prdoc"))
            existing = self._db.execute("SELECT * FROM prr_documents WHERE review_id=? AND content_hash=?", (review_id, record.get("content_hash"))).fetchone() if record.get("content_hash") else None
            if existing is not None:
                return self._document(dict(existing))
            self._db.execute("INSERT INTO prr_documents VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (document_id, review_id, record.get("run_id"), record.get("kind", "file"), record.get("title") or record.get("filename") or "document", record.get("media_type") or "application/octet-stream", record.get("filename"), record.get("stored_path"), record.get("url"), int(record.get("byte_size") or 0), record.get("content_hash"), record.get("origin", "user"), record.get("origin_path"), record.get("created_at") or _now()))
            self._touch(review_id)
            result = self.document(review_id, document_id)
            return self._save(f"document:{review_id}", request_id, payload, result) if isinstance(request_id, str) else result

    def add_skill(self, body: Mapping[str, Any]) -> dict[str, Any]:
        skill_id = _text(body.get("id"), "id", 64)
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", skill_id):
            raise PRReviewError("Invalid custom skill id", code="invalid_request", status=400)
        request_id = _text(body.get("request_id"), "request_id", 200)
        with self._transaction():
            cached = self._receipt("add_skill", request_id, dict(body))
            if cached is not None:
                return cached
            outputs = body.get("outputs") or ["*.md", "*.html", "*.mp3", "*.wav", "*.m4a", "*.mp4", "*.mov", "*.pdf"]
            if not isinstance(outputs, list) or not all(isinstance(item, str) for item in outputs):
                raise PRReviewError("Invalid outputs", code="invalid_request", status=400)
            kind = _text(body.get("kind", "custom"), "kind", 100, optional=True)
            description = _text(body.get("description", ""), "description", 20_000, optional=True)
            command = _text(body.get("command_template"), "command_template", 20_000, optional=True) if "command_template" in body else None
            existing = self._db.execute("SELECT * FROM prr_skills WHERE id=?", (skill_id,)).fetchone()
            if existing is not None:
                if existing["builtin"]:
                    raise PRReviewError("Built-in skills cannot be replaced", code="invalid_request", status=400)
                self._db.execute("UPDATE prr_skills SET title=?,kind=?,runner=?,prompt_template=?,command_template=?,outputs_json=?,description=?,enabled=1 WHERE id=?", (_text(body.get("title"), "title", 300), kind, "agent", body.get("prompt_template") or f"/{skill_id} {{number}}", command, _json(outputs), description, skill_id))
            else:
                self._db.execute("INSERT INTO prr_skills VALUES(?,?,?,?,?,?,?,?,?,?,?)", (skill_id, _text(body.get("title"), "title", 300), kind, "agent", body.get("prompt_template") or f"/{skill_id} {{number}}", command, _json(outputs), description, 0, 1, _now()))
            return self._save("add_skill", request_id, dict(body), self.skill(skill_id))

    def document_for_hash(self, review_id: str, content_hash: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM prr_documents WHERE review_id=? AND content_hash=?", (review_id, content_hash)).fetchone()
            return self._document(dict(row)) if row is not None else None

    def start_ranking(self, review_id: str, request_id: str) -> tuple[dict[str, Any], bool]:
        scope = f"rank:{review_id}"
        with self._transaction():
            cached = self._receipt(scope, request_id, {})
            if cached is not None:
                return cached, False
            review = self.get_review(review_id, True)
            if review["ranking_state"] == "running":
                return self._save(scope, request_id, {}, review), False
            self._db.execute("UPDATE prr_reviews SET ranking_state=?,ranking_error=? WHERE id=?", ("running", None, review_id))
            self._touch(review_id)
            result = self.get_review(review_id, True)
            self._save(scope, request_id, {}, result)
            return result, True

    def disable_skill(self, skill_id: str, request_id: str) -> list[dict[str, Any]]:
        with self._transaction():
            cached = self._receipt("remove_skill", request_id, {"id": skill_id})
            if cached is not None:
                return cached
            row = self._db.execute("SELECT * FROM prr_skills WHERE id=?", (skill_id,)).fetchone()
            if row is None:
                raise PRReviewError("Skill was not found", code="skill_not_found", status=404)
            if row["builtin"]:
                raise PRReviewError("Built-in skills cannot be removed", code="invalid_request", status=400)
            self._db.execute("UPDATE prr_skills SET enabled=0 WHERE id=?", (skill_id,))
            return self._save("remove_skill", request_id, {"id": skill_id}, self.skills())

    def create_run(self, review_id: str, skill_id: str, request_id: str, actor: str = "") -> dict[str, Any]:
        payload = {"skill_id": skill_id, "actor": actor}
        with self._transaction():
            cached = self._receipt(f"run:{review_id}", request_id, payload)
            if cached is not None:
                return cached
            review = self.get_review(review_id, True)
            if review["archived_at"]:
                raise PRReviewError("Review is archived", code="review_archived")
            if review["status"] != "ready":
                raise PRReviewError("Review is not ready", code="review_not_ready")
            skill = self.skill(skill_id)
            run_id = _id("prun")
            self._db.execute("INSERT INTO prr_skill_runs(id,review_id,skill_id,skill_title,state,launch,actor,created_at) VALUES(?,?,?,?,?,?,?,?)", (run_id, review_id, skill_id, skill["title"], "queued", "none", actor, _now()))
            self._event(review_id, "run.queued", "Skill run queued", {"run_id": run_id})
            self._touch(review_id)
            return self._save(f"run:{review_id}", request_id, payload, self.run(review_id, run_id))

    def queue_run(self, review_id: str, skill_id: str, request_id: str, actor: str = "") -> dict[str, Any]:
        """Record requested work while a newly created review is preparing."""
        payload = {"skill_id": skill_id, "actor": actor}
        with self._transaction():
            cached = self._receipt(f"queued-run:{review_id}", request_id, payload)
            if cached is not None:
                return cached
            review = self.get_review(review_id, True)
            if review["archived_at"]:
                raise PRReviewError("Review is archived", code="review_archived")
            skill = self.skill(skill_id)
            run_id = _id("prun")
            self._db.execute("INSERT INTO prr_skill_runs(id,review_id,skill_id,skill_title,state,launch,actor,created_at) VALUES(?,?,?,?,?,?,?,?)", (run_id, review_id, skill_id, skill["title"], "queued", "none", actor, _now()))
            self._event(review_id, "run.queued", "Skill run queued", {"run_id": run_id})
            self._touch(review_id)
            return self._save(f"queued-run:{review_id}", request_id, payload, self.run(review_id, run_id))

    def run(self, review_id: str, run_id: str) -> dict[str, Any]:
        with self._lock:
            row = self._db.execute("SELECT * FROM prr_skill_runs WHERE review_id=? AND id=?", (review_id, run_id)).fetchone()
            if row is None:
                raise PRReviewError("Run was not found", code="not_found", status=404)
            return dict(row)

    def runs_for_review(self, review_id: str) -> list[dict[str, Any]]:
        with self._lock:
            self.get_review(review_id)
            return [dict(row) for row in self._db.execute("SELECT * FROM prr_skill_runs WHERE review_id=? ORDER BY created_at DESC", (review_id,))]

    def update_run(self, review_id: str, run_id: str, **values: Any) -> dict[str, Any]:
        with self._transaction():
            self.run(review_id, run_id)
            if values:
                self._db.execute(f"UPDATE prr_skill_runs SET {','.join(f'{key}=?' for key in values)} WHERE id=?", (*values.values(), run_id))
                self._touch(review_id)
            return self.run(review_id, run_id)

    def mark(self, review_id: str, skill_id: str, state: str, request_id: str, actor: str = "", note: str = "") -> dict[str, Any]:
        if state not in {"ran", "not_run"}:
            raise PRReviewError("Invalid mark state", code="invalid_request", status=400)
        payload = {"skill_id": skill_id, "state": state, "actor": actor, "note": note}
        with self._transaction():
            cached = self._receipt(f"mark:{review_id}", request_id, payload)
            if cached is not None:
                return cached
            self.skill(skill_id)
            self._db.execute("INSERT INTO prr_skill_marks VALUES(?,?,?,?,?,?) ON CONFLICT(review_id,skill_id) DO UPDATE SET state=excluded.state,actor=excluded.actor,note=excluded.note,marked_at=excluded.marked_at", (review_id, skill_id, state, actor, note, _now()))
            self._touch(review_id)
            result = next(item for item in self.skill_states(review_id) if item["id"] == skill_id)
            return self._save(f"mark:{review_id}", request_id, payload, result)

    def set_ranking_state(self, review_id: str, state: str, error: str | None = None, *, expected_shas: tuple[str, str] | None = None) -> dict[str, Any]:
        if state not in {"idle", "running", "done", "failed"}:
            raise PRReviewError("Invalid ranking state", code="invalid_request", status=400)
        with self._lock:
            current = self.get_review(review_id)
            if expected_shas is not None and (current.get("base_sha"), current.get("head_sha")) != expected_shas:
                return current
            return self.update_review(review_id, ranking_state=state, ranking_error=error)

    def set_rankings(self, review_id: str, files: list[Mapping[str, Any]], request_id: str, *, expected_shas: tuple[str, str] | None = None) -> list[dict[str, Any]]:
        payload = {"files": files}
        with self._transaction():
            if expected_shas is not None:
                current = self.get_review(review_id)
                if (current.get("base_sha"), current.get("head_sha")) != expected_shas:
                    raise PRReviewError("The review changed during ranking", code="stale_ranking")
            cached = self._receipt(f"rankings:{review_id}", request_id, payload)
            if cached is not None:
                return cached
            if not isinstance(files, list):
                raise PRReviewError("Invalid ranking", code="invalid_request", status=400)
            for item in files:
                if not isinstance(item, Mapping) or item.get("impact") not in {"low", "medium", "high"} or not isinstance(item.get("path"), str):
                    raise PRReviewError("Invalid ranking", code="invalid_request", status=400)
                if self._db.execute("SELECT 1 FROM prr_files WHERE review_id=? AND path=?", (review_id, item["path"])).fetchone() is None:
                    raise PRReviewError("Ranking path was not found", code="invalid_request", status=400)
                self._db.execute("UPDATE prr_files SET impact=?,impact_reason=?,guided_order=?,guided_reason=? WHERE review_id=? AND path=?", (item["impact"], item.get("reason"), item.get("guided_order"), item.get("guided_reason"), review_id, item["path"]))
            self._db.execute("UPDATE prr_reviews SET ranking_state='done',ranking_error=NULL WHERE id=?", (review_id,))
            self._touch(review_id)
            return self._save(f"rankings:{review_id}", request_id, payload, self.files(review_id))

    def set_viewed(self, review_id: str, paths: list[str], viewed: bool, request_id: str, source: str = "user") -> list[dict[str, Any]]:
        payload = {"paths": paths, "viewed": viewed, "source": source}
        with self._transaction():
            cached = self._receipt(f"viewed:{review_id}", request_id, payload)
            if cached is not None:
                return cached
            if not isinstance(paths, list) or not paths or type(viewed) is not bool or not all(isinstance(path, str) for path in paths):
                raise PRReviewError("Invalid viewed request", code="invalid_request", status=400)
            for path in paths:
                if self._db.execute("SELECT 1 FROM prr_files WHERE review_id=? AND path=?", (review_id, path)).fetchone() is None:
                    raise PRReviewError("File was not found", code="not_found", status=404)
                self._db.execute("UPDATE prr_files SET viewed=?,viewed_at=?,viewed_source=? WHERE review_id=? AND path=?", (int(viewed), _now(), source, review_id, path))
            self._touch(review_id)
            return self._save(f"viewed:{review_id}", request_id, payload, self.files(review_id))
