"""Durable completion records and the archive cleanup queue.

This ledger is private companion state. Resource ownership is recorded by the
runtime at creation, never inferred from a directory name or an agent's prose.
The completion blob is immutable; cleanup attempts are an append-only log.
"""
from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import uuid
import zlib
from datetime import datetime, timezone


SCHEMA = """
CREATE TABLE IF NOT EXISTS fm_owned_resources(
 id TEXT PRIMARY KEY, feature_id TEXT NOT NULL REFERENCES fm_features(id),
 kind TEXT NOT NULL, path TEXT NOT NULL UNIQUE, identity_json TEXT NOT NULL,
 metadata_json TEXT NOT NULL, removed_at TEXT, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS fm_archives(
 id TEXT PRIMARY KEY, feature_id TEXT NOT NULL REFERENCES fm_features(id),
 feature_revision INTEGER NOT NULL, archived_at TEXT NOT NULL, status TEXT NOT NULL, attempt INTEGER NOT NULL DEFAULT 1,
 message TEXT NOT NULL DEFAULT '', record BLOB, record_sha256 TEXT,
 preview_token TEXT, cleanup_options_json TEXT NOT NULL DEFAULT '{}',
 facts_json TEXT NOT NULL DEFAULT '{}',
 search_text TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS fm_archives_feature ON fm_archives(feature_id,created_at);
CREATE TABLE IF NOT EXISTS fm_cleanup_log(
 sequence INTEGER PRIMARY KEY AUTOINCREMENT, archive_id TEXT NOT NULL REFERENCES fm_archives(id),
 attempt INTEGER NOT NULL, resource_id TEXT, kind TEXT NOT NULL, path TEXT NOT NULL,
 outcome TEXT NOT NULL, reason TEXT NOT NULL, bytes_reclaimed INTEGER NOT NULL DEFAULT 0,
 created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS fm_catalog_pointers(
 kind TEXT NOT NULL, row_id TEXT NOT NULL, feature_id TEXT NOT NULL REFERENCES fm_features(id),
 archive_id TEXT NOT NULL REFERENCES fm_archives(id), pointer_sha256 TEXT NOT NULL,
 original_sha256 TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(kind,row_id));
"""


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False)


def queue(store, feature, *, preview_token, cleanup_options):
    """Called inside the archive transaction, only on a new archive transition."""
    if feature["status"] != "completed":
        return None
    if not isinstance(preview_token, str) or not preview_token or not isinstance(cleanup_options, dict):
        raise ValueError("Archive cleanup requires an explicit reviewed selection")
    stamp = now()
    archive_id = "archive_" + uuid.uuid4().hex
    store._db.execute("""INSERT INTO fm_archives
        (id,feature_id,feature_revision,archived_at,status,preview_token,cleanup_options_json,created_at,updated_at)
        VALUES(?,?,?,?,'pending',?,?,?,?)""",
        (archive_id, feature["id"], feature["revision"], feature["archived_at"],
         preview_token, encoded(cleanup_options), stamp, stamp))
    return archive_id


def cancel(store, feature_id):
    store._db.execute("""UPDATE fm_archives SET status='cancelled',message=?,updated_at=?
        WHERE feature_id=? AND status IN ('pending','waiting','running','failed')""",
        ("Unarchived. Removed temporary resources are not restored.", now(), feature_id))


def latest(store, feature_id, *, with_record=True):
    with store._lock:
        columns = "*" if with_record else "id,feature_id,feature_revision,archived_at,status,attempt,message,created_at,updated_at,record IS NOT NULL AS history_available"
        row = store._db.execute(f"SELECT {columns} FROM fm_archives WHERE feature_id=? ORDER BY created_at DESC,id DESC LIMIT 1",
                                (feature_id,)).fetchone()
        return dict(row) if row else None


