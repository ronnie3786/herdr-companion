"""Bounded current-session context telemetry for First Mate coordinators.

Context usage is a point-in-time measurement from the managed coordinator
extension.  It is deliberately separate from cumulative billing usage and only
accepts telemetry carrying the feature's exact current native session identity.
"""
from __future__ import annotations

import json
import os
import stat
import threading
from collections import OrderedDict
from datetime import datetime
from pathlib import Path
from typing import Any, BinaryIO, Iterable, Mapping

MAX_SAFE_INTEGER = (1 << 53) - 1
MAX_TELEMETRY_BYTES = 1024 * 1024
MAX_TELEMETRY_RECORDS = 4096
MAX_TELEMETRY_RECORD_BYTES = 64 * 1024
DEFAULT_CONTEXT_TARGET = 150000
MAX_CONTEXT_CACHE_ENTRIES = 256

Measurement = tuple[datetime, int, int | None, str]
CacheKey = tuple[str, str, int, int, int, int]


def _safe_nonnegative_integer(value: Any) -> int | None:
    return value if type(value) is int and 0 <= value <= MAX_SAFE_INTEGER else None


def _safe_positive_integer(value: Any) -> int | None:
    result = _safe_nonnegative_integer(value)
    return result if result is not None and result > 0 else None


def _timestamp(value: Any) -> tuple[str, datetime] | None:
    if not isinstance(value, str) or not value or len(value) > 64:
        return None
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return value, parsed


