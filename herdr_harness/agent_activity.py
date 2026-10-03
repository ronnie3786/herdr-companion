"""Bounded current Pi activity for Chat and session summaries.

Activity labels come only from current structured events, without model calls.
"""

from __future__ import annotations

import threading
import time
from collections import OrderedDict
from typing import Any, Callable, Mapping, Optional

MAX_GIST_CHARS = 100
LIVE_PANE_LIMIT = 512
LIVE_TOOL_LIMIT = 64
LIVE_PUBLISH_INTERVAL_SECONDS = 1.0

_SESSION_BOUNDARY_TYPES = frozenset({"session_start", "session_shutdown"})
_READ_TOOLS = frozenset({"read", "grep", "find"})
_WRITE_TOOLS = frozenset({"write", "edit"})
_TEST_TOOLS = frozenset({"test", "pytest", "xcodebuild"})
_BROWSE_TOOLS = frozenset({"web", "web_search", "websearch", "browse", "browser", "http", "fetch"})


class AgentActivityManager:
    """Track current tool activity and coalesce session snapshot updates."""

    def __init__(self, *, on_session_activity: Optional[Callable[[str], None]] = None) -> None:
        self._lock = threading.Lock()
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
        self._observe_live_activity(pane_id, event, session_id=envelope.get("session_id"))

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

    def _run(self) -> None:
        while not self._stop_event.is_set():
            self._flush_live_activity()
            self._stop_event.wait(0.25)

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