def _summary_db(db, feature_id, archive_id=None):
    row = (db.execute("""SELECT id,status,attempt,message,updated_at,record IS NOT NULL AS history_available
                FROM fm_archives WHERE id=? AND feature_id=?""", (archive_id, feature_id)).fetchone()
           if archive_id else db.execute("""SELECT id,status,attempt,message,updated_at,
                record IS NOT NULL AS history_available FROM fm_archives WHERE feature_id=?
                ORDER BY created_at DESC,id DESC LIMIT 1""", (feature_id,)).fetchone())
    if not row:
        return None
    counts = dict(db.execute("""SELECT outcome,count(*) FROM fm_cleanup_log
        WHERE archive_id=? AND attempt=? GROUP BY outcome""", (row["id"], row["attempt"])).fetchall())
    reclaimed = db.execute("SELECT coalesce(sum(bytes_reclaimed),0) FROM fm_cleanup_log WHERE archive_id=?",
                           (row["id"],)).fetchone()[0]
    return {"id": row["id"], "status": row["status"], "attempt": row["attempt"],
            "message": row["message"], "history_available": bool(row["history_available"]),
            "bytes_reclaimed": reclaimed, "removed": counts.get("removed", 0),
            "retained": counts.get("retained", 0), "failed": counts.get("failed", 0),
            "updated_at": row["updated_at"]}


def summary(store, feature_id, archive_id=None):
    with store._lock:
        return _summary_db(store._db, feature_id, archive_id)


