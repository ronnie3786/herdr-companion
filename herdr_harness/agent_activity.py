"""Current Pi pane activity and summary bubbles for the Active Work board.

Current pane activity uses bounded event metadata without model calls.
Board summaries keep a bounded per-pane ring of recent tool
calls, and turns them into a short comic-style bubble written to the session
row and published over SSE. ``tool_execution_start`` triggers a debounced
update; ``agent_settled`` always bypasses the debounce.
"""

from __future__ import annotations

import json
import logging
import os
import queue
import threading
import time
import urllib.request
from collections import OrderedDict, deque
from typing import Any, Callable, Mapping, Optional

from .active_work import utc_now

DEFAULT_MODEL_URL = ""
DEFAULT_MODEL_NAME = ""
MODEL_TIMEOUT_SECONDS = 4.0
DEFAULT_DEBOUNCE_SECONDS = 20.0
MIN_DEBOUNCE_SECONDS = 2.0
MAX_DEBOUNCE_SECONDS = 300.0
RING_LIMIT = 48
MAX_GIST_CHARS = 100
MAX_PROMPT_CHARS = 1600
MAX_MESSAGE_CHARS = 40
MAX_MESSAGE_WORDS = 3
PANE_MISS_LOG_INTERVAL_SECONDS = 300.0
LIVE_PANE_LIMIT = 512
LIVE_TOOL_LIMIT = 64
LIVE_PUBLISH_INTERVAL_SECONDS = 1.0

logger = logging.getLogger(__name__)

_TOOL_RING_TYPES = frozenset({"tool_call", "tool_execution_start"})
_SESSION_BOUNDARY_TYPES = frozenset({"session_start", "session_shutdown"})
_READ_TOOLS = frozenset({"read", "grep", "find"})
_WRITE_TOOLS = frozenset({"write", "edit"})
_TEST_TOOLS = frozenset({"test", "pytest", "xcodebuild"})
_BROWSE_TOOLS = frozenset({"web", "web_search", "websearch", "browse", "browser", "http", "fetch"})


