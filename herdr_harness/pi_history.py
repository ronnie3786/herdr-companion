"""Recover reader history without changing Pi's model context or replay cursor.

The bridge deliberately sends small checkpoints. Their exact session file and
leaf identify the *saved* branch, including messages before compaction. Never
select a file by cwd, filename similarity, mtime, or the last entry in the file:
those guesses can expose a different session/branch or duplicate live events.
"""

from __future__ import annotations

from collections import OrderedDict
import copy
import json
import os
import stat
import threading
from typing import Any


# Bound a single malformed/binary-heavy record, not the conversation's length.
# Pi itself reads JSONL records whole. Normal text/tool records are much smaller.
_MAX_RECORD_BYTES = 64 * 1024 * 1024
_CACHE_BYTES = 32 * 1024 * 1024
_CACHE_FILES = 8
_MESSAGE_FIELDS = {
    "role", "content", "timestamp", "toolCallId", "toolName", "isError",
    "stopReason", "errorMessage", "model", "provider", "api", "usage", "details",
}


def _safe(value: Any, depth: int = 0) -> Any:
    """Match the bridge's transport redactions, including nested tool details."""
    if depth >= 24 and isinstance(value, (dict, list)):
        return {"omitted": True, "reason": "depth_limit"}
    if isinstance(value, list):
        return [_safe(item, depth + 1) for item in value]
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key.replace("_", "").lower().endswith("signature"):
                result[key] = {"omitted": True, "reason": "provider_signature"}
            elif key in {"data", "bytes"} and isinstance(item, str) and len(item) > 16_384:
                result[key] = {"omitted": True, "reason": "binary_payload", "length": len(item)}
            else:
                result[key] = _safe(item, depth + 1)
        return result
    return value


def _visible_entry(entry: dict) -> dict | None:
    """Allow only reader-visible entries, never prompts or extension state."""
    base = {key: entry.get(key) for key in ("type", "id", "parentId", "timestamp")}
    kind = entry.get("type")
    if kind == "message":
        message = entry.get("message")
        if not isinstance(message, dict) or message.get("role") not in {
            "user", "assistant", "toolResult", "tool_result",
        }:
            return None
        base["message"] = _safe({key: value for key, value in message.items() if key in _MESSAGE_FIELDS})
    elif kind in {"compaction", "branch_summary"}:
        # In newer Pi versions compactions also contain the entire system
        # prompt. That is agent setup, not user-visible conversation history.
        for key in ("summary", "firstKeptEntryId", "tokensBefore", "fromId"):
            if key in entry:
                base[key] = _safe(entry[key])
    elif kind == "model_change":
        for key in ("provider", "modelId"):
            if key in entry:
                base[key] = _safe(entry[key])
    elif kind == "custom_message" and entry.get("display", True) is True:
        for key in ("customType", "content", "display"):
            if key in entry:
                base[key] = _safe(entry[key])
    else:
        return None
    return base


class PiSavedHistory:
    """Small, private cache; no stored transcripts are modified or deleted."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._cache: OrderedDict[tuple, tuple[list[dict], int]] = OrderedDict()
        self._cache_bytes = 0

    def restore(self, snapshot: dict) -> dict:
        session = snapshot.get("session")
        if not isinstance(session, dict):
            return snapshot
        session_id, path = session.get("id"), session.get("file")
        leaf = session.get("leafId")
        if (not isinstance(session_id, str) or not session_id
                or not isinstance(path, str) or not os.path.isabs(path)
                or not path.endswith(".jsonl") or "\x00" in path
                or "leafId" not in session or (leaf is not None and not isinstance(leaf, str))):
            return snapshot
        try:
            # Nonblocking avoids hanging on a FIFO before fstat can reject it.
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as handle:
                info = os.fstat(handle.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                    raise ValueError("unsafe session file")
                key = (path, info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                       info.st_ctime_ns, session_id, leaf)
                with self._lock:
                    cached = self._cache.get(key)
                    if cached is not None:
                        self._cache.move_to_end(key)
                        entries = copy.deepcopy(cached[0])
                    else:
                        entries = self._read_branch(handle, session_id, leaf)
                        size = len(json.dumps(entries, ensure_ascii=False).encode("utf-8"))
                        if size <= _CACHE_BYTES:
                            while self._cache and (len(self._cache) >= _CACHE_FILES
                                                   or self._cache_bytes + size > _CACHE_BYTES):
                                _, (_, removed_size) = self._cache.popitem(last=False)
                                self._cache_bytes -= removed_size
                            self._cache[key] = (copy.deepcopy(entries), size)
                            self._cache_bytes += size
        except (OSError, ValueError, TypeError, RecursionError):
            # A newly started session may not be on disk yet. Keep the working
            # bridge projection and its honest truncation flag; never substitute
            # another file or claim a partial branch is complete.
            return {**snapshot, "history": {"source": "bridge", "complete": False}}
        return {**snapshot, "entries": entries, "truncated": False,
                "history": {"source": "session_file", "complete": True}}

    @staticmethod
    def _read_branch(handle: Any, session_id: str, leaf: str | None) -> list[dict]:
        def read_record() -> dict:
            raw = handle.readline(_MAX_RECORD_BYTES + 1)
            if not raw or len(raw) > _MAX_RECORD_BYTES or not raw.endswith(b"\n"):
                raise ValueError("incomplete session record")
            value = json.loads(raw)
            if not isinstance(value, dict):
                raise ValueError("invalid session record")
            return value

        header = read_record()
        if header.get("type") != "session" or header.get("id") != session_id or header.get("version") not in {2, 3}:
            raise ValueError("session identity or format mismatch")
        if leaf is None:
            return []

        # Index just offsets and ancestry; abandoned branches and image payloads
        # do not stay in memory. Stop at the checkpoint's exact leaf, ignoring any
        # later (possibly half-written) turn that SSE still needs to replay.
        index: dict[str, tuple[str | None, int]] = {}
        while True:
            offset = handle.tell()
            entry = read_record()
            entry_id, parent = entry.get("id"), entry.get("parentId")
            if (not isinstance(entry_id, str) or not entry_id or entry_id in index
                    or "parentId" not in entry or (parent is not None and not isinstance(parent, str))):
                raise ValueError("invalid session ancestry")
            index[entry_id] = (parent, offset)
            if entry_id == leaf:
                break

        offsets: list[tuple[str, str | None, int]] = []
        seen: set[str] = set()
        current = leaf
        while current is not None:
            if current in seen or current not in index:
                raise ValueError("incomplete or cyclic branch")
            seen.add(current)
            parent, offset = index[current]
            offsets.append((current, parent, offset))
            current = parent
        result = []
        for entry_id, parent, offset in reversed(offsets):
            handle.seek(offset)
            record = read_record()
            if record.get("id") != entry_id or record.get("parentId") != parent:
                raise ValueError("session branch changed during read")
            entry = _visible_entry(record)
            if entry is not None:
                result.append(entry)
        return result
