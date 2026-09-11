"""Conservative chat retirement and explicitly reserved, reusable shell panes.

The native API has no atomic replace-last-pane operation. Companion mutations
share the service's placement lock; native clients can still change topology, so
we revalidate identities and survivors before every destructive step. Unknown
outcomes never trigger a blind retry or rollback that could close somebody's work.
"""
from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import TYPE_CHECKING, Optional

from .client import HerdrClientError
from .normalization import pane_index

if TYPE_CHECKING:
    from .service import HerdrService


class PaneLifecycle:
    def __init__(self, service: HerdrService, path: Optional[str] = None) -> None:
        self.service = service
        self.namespace = service.client.socket_path
        self._lock = threading.RLock()
        if path:
            target = Path(path).expanduser()
            target.parent.mkdir(parents=True, exist_ok=True)
            # Create with private permissions before SQLite writes any data.
            descriptor = os.open(target, os.O_CREAT | os.O_WRONLY, 0o600)
            os.close(descriptor)
            os.chmod(target, 0o600)
            path = str(target)
        self._db = sqlite3.connect(path or ":memory:", check_same_thread=False)
        self._db.execute("CREATE TABLE IF NOT EXISTS pane_lifecycle (namespace TEXT, key TEXT, value TEXT NOT NULL, PRIMARY KEY(namespace, key))")
        self._db.commit()
        self.quit_timeout = 5.0
        self.poll_interval = 0.1

    def close(self) -> None:
        with self._lock:
            self._db.close()

    def _get(self, key: str) -> Optional[dict]:
        with self._lock:
            row = self._db.execute("SELECT value FROM pane_lifecycle WHERE namespace = ? AND key = ?", (self.namespace, key)).fetchone()
        return json.loads(row[0]) if row else None

    def _put(self, key: str, value: Optional[dict]) -> None:
        with self._lock, self._db:
            if value is None:
                self._db.execute("DELETE FROM pane_lifecycle WHERE namespace = ? AND key = ?", (self.namespace, key))
            else:
                self._db.execute("INSERT OR REPLACE INTO pane_lifecycle VALUES (?, ?, ?)", (self.namespace, key, json.dumps(value)))

    @staticmethod
    def _identity(pane: dict) -> dict:
        return {key: pane.get(key) for key in ("pane_id", "terminal_id", "workspace_id", "tab_id")}

    @staticmethod
    def _error(message: str, code: str = "pane_retirement_conflict") -> HerdrClientError:
        return HerdrClientError(message, code=code)

    def reservation(self, pane: dict) -> bool:
        record = self._get("reserved:" + str(pane.get("pane_id")))
        return bool(record and record == self._identity(pane))

    def release(self, pane_id: str) -> None:
        self._put("reserved:" + pane_id, None)

    def observe(self, snapshot: dict) -> None:
        """Never infer reservations from an ordinary idle shell or a pane label."""
        panes = pane_index(snapshot)
        with self._lock:
            records = self._db.execute("SELECT key, value FROM pane_lifecycle WHERE namespace = ? AND key LIKE 'reserved:%'", (self.namespace,)).fetchall()
        for key, value in records:
            pane = panes.get(key.removeprefix("reserved:"))
            if pane is None or self._identity(pane) != json.loads(value) or pane.get("agent") or pane.get("display_agent"):
                self._put(key, None)

    def enrich(self, pane: dict) -> None:
        if self.reservation(pane):
            pane["reserved_shell"] = True
        else:
            pane.pop("reserved_shell", None)

    def record_tab_rename(self, tab_id: str, pane_id: str, label: Optional[str], previous_label: Optional[str]) -> None:
        previous = self._get("title:" + tab_id)
        original = previous["original"] if previous and previous.get("label") == previous_label else previous_label
        self._put("title:" + tab_id, {"pane_id": pane_id, "label": label, "original": original})

    def forget_tab_rename(self, tab_id: str) -> None:
        self._put("title:" + tab_id, None)

    def before_mutation(self, method: str, params: dict) -> None:
        if method in {"pane.send_text", "pane.send_keys", "pane.send_input", "pane.run", "agent.start", "agent.prompt", "pane.rename"}:
            if pane_id := params.get("pane_id"):
                self.release(str(pane_id))
        if method == "tab.rename" and params.get("tab_id"):
            self.forget_tab_rename(str(params["tab_id"]))

    def _process_info(self, pane_id: str) -> dict:
        raw = self.service._request_native("pane.process_info", {"pane_id": pane_id})
        info = raw.get("process_info") if isinstance(raw, dict) else None
        if (not isinstance(info, dict) or info.get("pane_id") != pane_id
                or not isinstance(info.get("foreground_processes", []), list)
                or not all(isinstance(item, dict) for item in info.get("foreground_processes", []))):
            raise self._error("Cannot verify this pane's processes; pane left open.", "pane_process_unavailable")
        info.setdefault("foreground_processes", [])
        return info

    @staticmethod
    def _is_shell(info: dict) -> bool:
        shell_pid = info.get("shell_pid")
        processes = info.get("foreground_processes")
        # A foreground group equal to the original process is not enough: Pi
        # can be exec'd as that process. Require an identifiable shell too.
        return (
            isinstance(shell_pid, int) and shell_pid > 0
            and isinstance(processes, list) and len(processes) == 1
            and processes[0].get("pid") == shell_pid
            and str(processes[0].get("name") or "").removeprefix("-").split("/")[-1]
            in {"sh", "bash", "zsh", "fish", "dash", "ksh", "nu", "pwsh", "powershell", "cmd.exe"}
        )

    @staticmethod
    def _is_pi(info: dict) -> bool:
        for process in info.get("foreground_processes", []):
            argv = process.get("argv") or []
            executable = str(process.get("argv0") or (argv[0] if argv else process.get("name")) or "")
            if executable.split("/")[-1] == "pi":
                return True
            if executable.split("/")[-1] in {"node", "bun"} and len(argv) > 1:
                script = str(argv[1])
                if script.split("/")[-1] == "pi" or "/pi-coding-agent/" in script:
                    return True
        return False

    def _checked_pane(self, snapshot: dict, identity: dict, *, missing_ok: bool = False) -> Optional[dict]:
        pane = pane_index(snapshot).get(identity["pane_id"])
        if pane is None and missing_ok:
            return None
        if pane is None or self._identity(pane) != identity:
            raise self._error("The pane moved or its terminal changed; nothing else will be closed.")
        return pane

    def _session(self, pane_id: str, expected: Optional[str]) -> dict:
        capability = self.service.pi_semantic.capability(pane_id)
        if capability.get("session_id") != expected:
            raise self._error("The Pi session changed; pane left open.")
        return capability

    def _survivors(self, snapshot: dict, identity: dict) -> list[dict]:
        tabs = snapshot.get("tabs", [])
        if not any(tab.get("tab_id") == identity["tab_id"] and tab.get("workspace_id") == identity["workspace_id"] for tab in tabs):
            raise self._error("The original tab is no longer available.")
        return [pane for pane in snapshot.get("panes", []) if pane.get("workspace_id") == identity["workspace_id"] and pane.get("tab_id") == identity["tab_id"] and pane.get("pane_id") != identity["pane_id"]]

    def retire(self, pane_id: str, *, request_id: str, terminal_id: str, session_id: Optional[str]) -> dict:
        signature = {"pane_id": pane_id, "terminal_id": terminal_id, "session_id": session_id}
        key = "retire:" + request_id
        with self.service._quick_session_lock:
            record = self._get(key)
            if record:
                if record.get("signature") != signature:
                    raise self._error("This request ID was already used for another chat.")
                if record.get("result"):
                    return record["result"]
                raise self._error(record.get("error") or "An earlier close has an unknown outcome. Refresh before trying again.", record.get("code") or "pane_retirement_outcome_unknown")
            # Journal intent before any native mutation. An interrupted process
            # leaves a pending entry that refuses to repeat an uncertain split.
            self._put(key, {"signature": signature})
            try:
                result = self._retire(pane_id, terminal_id, session_id)
            except HerdrClientError as exc:
                self._put(key, {"signature": signature, "error": str(exc), "code": exc.code})
                raise
            self._put(key, {"signature": signature, "result": result})
            return result

    def _retire(self, pane_id: str, terminal_id: str, session_id: Optional[str]) -> dict:
        snapshot = self.service.refresh_snapshot(force=True)
        pane = pane_index(snapshot).get(pane_id)
        if pane is None:
            raise self._error("Pane not found.", "pane_not_found")
        identity = self._identity(pane)
        if not terminal_id or identity["terminal_id"] != terminal_id or not identity["tab_id"]:
            raise self._error("The selected terminal changed; pane left open.")
        capability = self._session(pane_id, session_id)
        initial_process = self._process_info(pane_id)
        shell_ready = self._is_shell(initial_process)
        if not shell_ready and (not session_id or not capability.get("connected") or not self._is_pi(initial_process)):
            raise self._error("A live, identified Pi connection is required to quit this process safely; pane left open.")
        survivors = self._survivors(snapshot, identity)
        replacement_id = None
        if not survivors:
            cwd = self.service._canonical_directory(pane.get("foreground_cwd")) or self.service._canonical_directory(pane.get("cwd"))
            if cwd is None:
                raise self._error("The chat folder is unavailable; pane left open.", "invalid_cwd")
            raw = self.service._request_native("pane.split", {"target_pane_id": pane_id, "direction": "right", "cwd": str(cwd), "focus": False})
            # Only trust the actual split result, never an unrelated new pane
            # found by guessing from the next snapshot.
            replacement_id = raw.get("pane", {}).get("pane_id") if isinstance(raw, dict) and isinstance(raw.get("pane"), dict) else None
            if not replacement_id:
                raise self._error("The replacement shell could not be identified. The old chat was not ended; refresh to inspect the tab.", "pane_retirement_outcome_unknown")
            snapshot = self.service.refresh_snapshot(force=True)
            replacement = pane_index(snapshot).get(replacement_id)
            if replacement is None or replacement_id == pane_id or replacement.get("tab_id") != identity["tab_id"] or replacement.get("workspace_id") != identity["workspace_id"] or not replacement.get("terminal_id"):
                raise self._error("The replacement shell moved or could not be verified; old chat left open.")
            # Shell startup can take a moment. Never send /quit before the new
            # terminal is verified alive and ready in the intended directory.
            deadline = time.monotonic() + self.quit_timeout
            while not self._is_shell(self._process_info(replacement_id)):
                if time.monotonic() >= deadline:
                    raise self._error("The replacement shell did not become ready; old chat left open.", "replacement_not_ready")
                time.sleep(self.poll_interval)
            verified = self.service.refresh_snapshot(force=True)
            verified_replacement = self._checked_pane(verified, self._identity(replacement))
            assert verified_replacement is not None
            actual_cwd = self.service._canonical_directory(verified_replacement.get("foreground_cwd")) or self.service._canonical_directory(verified_replacement.get("cwd"))
            if actual_cwd != cwd:
                raise self._error("The replacement shell changed folders during startup; old chat left open.")
            self._put("reserved:" + replacement_id, self._identity(replacement))

        snapshot = self.service.refresh_snapshot(force=True)
        self._checked_pane(snapshot, identity)
        if not self._survivors(snapshot, identity):
            raise self._error("The tab no longer has a replacement; old chat left open.")
        capability = self._session(pane_id, session_id)
        process = self._process_info(pane_id)
        if not self._is_shell(process):
            if not capability.get("connected") or process != initial_process:
                raise self._error("The foreground process or Pi connection changed; pane left open.")
            self.service._request_native("pane.send_input", {"pane_id": pane_id, "text": "/quit", "keys": ["enter"]})
            deadline = time.monotonic() + self.quit_timeout
            while True:
                snapshot = self.service.refresh_snapshot(force=True)
                current = self._checked_pane(snapshot, identity, missing_ok=True)
                if current is None:
                    break  # Command-only panes can disappear on Pi exit.
                self._session(pane_id, session_id)
                if self._is_shell(self._process_info(pane_id)):
                    break
                if time.monotonic() >= deadline:
                    raise self._error("Pi did not exit; its pane was left open. A replacement shell, if created, is still available.", "pi_quit_timeout")
                time.sleep(self.poll_interval)

        snapshot = self.service.refresh_snapshot(force=True)
        survivors = self._survivors(snapshot, identity)
        if not survivors:
            raise self._error("No surviving pane could be verified; the tab will not be closed.")
        if self._checked_pane(snapshot, identity, missing_ok=True) is not None:
            self._session(pane_id, session_id)
            if not self._is_shell(self._process_info(pane_id)):
                raise self._error("Another process is using the pane; it was left open.")
            try:
                self.service._request_native("pane.close", {"pane_id": pane_id})
            except HerdrClientError:
                # A timeout may occur after the close was accepted. Never send
                # the close a second time, even if the pane ID still exists.
                after = self.service.refresh_snapshot(force=True)
                if pane_id in pane_index(after) or not self._survivors(after, identity):
                    raise self._error("The close outcome is uncertain. Refresh the tab before trying again.", "pane_retirement_outcome_unknown")
        snapshot = self.service.refresh_snapshot(force=True)
        if pane_id in pane_index(snapshot):
            raise self._error("The old pane is still present; refresh before trying again.", "pane_retirement_outcome_unknown")
        survivors = self._survivors(snapshot, identity)
        if not survivors:
            raise self._error("The tab changed during close; refresh to inspect the workspace.", "pane_retirement_outcome_unknown")
        warnings = []
        if len(survivors) == 1 and self.reservation(survivors[0]):
            title = self._get("title:" + identity["tab_id"])
            tab = next(tab for tab in snapshot["tabs"] if tab["tab_id"] == identity["tab_id"])
            if title and title.get("pane_id") == pane_id and title.get("label") == tab.get("label"):
                try:
                    self.service._request_native("tab.rename", {"tab_id": identity["tab_id"], "label": title["original"]})
                    self.forget_tab_rename(identity["tab_id"])
                except HerdrClientError:
                    warnings.append("Chat closed, but the tab name could not be restored.")
        selected = next((item for item in survivors if item.get("pane_id") == replacement_id), survivors[0])
        return {"ok": True, "closedPaneId": pane_id, "workspaceId": identity["workspace_id"], "tabId": identity["tab_id"], "nextPaneId": selected["pane_id"], "reservedShell": self.reservation(selected), "warnings": warnings}

    def take_reserved_for_pi(self, snapshot: dict, tab_id: str, cwd: Path) -> Optional[str]:
        """Reuse an empty tab's slot, never an arbitrary idle terminal."""
        panes = [pane for pane in snapshot.get("panes", []) if pane.get("tab_id") == tab_id]
        if len(panes) != 1 or not self.reservation(panes[0]):
            return None
        pane = panes[0]
        actual_cwd = self.service._canonical_directory(pane.get("foreground_cwd")) or self.service._canonical_directory(pane.get("cwd"))
        if actual_cwd != cwd:
            return None
        pane_id = pane["pane_id"]
        if not self._is_shell(self._process_info(pane_id)):
            raise self._error("The reserved shell is already running a process; refresh before starting Pi.")
        self.release(pane_id)
        return pane_id

    def open_reserved_shell(self, pane_id: str, *, terminal_id: str, action: str = "shell") -> dict:
        with self.service._quick_session_lock:
            snapshot = self.service.refresh_snapshot(force=True)
            pane = pane_index(snapshot).get(pane_id)
            if pane is None or pane.get("terminal_id") != terminal_id:
                raise self._error("The reserved terminal changed; refresh the workspace.")
            if not self.reservation(pane):
                raise self._error("This shell is no longer reserved; refresh the workspace.")
            if action == "pi" and not self._is_shell(self._process_info(pane_id)):
                self.release(pane_id)
                raise self._error("This terminal is already running a process. It has been revealed as a normal terminal; Pi was not started.")
            # Open shell only reveals the terminal; it never sends input or
            # interrupts a command that was started directly in native Herdr.
            # Consuming the reservation first makes repeated/uncertain requests
            # unable to launch Pi twice. Launch failure leaves a normal shell.
            self.release(pane_id)
            if action == "pi":
                self.service._request_native("agent.start", {
                    "pane_id": pane_id, "name": "pi-" + uuid.uuid4().hex[:8],
                    "kind": "pi", "args": self.service.pi_extension_args(), "timeout_ms": 30000,
                })
            self.service.refresh_snapshot(force=True)
            return {"ok": True}
