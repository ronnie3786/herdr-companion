"""Skims for First Mate chat and HUD chats: the asynchronous hook.

A finished conversation reply (First Mate replies, notices, stage results, and
escalations) or a completed HUD chat turn of at least `skim_min_words` words
gets a pending skim in the same write that stores it, so clients can show a
quiet "Skimming…" right away. A small worker pool then runs one tool-free Pi
inference per reply (profile `first-mate-skim-v1`), normalizes the markup with
herdr_harness.skim, and stores the result beside the reply. The reply itself is
never delayed, changed, or re-sent: a failed or rejected skim only means the
client keeps showing the full reply.

The model sees the reply and the human question it answers, nothing else.
Nothing here logs reply or skim text; logs carry ids, statuses, and timings.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import itertools
import json
import logging
import os
from pathlib import Path
import queue
import tempfile
import threading
import time
from typing import Any, Callable, Mapping, Optional
import uuid

from . import skim
from .skim_chat_store import ChatSkimStore
from .agent_runs import (
    MODEL_PATTERN,
    SKIM_PROFILE,
    SKIM_TIMEOUT_SECONDS,
    TERMINAL_STATUSES,
    THINKING_LEVELS,
    AgentRunError,
)

CAPABILITY = "first-mate-skim-v1"
HUD_PROFILE = "hud-chat-v1"
SKIM_FILE = "skim.json"
MAX_ATTEMPTS = 2
MAX_USER_MESSAGE_CHARS = 131072
SWEEP_SECONDS = 300
_NEW, _BACKFILL = 0, 1
_LOG = logging.getLogger(__name__)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _flag(environ: Mapping[str, str], key: str, default: bool) -> bool:
    value = environ.get(key)
    if value is None or not value.strip():
        return default
    return value.strip().lower() not in {"0", "false", "no", "off"}


def _bounded(environ: Mapping[str, str], key: str, default: int, minimum: int, maximum: int) -> int:
    try:
        return max(minimum, min(maximum, int(environ.get(key, default))))
    except (TypeError, ValueError):
        return default


@dataclass(frozen=True)
class SkimSettings:
    """`[first_mate]` skim settings. The operator's real values stay private."""

    enabled: bool = True
    hud_chats: bool = True
    model: str = ""  # Empty: Pi's configured default model.
    thinking: str = "low"
    min_words: int = 80
    backfill_hours: int = 24
    workers: int = 2

    @classmethod
    def from_environ(cls, environ: Mapping[str, str]) -> "SkimSettings":
        enabled = _flag(environ, "HERDR_FIRST_MATE_SKIM", True)
        model = (environ.get("HERDR_FIRST_MATE_SKIM_MODEL") or "").strip()
        if model and not MODEL_PATTERN.fullmatch(model):
            _LOG.warning("Skims are off: skim_model is not a valid Pi model selection.")
            enabled = False
        thinking = (environ.get("HERDR_FIRST_MATE_SKIM_THINKING") or "low").strip().lower()
        if thinking not in THINKING_LEVELS:
            _LOG.warning("skim_thinking is not a Pi thinking level; using low.")
            thinking = "low"
        return cls(
            enabled=enabled,
            hud_chats=_flag(environ, "HERDR_FIRST_MATE_SKIM_HUD_CHATS", True),
            model=model,
            thinking=thinking,
            min_words=_bounded(environ, "HERDR_FIRST_MATE_SKIM_MIN_WORDS", 80, 1, 5000),
            backfill_hours=_bounded(environ, "HERDR_FIRST_MATE_SKIM_BACKFILL_HOURS", 24, 0, 24 * 30),
            workers=_bounded(environ, "HERDR_FIRST_MATE_SKIM_WORKERS", 2, 1, 2),
        )

    def key(self, text: Any) -> Optional[dict]:
        """The idempotency key for one reply, or None when it is too short to skim."""
        if not isinstance(text, str):
            return None
        canonical = skim.canonicalize(text)
        if skim.words(canonical) < self.min_words:
            return None
        return {
            "format": skim.DEFAULT_FORMAT, "prompt_version": skim.PROMPT_VERSION,
            "segmenter_version": skim.SEGMENTER_VERSION, "skim_version": skim.SKIM_VERSION,
            "model": self.model, "thinking": self.thinking,
            "reply_sha256": hashlib.sha256(canonical.encode("utf-8")).hexdigest(),
        }


