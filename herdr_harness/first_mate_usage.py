"""Cached, source-bounded usage accounting for managed First Mate Pi sessions.

Only session files named by the First Mate ledger or managed job inventory are
read.  Transcript content is never returned by this module.
"""
from __future__ import annotations

import json
import math
import os
import stat as stat_module
import threading
from collections import OrderedDict
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from .usage_json import UsageJSON, usage_fingerprint

MAX_RECORD = 4 * 1024 * 1024
MAX_SAFE_INTEGER = (1 << 53) - 1


def _iso_from_ns(value: int) -> str:
    try:
        return datetime.fromtimestamp(value / 1_000_000_000, timezone.utc).isoformat().replace("+00:00", "Z")
    except (OverflowError, OSError, ValueError):
        return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _finite_nonnegative(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    # Do not silently round an arbitrary-precision JSON integer into a Double.
    if type(value) is int and value > MAX_SAFE_INTEGER:
        return None
    try:
        converted = float(value)
    except (OverflowError, ValueError):
        return None
    return converted if math.isfinite(converted) and converted >= 0 else None


def _sum_costs(values: Iterable[float]) -> tuple[float | None, bool]:
    total = 0.0
    accepted = False
    complete = True
    for value in values:
        candidate = total + value
        if not math.isfinite(candidate):
            complete = False
            continue
        total = candidate
        accepted = True
    return (total if accepted else None), complete


def _token(value: Any) -> int | None:
    return value if type(value) is int and 0 <= value <= MAX_SAFE_INTEGER else None


def _bounded_sum(values: Iterable[Any]) -> tuple[int, bool]:
    total = 0
    complete = True
    for value in values:
        counter = _token(value)
        if counter is None or counter > MAX_SAFE_INTEGER - total:
            complete = False
            continue
        total += counter
    return total, complete


def _text_or_none(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _status(cost: float | None, complete: bool) -> str:
    if cost is None:
        return "unavailable"
    return "complete" if complete else "partial"


def _empty_summary(updated_at: str, *, session_count: int = 1) -> dict:
    return {
        "currency": "USD", "cost_usd": None, "status": "unavailable",
        "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0,
        "cache_write_tokens": 0, "total_tokens": 0,
        "usage_records": 0, "missing_cost_records": 0,
        "skipped_records": 0, "unaccounted_records": 0,
        "session_count": session_count, "known_cost_sessions": 0,
        "models": [], "updated_at": updated_at,
    }


def aggregate_usage(summaries: Iterable[dict], *, updated_at: str) -> dict:
    """Combine summaries while keeping every public counter JSON-safe."""
    items = list(summaries)
    session_count, counters_complete = _bounded_sum(item.get("session_count", 0) for item in items)
    result = _empty_summary(updated_at, session_count=session_count)
    result["updated_at"] = max([updated_at, *(str(item.get("updated_at") or "") for item in items)])
    for name in ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
                 "total_tokens", "usage_records", "missing_cost_records", "known_cost_sessions",
                 "skipped_records", "unaccounted_records"):
        result[name], valid = _bounded_sum(item.get(name, 0) for item in items)
        counters_complete = counters_complete and valid

    known_costs = []
    costs_complete = True
    for item in items:
        raw_cost = item.get("cost_usd")
        if raw_cost is None:
            continue
        cost = _finite_nonnegative(raw_cost)
        if cost is None:
            costs_complete = False
        else:
            known_costs.append(cost)
    result["cost_usd"], additions_complete = _sum_costs(known_costs)
    costs_complete = costs_complete and additions_complete
    if not costs_complete:
        missing, incremented = _bounded_sum((result["missing_cost_records"], 1))
        result["missing_cost_records"] = missing
        counters_complete = counters_complete and incremented
    complete = (bool(items) and counters_complete and costs_complete
                and all(item.get("status") == "complete" for item in items))
    result["status"] = _status(result["cost_usd"], complete)
    if any(item.get("stale") for item in items):
        result["stale"] = True
        if result["cost_usd"] is not None:
            result["status"] = "partial"

    models: dict[tuple[str | None, str | None], list[dict]] = {}
    for item in items:
        for model in item.get("models", []):
            models.setdefault((model.get("provider"), model.get("model")), []).append(model)
    rendered = []
    for (provider, model), rows in sorted(models.items(), key=lambda pair: ((pair[0][0] or ""), (pair[0][1] or ""))):
        row = aggregate_usage(rows, updated_at=result["updated_at"])
        for name in ("currency", "session_count", "known_cost_sessions", "models", "updated_at", "stale"):
            row.pop(name, None)
        row["provider"], row["model"] = provider, model
        rendered.append(row)
    result["models"] = rendered
    return result


class FirstMateUsage:
    """Stream saved JSONL with stat caching and aggregate managed inventory."""

    def __init__(self, sessions_root: str | Path, *, enabled: bool = True,
                 stop_event: threading.Event | None = None, max_cached_sources: int = 4096):
        self.sessions_root = Path(sessions_root).expanduser().resolve()
        self.enabled = enabled
        self._stop_event = stop_event
        self._max_cached_sources = max(1, max_cached_sources)
        self._lock = threading.RLock()
        # Retain one current version per source, with a bounded LRU for both
        # current and last-good values. This is a disposable display cache.
        self._cache: OrderedDict[tuple[str, str | None], tuple[tuple[int, ...], dict]] = OrderedDict()
        self._last_good: OrderedDict[tuple[str, str | None], dict] = OrderedDict()

    def _check_cancelled(self) -> None:
        if self._stop_event is not None and self._stop_event.is_set():
            raise InterruptedError("First Mate usage refresh stopped")

    @staticmethod
    def _signature(value: os.stat_result) -> tuple[int, ...]:
        # ctime also detects same-size rewrites whose writer restores mtime.
        return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)

    @staticmethod
    def _unavailable(state: str, updated_at: str | None = None) -> dict:
        result = _empty_summary(updated_at or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))
        result.update(_source_state=state, _session_id=None, _identity_valid=False)
        return result

    def _remember(self, cache: OrderedDict, key: tuple[str, str | None], value: Any) -> None:
        cache[key] = value
        cache.move_to_end(key)
        while len(cache) > self._max_cached_sources:
            cache.popitem(last=False)

    def _safe_path(self, value: str | Path) -> Path:
        path = Path(value).expanduser().resolve()
        path.relative_to(self.sessions_root)
        return path

    @contextmanager
    def _open_source(self, path: Path):
        """Open a regular source beneath the root without a symlink/FIFO race."""
        parts = path.relative_to(self.sessions_root).parts
        if not parts:
            raise OSError("session source is not a regular file")
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        directory = os.open(self.sessions_root, directory_flags)
        descriptor = None
        try:
            for part in parts[:-1]:
                child = os.open(part, directory_flags, dir_fd=directory)
                os.close(directory)
                directory = child
            descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=directory)
            if not stat_module.S_ISREG(os.fstat(descriptor).st_mode):
                raise OSError("session source is not a regular file")
            with os.fdopen(descriptor, "rb") as handle:
                descriptor = None  # fdopen owns the descriptor, including on failure.
                yield handle
        finally:
            if descriptor is not None:
                os.close(descriptor)
            os.close(directory)

    def discover_session_id(self, session_file: str | Path, expected: str | None = None) -> str | None:
        """Read only a strict first header, independently of optional accounting.

        This closes the started-but-unbound dispatch gap without scanning its
        transcript. Callers must still validate current ownership before opening.
        """
        self._check_cancelled()
        try:
            path = self._safe_path(session_file)
            before = path.stat()
            if not stat_module.S_ISREG(before.st_mode):
                return None
            signature = self._signature(before)
            with self._open_source(path) as handle:
                opened = os.fstat(handle.fileno())
                if not stat_module.S_ISREG(opened.st_mode) or self._signature(opened) != signature:
                    return None
                line = handle.readline(MAX_RECORD + 1)
                self._check_cancelled()
                if (len(line) > MAX_RECORD or not line.endswith(b"\n")
                        or self._signature(os.fstat(handle.fileno())) != signature):
                    return None
            if self._safe_path(session_file) != path or self._signature(path.stat()) != signature:
                return None
            entry = json.loads(line)
            identity = entry.get("id") if isinstance(entry, dict) and entry.get("type") == "session" else None
            return identity if (isinstance(identity, str) and identity
                                and (expected is None or identity == expected)) else None
        except InterruptedError:
            raise
        except (OSError, RuntimeError, ValueError, UnicodeError):
            return None

    @staticmethod
    def _stale(summary: dict) -> dict:
        result = {**summary, "stale": True}
        result["models"] = [{**model, "status": "partial" if model.get("cost_usd") is not None else "unavailable"}
                            for model in summary.get("models", [])]
        result["status"] = "partial" if result.get("cost_usd") is not None else "unavailable"
        return result

    def session_usage(self, session_file: str | Path, expected_session_id: str | None = None) -> dict:
        """Synchronous engine for the background owner, never a request cache.

        Serialize cache misses so another caller cannot duplicate a scan or
        publish an older parse after a newer one. The runtime's projection cache
        has its own lock and never waits for this lock.
        """
        if not self.enabled:
            # Operational circuit breaker: keep saved-session identities and
            # conversations available without scanning their full usage history.
            return self._unavailable("disabled")
        self._check_cancelled()
        with self._lock:
            self._check_cancelled()
            return self._session_usage(session_file, expected_session_id)

    def _session_usage(self, session_file: str | Path, expected_session_id: str | None) -> dict:
        # A lexical key lets a definitive rejection evict the exact previous
        # claim, including a symlink that now points outside the managed root.
        cache_key = (os.path.abspath(os.path.expanduser(str(session_file))), expected_session_id)

        def reject(state: str, updated_at: str | None = None) -> dict:
            self._cache.pop(cache_key, None)
            self._last_good.pop(cache_key, None)
            return self._unavailable(state, updated_at)

        def unavailable(state: str, updated_at: str | None = None) -> dict:
            # A transient failure must be retried even if its stat is unchanged.
            self._cache.pop(cache_key, None)
            previous = self._last_good.get(cache_key)
            if previous is not None:
                self._last_good.move_to_end(cache_key)
                return self._stale(previous)
            return self._unavailable(state, updated_at)

        try:
            path = self._safe_path(session_file)
        except ValueError:
            return reject("path_escape")
        except (OSError, RuntimeError):
            return unavailable("unreadable")
        try:
            stat = path.stat()
            if not stat_module.S_ISREG(stat.st_mode):
                return reject("not_regular")
            signature = self._signature(stat)
        except OSError:
            return unavailable("unreadable")

        cached = self._cache.get(cache_key)
        if cached is not None and cached[0] == signature:
            self._cache.move_to_end(cache_key)
            return cached[1]
        parsed = self._parse(path, expected_session_id, _iso_from_ns(stat.st_mtime_ns))
        self._check_cancelled()
        state = parsed.get("_source_state")
        if state in {"identity_mismatch", "malformed_header", "missing_header", "not_regular"}:
            reject(str(state))
            self._remember(self._cache, cache_key, (signature, parsed))
            return parsed
        if state in {"unreadable", "truncated_header", "source_changed"}:
            return unavailable(str(state), parsed.get("updated_at"))
        try:
            if self._safe_path(session_file) != path:
                return reject("source_changed")
            if self._signature(path.stat()) != signature or parsed.pop("_source_signature", None) != signature:
                return unavailable("source_changed", parsed.get("updated_at"))
        except ValueError:
            return reject("path_escape")
        except (OSError, RuntimeError):
            return unavailable("unreadable", parsed.get("updated_at"))
        if parsed.get("_identity_valid") and parsed.get("cost_usd") is not None:
            self._remember(self._last_good, cache_key, parsed)
        self._remember(self._cache, cache_key, (signature, parsed))
        return parsed

    def _parse(self, path: Path, expected_session_id: str | None, updated_at: str) -> dict:
        summary = _empty_summary(updated_at)
        summary.update(_session_id=None, _identity_valid=False, _source_state="missing_header")
        token_names = {
            "input_tokens": "input", "output_tokens": "output",
            "cache_read_tokens": "cacheRead", "cache_write_tokens": "cacheWrite",
            "total_tokens": "totalTokens",
        }
        totals = {name: 0 for name in token_names}
        total_cost = 0.0
        valid_costs = 0
        missing_costs = 0
        usage_records = 0
        gaps = False
        header_seen = False
        seen: dict[str, bytes] = {}
        actual_model = None
        actual_thinking = None
        # Scalar accumulators avoid retaining one summary object per usage record.
        model_rows: dict[tuple[str | None, str | None], dict] = {}

        def add_counter(bucket: dict, name: str, value: int) -> bool:
            if value > MAX_SAFE_INTEGER - bucket[name]:
                return False
            bucket[name] += value
            return True

        try:
            with self._open_source(path) as handle:
                opened = os.fstat(handle.fileno())
                if not stat_module.S_ISREG(opened.st_mode):
                    return self._unavailable("not_regular", updated_at)
                opened_signature = self._signature(opened)
                remaining = opened.st_size

                def read_chunk() -> bytes:
                    nonlocal remaining
                    self._check_cancelled()
                    # A pass ends at its original boundary, even if a writer is
                    # continuously appending faster than this reader proceeds.
                    if remaining <= 0:
                        return b""
                    value = handle.readline(min(MAX_RECORD + 1, remaining))
                    remaining -= len(value)
                    return value

                while True:
                    line = read_chunk()
                    if not line:
                        break
                    canonical = None
                    if len(line) > MAX_RECORD:
                        if not header_seen:
                            summary["_source_state"] = "malformed_header"
                            return summary
                        # Skip retaining bulky content, not the record's usage.
                        add_counter(summary, "skipped_records", 1)

                        def chunks():
                            nonlocal line
                            while line:
                                yield line
                                if line.endswith(b"\n"):
                                    return
                                line = read_chunk()

                        source = chunks()
                        try:
                            reader = UsageJSON(source, check_cancelled=self._check_cancelled)
                            entry = reader.record()
                        except (ValueError, UnicodeError, RecursionError):
                            # Finish this record so the next line is independent.
                            for _ in source:
                                pass
                            gaps = True
                            add_counter(summary, "unaccounted_records", 1)
                            missing_costs = min(MAX_SAFE_INTEGER, missing_costs + 1)
                            continue
                        canonical = reader.fingerprint
                    if not line.endswith(b"\n"):
                        if not header_seen:
                            summary["_source_state"] = "truncated_header"
                            return summary
                        gaps = True
                        add_counter(summary, "unaccounted_records", 1)
                        missing_costs = min(MAX_SAFE_INTEGER, missing_costs + 1)
                        break
                    if canonical is None:
                        try:
                            entry = json.loads(line)
                        except (ValueError, UnicodeError, RecursionError):
                            if not header_seen:
                                summary["_source_state"] = "malformed_header"
                                return summary
                            gaps = True
                            add_counter(summary, "unaccounted_records", 1)
                            missing_costs = min(MAX_SAFE_INTEGER, missing_costs + 1)
                            continue
                    if not isinstance(entry, dict):
                        if not header_seen:
                            summary["_source_state"] = "malformed_header"
                            return summary
                        gaps = True
                        add_counter(summary, "unaccounted_records", 1)
                        continue
                    if not header_seen:
                        native_id = entry.get("id") if entry.get("type") == "session" else None
                        if not isinstance(native_id, str) or not native_id:
                            summary["_source_state"] = "malformed_header"
                            return summary
                        if expected_session_id and native_id != expected_session_id:
                            summary["_source_state"] = "identity_mismatch"
                            return summary
                        summary.update(_session_id=native_id, _identity_valid=True, _source_state="valid")
                        header_seen = True
                        continue

                    if not isinstance(entry.get("type"), str):
                        gaps = True
                        add_counter(summary, "unaccounted_records", 1)
                        continue
                    if entry.get("type") == "model_change":
                        model_value = entry.get("model")
                        if isinstance(model_value, dict):
                            provider = model_value.get("provider")
                            model_id = model_value.get("id") or model_value.get("modelId")
                        else:
                            provider = entry.get("provider")
                            model_id = entry.get("modelId") or entry.get("model")
                        if isinstance(provider, str) and provider and isinstance(model_id, str) and model_id:
                            actual_model = provider + "/" + model_id
                        continue
                    if entry.get("type") == "thinking_level_change":
                        level = entry.get("thinkingLevel") or entry.get("thinking_level") or entry.get("level")
                        if isinstance(level, str) and level:
                            actual_thinking = level
                        continue

                    identity = entry.get("id")
                    if canonical is None:
                        try:
                            canonical = usage_fingerprint(entry)
                        except RecursionError:
                            gaps = True
                            add_counter(summary, "unaccounted_records", 1)
                            missing_costs = min(MAX_SAFE_INTEGER, missing_costs + 1)
                            continue
                    key = "id:" + identity if isinstance(identity, str) and identity else "hash:" + canonical.hex()
                    if key in seen:
                        if seen[key] != canonical:
                            gaps = True
                            add_counter(summary, "unaccounted_records", 1)
                            missing_costs = min(MAX_SAFE_INTEGER, missing_costs + 1)
                        continue
                    seen[key] = canonical
                    usage: Any = None
                    provider = model = None
                    expected_usage = False
                    if entry.get("type") == "message":
                        if not isinstance(entry.get("message"), dict):
                            gaps = True
                            add_counter(summary, "unaccounted_records", 1)
                            continue
                        message = entry["message"]
                        if message.get("role") == "assistant":
                            expected_usage = True
                            usage = message.get("usage")
                            provider, model = message.get("provider"), message.get("model")
                            if isinstance(provider, str) and provider and isinstance(model, str) and model:
                                actual_model = provider + "/" + model
                            level = message.get("thinkingLevel") or message.get("thinking_level")
                            if isinstance(level, str) and level:
                                actual_thinking = level
                        elif message.get("role") == "toolResult" and "usage" in message:
                            expected_usage = True
                            usage = message.get("usage")
                            provider, model = message.get("provider"), message.get("model")
                        elif not isinstance(message.get("role"), str) or message.get("role") not in {
                            "user", "system", "toolResult", "bashExecution", "custom",
                            "branchSummary", "compactionSummary",
                        }:
                            gaps = True
                            add_counter(summary, "unaccounted_records", 1)
                    elif entry.get("type") in {"compaction", "branch_summary"}:
                        # These summaries can represent a model call. Missing usage
                        # is unknown coverage, not proof that the call was free.
                        expected_usage = True
                        usage = entry.get("usage")
                        provider, model = entry.get("provider"), entry.get("model") or entry.get("modelId")
                    if not expected_usage:
                        continue

                    if usage_records == MAX_SAFE_INTEGER:
                        gaps = True
                    else:
                        usage_records += 1
                    provider = _text_or_none(provider)
                    model = _text_or_none(model)
                    if isinstance(usage, dict):
                        provider = provider or _text_or_none(usage.get("provider"))
                        model = model or _text_or_none(usage.get("model")) or _text_or_none(usage.get("modelId"))
                    model_row = model_rows.setdefault((provider, model), {
                        **{name: 0 for name in token_names},
                        "usage_records": 0, "missing_cost_records": 0,
                        "cost_usd": 0.0, "has_cost": False, "complete": True,
                    })
                    if model_row["usage_records"] == MAX_SAFE_INTEGER:
                        model_row["complete"] = False
                    else:
                        model_row["usage_records"] += 1

                    valid_record = isinstance(usage, dict)
                    if valid_record:
                        for output_name, input_name in token_names.items():
                            value = _token(usage.get(input_name))
                            if value is None:
                                valid_record = False
                                continue
                            if not add_counter(totals, output_name, value):
                                valid_record = False
                            if not add_counter(model_row, output_name, value):
                                model_row["complete"] = False
                        cost = usage.get("cost")
                        cost_value = _finite_nonnegative(cost.get("total")) if isinstance(cost, dict) else None
                    else:
                        cost_value = None

                    session_cost_valid = cost_value is not None and math.isfinite(total_cost + cost_value)
                    model_cost_valid = cost_value is not None and math.isfinite(model_row["cost_usd"] + cost_value)
                    if session_cost_valid:
                        valid_costs += 1
                        total_cost += cost_value
                    else:
                        if missing_costs < MAX_SAFE_INTEGER:
                            missing_costs += 1
                        gaps = True
                    if model_cost_valid:
                        model_row["cost_usd"] += cost_value
                        model_row["has_cost"] = True
                    else:
                        if model_row["missing_cost_records"] < MAX_SAFE_INTEGER:
                            model_row["missing_cost_records"] += 1
                        model_row["complete"] = False
                    if not valid_record:
                        gaps = True
                        model_row["complete"] = False
                if self._signature(os.fstat(handle.fileno())) != opened_signature:
                    return self._unavailable("source_changed", updated_at)
                summary["_source_signature"] = opened_signature
        except InterruptedError:
            raise
        except OSError:
            unavailable = _empty_summary(updated_at)
            unavailable.update(_session_id=None, _identity_valid=False, _source_state="unreadable")
            return unavailable
        if not header_seen:
            summary["_source_state"] = "truncated_header"
            return summary

        summary.update(totals)
        summary["_actual_model"] = actual_model
        summary["_actual_thinking"] = actual_thinking
        summary["usage_records"] = usage_records
        summary["missing_cost_records"] = missing_costs
        if usage_records == 0 and not gaps:
            summary["cost_usd"] = 0.0
            summary["known_cost_sessions"] = 1
            summary["status"] = "complete"
        elif valid_costs:
            summary["cost_usd"] = total_cost
            summary["known_cost_sessions"] = 1
            summary["status"] = "partial" if gaps else "complete"
        summary["models"] = []
        for (provider, model), row in sorted(model_rows.items(), key=lambda pair: ((pair[0][0] or ""), (pair[0][1] or ""))):
            cost = row["cost_usd"] if row.pop("has_cost") else None
            complete = row.pop("complete")
            row.update(provider=provider, model=model, cost_usd=cost,
                       status=_status(cost, complete))
            summary["models"].append(row)
        return summary

    @staticmethod
    def public_summary(summary: dict) -> dict:
        return {key: value for key, value in summary.items() if not key.startswith("_")}

    def account(self, *, feature_id: str, assignments: list[dict], ledger_sessions: list[dict],
                jobs: list[dict], jobs_root: Path, updated_at: str, discover_unbound: bool = False) -> dict:
        """Account one feature from its complete ledger and managed job inventory."""
        assignment_by_id = {assignment["id"]: assignment for assignment in assignments}
        jobs_by_id = {job.get("id"): job for job in jobs if job.get("id")}

        def advisor_assignment(job: dict) -> str | None:
            current = job
            seen_jobs = set()
            while current and current.get("id") not in seen_jobs:
                seen_jobs.add(current.get("id"))
                if current.get("kind") == "worker":
                    identity = current.get("claim", {}).get("id")
                    return identity if identity in assignment_by_id else None
                current = jobs_by_id.get(current.get("parent_job_id"))
            return None

        eligible_jobs = [job for job in jobs
                         if job.get("native_session_id")
                         or (jobs_root / str(job.get("id")) / "started.json").exists()]

        def canonical_path(value: Any) -> str:
            try:
                if not self.enabled:
                    # Group recorded metadata lexically when no files are read.
                    # Resolving every historical path for every card is expensive.
                    # The session reader still validates paths before opening them.
                    return os.path.abspath(os.path.expanduser(str(value))) if value else ""
                return str(Path(str(value)).expanduser().resolve()) if value else ""
            except (OSError, RuntimeError, ValueError):
                return str(value or "")

        # Only unbound started jobs may discover identity from a trusted header.
        # A stored native ID always remains authoritative and is validated later.
        discovered_job_ids: dict[str, str] = {}
        for job in eligible_jobs:
            self._check_cancelled()
            if job.get("native_session_id") or not job.get("session_file"):
                continue
            if not (jobs_root / str(job.get("id")) / "started.json").exists():
                continue
            # Header discovery is independent of optional accounting. Explicit
            # metadata-only callers can retain access across the bind crash gap.
            native_id = (self.discover_session_id(job["session_file"])
                         if self.enabled or discover_unbound else None)
            if native_id:
                discovered_job_ids[str(job.get("id"))] = native_id

        path_features: dict[str, set[str]] = {}
        native_features: dict[str, set[str]] = {}
        for row in ledger_sessions:
            self._check_cancelled()
            path = canonical_path(row.get("session_file"))
            if path and row.get("feature_id"):
                path_features.setdefault(path, set()).add(row["feature_id"])
            if row.get("native_session_id") and row.get("feature_id"):
                native_features.setdefault(row["native_session_id"], set()).add(row["feature_id"])
        for job in eligible_jobs:
            self._check_cancelled()
            path = canonical_path(job.get("session_file"))
            if path and job.get("feature_id"):
                path_features.setdefault(path, set()).add(job["feature_id"])
            native_id = job.get("native_session_id") or discovered_job_ids.get(str(job.get("id")))
            if native_id and job.get("feature_id"):
                native_features.setdefault(native_id, set()).add(job["feature_id"])

        sources: dict[str, dict] = {}
        for row in ledger_sessions:
            if row.get("feature_id") != feature_id:
                continue
            path = canonical_path(row.get("session_file"))
            if not path:
                continue
            source = sources.setdefault(path, {"path": path, "expected_ids": set(), "jobs": [], "ledger": None})
            if row.get("native_session_id"):
                source["expected_ids"].add(row["native_session_id"])
            source["ledger"] = row
        for job in eligible_jobs:
            if job.get("feature_id") != feature_id:
                continue
            path = canonical_path(job.get("session_file"))
            if not path:
                # A started managed dispatch without a source still affects coverage.
                path = "missing-job:" + str(job.get("id"))
            source = sources.setdefault(path, {"path": path, "expected_ids": set(), "jobs": [], "ledger": None})
            native_id = job.get("native_session_id") or discovered_job_ids.get(str(job.get("id")))
            if native_id:
                source["expected_ids"].add(native_id)
            source["jobs"].append(job)

        accounted: dict[str, dict] = {}
        anonymous = 0
        for source in sources.values():
            self._check_cancelled()
            expected_ids = source["expected_ids"]
            expected = next(iter(expected_ids)) if len(expected_ids) == 1 else None
            cross_feature = (len(path_features.get(source["path"], set())) > 1
                             or (expected is not None and len(native_features.get(expected, set())) > 1))
            if source["path"].startswith("missing-job:") or len(expected_ids) > 1 or cross_feature:
                parsed = _empty_summary(updated_at)
            else:
                parsed = self.session_usage(source["path"], expected)
            if not parsed.get("_identity_valid") and not parsed.get("stale"):
                source_updated_at = ((source.get("ledger") or {}).get("updated_at")
                                     or next((job.get("created_at") for job in source["jobs"] if job.get("created_at")), None)
                                     or updated_at)
                parsed = {**parsed, "updated_at": source_updated_at}
            # Ownership conflicts stay anonymous/unopenable instead of exposing a
            # native identity under two features.
            native_id = None if cross_feature else (parsed.get("_session_id") or expected)
            identity = "native:" + native_id if native_id else "anonymous:" + str(anonymous)
            anonymous += native_id is None
            if identity in accounted:
                # A native Pi session reused by multiple dispatches is one cost source.
                existing = accounted[identity]
                existing["jobs"].extend(source["jobs"])
                if not existing.get("ledger"):
                    existing["ledger"] = source.get("ledger")
                if existing["path"] != source["path"]:
                    existing["summary"] = self._stale(existing["summary"])
                continue
            accounted[identity] = {**source, "native_id": native_id, "summary": parsed,
                                   "identity_conflict": cross_feature or len(expected_ids) > 1}

        assignment_sources: dict[str, set[str]] = {identity: set() for identity in assignment_by_id}
        public_sessions = []
        all_summaries = []
        for identity, source in accounted.items():
            summary = source["summary"]
            all_summaries.append(summary)
            row = source.get("ledger")
            attached: set[str] = set()
            if row and row.get("assignment_id") in assignment_by_id:
                attached.add(row["assignment_id"])
            for job in source["jobs"]:
                if job.get("kind") == "worker" and job.get("claim", {}).get("id") in assignment_by_id:
                    attached.add(job["claim"]["id"])
                elif job.get("kind") == "advisor":
                    target = advisor_assignment(job)
                    if target:
                        attached.add(target)
            for assignment_id in attached:
                assignment_sources[assignment_id].add(identity)

            native_id = source.get("native_id")
            if not native_id:
                continue
            jobs_for_source = source["jobs"]
            representative = jobs_for_source[-1] if jobs_for_source else None
            kind = representative.get("kind") if representative else ("worker" if row and row.get("assignment_id") else "coordinator")
            if row:
                public = {key: value for key, value in row.items() if key != "session_file"}
            else:
                claim = (representative or {}).get("claim", {})
                created = (representative or {}).get("created_at") or updated_at
                public = {
                    "native_session_id": native_id, "feature_id": feature_id,
                    "assignment_id": next(iter(attached), None),
                    "title": claim.get("title") or ("First Mate" if kind == "coordinator" else "First Mate advisor"),
                    "role": "first_mate" if kind == "coordinator" else kind,
                    "status": "retained" if (jobs_root / str((representative or {}).get("id")) / "finalized.json").exists() else "active",
                    "generation": claim.get("generation", 0), "attempt": claim.get("attempt"),
                    "input_revision": claim.get("input_revision"), "created_at": created,
                    "updated_at": summary.get("updated_at") or created,
                    "ownership_status": "retained" if (jobs_root / str((representative or {}).get("id")) / "finalized.json").exists() else "active",
                }
            public["kind"] = kind
            parent_session_id = None
            for job in reversed(jobs_for_source):
                parent = jobs_by_id.get(job.get("parent_job_id"))
                if parent and parent.get("native_session_id") and parent.get("native_session_id") != native_id:
                    parent_session_id = parent["native_session_id"]
                    break
            if parent_session_id:
                public["parent_session_id"] = parent_session_id
            requested = dict((representative or {}).get("model_selection") or {})
            validated_history = bool(summary.get("_identity_valid")) and not summary.get("stale")
            state_fallback_allowed = not source.get("identity_conflict")
            actual_model = ((summary.get("_actual_model") if validated_history else None)
                            or ((representative or {}).get("actual_model") if state_fallback_allowed else None))
            actual_thinking = ((summary.get("_actual_thinking") if validated_history else None)
                               or ((representative or {}).get("actual_thinking") if state_fallback_allowed else None))
            if requested or actual_model or actual_thinking:
                if not requested:
                    requested = {
                        "profile": "coordinator" if kind == "coordinator" else "execution",
                        "requested_model": str((representative or {}).get("model") or ""),
                        "requested_thinking": str((representative or {}).get("thinking") or ""),
                        "source": "pi_default",
                    }
                requested["actual_model"] = actual_model if isinstance(actual_model, str) and actual_model else None
                requested["actual_thinking"] = actual_thinking if isinstance(actual_thinking, str) and actual_thinking else None
                public["model_selection"] = requested
            public["usage"] = self.public_summary(summary)
            public_sessions.append(public)

        own_usage = {
            assignment_id: aggregate_usage((accounted[key]["summary"] for key in keys), updated_at=updated_at)
            for assignment_id, keys in assignment_sources.items()
        }
        children: dict[str, list[str]] = {identity: [] for identity in assignment_by_id}
        for assignment in assignments:
            parent = assignment.get("metadata", {}).get("parent_assignment_id")
            if parent in children and assignment["id"] != parent:
                children[parent].append(assignment["id"])

        subtree_usage = {}
        for root in assignment_by_id:
            stack, seen_assignments, source_ids = [root], set(), set()
            while stack:
                current = stack.pop()
                if current in seen_assignments:
                    continue
                seen_assignments.add(current)
                source_ids.update(assignment_sources.get(current, set()))
                stack.extend(children.get(current, []))
            subtree_usage[root] = aggregate_usage((accounted[key]["summary"] for key in source_ids), updated_at=updated_at)

        public_sessions.sort(key=lambda row: (row.get("created_at") or "", row["native_session_id"]), reverse=True)
        return {
            "usage": aggregate_usage(all_summaries, updated_at=updated_at),
            "assignment_usage": own_usage, "subtree_usage": subtree_usage,
            "sessions": public_sessions,
        }