class AgentActivityManager:
    """Turn Pi tool activity into short live bubbles on Active Work sessions."""

    def __init__(
        self,
        active_work: Any,
        broker: Any,
        environ: Optional[Mapping[str, str]] = None,
        *,
        model_url: Optional[str] = None,
        model_name: Optional[str] = None,
        timeout: float = MODEL_TIMEOUT_SECONDS,
        debounce: Optional[float] = None,
        on_session_activity: Optional[Callable[[str], None]] = None,
    ) -> None:
        self.environ = dict(os.environ if environ is None else environ)
        self.active_work = active_work
        self.broker = broker
        if model_url is None:
            model_url = self.environ.get("HERDR_HARNESS_ACTIVITY_MODEL_URL", DEFAULT_MODEL_URL)
        self.model_url = str(model_url).strip() if str(model_url).strip() else ""
        self.model_name = model_name or self.environ.get(
            "HERDR_HARNESS_ACTIVITY_MODEL_NAME", DEFAULT_MODEL_NAME
        )
        self.timeout = timeout
        if debounce is None:
            raw = self.environ.get("HERDR_HARNESS_ACTIVITY_DEBOUNCE_SECONDS", "")
            try:
                debounce = float(raw) if raw else DEFAULT_DEBOUNCE_SECONDS
            except ValueError:
                debounce = DEFAULT_DEBOUNCE_SECONDS
            debounce = min(max(debounce, MIN_DEBOUNCE_SECONDS), MAX_DEBOUNCE_SECONDS)
        self.debounce_seconds = debounce
        self._lock = threading.Lock()
        self._rings: dict[str, deque] = {}
        self._last_written: dict[str, str] = {}
        self._last_write_at: dict[str, float] = {}
        self._statuses: dict[str, str] = {}
        self._pane_miss_logged_at: dict[str, float] = {}
        self._queue: "queue.Queue[tuple[str, str]]" = queue.Queue()
        self._stop_event = threading.Event()
        self._started = False
        self._thread: Optional[threading.Thread] = None
        self._on_session_activity = on_session_activity
        self._live_activity: OrderedDict[str, Optional[str]] = OrderedDict()
        self._live_tools: dict[str, OrderedDict[str, str]] = {}
        self._live_session_ids: dict[str, str] = {}
        self._native_statuses: OrderedDict[str, str] = OrderedDict()
        self._live_dirty: set[str] = set()
        self._live_emitted_at: dict[str, float] = {}

    def start(self) -> None:
        with self._lock:
            if self._started:
                return
            self._started = True
            self._stop_event = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            name="herdr-agent-activity",
            daemon=True,
        )
        self._thread.start()

    def stop(self) -> None:
        with self._lock:
            if not self._started:
                return
            self._started = False
        self._stop_event.set()
        thread = self._thread
        if thread is not None and thread.is_alive():
            thread.join(timeout=2.0)
        self._thread = None

    def handle_event(self, envelope: Any) -> None:
        try:
            self._handle_event(envelope)
        except Exception:
            pass

    def _handle_event(self, envelope: Any) -> None:
        if not isinstance(envelope, dict):
            return
        pane_id = envelope.get("pane_id")
        event = envelope.get("event")
        if not isinstance(pane_id, str) or not pane_id or not isinstance(event, dict):
            return
        event_type = event.get("type")
        self._observe_live_activity(pane_id, event, session_id=envelope.get("session_id"))
        if event_type in _SESSION_BOUNDARY_TYPES:
            with self._lock:
                self._rings.pop(pane_id, None)
                self._last_written.pop(pane_id, None)
                self._last_write_at.pop(pane_id, None)
                self._statuses.pop(pane_id, None)
            return
        if event_type in _TOOL_RING_TYPES:
            entry = self._tool_entry(event_type, event)
            if entry is not None:
                with self._lock:
                    ring = self._rings.get(pane_id)
                    if ring is None:
                        ring = self._rings[pane_id] = deque(maxlen=RING_LIMIT)
                    ring.append(entry)
                if event_type == "tool_execution_start":
                    self._enqueue(pane_id, "tool_execution_start")
            return
        if event_type == "agent_settled":
            self._enqueue(pane_id, "agent_settled")

    @staticmethod
    def _tool_entry(event_type: Any, event: dict) -> Optional[tuple[str, str]]:
        if event_type == "tool_execution_start":
            name = event.get("toolName")
            args = event.get("args")
        else:
            call = event.get("toolCall")
            if isinstance(call, dict):
                name = call.get("name") or call.get("toolName")
                args = call.get("arguments") or call.get("args")
            else:
                name = event.get("name")
                args = event.get("args")
        name = str(name or "").strip()
        if not name:
            return None
        gist = ""
        if name == "bash" and isinstance(args, dict):
            command = args.get("command")
            if isinstance(command, str):
                gist = " ".join(command.split())[:MAX_GIST_CHARS]
        elif name == "subagent" and isinstance(args, dict):
            agent_name = args.get("agent") or args.get("name") or args.get("agentName")
            if isinstance(agent_name, str) and agent_name:
                gist = " ".join(agent_name.split())[:MAX_GIST_CHARS]
        return (name, gist)

    def _enqueue(self, pane_id: str, trigger: str) -> None:
        with self._lock:
            if not self._started:
                return
        self._queue.put((pane_id, trigger))

    def _run(self) -> None:
        while not self._stop_event.is_set():
            self._flush_live_activity()
            try:
                pane_id, trigger = self._queue.get(timeout=0.25)
            except queue.Empty:
                continue
            try:
                self._summarize(pane_id, trigger)
            except Exception:
                pass

    def session_activity(self, pane_id: str, *, status: str) -> Optional[str]:
        """Return current work, never a topic title or a completed tool's gist."""
        if status != "working":
            return None
        with self._lock:
            return self._live_activity.get(pane_id)

    def sync_session_activity(self, statuses: Mapping[str, str]) -> None:
        """Native stop/blocked states and removed panes invalidate live activity."""
        with self._lock:
            removed = [pane_id for pane_id in self._live_activity if pane_id not in statuses]
            for pane_id in removed:
                self._live_activity.pop(pane_id, None)
                self._live_tools.pop(pane_id, None)
                self._live_session_ids.pop(pane_id, None)
                self._live_dirty.discard(pane_id)
                self._live_emitted_at.pop(pane_id, None)
            for pane_id, status in statuses.items():
                # A semantic tool start can beat the native working update.
                # Preserve it across unchanged idle/done snapshots, while the
                # public projection remains hidden until native says working.
                if (status != "working" and pane_id in self._native_statuses
                        and status != self._native_statuses[pane_id]
                        and pane_id in self._live_activity):
                    self._set_live_activity_locked(pane_id, None)
                    self._live_tools.pop(pane_id, None)
            self._native_statuses = OrderedDict(list(statuses.items())[-LIVE_PANE_LIMIT:])
        self._flush_live_activity()

    def _observe_live_activity(self, pane_id: str, event: dict, *, session_id: Any = None) -> None:
        event_type = event.get("type")
        with self._lock:
            if isinstance(session_id, str) and session_id:
                if self._live_session_ids.get(pane_id) != session_id:
                    self._set_live_activity_locked(pane_id, None)
                    self._live_tools.pop(pane_id, None)
                    self._live_session_ids[pane_id] = session_id
            if event_type in _SESSION_BOUNDARY_TYPES or event_type in {
                "agent_settled", "agent_end", "session_tree", "stream.reset",
            } or (event_type == "bridge.connection" and event.get("connected") is False):
                if pane_id in self._live_activity:
                    self._set_live_activity_locked(pane_id, None)
                self._live_tools.pop(pane_id, None)
            elif event_type == "agent_start":
                self._live_tools.pop(pane_id, None)
                self._set_live_activity_locked(pane_id, "working")
            elif event_type == "session_before_compact":
                self._set_live_activity_locked(pane_id, "compacting context")
            elif event_type in {"session_compact", "session_compact_end"}:
                if self._live_activity.get(pane_id) == "compacting context":
                    self._set_live_activity_locked(pane_id, None)
            elif event_type == "tool_execution_start":
                entry = self._tool_entry(event_type, event)
                if entry is not None:
                    phrase = self._live_tool_phrase(*entry)
                    tools = self._live_tools.setdefault(pane_id, OrderedDict())
                    call_id = str(event.get("toolCallId") or "current")
                    tools[call_id] = phrase
                    tools.move_to_end(call_id)
                    while len(tools) > LIVE_TOOL_LIMIT:
                        tools.popitem(last=False)
                    self._set_live_activity_locked(pane_id, phrase)
            elif event_type == "tool_execution_end":
                tools = self._live_tools.get(pane_id)
                if tools is not None:
                    tools.pop(str(event.get("toolCallId") or "current"), None)
                    phrase = next(reversed(tools.values())) if tools else "working"
                    self._set_live_activity_locked(pane_id, phrase)
            elif event_type == "message_update":
                update = event.get("assistantMessageEvent")
                update_type = update.get("type") if isinstance(update, dict) else None
                if not self._live_tools.get(pane_id):
                    if update_type in {"thinking_start", "thinking_delta"}:
                        self._set_live_activity_locked(pane_id, "thinking")
                    elif update_type in {"text_start", "text_delta"}:
                        self._set_live_activity_locked(pane_id, "writing response")
        self._flush_live_activity()

    def _set_live_activity_locked(self, pane_id: str, phrase: Optional[str]) -> None:
        previous = self._live_activity.get(pane_id)
        self._live_activity[pane_id] = phrase
        self._live_activity.move_to_end(pane_id)
        if previous != phrase:
            self._live_dirty.add(pane_id)
        while len(self._live_activity) > LIVE_PANE_LIMIT:
            expired, _ = self._live_activity.popitem(last=False)
            self._live_tools.pop(expired, None)
            self._live_session_ids.pop(expired, None)
            self._live_dirty.discard(expired)
            self._live_emitted_at.pop(expired, None)

    def _flush_live_activity(self) -> None:
        if self._on_session_activity is None:
            return
        now = time.monotonic()
        with self._lock:
            due = [pane_id for pane_id in self._live_dirty
                   if now - self._live_emitted_at.get(pane_id, float("-inf")) >= LIVE_PUBLISH_INTERVAL_SECONDS]
            for pane_id in due:
                self._live_dirty.discard(pane_id)
                self._live_emitted_at[pane_id] = now
        for pane_id in due:
            try:
                self._on_session_activity(pane_id)
            except Exception:
                pass

    @staticmethod
    def _live_tool_phrase(name: str, gist: str) -> str:
        name, gist = name.lower(), gist.lower()
        if name == "subagent":
            return "delegating"
        if name in _READ_TOOLS:
            return "reading files"
        if name in _WRITE_TOOLS:
            return "editing code"
        if name in _BROWSE_TOOLS:
            return "browsing"
        # Xcodebuild also builds, archives, cleans, and lists project metadata.
        # The bounded command gist can omit its action, so do not infer tests.
        if name == "xcodebuild" or (name == "bash" and "xcodebuild" in gist):
            return "running command"
        if name in _TEST_TOOLS:
            return "running tests"
        if name == "bash":
            if any(value in gist for value in ("pytest", "npm test", "swift test")):
                return "running tests"
            if "git commit" in gist:
                return "committing"
            if "git push" in gist:
                return "pushing"
            if "gh pr" in gist or "gh review" in gist:
                return "reviewing"
            return "running command"
        return "using tools"

    def _summarize(self, pane_id: str, trigger: str) -> None:
        with self._lock:
            if trigger != "agent_settled":
                last_at = self._last_write_at.get(pane_id)
                if last_at is not None and time.monotonic() - last_at < self.debounce_seconds:
                    return
        phrase = self._canned_phrase(pane_id)
        if phrase is None and self.model_url and self.model_name:
            phrase = self._model_phrase(pane_id)
        if phrase is None:
            with self._lock:
                phrase = None if pane_id in self._last_written else "working"
        if phrase is None:
            return
        with self._lock:
            if phrase == self._last_written.get(pane_id):
                return
            status = "running" if self._statuses.get(pane_id) in (None, "unknown", "queued") else None
        now = utc_now()
        item = self.active_work.update_session_activity(
            pane_id,
            activity_message=phrase,
            activity_message_at=now,
            status=status,
            last_seen_at=now,
        )
        if item is None:
            with self._lock:
                self._last_written.pop(pane_id, None)
                self._last_write_at.pop(pane_id, None)
                self._statuses.pop(pane_id, None)
                self._log_pane_miss_locked(pane_id)
            return
        with self._lock:
            self._last_written[pane_id] = phrase
            self._last_write_at[pane_id] = time.monotonic()
            self._remember_status_locked(pane_id, item)
        self.broker.publish(
            "active_work.updated",
            {
                "work_item_id": item.get("id"),
                "revision": item.get("revision"),
                "change": "activity",
                "generated_at": utc_now(),
            },
        )

    def _log_pane_miss_locked(self, pane_id: str) -> None:
        """Log one structured line per pane per interval when activity finds no session."""
        now = time.monotonic()
        last_logged_at = self._pane_miss_logged_at.get(pane_id)
        if (
            last_logged_at is not None
            and now - last_logged_at < PANE_MISS_LOG_INTERVAL_SECONDS
        ):
            return
        self._pane_miss_logged_at[pane_id] = now
        logger.warning("activity pane miss pane_id=%s", pane_id)

    def _remember_status_locked(self, pane_id: str, item: dict) -> None:
        sessions = item.get("pi_sessions")
        if not isinstance(sessions, list):
            return
        for session in sessions:
            if isinstance(session, dict) and session.get("pane_id") == pane_id:
                status = session.get("status")
                if isinstance(status, str) and status:
                    self._statuses[pane_id] = status
                return

    def _canned_phrase(self, pane_id: str) -> Optional[str]:
        with self._lock:
            entries = list(self._rings.get(pane_id) or ())
        if not entries:
            return None
        reads = writes = 0
        for name, gist in reversed(entries):
            lowered = gist.lower()
            if name == "subagent":
                return "delegating"
            if name == "bash" and "git commit" in lowered:
                return "committing"
            if name == "bash" and "git push" in lowered:
                return "pushing"
            if name == "bash" and ("gh pr" in lowered or "gh review" in lowered):
                return "reviewing"
            if name in _TEST_TOOLS or (
                name == "bash" and ("pytest" in lowered or "xcodebuild" in lowered)
            ):
                return "running tests"
            if name in _BROWSE_TOOLS:
                return "browsing"
            if name in _READ_TOOLS:
                reads += 1
            elif name in _WRITE_TOOLS:
                writes += 1
        total = len(entries)
        if reads / total >= 0.6:
            return "scanning code"
        if writes / total > 0.5:
            return "editing code"
        return None

    def _model_phrase(self, pane_id: str) -> Optional[str]:
        with self._lock:
            entries = list(self._rings.get(pane_id) or ())
        if not entries:
            return None
        lines = [f"- {name}: {gist}" if gist else f"- {name}" for name, gist in entries]
        tool_text = "\n".join(lines)[:MAX_PROMPT_CHARS]
        prompt = (
            "Recent tool activity of a coding agent (newest last):\n"
            f"{tool_text}\n"
            "Describe in 1 to 3 comic-style words what the agent is doing right now. "
            "Reply with only those words."
        )
        body = {
            "model": self.model_name,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 24,
            "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": False},
        }
        request = urllib.request.Request(
            f"{self.model_url}/chat/completions",
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except Exception:
            return None
        choices = payload.get("choices") if isinstance(payload, dict) else None
        if not isinstance(choices, list) or not choices:
            return None
        first = choices[0] if isinstance(choices[0], dict) else None
        message = first.get("message") if isinstance(first, dict) else None
        content = message.get("content") if isinstance(message, dict) else None
        return self._sanitize(content)

    @staticmethod
    def _sanitize(raw: Any) -> Optional[str]:
        if not isinstance(raw, str):
            return None
        text = " ".join(raw.split())
        if not text or len(text) > MAX_MESSAGE_CHARS:
            return None
        if len(text.split()) > MAX_MESSAGE_WORDS:
            return None
        return text
