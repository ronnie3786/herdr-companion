"""Bounded incremental discovery of pull-request links in managed evidence.

First Mate features can retain links explicitly, and managed agents can register
them through ``fm_save_link``. This module adds the automatic side: recognizable
GitHub pull-request URLs found in evidence that the companion already owns are
retained for the feature without any model turn, provider request, or network
fetch.

Eligible evidence is deliberately narrow:

* native Pi session records that the SQL session ledger already owns, plus
  validated managed dispatch jobs (including finalized jobs and retained
  predecessor sessions);
* accepted outcome summaries, completed visit summaries, and documents attached
  to accepted outcomes.

Only textual ``user``, ``assistant``, and ``toolResult`` content is inspected.
Thinking blocks, arbitrary filesystem history, unowned sessions, and source text
are never interpreted or executed. Session reads require containment under the
private sessions root, a matching session header, and unambiguous feature
ownership. Scans are bounded per pass, round-robin scheduled, and recorded in a
private cursor file that is written only after every attempted upsert succeeds.
Discovery stores only exact ``github.com/<owner>/<repo>/pull/<number>`` links;
general URLs are saved explicitly. Draft, ready, merged, and closed wording is
irrelevant: recognition is the URL alone.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import time
import uuid
from typing import Any, Callable, Mapping

from .alerts import utc_now
from .first_mate_links import parse_github_pull_request

MAX_RECORD_BYTES = 4 * 1024 * 1024
MAX_JOB_BYTES = 4 * 1024 * 1024
MAX_CURSOR_BYTES = 64 * 1024 * 1024
ACCEPTED_VERDICTS = {"success", "passed"}
MESSAGE_ROLES = {"user", "assistant", "toolResult"}

_URL_PATTERN = re.compile(r"https?://[^\s<>\"'`)\]}\x00-\x1f]+")
_TRAILING_PUNCTUATION = ".,;:!?…\"'"


def github_pull_requests(text: str) -> list[str]:
    """Return exact canonical GitHub PR URLs found in one text value.

    Plain URLs, Markdown link destinations, and angle-bracket autolinks all
    reduce to the same URL substring. Invalid or non-PR candidates are ignored;
    the result preserves first-seen order and contains each PR once.
    """
    if not isinstance(text, str) or not text:
        return []
    found: list[str] = []
    seen: set[str] = set()
    for match in _URL_PATTERN.finditer(text):
        candidate = match.group(0).rstrip(_TRAILING_PUNCTUATION)
        parsed = parse_github_pull_request(candidate)
        if parsed is None or parsed["url"] in seen:
            continue
        seen.add(parsed["url"])
        found.append(parsed["url"])
    return found


def message_texts(record: Mapping[str, Any]) -> list[str]:
    """Return only textual message content eligible for discovery.

    Thinking blocks and structured non-text parts are never inspected. An
    assistant message's text remains eligible whether or not it is the final
    reply, and tool results are included because ``gh`` output is evidence.
    """
    if record.get("type") != "message":
        return []
    message = record.get("message")
    if not isinstance(message, Mapping) or message.get("role") not in MESSAGE_ROLES:
        return []
    content = message.get("content")
    texts: list[str] = []
    if isinstance(content, str):
        texts.append(content)
    elif isinstance(content, list):
        for item in content:
            if isinstance(item, Mapping) and item.get("type") == "text" and isinstance(item.get("text"), str):
                texts.append(item["text"])
    return texts


def _read_bounded_json(path: Path, maximum: int) -> Any:
    try:
        with path.open("rb") as handle:
            raw = handle.read(maximum + 1)
    except OSError:
        return None
    if len(raw) > maximum:
        return None
    try:
        return json.loads(raw)
    except (ValueError, UnicodeError):
        return None


def _read_records(path: Path, offset: int, maximum_bytes: int) -> tuple[list[dict], int]:
    """Read complete JSONL records from ``offset`` within a byte budget.

    A partial final record is left for a later pass; the returned offset always
    points at the byte after the last complete line that was interpreted.
    """
    records: list[dict] = []
    try:
        with path.open("rb") as handle:
            handle.seek(offset)
            after = offset
            while after - offset < maximum_bytes:
                line = handle.readline(MAX_RECORD_BYTES + 1)
                if not line:
                    break
                if len(line) > MAX_RECORD_BYTES:
                    # Consume the oversized record without interpreting it.
                    while line and not line.endswith(b"\n"):
                        line = handle.readline(MAX_RECORD_BYTES + 1)
                    after = handle.tell()
                    continue
                if not line.endswith(b"\n"):
                    break
                try:
                    value = json.loads(line)
                    if isinstance(value, dict):
                        records.append(value)
                except (ValueError, UnicodeError):
                    pass
                after = handle.tell()
    except OSError:
        return [], offset
    return records, after


def _session_header(path: Path) -> str | None:
    """Return the native session ID from a complete first session header."""
    try:
        with path.open("rb") as handle:
            line = handle.readline(MAX_RECORD_BYTES + 1)
    except OSError:
        return None
    if not line.endswith(b"\n") or len(line) > MAX_RECORD_BYTES:
        return None
    try:
        value = json.loads(line)
    except (ValueError, UnicodeError):
        return None
    if not isinstance(value, Mapping) or value.get("type") != "session":
        return None
    native_id = value.get("id")
    return native_id if isinstance(native_id, str) and native_id else None


class FirstMateLinkDiscovery:
    """Bounded, incremental PR discovery over feature-owned managed evidence.

    The store owns links and deduplicates canonical URLs, so re-reading a source
    after a crash or a changed cursor is safe. This class only decides which
    evidence is eligible, reads it incrementally, and checkpoints its progress.
    """

    def __init__(self, store: Any, *, root: str | Path, minimum_interval: float = 5.0,
                 max_sources_per_pass: int = 8, max_bytes_per_pass: int = 2 * 1024 * 1024,
                 max_bytes_per_source: int = 512 * 1024,
                 clock: Callable[[], float] | None = None) -> None:
        self.store = store
        self.root = Path(root).expanduser().resolve()
        self.sessions_root = (self.root / "sessions").resolve()
        self.jobs_root = self.root / "jobs"
        self.cursor_path = self.root / "link-discovery" / "cursors.json"
        self.minimum_interval = max(0.0, float(minimum_interval))
        self.max_sources_per_pass = max(1, int(max_sources_per_pass))
        self.max_bytes_per_pass = max(1024, int(max_bytes_per_pass))
        self.max_bytes_per_source = max(1024, int(max_bytes_per_source))
        self._clock = clock or time.monotonic
        self._last_scan: float | None = None
        self._native_owners: dict[str, tuple[str, Path]] = {}

    # -- cursor persistence -------------------------------------------------

    def _load_cursor(self) -> dict:
        value = _read_bounded_json(self.cursor_path, MAX_CURSOR_BYTES)
        if not isinstance(value, Mapping):
            return {"version": 1, "next_key": None, "sources": {}}
        sources = value.get("sources")
        next_key = value.get("next_key")
        return {"version": 1,
                "next_key": next_key if isinstance(next_key, str) else None,
                "sources": dict(sources) if isinstance(sources, Mapping) else {}}

    def _write_cursor(self, value: Mapping[str, Any]) -> None:
        self.cursor_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.cursor_path.parent, 0o700)
        temporary = self.cursor_path.with_name(self.cursor_path.name + "." + uuid.uuid4().hex + ".tmp")
        try:
            with temporary.open("x", encoding="utf-8") as handle:
                os.chmod(temporary, 0o600)
                json.dump(value, handle, ensure_ascii=False)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.cursor_path)
            descriptor = os.open(self.cursor_path.parent, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        finally:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass

    # -- source inventory ---------------------------------------------------

    def _contained_session(self, value: Any) -> Path | None:
        if not isinstance(value, str) or not value:
            return None
        try:
            path = Path(value).expanduser().resolve()
        except (OSError, RuntimeError):
            return None
        try:
            path.relative_to(self.sessions_root)
        except ValueError:
            return None
        return path

    def _valid_jobs(self) -> list[dict]:
        jobs: list[dict] = []
        try:
            paths = sorted(self.jobs_root.glob("*/job.json"))
        except OSError:
            return jobs
        for path in paths:
            value = _read_bounded_json(path, MAX_JOB_BYTES)
            if not isinstance(value, Mapping):
                continue
            if value.get("id") != path.parent.name:
                continue
            if value.get("kind") not in {"coordinator", "worker", "advisor"}:
                continue
            if not isinstance(value.get("feature_id"), str) or not value["feature_id"]:
                continue
            if not isinstance(value.get("session_file"), str) or not value["session_file"]:
                continue
            jobs.append(dict(value))
        return jobs

    def _inventory(self) -> list[dict]:
        features = {feature["id"]: feature for feature in self.store.list_features("all")}
        ledger = self.store.list_session_records()
        jobs = self._valid_jobs()

        path_features: dict[Path, set[str]] = {}
        native_owners: dict[str, tuple[str, Path]] = {}
        for row in ledger:
            feature_id = row.get("feature_id")
            path = self._contained_session(row.get("session_file"))
            if feature_id in features and path is not None:
                path_features.setdefault(path, set()).add(feature_id)
                native_id = row.get("native_session_id")
                if isinstance(native_id, str) and native_id:
                    native_owners[native_id] = (feature_id, path)
        for job in jobs:
            feature_id = job.get("feature_id")
            path = self._contained_session(job.get("session_file"))
            if feature_id in features and path is not None:
                path_features.setdefault(path, set()).add(feature_id)
        self._native_owners = native_owners

        pending: dict[tuple[str, Path], dict] = {}

        def add_session(feature_id: str, path: Path, native_id: Any,
                        assignment_id: Any = None) -> None:
            # A path with more than one owning feature is never scanned.
            if feature_id not in features or len(path_features.get(path, ())) != 1:
                return
            entry = pending.get((feature_id, path))
            if entry is None:
                entry = {"key": f"session:{feature_id}:{path}", "kind": "session",
                         "feature_id": feature_id, "path": path,
                         "assignment_id": assignment_id if isinstance(assignment_id, str) else None,
                         "expected": set()}
                pending[(feature_id, path)] = entry
            if isinstance(native_id, str) and native_id:
                entry["expected"].add(native_id)

        for row in ledger:
            path = self._contained_session(row.get("session_file"))
            if path is not None:
                add_session(row.get("feature_id"), path, row.get("native_session_id"),
                            row.get("assignment_id"))
        for job in jobs:
            path = self._contained_session(job.get("session_file"))
            if path is not None:
                add_session(job.get("feature_id"), path, job.get("native_session_id"))

        sources = [entry for entry in pending.values() if len(entry["expected"]) <= 1]

        assignments = self.store.list_assignments()
        accepted: dict[str, dict] = {}
        for assignment in assignments:
            if assignment.get("verdict") not in ACCEPTED_VERDICTS:
                continue
            accepted[assignment["id"]] = assignment
            summary = assignment.get("summary")
            if isinstance(summary, str) and summary.strip():
                provenance: dict[str, Any] = {"assignment_id": assignment["id"]}
                if assignment.get("native_session_id"):
                    provenance["native_session_id"] = assignment["native_session_id"]
                sources.append({"key": f"outcome:{assignment['feature_id']}:{assignment['id']}",
                                "kind": "text", "feature_id": assignment["feature_id"],
                                "text": summary, "provenance": provenance})

        for feature_id in features:
            snapshot = self.store.snapshot(feature_id)
            for visit in snapshot.get("visits", []):
                if visit.get("status") != "completed":
                    continue
                summary = visit.get("summary")
                if isinstance(summary, str) and summary.strip():
                    sources.append({"key": f"visit:{feature_id}:{visit['id']}", "kind": "text",
                                    "feature_id": feature_id, "text": summary,
                                    "provenance": {"message_id": visit.get("authorization_message_id")}
                                    if visit.get("authorization_message_id") else {}})
            for document in snapshot.get("documents", []):
                assignment = accepted.get(document.get("assignment_id"))
                document_id = document.get("id")
                if assignment is None or not isinstance(document_id, str):
                    continue
                sources.append({"key": f"document:{feature_id}:{document_id}", "kind": "document",
                                "feature_id": feature_id, "document_id": document_id,
                                "assignment_id": assignment["id"],
                                "native_session_id": document.get("native_session_id")})
        return sources

    # -- bounded scanning ---------------------------------------------------

    def scan_once(self, *, force: bool = False) -> dict:
        """One bounded round-robin pass over the current eligible inventory."""
        now = self._clock()
        if not force and self._last_scan is not None and now - self._last_scan < self.minimum_interval:
            return {"ok": True, "skipped": "interval", "attempted": 0, "saved": 0}
        self._last_scan = now

        state = self._load_cursor()
        sources = self._inventory()
        sources.sort(key=lambda source: source["key"])
        if not sources:
            self._write_cursor({"version": 1, "next_key": None, "sources": {}})
            return {"ok": True, "attempted": 0, "saved": 0, "sources": 0}

        keys = [source["key"] for source in sources]
        start = keys.index(state["next_key"]) if state["next_key"] in keys else 0
        updated = dict(state["sources"])
        attempted = saved = bytes_used = 0
        for position in range(len(sources)):
            if attempted >= self.max_sources_per_pass or bytes_used >= self.max_bytes_per_pass:
                break
            source = sources[(start + position) % len(sources)]
            outcome = self._scan_source(source, updated.get(source["key"], {}))
            updated[source["key"]] = outcome["cursor"]
            attempted += 1
            saved += outcome["saved"]
            bytes_used += outcome["bytes"]

        known = set(keys)
        self._write_cursor({"version": 1,
                            "next_key": keys[(start + attempted) % len(keys)],
                            "sources": {key: value for key, value in updated.items() if key in known}})
        return {"ok": True, "attempted": attempted, "saved": saved, "sources": len(sources)}

    def _scan_source(self, source: Mapping[str, Any], cursor: Mapping[str, Any]) -> dict:
        if source["kind"] == "session":
            return self._scan_session(source, cursor)
        return self._scan_text(source, cursor)

    def _header_matches(self, source: Mapping[str, Any], native_id: str) -> bool:
        # The ledger's native-ID ownership is authoritative even when a job
        # names the same ID: a copied header must not migrate a session.
        owner = self._native_owners.get(native_id)
        if owner is not None:
            feature_id, owner_path = owner
            if feature_id != source["feature_id"] or owner_path != source["path"]:
                return False
        expected = source.get("expected") or set()
        if expected:
            return native_id in expected
        return True

    def _scan_session(self, source: Mapping[str, Any], cursor: Mapping[str, Any]) -> dict:
        path: Path = source["path"]
        existing = dict(cursor) if isinstance(cursor, Mapping) else {}
        try:
            stat = path.stat()
        except OSError:
            # An unavailable source preserves its saved links and cursor.
            return {"bytes": 0, "saved": 0, "cursor": existing}
        native_id = _session_header(path)
        if native_id is None or not self._header_matches(source, native_id):
            return {"bytes": 0, "saved": 0, "cursor": existing}
        offset = existing.get("offset")
        if (not isinstance(offset, int) or isinstance(offset, bool) or offset < 0
                or existing.get("inode") != stat.st_ino or existing.get("device") != stat.st_dev
                or offset > stat.st_size):
            # First read, replacement, or truncation: restart this source.
            offset = 0
        records, after = _read_records(path, offset, self.max_bytes_per_source)
        saved = 0
        for record in records:
            for text in message_texts(record):
                for url in github_pull_requests(text):
                    self._upsert(source, url, native_session_id=native_id,
                                 assignment_id=source.get("assignment_id"))
                    saved += 1
        return {"bytes": max(0, after - offset), "saved": saved,
                "cursor": {"offset": after, "inode": stat.st_ino, "device": stat.st_dev}}

    def _scan_text(self, source: Mapping[str, Any], cursor: Mapping[str, Any]) -> dict:
        existing = dict(cursor) if isinstance(cursor, Mapping) else {}
        if source["kind"] == "document":
            document = self.store.get_document(source["document_id"])
            if document.get("feature_id") != source["feature_id"]:
                raise ValueError("Document ownership changed during link discovery")
            text = document.get("content")
            text = text if isinstance(text, str) else ""
        else:
            text = source.get("text")
            text = text if isinstance(text, str) else ""
        digest = hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()
        if existing.get("sha256") == digest:
            return {"bytes": 0, "saved": 0, "cursor": existing}
        saved = 0
        for url in github_pull_requests(text):
            self._upsert(source, url, native_session_id=source.get("native_session_id"),
                         assignment_id=source.get("assignment_id"),
                         document_id=source.get("document_id"))
            saved += 1
        return {"bytes": len(text.encode("utf-8", "replace")), "saved": saved,
                "cursor": {"sha256": digest}}

    def _upsert(self, source: Mapping[str, Any], url: str, *, native_session_id: Any = None,
                assignment_id: Any = None, document_id: Any = None) -> None:
        provenance: dict[str, str] = {}
        if isinstance(native_session_id, str) and native_session_id:
            provenance["native_session_id"] = native_session_id
        if isinstance(assignment_id, str) and assignment_id:
            provenance["assignment_id"] = assignment_id
        if isinstance(document_id, str) and document_id:
            provenance["document_id"] = document_id
        declared = source.get("provenance")
        if isinstance(declared, Mapping):
            for name, value in declared.items():
                if isinstance(value, str) and value:
                    provenance.setdefault(name, value)
        provenance["observed_at"] = utc_now()
        self.store.register_link(source["feature_id"], url=url, source="discovery",
                                 provenance=provenance)
