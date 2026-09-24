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
ownership. Discovery stores only exact ``github.com/<owner>/<repo>/pull/<number>``
links (owner and repository casing is folded); general URLs are saved explicitly.
Draft, ready, merged, and closed wording is irrelevant: recognition is the URL
alone.

The pass is bounded from end to end. Inventory is built one lightweight page per
category with durable per-category cursors, so a pass never reads a public
snapshot, an event stream, or the whole session ledger. Sessions are read in
record units with a resumable cursor: a final partial line is left for its next
append and an over-long line is skipped in bounded chunks across passes. Outcome,
visit, and document text is read through bounded SQL slices with resumable
character offsets and an overlap tail so a URL split across slices is still seen.
All of these reads draw on one shared byte budget and the whole cursor is written
only after every attempted upsert succeeds.
"""
from __future__ import annotations

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
MAX_HEADER_BYTES = 256 * 1024
MAX_CURSOR_BYTES = 64 * 1024 * 1024
MAX_SOURCE_STATES = 20000
MAX_JOB_PATH_ENTRIES = 20000
TEXT_CHUNK_CHARS = 64 * 1024
URL_OVERLAP_CHARS = 4096 + 64
ACCEPTED_VERDICTS = ("success", "passed")
MESSAGE_ROLES = {"user", "assistant", "toolResult"}
JOB_KINDS = {"coordinator", "worker", "advisor"}
INVENTORY_CATEGORIES = ("session", "job", "outcome", "visit", "document")

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


class _PassBudget:
    """One shared, monotonically decreasing byte allowance per scan pass.

    ``take`` never lets the recorded remaining value go below zero. A complete
    session record may overshoot the remaining allowance by at most
    ``MAX_RECORD_BYTES`` because parsing needs whole lines; everything else,
    including chunked skips and text slices, stops at zero.
    """

    __slots__ = ("remaining",)

    def __init__(self, maximum: int) -> None:
        self.remaining = max(0, int(maximum))

    def take(self, amount: int) -> int:
        granted = max(0, min(int(amount), self.remaining))
        self.remaining -= granted
        return granted

    @property
    def exhausted(self) -> bool:
        return self.remaining <= 0


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


def _read_json_with_bytes(path: Path, maximum: int, budget: _PassBudget) -> tuple[Any, int]:
    """Read one bounded JSON document and charge its bytes to the pass budget.

    A job record is read whole up to a constant cap even when the remaining
    budget is smaller, so the job cursor can always advance; the overshoot is
    bounded by ``maximum``.
    """
    try:
        with path.open("rb") as handle:
            raw = handle.read(maximum + 1)
    except OSError:
        return None, 0
    consumed = min(len(raw), maximum + 1)
    budget.take(consumed)
    if len(raw) > maximum:
        return None, consumed
    try:
        return json.loads(raw), consumed
    except (ValueError, UnicodeError):
        return None, consumed


def _read_records(path: Path, offset: int, maximum_bytes: int, budget: _PassBudget,
                  skipping: bool) -> tuple[list[dict], int, int, bool]:
    """Read complete JSONL records from ``offset`` within the shared budget.

    Returns ``(records, after, bytes_read, skipping)``. An incomplete final line
    is left for a later pass: the returned offset stays at its start. A line that
    is longer than ``MAX_RECORD_BYTES`` is skipped in bounded steps; ``skipping``
    is returned so the next pass resumes scanning for its newline without
    draining an arbitrarily large record.
    """
    records: list[dict] = []
    bytes_read = 0
    after = offset
    if maximum_bytes <= 0 or budget.exhausted:
        return records, after, bytes_read, skipping
    try:
        with path.open("rb") as handle:
            handle.seek(offset)
            while bytes_read < maximum_bytes and not budget.exhausted:
                if skipping:
                    allowance = min(maximum_bytes - bytes_read, budget.remaining, 64 * 1024)
                    if allowance <= 0:
                        break
                    chunk = handle.read(allowance)
                    if not chunk:
                        break
                    bytes_read += len(chunk)
                    budget.take(len(chunk))
                    newline = chunk.find(b"\n")
                    if newline < 0:
                        after = handle.tell()
                        continue
                    after = handle.tell() - (len(chunk) - newline - 1)
                    handle.seek(after)
                    skipping = False
                    continue
                line_start = handle.tell()
                line = handle.readline(MAX_RECORD_BYTES + 1)
                if not line:
                    break
                if line.endswith(b"\n"):
                    bytes_read += len(line)
                    budget.take(len(line))
                    after = handle.tell()
                    if len(line) <= MAX_RECORD_BYTES:
                        try:
                            value = json.loads(line)
                        except (ValueError, UnicodeError):
                            pass
                        else:
                            if isinstance(value, dict):
                                records.append(value)
                    continue
                if len(line) > MAX_RECORD_BYTES:
                    # Consume one bounded piece of the oversized record; the
                    # next pass continues scanning for its newline.
                    bytes_read += len(line)
                    budget.take(len(line))
                    after = handle.tell()
                    skipping = True
                    continue
                # A partial final record without its newline: do not consume it.
                handle.seek(line_start)
                break
    except OSError:
        return [], offset, 0, skipping
    return records, after, bytes_read, skipping


def _session_header(path: Path, budget: _PassBudget) -> str | None:
    """Return the native session ID from a complete first session header."""
    allowance = min(MAX_HEADER_BYTES, max(0, budget.remaining))
    if allowance <= 0:
        return None
    try:
        with path.open("rb") as handle:
            line = handle.readline(allowance + 1)
    except OSError:
        return None
    budget.take(min(len(line), allowance))
    if not line.endswith(b"\n") or len(line) > allowance:
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

    # -- cursor persistence -------------------------------------------------

    def _load_cursor(self) -> dict:
        value = _read_bounded_json(self.cursor_path, MAX_CURSOR_BYTES)
        if not isinstance(value, Mapping):
            return self._empty_cursor()
        sources = value.get("sources")
        inventory = value.get("inventory")
        cursor = self._empty_cursor()
        if isinstance(sources, Mapping):
            cursor["sources"] = dict(sources)
        if isinstance(inventory, Mapping):
            after = inventory.get("after")
            category = inventory.get("category")
            job_paths = inventory.get("job_paths")
            cursor["inventory"] = {
                "category": category if isinstance(category, int) and not isinstance(category, bool) and category >= 0 else 0,
                "after": dict(after) if isinstance(after, Mapping) else {},
                "job_paths": {key: value for key, value in job_paths.items()
                              if isinstance(key, str) and isinstance(value, str)}
                if isinstance(job_paths, Mapping) else {},
            }
        return cursor

    @staticmethod
    def _empty_cursor() -> dict:
        return {"version": 2, "inventory": {"category": 0, "after": {}, "job_paths": {}}, "sources": {}}

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

    def _session_page(self, after: Any, limit: int) -> tuple[list[dict], Any, bool]:
        rows = self.store.link_discovery_sessions(after=after, limit=limit)
        entries: list[dict] = []
        for row in rows:
            feature_id = row.get("feature_id")
            path = self._contained_session(row.get("session_file"))
            if not isinstance(feature_id, str) or not feature_id or path is None:
                continue
            entries.append({"key": f"session:{feature_id}:{path}", "kind": "session",
                            "feature_id": feature_id, "path": path,
                            "native_session_id": row.get("native_session_id"),
                            "assignment_id": row.get("assignment_id")})
        return entries, rows[-1]["native_session_id"] if rows else after, len(rows) < limit

    def _job_page(self, after: Any, limit: int, budget: _PassBudget,
                  job_paths: dict[str, str]) -> tuple[list[dict], Any, bool]:
        try:
            names = sorted(path.parent.name for path in self.jobs_root.glob("*/job.json"))
        except OSError:
            return [], None, True
        pending = [name for name in names if after is None or name > after]
        if not pending:
            return [], after, True
        entries: list[dict] = []
        last = after
        complete = True
        examined = 0
        for name in pending:
            if len(entries) >= limit or examined >= limit or budget.exhausted:
                complete = False
                break
            examined += 1
            value, _ = _read_json_with_bytes(self.jobs_root / name / "job.json", MAX_JOB_BYTES, budget)
            last = name
            if not isinstance(value, Mapping):
                continue
            if value.get("id") != name or value.get("kind") not in JOB_KINDS:
                continue
            feature_id = value.get("feature_id")
            if not isinstance(feature_id, str) or not feature_id:
                continue
            path = self._contained_session(value.get("session_file"))
            if path is None:
                continue
            owner = (self.store.link_discovery_session_by_file(str(path))
                     if len(str(path)) <= 4000 else None)
            if owner is not None and owner.get("feature_id") != feature_id:
                continue
            entries.append({"key": f"session:{feature_id}:{path}", "kind": "session",
                            "feature_id": feature_id, "path": path,
                            "native_session_id": value.get("native_session_id"),
                            "assignment_id": None})
        by_path: dict[Path, set[str]] = {}
        for entry in entries:
            by_path.setdefault(entry["path"], set()).add(entry["feature_id"])
        result: list[dict] = []
        for entry in entries:
            key = str(entry["path"])
            known = job_paths.get(key)
            if len(by_path[entry["path"]]) > 1 or (known is not None and known != entry["feature_id"]):
                entry["ambiguous"] = True
            if known is None:
                job_paths[key] = entry["feature_id"]
            result.append(entry)
        if len(job_paths) > MAX_JOB_PATH_ENTRIES:
            for key in list(job_paths)[:-MAX_JOB_PATH_ENTRIES]:
                job_paths.pop(key, None)
        return result, last, complete

    def _outcome_page(self, after: Any, limit: int) -> tuple[list[dict], Any, bool]:
        rows = self.store.link_discovery_outcomes(ACCEPTED_VERDICTS, after=after, limit=limit)
        entries = [{"key": f"outcome:{row['feature_id']}:{row['id']}", "kind": "outcome",
                    "feature_id": row["feature_id"], "assignment_id": row["id"],
                    "native_session_id": row.get("native_session_id"),
                    "updated_at": row.get("updated_at"), "text_length": row.get("text_length")}
                   for row in rows]
        return entries, rows[-1]["id"] if rows else after, len(rows) < limit

    def _visit_page(self, after: Any, limit: int) -> tuple[list[dict], Any, bool]:
        rows = self.store.link_discovery_visits(after=after, limit=limit)
        entries = [{"key": f"visit:{row['feature_id']}:{row['id']}", "kind": "visit",
                    "feature_id": row["feature_id"], "visit_id": row["id"],
                    "message_id": row.get("authorization_message_id"),
                    "updated_at": row.get("updated_at"), "text_length": row.get("text_length")}
                   for row in rows]
        return entries, rows[-1]["id"] if rows else after, len(rows) < limit

    def _document_page(self, after: Any, limit: int) -> tuple[list[dict], Any, bool]:
        rows = self.store.link_discovery_documents(ACCEPTED_VERDICTS, after=after, limit=limit)
        entries = [{"key": f"document:{row['feature_id']}:{row['id']}", "kind": "document",
                    "feature_id": row["feature_id"], "document_id": row["id"],
                    "assignment_id": row.get("assignment_id"),
                    "native_session_id": row.get("native_session_id"),
                    "updated_at": None, "text_length": row.get("text_length")}
                   for row in rows]
        return entries, rows[-1]["id"] if rows else after, len(rows) < limit

    def _inventory_page(self, category: str, after: Any, limit: int, budget: _PassBudget,
                        job_paths: dict[str, str]) -> tuple[list[dict], Any, bool]:
        if category == "session":
            return self._session_page(after, limit)
        if category == "job":
            return self._job_page(after, limit, budget, job_paths)
        if category == "outcome":
            return self._outcome_page(after, limit)
        if category == "visit":
            return self._visit_page(after, limit)
        return self._document_page(after, limit)

    def _inventory(self, state: Mapping[str, Any], budget: _PassBudget) -> tuple[list[dict], dict]:
        inventory = state.get("inventory") if isinstance(state.get("inventory"), Mapping) else {}
        raw_category = inventory.get("category")
        category = (raw_category if isinstance(raw_category, int) and not isinstance(raw_category, bool)
                    and raw_category >= 0 else 0) % len(INVENTORY_CATEGORIES)
        raw_after = inventory.get("after")
        after = dict(raw_after) if isinstance(raw_after, Mapping) else {}
        raw_paths = inventory.get("job_paths")
        job_paths = ({key: value for key, value in raw_paths.items()
                      if isinstance(key, str) and isinstance(value, str)}
                     if isinstance(raw_paths, Mapping) else {})

        collected: list[dict] = []
        visited: set[str] = set()
        while (len(collected) < self.max_sources_per_pass and len(visited) < len(INVENTORY_CATEGORIES)
               and not budget.exhausted):
            name = INVENTORY_CATEGORIES[category % len(INVENTORY_CATEGORIES)]
            visited.add(name)
            remaining = self.max_sources_per_pass - len(collected)
            entries, next_after, exhausted = self._inventory_page(name, after.get(name), remaining, budget, job_paths)
            after[name] = None if exhausted else next_after
            collected.extend(entries)
            category = (category + 1) % len(INVENTORY_CATEGORIES)

        unique: dict[str, dict] = {}
        for entry in collected:
            unique.setdefault(entry["key"], entry)
        return list(unique.values()), {"category": category, "after": after, "job_paths": job_paths}

    # -- bounded scanning ---------------------------------------------------

    def scan_once(self, *, force: bool = False) -> dict:
        """One bounded round-robin pass over the current eligible inventory."""
        now = self._clock()
        if not force and self._last_scan is not None and now - self._last_scan < self.minimum_interval:
            return {"ok": True, "skipped": "interval", "attempted": 0, "saved": 0}
        self._last_scan = now

        state = self._load_cursor()
        budget = _PassBudget(self.max_bytes_per_pass)
        sources, inventory = self._inventory(state, budget)
        updated = dict(state.get("sources") or {})
        attempted = saved = 0
        for source in sources:
            if attempted >= self.max_sources_per_pass or budget.exhausted:
                break
            outcome = self._scan_source(source, updated.get(source["key"], {}), budget)
            updated[source["key"]] = outcome["cursor"]
            attempted += 1
            saved += outcome["saved"]

        if len(updated) > MAX_SOURCE_STATES:
            updated = dict(list(updated.items())[-MAX_SOURCE_STATES:])
        self._write_cursor({"version": 2, "inventory": inventory, "sources": updated})
        return {"ok": True, "attempted": attempted, "saved": saved, "sources": len(sources),
                "bytes": self.max_bytes_per_pass - budget.remaining}

    def _scan_source(self, source: Mapping[str, Any], cursor: Mapping[str, Any],
                     budget: _PassBudget) -> dict:
        if source["kind"] == "session":
            return self._scan_session(source, cursor, budget)
        return self._scan_text(source, cursor, budget)

    def _header_matches(self, source: Mapping[str, Any], native_id: str) -> bool:
        # The ledger's native-ID ownership is authoritative even when a job
        # names the same ID: a copied header must not migrate a session. A path
        # the ledger already owns only accepts its recorded native ID, and IDs
        # beyond the ledger's own bound cannot have an owner.
        path_text = str(source["path"])
        owner_by_file = (self.store.link_discovery_session_by_file(path_text)
                         if len(path_text) <= 4000 else None)
        if owner_by_file is not None:
            if (owner_by_file.get("feature_id") != source["feature_id"]
                    or owner_by_file.get("native_session_id") != native_id):
                return False
        owner = self.store.link_discovery_session_owner(native_id) if len(native_id) <= 500 else None
        if owner is not None:
            owner_path = self._contained_session(owner.get("session_file"))
            if owner.get("feature_id") != source["feature_id"] or owner_path != source["path"]:
                return False
        expected = source.get("native_session_id")
        if isinstance(expected, str) and expected:
            return native_id == expected
        return True

    def _scan_session(self, source: Mapping[str, Any], cursor: Mapping[str, Any],
                      budget: _PassBudget) -> dict:
        path: Path = source["path"]
        existing = dict(cursor) if isinstance(cursor, Mapping) else {}
        if source.get("ambiguous"):
            return {"saved": 0, "cursor": existing}
        try:
            stat = path.stat()
        except OSError:
            # An unavailable source preserves its saved links and cursor.
            return {"saved": 0, "cursor": existing}
        native_id = _session_header(path, budget)
        if native_id is None or not self._header_matches(source, native_id):
            return {"saved": 0, "cursor": existing}
        offset = existing.get("offset")
        skipping = existing.get("skipping") is True
        if (not isinstance(offset, int) or isinstance(offset, bool) or offset < 0
                or existing.get("inode") != stat.st_ino or existing.get("device") != stat.st_dev
                or offset > stat.st_size):
            # First read, replacement, or truncation: restart this source.
            offset, skipping = 0, False
        records, after, _, still_skipping = _read_records(
            path, offset, self.max_bytes_per_source, budget, skipping)
        saved = 0
        for record in records:
            for text in message_texts(record):
                for url in github_pull_requests(text):
                    self._upsert(source, url, native_session_id=native_id,
                                 assignment_id=source.get("assignment_id"))
                    saved += 1
        new_cursor: dict[str, Any] = {"offset": after, "inode": stat.st_ino, "device": stat.st_dev}
        if still_skipping:
            new_cursor["skipping"] = True
        return {"saved": saved, "cursor": new_cursor}

    def _text_slice(self, source: Mapping[str, Any], offset: int, limit: int) -> dict | None:
        if source["kind"] == "document":
            return self.store.link_discovery_document_slice(
                source["document_id"], ACCEPTED_VERDICTS, offset=offset, limit=limit)
        if source["kind"] == "outcome":
            return self.store.link_discovery_outcome_slice(
                source["assignment_id"], ACCEPTED_VERDICTS, offset=offset, limit=limit)
        return self.store.link_discovery_visit_slice(source["visit_id"], offset=offset, limit=limit)

    def _scan_text(self, source: Mapping[str, Any], cursor: Mapping[str, Any],
                   budget: _PassBudget) -> dict:
        existing = dict(cursor) if isinstance(cursor, Mapping) else {}
        total = source.get("text_length")
        identity = source.get("updated_at")
        offset = existing.get("offset")
        tail = existing.get("tail")
        valid = (isinstance(offset, int) and not isinstance(offset, bool) and offset >= 0
                 and existing.get("length") == total and existing.get("identity") == identity
                 and isinstance(tail, str))
        if not valid:
            offset, tail = 0, ""
        limit = min(TEXT_CHUNK_CHARS, max(1, budget.remaining))
        row = self._text_slice(source, offset, limit)
        if row is None:
            # Ownership or acceptance changed since inventory; re-inventory first.
            return {"saved": 0, "cursor": {}}
        if row.get("feature_id") != source["feature_id"] or row.get("text_length") != total:
            return {"saved": 0, "cursor": {}}
        chunk = row.get("text") if isinstance(row.get("text"), str) else ""
        text = tail + chunk
        saved = 0
        for url in github_pull_requests(text):
            if source["kind"] == "document":
                self._upsert(source, url, native_session_id=source.get("native_session_id"),
                             assignment_id=source.get("assignment_id"),
                             document_id=source.get("document_id"))
            elif source["kind"] == "outcome":
                self._upsert(source, url, native_session_id=source.get("native_session_id"),
                             assignment_id=source.get("assignment_id"))
            else:
                self._upsert(source, url, message_id=source.get("message_id"))
            saved += 1
        budget.take(len(chunk.encode("utf-8", "replace")))
        new_offset = offset + len(chunk)
        new_tail = (tail + chunk)[-URL_OVERLAP_CHARS:] if new_offset < total else ""
        return {"saved": saved,
                "cursor": {"offset": new_offset, "length": total, "identity": identity, "tail": new_tail}}

    def _upsert(self, source: Mapping[str, Any], url: str, *, native_session_id: Any = None,
                assignment_id: Any = None, document_id: Any = None, message_id: Any = None) -> None:
        provenance: dict[str, str] = {}
        for name, value in (("native_session_id", native_session_id),
                            ("assignment_id", assignment_id),
                            ("document_id", document_id),
                            ("message_id", message_id)):
            if isinstance(value, str) and value:
                provenance[name] = value
        declared = source.get("provenance")
        if isinstance(declared, Mapping):
            for name, value in declared.items():
                if isinstance(value, str) and value:
                    provenance.setdefault(name, value)
        provenance["observed_at"] = utc_now()
        self.store.register_link(source["feature_id"], url=url, source="discovery",
                                 provenance=provenance)