def handoff_target_tokens(configured_target: Any, context_window: Any = None) -> int:
    """Apply the managed-rotation reserve policy using JSON-safe integers only."""
    configured = _safe_positive_integer(configured_target) or DEFAULT_CONTEXT_TARGET
    window = _safe_positive_integer(context_window)
    if window is None:
        return configured
    reserve = max(8192, window // 10)
    return min(configured, max(4096, window - reserve))


def _tail_records(handle: BinaryIO, size: int) -> list[dict]:
    """Read a bounded complete-record tail without interpreting partial writes."""
    start = max(0, size - MAX_TELEMETRY_BYTES)
    handle.seek(start)
    data = handle.read(MAX_TELEMETRY_BYTES)
    if start:
        newline = data.find(b"\n")
        if newline < 0:
            return []
        data = data[newline + 1 :]
    if data and not data.endswith(b"\n"):
        data = data[: data.rfind(b"\n") + 1]
    records: list[dict] = []
    for line in data.splitlines()[-MAX_TELEMETRY_RECORDS:]:
        if not line or len(line) > MAX_TELEMETRY_RECORD_BYTES:
            continue
        try:
            value = json.loads(line)
        except (UnicodeError, ValueError, RecursionError):
            continue
        if isinstance(value, dict):
            records.append(value)
    return records


class FirstMateContext:
    """Project the latest valid measurement for one exact coordinator session."""

    def __init__(self, jobs_root: str | Path, configured_target: int) -> None:
        self.jobs_root = Path(jobs_root).expanduser().resolve()
        self.configured_target = handoff_target_tokens(configured_target)
        self._cache: OrderedDict[CacheKey, Measurement | None] = OrderedDict()
        self._cache_lock = threading.Lock()

    @staticmethod
    def _job_identity(job: Mapping[str, Any]) -> str | None:
        identity = job.get("id")
        if (not isinstance(identity, str) or not identity or len(identity) > 256
                or identity in {".", ".."} or "/" in identity or "\\" in identity
                or any(ord(character) < 32 or 127 <= ord(character) <= 159
                       for character in identity)):
            return None
        return identity

    def _open_telemetry(self, identity: str) -> tuple[BinaryIO, os.stat_result]:
        """Open exactly one regular job telemetry file without following symlinks."""
        no_follow = getattr(os, "O_NOFOLLOW", 0)
        nonblocking = getattr(os, "O_NONBLOCK", 0)
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | no_follow
        root_fd = os.open(self.jobs_root, directory_flags)
        try:
            job_fd = os.open(identity, directory_flags, dir_fd=root_fd)
        finally:
            os.close(root_fd)
        try:
            file_fd = os.open(
                "telemetry.jsonl", os.O_RDONLY | no_follow | nonblocking, dir_fd=job_fd)
        finally:
            os.close(job_fd)
        try:
            metadata = os.fstat(file_fd)
            if not stat.S_ISREG(metadata.st_mode):
                raise OSError("telemetry is not a regular file")
            return os.fdopen(file_fd, "rb"), metadata
        except BaseException:
            os.close(file_fd)
            raise

    def _evict(self, identity: str) -> None:
        with self._cache_lock:
            for key in [key for key in self._cache if key[0] == identity]:
                del self._cache[key]

    @staticmethod
    def _parse_measurement(handle: BinaryIO, size: int,
                           native_session_id: str) -> Measurement | None:
        latest: Measurement | None = None
        for event in _tail_records(handle, size):
            if (event.get("type") != "context_usage"
                    or event.get("native_session_id") != native_session_id):
                continue
            observed = _timestamp(event.get("time"))
            payload = event.get("payload")
            if observed is None or not isinstance(payload, dict):
                continue
            tokens = _safe_nonnegative_integer(payload.get("tokens"))
            if tokens is None:
                continue
            context_window = _safe_positive_integer(payload.get("contextWindow"))
            sample = (observed[1], tokens, context_window, observed[0])
            # Append order resolves equal timestamps within this one job.
            if latest is None or sample[0] >= latest[0]:
                latest = sample
        return latest

    def _measurement(self, identity: str,
                     native_session_id: str) -> Measurement | None:
        try:
            handle, metadata = self._open_telemetry(identity)
        except OSError:
            self._evict(identity)
            return None
        signature = (metadata.st_dev, metadata.st_ino,
                     metadata.st_size, metadata.st_mtime_ns)
        key: CacheKey = (identity, native_session_id, *signature)
        with self._cache_lock:
            if key in self._cache:
                measurement = self._cache.pop(key)
                self._cache[key] = measurement
                handle.close()
                return measurement
        try:
            measurement = self._parse_measurement(
                handle, metadata.st_size, native_session_id)
            after = os.fstat(handle.fileno())
        except OSError:
            handle.close()
            self._evict(identity)
            return None
        finally:
            if not handle.closed:
                handle.close()
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != signature:
            self._evict(identity)
            return None
        with self._cache_lock:
            for old_key in [old_key for old_key in self._cache
                            if old_key[:2] == (identity, native_session_id)]:
                del self._cache[old_key]
            self._cache[key] = measurement
            self._cache.move_to_end(key)
            while len(self._cache) > MAX_CONTEXT_CACHE_ENTRIES:
                self._cache.popitem(last=False)
        return measurement

    def project(self, feature: Mapping[str, Any], jobs: Iterable[Mapping[str, Any]]) -> dict:
        native_session_id = feature.get("native_session_id")
        if not isinstance(native_session_id, str) or not native_session_id:
            native_session_id = None
        unavailable = {
            "native_session_id": native_session_id,
            "status": "unavailable",
            "tokens": None,
            "context_window": None,
            "handoff_target_tokens": self.configured_target,
            "observed_at": None,
        }
        if native_session_id is None:
            return unavailable

        latest: Measurement | None = None
        candidates = [job for job in jobs
                      if job.get("kind") == "coordinator"
                      and job.get("feature_id") == feature.get("id")
                      and job.get("native_session_id") == native_session_id]
        candidates.sort(
            key=lambda job: (str(job.get("created_at") or ""), str(job.get("id") or "")),
            reverse=True,
        )
        # A new turn can create its job before it emits context telemetry. Keep
        # the last measured value for this exact native session, but never cross
        # a session rotation or search an unbounded history.
        for job in candidates[:128]:
            identity = self._job_identity(job)
            if identity is None:
                continue
            measurement = self._measurement(identity, native_session_id)
            # Candidates are newest-first, so equal timestamps retain the newer
            # job. Append order for equal timestamps within a job is resolved by
            # _parse_measurement.
            if measurement is not None and (
                    latest is None or measurement[0] > latest[0]):
                latest = measurement
        if latest is None:
            return unavailable
        _, tokens, context_window, observed_at = latest
        return {
            "native_session_id": native_session_id,
            "status": "measured",
            "tokens": tokens,
            "context_window": context_window,
            "handoff_target_tokens": handoff_target_tokens(self.configured_target, context_window),
            "observed_at": observed_at,
        }