def progress(store, feature_id, archive_id=None, *, after=0, limit=100):
    """Return one bounded, archive-generation-pinned cleanup page."""
    if store.path:
        db = sqlite3.connect(store.path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA query_only=ON")
        db.execute("BEGIN")
        close = True
        guard = None
    else:
        db, close, guard = store._db, False, store._lock
        guard.acquire()
    try:
        row = (db.execute("SELECT id FROM fm_archives WHERE id=? AND feature_id=?",
                                 (archive_id, feature_id)).fetchone()
               if archive_id else db.execute(
                   "SELECT id FROM fm_archives WHERE feature_id=? ORDER BY created_at DESC,id DESC LIMIT 1",
                   (feature_id,)).fetchone())
        if not row:
            from .first_mate_store import FirstMateError
            raise FirstMateError("No archive cleanup exists for this session", code="not_found", status=404)
        archive_id = row["id"]
        rows = db.execute("""SELECT sequence,attempt,resource_id,kind,path,outcome,reason,
                bytes_reclaimed,created_at FROM fm_cleanup_log
            WHERE archive_id=? AND sequence>? ORDER BY sequence LIMIT ?""",
            (archive_id, after, limit + 1)).fetchall()
        page = [dict(item) for item in rows[:limit]]
        return {"archive_id": archive_id, "cleanup": _summary_db(db, feature_id, archive_id),
                "logs": page, "next_after": page[-1]["sequence"] if len(rows) > limit and page else None}
    finally:
        if close:
            if db.in_transaction:
                db.execute("ROLLBACK")
            db.close()
        elif guard:
            guard.release()


def facts(store, feature):
    """Small frozen projection for polling; never inflate the full record here."""
    with store._lock:
        row = store._db.execute("""SELECT facts_json FROM fm_archives WHERE feature_id=?
            AND feature_revision=? AND record IS NOT NULL ORDER BY created_at DESC,id DESC LIMIT 1""",
            (feature["id"], feature["revision"])).fetchone()
        return json.loads(row[0]) if row and feature["status"] == "completed" else {}


def record(row):
    """Every read, including the deletion barrier, verifies the saved bytes."""
    if row["record"] is None:
        return None
    raw = zlib.decompress(row["record"])
    if hashlib.sha256(raw).hexdigest() != row["record_sha256"]:
        raise ValueError("Completion record integrity check failed")
    return json.loads(raw)


def _prior_catalog(store, archive_id, feature_id):
    row = store._db.execute("""SELECT * FROM fm_archives WHERE feature_id=? AND id<>? AND record IS NOT NULL
        ORDER BY created_at DESC,id DESC LIMIT 1""", (feature_id, archive_id)).fetchone()
    return record(row) if row else None


def _catalog_original(store, feature_id, kind, row_id, current_body, body_key, archive_cache=None):
    pointer = store._db.execute("""SELECT * FROM fm_catalog_pointers
        WHERE feature_id=? AND kind=? AND row_id=?""", (feature_id, kind, row_id)).fetchone()
    if not pointer or hashlib.sha256(current_body.encode()).hexdigest() != pointer["pointer_sha256"]:
        return None
    archive_cache = archive_cache if archive_cache is not None else {}
    if pointer["archive_id"] not in archive_cache:
        row = store._db.execute("SELECT * FROM fm_archives WHERE id=? AND feature_id=?",
                                (pointer["archive_id"], feature_id)).fetchone()
        archive_cache[pointer["archive_id"]] = record(row) if row else None
    saved_record = archive_cache[pointer["archive_id"]]
    collection = {"message": "messages", "document": "documents", "feedback_source": "feedback_sources"}[kind]
    id_key = "message_id" if kind == "feedback_source" else "id"
    original = next((item for item in (saved_record or {}).get(collection, []) if item[id_key] == row_id), None)
    if not original or hashlib.sha256(original[body_key].encode()).hexdigest() != pointer["original_sha256"]:
        raise ValueError("A catalog pointer cannot be matched to its verified original")
    return original


def _restore_catalog_rows(store, feature_id, current, kind, body_key, id_key="id"):
    archive_cache = {}
    restored = []
    for item in current:
        old = _catalog_original(store, feature_id, kind, item[id_key], item[body_key], body_key, archive_cache)
        restored.append(old or item)
    return restored


def retain_record(store, archive, runtime_feature, jobs):
    """Inside a write transaction, retain all evidence without snapshot limits."""
    feature_id = archive["feature_id"]
    value = {"schema_version": 1, "recorded_at": now(), "feature": runtime_feature,
             "jobs": jobs,
             "retention": "Documents, deliverables, conversations, execution logs, recovery backups and published releases are retained. Only explicitly owned disposable resources are eligible.",
             "limitations": "Build/version references and external deliverables are preserved where recorded in messages, documents or links. Unrecorded facts are unknown. Verification and usage below are historical observations, not a new verification run."}
    for table in ("visits", "assignments", "messages", "documents", "events", "sessions", "handoffs", "links",
                  "verification_runs", "suite_inventories", "verification_assessments", "owned_resources",
                  "feedback_sources", "feedback", "message_skims"):
        value[table] = [store._decode(row) for row in store._db.execute(
            f"SELECT * FROM fm_{table} WHERE feature_id=? ORDER BY rowid", (feature_id,))]
    prior = _prior_catalog(store, archive["id"], feature_id)
    value["messages"] = _restore_catalog_rows(store, feature_id, value["messages"], "message", "text")
    value["documents"] = _restore_catalog_rows(store, feature_id, value["documents"], "document", "content")
    value["feedback_sources"] = _restore_catalog_rows(
        store, feature_id, value["feedback_sources"], "feedback_source", "response_text", "message_id")
    value["attempts"] = [store._decode(row) for row in store._db.execute("""SELECT x.* FROM fm_attempts x
        JOIN fm_assignments a ON a.id=x.assignment_id WHERE a.feature_id=? ORDER BY x.created_at,x.id""", (feature_id,))]
    value["memberships"] = [dict(row) for row in store._db.execute("""SELECT m.* FROM fm_assignment_memberships m
        JOIN fm_visits v ON v.id=m.visit_id WHERE v.feature_id=? ORDER BY m.created_at""", (feature_id,))]
    value["original_request"] = ((prior or {}).get("original_request") or
        next((message["text"] for message in value["messages"]
              if message.get("metadata", {}).get("initial")), runtime_feature["goal"]))
    value["completed_at"] = next((event["created_at"] for event in reversed(value["events"])
                                 if event["type"] == "feature.complete"), None)
    for document in value["documents"]:
        if hashlib.sha256(document["content"].encode()).hexdigest() != document["content_hash"]:
            raise ValueError("A retained document failed its content integrity check")
    raw = encoded(value).encode()
    search_text = "\n".join([runtime_feature["title"], runtime_feature["goal"]] +
        [encoded(value[key]) for key in ("visits", "assignments", "messages", "documents", "links", "attempts")])
    store._db.execute("UPDATE fm_archives SET record=?,record_sha256=?,facts_json=?,search_text=?,updated_at=? WHERE id=? AND record IS NULL",
                      (zlib.compress(raw), hashlib.sha256(raw).hexdigest(),
                       encoded({key: runtime_feature.get(key, {}) for key in ("usage", "verification")}),
                       search_text, now(), archive["id"]))


def cleanup_options(row):
    value = json.loads(dict(row).get("cleanup_options_json") or "{}")
    resource_ids = value.get("resource_ids")
    return {"resource_ids": resource_ids if isinstance(resource_ids, list) else [],
            "keep_documents": value.get("keep_documents", True),
            "keep_chat": value.get("keep_chat", True)}


def compact_live_rows(store, row, kind):
    """Replace live bodies with catalog pointers after verifying the immutable record.

    IDs, metadata, and foreign-key targets remain in place. SQLite file size is
    deliberately not reported as reclaimed space.
    """
    saved = record(row)
    if not saved:
        raise ValueError("Completion catalog is unavailable")
    archive_id, feature_id = row["id"], row["feature_id"]
    pointer = f"[Archived in First Mate completion record {archive_id}.]"
    if kind == "documents":
        catalog = {item["id"]: item for item in saved["documents"]}
        current = [store._decode(item) for item in store._db.execute(
            "SELECT * FROM fm_documents WHERE feature_id=? ORDER BY rowid", (feature_id,))]
        for item in current:
            original = catalog.get(item["id"])
            if not original or hashlib.sha256(original["content"].encode()).hexdigest() != original["content_hash"]:
                raise ValueError("A live document has no verified catalog original")
            restored = _catalog_original(store, feature_id, "document", item["id"], item["content"], "content")
            if (restored or item)["content"] != original["content"]:
                raise ValueError("A live document changed after the completion catalog was saved")
        digest = hashlib.sha256(pointer.encode()).hexdigest()
        store._db.execute("UPDATE fm_documents SET content=?,content_hash=? WHERE feature_id=?", (pointer, digest, feature_id))
        for item in current:
            original = catalog[item["id"]]
            store._db.execute("""INSERT INTO fm_catalog_pointers
                (kind,row_id,feature_id,archive_id,pointer_sha256,original_sha256,created_at)
                VALUES('document',?,?,?,?,?,?) ON CONFLICT(kind,row_id) DO UPDATE SET
                archive_id=excluded.archive_id,pointer_sha256=excluded.pointer_sha256,
                original_sha256=excluded.original_sha256,created_at=excluded.created_at""",
                (item["id"], feature_id, archive_id, digest,
                 hashlib.sha256(original["content"].encode()).hexdigest(), now()))
        return len(current)
    if kind == "chat":
        catalog = {item["id"]: item for item in saved["messages"]}
        current = [store._decode(item) for item in store._db.execute(
            "SELECT * FROM fm_messages WHERE feature_id=? ORDER BY rowid", (feature_id,))]
        for item in current:
            original = catalog.get(item["id"])
            if not original:
                raise ValueError("A live chat message has no catalog original")
            restored = _catalog_original(store, feature_id, "message", item["id"], item["text"], "text")
            if (restored or item)["text"] != original["text"]:
                raise ValueError("A live chat message changed after the completion catalog was saved")
        feedback_catalog = {item["message_id"]: item for item in saved.get("feedback_sources", [])}
        feedback_rows = [dict(item) for item in store._db.execute(
            "SELECT * FROM fm_feedback_sources WHERE feature_id=? ORDER BY rowid", (feature_id,))]
        for item in feedback_rows:
            original = feedback_catalog.get(item["message_id"])
            if not original:
                raise ValueError("A feedback source has no verified catalog original")
            restored = _catalog_original(store, feature_id, "feedback_source", item["message_id"],
                                         item["response_text"], "response_text")
            if (restored or item)["response_text"] != original["response_text"]:
                raise ValueError("A feedback source changed after the completion catalog was saved")
        store._db.execute("UPDATE fm_messages SET text=? WHERE feature_id=?", (pointer, feature_id))
        digest = hashlib.sha256(pointer.encode()).hexdigest()
        for item in current:
            original = catalog[item["id"]]
            store._db.execute("""INSERT INTO fm_catalog_pointers
                (kind,row_id,feature_id,archive_id,pointer_sha256,original_sha256,created_at)
                VALUES('message',?,?,?,?,?,?) ON CONFLICT(kind,row_id) DO UPDATE SET
                archive_id=excluded.archive_id,pointer_sha256=excluded.pointer_sha256,
                original_sha256=excluded.original_sha256,created_at=excluded.created_at""",
                (item["id"], feature_id, archive_id, digest,
                 hashlib.sha256(original["text"].encode()).hexdigest(), now()))
        store._db.execute("UPDATE fm_feedback_sources SET response_text=? WHERE feature_id=?", (pointer, feature_id))
        for item in feedback_rows:
            original = feedback_catalog[item["message_id"]]
            store._db.execute("""INSERT INTO fm_catalog_pointers
                (kind,row_id,feature_id,archive_id,pointer_sha256,original_sha256,created_at)
                VALUES('feedback_source',?,?,?,?,?,?) ON CONFLICT(kind,row_id) DO UPDATE SET
                archive_id=excluded.archive_id,pointer_sha256=excluded.pointer_sha256,
                original_sha256=excluded.original_sha256,created_at=excluded.created_at""",
                (item["message_id"], feature_id, archive_id, digest,
                 hashlib.sha256(original["response_text"].encode()).hexdigest(), now()))
        skim_ids = [item[0] for item in store._db.execute(
            "SELECT message_id FROM fm_message_skims WHERE feature_id=?", (feature_id,))]
        store._db.execute("DELETE FROM fm_message_skims WHERE feature_id=?", (feature_id,))
        for message_id in skim_ids:
            store._skim_documents.pop(message_id, None)
        return len(current)
    raise ValueError("Unknown catalog compaction kind")


def log(store, archive, *, kind, path, outcome, reason, resource_id=None, bytes_reclaimed=0):
    store._db.execute("""INSERT INTO fm_cleanup_log
        (archive_id,attempt,resource_id,kind,path,outcome,reason,bytes_reclaimed,created_at) VALUES(?,?,?,?,?,?,?,?,?)""",
        (archive["id"], archive["attempt"], resource_id, kind, path, outcome, reason, bytes_reclaimed, now()))


def retry(store, feature_id, request_id):
    from .first_mate_store import FirstMateError, _text
    request_id = _text(request_id, "request_id", 200)
    with store._transaction():
        cached = store._receipt("archive-retry:" + feature_id, request_id, {})
        if cached is not None:
            return cached
        feature = store._one("fm_features", feature_id)
        row = latest(store, feature_id)
        if not row or not feature["archived_at"] or feature["status"] != "completed" or feature["revision"] != row["feature_revision"]:
            raise FirstMateError("Retry requires the same completed, archived session", code="archive_retry_unavailable")
        if row["status"] in {"completed", "failed"}:
            store._db.execute("UPDATE fm_archives SET status='pending',attempt=attempt+1,message='',updated_at=? WHERE id=?",
                              (now(), row["id"]))
            store._event(feature_id, "archive.cleanup", "Archive cleanup retry queued", {"archive_id": row["id"]})
        return store._save_receipt("archive-retry:" + feature_id, request_id, {}, summary(store, feature_id))


def search(store, query="", offset=0, limit=50):
    with store._lock:
        rows = store._db.execute("""SELECT a.id,a.feature_id,a.status,a.created_at,f.title
            FROM fm_archives a JOIN fm_features f ON f.id=a.feature_id
            WHERE a.record IS NOT NULL AND instr(lower(a.search_text),lower(?))>0
            ORDER BY a.created_at DESC,a.id DESC LIMIT ? OFFSET ?""", (query, limit + 1, offset)).fetchall()
        return {"records": [dict(row) for row in rows[:limit]],
                "next_offset": offset + limit if len(rows) > limit else None}


def report(store, feature_id, archive_id=None):
    from .first_mate_store import FirstMateError
    with store._lock:
        store._one("fm_features", feature_id)
        row = (store._db.execute("SELECT * FROM fm_archives WHERE id=? AND feature_id=?", (archive_id, feature_id)).fetchone()
               if archive_id else latest(store, feature_id))
        if not row:
            raise FirstMateError("No completion record exists for this session", code="not_found", status=404)
        value = record(row)
        lines = ["# First Mate completion record", "", f"Record: {row['id']}",
                 f"Cleanup: {row['status']} (attempt {row['attempt']})", row["message"], ""]
        if value:
            feature = value["feature"]
            lines += ["## Task", "", feature["title"], "", f"ID: {feature_id}",
                      f"Work item / ticket: {feature.get('work_item_id') or 'Not recorded'}",
                      f"Created: {feature['created_at']}", f"Archived: {feature.get('archived_at')}",
                      f"Completed: {value['completed_at'] or 'Not recorded'}",
                      f"Outcome: {feature['status']}", f"Record saved: {value['recorded_at']}",
                      "", "## Original request", "", value["original_request"], "", "## Final goal", "", feature["goal"],
                      "", "## Retention and limitations", "",
                      value["retention"], "", value["limitations"], "",
                      "## Archive selection", "", _json_block(cleanup_options(dict(row))), ""]
            for heading, data in (("Historical verification", feature.get("verification", {})),
                                  ("Historical usage and cost", feature.get("usage", {}))):
                lines += ["## " + heading, "", _json_block(data), ""]
            for key, title in (("visits", "Stages and outcomes"), ("assignments", "Assignments and delivered changes"),
                               ("attempts", "Commits and attempts"), ("links", "PRs, builds and saved links"),
                               ("verification_runs", "Actual verification runs"), ("suite_inventories", "Suite inventories"),
                               ("verification_assessments", "Recorded verification assessments"), ("messages", "Conversation"),
                               ("feedback", "Response feedback"),
                               ("sessions", "Saved execution sessions"), ("jobs", "Execution receipts")):
                lines += ["## " + title, "", _json_block(value[key]), ""]
            lines += ["## Owned resources and preserved revisions", "", _json_block(value["owned_resources"]),
                      "", _json_block(feature.get("archive_resource_revisions", {})), ""]
            lines += ["## Final documents", ""]
            for document in value["documents"]:
                lines += ["### " + document["title"], "", f"Document: {document['id']} ({document['content_hash']})",
                          "", document["content"], ""]
        else:
            lines += ["Completion record is pending. No cleanup is permitted before it is saved and verified.", ""]
        lines += ["## Cleanup log", "", "Reclaimed bytes are approximate logical sizes, not filesystem free-space measurements.", ""]
        for entry in store._db.execute("SELECT * FROM fm_cleanup_log WHERE archive_id=? ORDER BY sequence", (row["id"],)):
            lines += [f"- {entry['created_at']} · attempt {entry['attempt']} · {entry['outcome']} · {entry['kind']}",
                      f"  Path/reference: {entry['path']}", f"  Reason: {entry['reason']}",
                      f"  Approximate reclaimed bytes: {entry['bytes_reclaimed']}"]
        return "\n".join(lines) + "\n"


def _json_block(value):
    # Longer than any backtick run in recorded user/agent content.
    content = json.dumps(value, ensure_ascii=False, indent=2)
    fence = "`" * max(3, 1 + max((len(part) for part in re.findall(r'`+', content)), default=0))
    return fence + "json\n" + content + "\n" + fence