# -- HUD chat skims live beside their run --------------------------------------

def _read_state(run_dir: Path) -> Optional[dict]:
    try:
        with (run_dir / SKIM_FILE).open("r", encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, ValueError, UnicodeError):
        return None
    return state if isinstance(state, dict) else None


def _write_state(run_dir: Path, state: dict) -> None:
    temporary = run_dir / f".skim.{uuid.uuid4().hex}.tmp"
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            json.dump(state, handle, separators=(",", ":"), ensure_ascii=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, run_dir / SKIM_FILE)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def public_run_skim(run_dir: Path) -> Optional[dict]:
    """The skim a HUD chat turn exposes, or None when it has none."""
    state = _read_state(run_dir)
    if state is None or state.get("status") not in {"pending", "ready", "failed", "rejected"}:
        return None
    return skim.served(state)


class SkimService:
    """Queue, run, and store skims without ever delaying a reply."""

    def __init__(self, settings: SkimSettings, *, agent_runs: Callable[[], Any],
                 publish: Optional[Callable[[str, dict], Any]] = None,
                 chat_store_path: str = ":memory:") -> None:
        self.settings = settings
        self._agent_runs = agent_runs
        self._publish = publish
        self._store: Any = None
        self._runs: Any = None
        self._queue: "queue.PriorityQueue[tuple[int, int, tuple[str, str]]]" = queue.PriorityQueue()
        # Queued and running jobs: recovery and sweeps never start a second
        # inference for a skim that is already waiting or in progress.
        self._queued: set[tuple[str, str]] = set()
        self._active: set[tuple[str, str]] = set()
        self._order = itertools.count()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._sweep_now = threading.Event()
        self._threads: list[threading.Thread] = []
        self._started = False
        self._chats = ChatSkimStore(chat_store_path)

    # -- wiring --------------------------------------------------------------

    def capabilities(self) -> dict:
        return {"enabled": self.settings.enabled, "hud_chats": self.settings.enabled and self.settings.hud_chats,
                "min_words": self.settings.min_words, "format": skim.DEFAULT_FORMAT,
                "prompt_version": skim.PROMPT_VERSION}

    def request_chat(self, *, reply: str, question: str | None = None) -> dict:
        """Idempotent and asynchronous: viewing a reply never waits on a model."""
        if len(reply) > MAX_USER_MESSAGE_CHARS or (question is not None and len(question) > 16000):
            raise AgentRunError("The reply is too large to skim.", code="skim_too_large", status=413)
        key = self.settings.key(reply) if self.settings.enabled else None
        if key is None:
            return {"id": None, "skim": None}
        question = _question(question)
        identifier = hashlib.sha256(json.dumps([key, question], sort_keys=True).encode()).hexdigest()
        state = self._chats.create(identifier, {**key, "status": "pending", "updated_at": _now()}, question, reply)
        self.start()
        if state["status"] == "pending":
            self._enqueue(("chat", identifier), _NEW)
        return {"id": identifier, "skim": skim.served(state)}

    def chat(self, identifier: str) -> dict:
        state = self._chats.get(identifier)
        if state is None:
            raise AgentRunError("This skim is no longer cached.", code="skim_not_found", status=404)
        return {"id": identifier, "skim": skim.served(state)}

    def _skim_chat(self, identifier: str) -> None:
        source = self._chats.begin(identifier)
        if source is None:
            return
        state, question, reply = source
        outcome = self._infer(question, reply, state)
        if outcome is not None:
            self._chats.finish(identifier, outcome)

    def attach_store(self, store: Any) -> None:
        """Record pending skims with First Mate replies and queue them after commit."""
        self._store = store
        if not self.settings.enabled:
            return
        store.skim_policy = self.settings.key
        if self._on_reply not in store.reply_listeners:
            store.reply_listeners.append(self._on_reply)

    def attach_agent_runs(self, manager: Any) -> None:
        self._runs = manager
        if self.settings.enabled and self.settings.hud_chats and self._on_run_completed not in manager.completion_listeners:
            manager.completion_listeners.append(self._on_run_completed)

    def start(self) -> None:
        with self._lock:
            if self._started:
                return
            self._started = True
        if not self.settings.enabled:
            # Turning skims off never strands a reader on "Skimming".
            for identifier in self._chats.pending():
                self._chats.finish(identifier, {"status": "failed"})
            if self._store is not None:
                for feature_id in self._store.abandon_pending_skims("disabled"):
                    self._changed(feature_id)
            return
        self._stop.clear()
        for index in range(self.settings.workers):
            thread = threading.Thread(target=self._work, name=f"herdr-skim-{index}", daemon=True)
            thread.start()
            self._threads.append(thread)
        sweeper = threading.Thread(target=self._sweep_loop, name="herdr-skim-sweep", daemon=True)
        sweeper.start()
        self._threads.append(sweeper)

    def stop(self) -> None:
        self._stop.set()
        self._sweep_now.set()
        for thread in self._threads:
            if thread.is_alive():
                thread.join(timeout=2)
        self._threads.clear()
        with self._lock:
            self._started = False

    # -- queueing ------------------------------------------------------------

    def _enqueue(self, job: tuple[str, str], priority: int) -> None:
        with self._lock:
            if job in self._queued or job in self._active:
                return
            self._queued.add(job)
        self._queue.put((priority, next(self._order), job))

    def _on_reply(self, feature_id: str, message_id: str) -> None:
        # Called only for replies whose pending skim committed with them.
        self._enqueue(("message", message_id), _NEW)

    def _on_run_completed(self, run: dict) -> None:
        """Called under the run manager's lock just before a HUD turn is saved."""
        if run.get("profile") != HUD_PROFILE or run.get("status") != "completed":
            return
        key = self.settings.key(run.get("response"))
        if key is None or self._runs is None:
            return
        run_dir = self._runs._run_dir(str(run["id"]))
        if _read_state(run_dir) is not None:
            return
        now = _now()
        _write_state(run_dir, {**key, "status": "pending", "attempts": 0, "created_at": now, "updated_at": now})
        self._enqueue(("run", str(run["id"])), _NEW)

    # -- workers -------------------------------------------------------------

    def _work(self) -> None:
        while not self._stop.is_set():
            try:
                _, _, job = self._queue.get(timeout=0.5)
            except queue.Empty:
                continue
            with self._lock:
                self._queued.discard(job)
                if job in self._active:
                    continue
                self._active.add(job)
            try:
                if job[0] == "message":
                    self._skim_message(job[1])
                elif job[0] == "chat":
                    self._skim_chat(job[1])
                else:
                    self._skim_run(job[1])
            except Exception as exc:  # A skim is optional; never take the worker down.
                _LOG.warning("Skim job for %s failed unexpectedly: %s", job[1], type(exc).__name__)
                self._settle_after_error(job)
            finally:
                with self._lock:
                    self._active.discard(job)

    def _settle_after_error(self, job: tuple[str, str]) -> None:
        """Never leave a reader on "Skimming" because a job broke midway."""
        try:
            if job[0] == "chat":
                self._chats.finish(job[1], {"status": "failed"})
            elif job[0] == "message" and self._store is not None:
                feature_id = self._store.finish_skim(job[1], "failed", error="internal")
                if feature_id:
                    self._changed(feature_id)
            elif job[0] == "run" and self._runs is not None:
                manager = self._runs
                with manager._lock:
                    run_dir = manager._run_dir(job[1])
                    state = _read_state(run_dir)
                    if state is not None and state.get("status") == "pending":
                        _write_state(run_dir, {**state, "status": "failed", "error": "internal", "updated_at": _now()})
        except Exception:
            pass

    def _changed(self, feature_id: str) -> None:
        if self._publish is not None:
            try:
                self._publish("first_mate.updated", {"feature_id": feature_id, "generatedAt": _now()})
            except Exception:
                pass

    def _skim_message(self, message_id: str) -> None:
        store = self._store
        if store is None:
            return
        source = store.skim_source(message_id)
        if source is None:
            store.finish_skim(message_id, "failed", error="ineligible")
            return
        key = store.begin_skim(message_id, max_attempts=MAX_ATTEMPTS)
        if key is None:
            return
        outcome = self._infer(source["question"], source["text"], key)
        if outcome is None:
            return  # Shutting down: the pending skim resumes once after restart.
        feature_id = store.finish_skim(message_id, **outcome)
        _LOG.info("Skim %s for message %s in %s ms", outcome["status"], message_id, outcome.get("duration_ms"))
        if feature_id:
            self._changed(feature_id)

    def _skim_run(self, run_id: str) -> None:
        manager = self._runs
        if manager is None:
            return
        with manager._lock:
            try:
                run = manager._read(run_id)
            except AgentRunError:
                return
            run_dir = manager._run_dir(run_id)
            state = _read_state(run_dir)
            if state is None or state.get("status") != "pending":
                return
            state["updated_at"] = _now()
            if int(state.get("attempts") or 0) >= MAX_ATTEMPTS:
                _write_state(run_dir, {**state, "status": "failed", "error": "interrupted"})
                return
            state["attempts"] = int(state.get("attempts") or 0) + 1
            _write_state(run_dir, state)
        if run.get("status") not in {"completed", "promoted"} or not isinstance(run.get("response"), str):
            outcome = {"status": "failed", "error": "ineligible"}
        else:
            outcome = self._infer(run.get("prompt"), run["response"], state)
        if outcome is None:
            return  # Shutting down: the pending skim resumes once after restart.
        with manager._lock:
            try:
                manager._read(run_id)
            except AgentRunError:
                return  # The chat was deleted meanwhile.
            current = _read_state(run_dir)
            if current is None or current.get("status") != "pending":
                return
            current.update(outcome, updated_at=_now())
            _write_state(run_dir, current)
        _LOG.info("Skim %s for HUD turn %s in %s ms", outcome["status"], run_id, outcome.get("duration_ms"))

    def _infer(self, question: Optional[str], reply: str, key: Mapping[str, Any]) -> Optional[dict]:
        """One tool-free Pi inference, normalized. Never raises for model problems.

        Returns None when the companion is stopping, so the skim stays pending.
        """
        prompt = skim.prompt_for(_question(question), reply, format=key["format"], version=key["prompt_version"])
        if len(prompt.user) > MAX_USER_MESSAGE_CHARS:
            return {"status": "failed", "error": "reply_too_long"}
        manager = self._agent_runs()
        started = time.monotonic()
        try:
            envelope = manager.start(
                prompt=prompt.user, label="Skim", cwd=tempfile.gettempdir(), topology={}, mode="ask",
                model=key["model"] or None, thinking_level=key["thinking"] or None,
                _assistant={"profile": SKIM_PROFILE, "skimSystem": prompt.system},
            )
        except AgentRunError as exc:
            return {"status": "failed", "error": f"start:{exc.code}"}
        run_id = envelope["run"]["id"]
        run = self._wait(manager, run_id)
        duration_ms = int((time.monotonic() - started) * 1000)
        if self._stop.is_set() and (run is None or run.get("status") != "completed"):
            return None
        try:
            manager.delete(run_id)  # The skim row keeps what matters; drop the copy.
        except AgentRunError:
            pass
        if run is None or run.get("status") != "completed":
            return {"status": "failed", "error": _failure(run), "duration_ms": duration_ms}
        output = run.get("response") or ""
        try:
            document, normalized, _ = skim.skim_from_output(reply=reply, output=output, format=key["format"])
        except skim.SkimRejected as exc:
            return {"status": "rejected", "output": output, "error": str(exc), "duration_ms": duration_ms}
        if not skim.has_content(normalized):
            return {"status": "rejected", "output": output, "error": "The skim had no sentence or next step.",
                    "duration_ms": duration_ms}
        return {"status": "ready", "output": output, "document": normalized,
                "segments": skim.segment_table(document), "warnings": normalized["warnings"],
                "duration_ms": duration_ms}

    def _wait(self, manager: Any, run_id: str) -> Optional[dict]:
        deadline = time.monotonic() + SKIM_TIMEOUT_SECONDS + 30
        with manager._lock:
            thread = manager._threads.get(run_id)
        if thread is not None:
            thread.join(timeout=max(0.0, deadline - time.monotonic()))
        while True:
            try:
                with manager._lock:
                    run = manager._read(run_id)
            except AgentRunError:
                return None
            if run.get("status") in TERMINAL_STATUSES:
                return run
            if time.monotonic() > deadline or self._stop.is_set():
                try:
                    manager.cancel(run_id)
                except AgentRunError:
                    pass
                return run
            time.sleep(0.1)

    # -- recovery and backfill ------------------------------------------------

    def _sweep_loop(self) -> None:
        # Let the companion finish starting before touching old work.
        if self._stop.wait(5):
            return
        self._recover()
        while not self._stop.is_set():
            try:
                self.sweep()
            except Exception as exc:
                _LOG.warning("Skim sweep failed: %s", type(exc).__name__)
            self._sweep_now.wait(SWEEP_SECONDS)
            self._sweep_now.clear()

    def _recover(self) -> None:
        """Resume pending skims a restart interrupted (each runs at most twice)."""
        for identifier in self._chats.pending():
            self._enqueue(("chat", identifier), _NEW)
        if self._store is not None:
            for message_id in self._store.pending_skims():
                self._enqueue(("message", message_id), _NEW)

    def sweep(self) -> None:
        """Queue recent replies that have no skim yet (bounded backfill)."""
        since = datetime.now(timezone.utc) - timedelta(hours=self.settings.backfill_hours)
        since_text = since.isoformat().replace("+00:00", "Z")
        store = self._store
        if store is not None and self.settings.backfill_hours:
            # Short replies never get a row, so page past them instead of
            # letting them fill the window on every sweep.
            queued = offset = 0
            while queued < 40 and offset < 2000:
                page = store.unskimmed_replies(since_text, limit=100, offset=offset,
                                               minimum_characters=self.settings.min_words * 2)
                for message_id in page:
                    if queued >= 40:
                        break
                    source = store.skim_source(message_id)
                    key = self.settings.key(source["text"]) if source else None
                    if key is not None and store.queue_skim(message_id, key):
                        self._enqueue(("message", message_id), _BACKFILL)
                        queued += 1
                        offset -= 1  # A queued reply leaves the unskimmed set.
                if len(page) < 100:
                    break
                offset += 100
        manager = self._runs
        if manager is None or not self.settings.hud_chats:
            return
        from .hud_chats import all_threads
        queued = 0
        with manager._lock:
            members = [run for runs in all_threads(manager).values() for run in runs]
        for run in sorted(members, key=lambda item: item.get("finishedAt") or "", reverse=True):
            run_id = str(run["id"])
            state = _read_state(manager._run_dir(run_id))
            if state is not None:
                if state.get("status") == "pending":
                    self._enqueue(("run", run_id), _NEW)
                continue
            if (queued >= 40 or not self.settings.backfill_hours or run.get("status") != "completed"
                    or (run.get("finishedAt") or "") < since_text):
                continue
            key = self.settings.key(run.get("response"))
            if key is None:
                continue
            with manager._lock:
                run_dir = manager._run_dir(run_id)
                if not run_dir.is_dir() or _read_state(run_dir) is not None:
                    continue
                now = _now()
                _write_state(run_dir, {**key, "status": "pending", "attempts": 0, "created_at": now, "updated_at": now})
            self._enqueue(("run", run_id), _BACKFILL)
            queued += 1


def _question(text: Optional[str]) -> Optional[str]:
    """The human's words only: attachment paths are local details, not the question."""
    if not isinstance(text, str):
        return None
    lines = [line for line in text.split("\n")
             if not (line.startswith("Attachment: `") and line.rstrip().endswith("`"))]
    return "\n".join(lines)


def _failure(run: Optional[Mapping[str, Any]]) -> str:
    if run is None:
        return "missing"
    status = run.get("status")
    if status == "cancelled":
        return "cancelled"
    error = str(run.get("error") or "")
    if "did not finish within" in error:
        return "timeout"
    if status == "failed":
        return ("model:" + error)[:200]
    return f"status:{status}"
