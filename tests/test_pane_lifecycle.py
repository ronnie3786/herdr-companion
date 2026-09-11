import copy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from herdr_harness.client import HerdrClientError
from herdr_harness.pane_lifecycle import PaneLifecycle
from herdr_harness.service import HerdrService
from tests.test_herdr_service import FakeClient, snapshot_with_status


def shell_process(pane_id, pid=100):
    return {"pane_id": pane_id, "shell_pid": pid, "foreground_process_group_id": pid,
            "foreground_processes": [{"pid": pid, "name": "zsh", "argv": ["/bin/zsh"]}]}


def pi_process(pane_id):
    return {"pane_id": pane_id, "shell_pid": 100, "foreground_process_group_id": 200,
            "foreground_processes": [{"pid": 200, "name": "node", "argv": ["/usr/bin/node", "/tools/pi-coding-agent/dist/cli.js"]}]}


class LifecycleClient(FakeClient):
    def __init__(self, cwd):
        snapshot = snapshot_with_status("idle")
        snapshot["panes"][0].update(cwd=cwd, agent="pi", label="Old chat")
        super().__init__([snapshot])
        self.snapshots = []
        self.processes = {"w1:p1": pi_process("w1:p1")}
        self.quit_mode = "shell"
        self.fail_method = None
        self.hook = None

    def snapshot(self):
        return copy.deepcopy(self.last)

    def request(self, method, params):
        self.requests.append((method, copy.deepcopy(params)))
        if self.hook:
            self.hook(method, params)
        if method == self.fail_method:
            raise HerdrClientError("native request failed", code="herdr_timeout")
        pane_id = params.get("pane_id")
        if method == "pane.process_info":
            return {"type": "pane_process_info", "process_info": copy.deepcopy(self.processes[pane_id])}
        if method == "pane.split":
            pane_id = "w1:p" + str(len(self.last["panes"]) + 1)
            pane = {"pane_id": pane_id, "terminal_id": "term_" + pane_id,
                    "workspace_id": "w1", "tab_id": "w1:t1", "cwd": params["cwd"], "agent_status": "unknown"}
            self.last["panes"].append(pane)
            self.processes[pane_id] = shell_process(pane_id, 101)
            return {"type": "pane", "pane": copy.deepcopy(pane)}
        if method == "pane.send_input":
            if self.quit_mode == "shell":
                self.processes[pane_id] = shell_process(pane_id)
                self.last["panes"][0]["agent"] = None
            elif self.quit_mode == "exit":
                self.last["panes"] = [p for p in self.last["panes"] if p["pane_id"] != pane_id]
        if method == "pane.close":
            panes = self.last["panes"]
            target = next(p for p in panes if p["pane_id"] == pane_id)
            assert any(p["pane_id"] != pane_id and p["tab_id"] == target["tab_id"] for p in panes), "Would destroy the last pane's tab"
            self.last["panes"] = [p for p in panes if p["pane_id"] != pane_id]
        if method == "tab.rename":
            self.last["tabs"][0]["label"] = params["label"]
        if method == "agent.start":
            pane = next(p for p in self.last["panes"] if p["pane_id"] == pane_id)
            pane["agent"] = "pi"
            self.processes[pane_id] = pi_process(pane_id)
        return {"type": "ok"}


class LifecycleSemantic:
    def __init__(self):
        self.connected = True
        self.session_id = "synthetic-session-1"

    def sync_snapshot(self, snapshot):
        pass

    def capability(self, pane_id):
        return {"connected": self.connected, "session_id": self.session_id}

    def session_label_checkpoint(self, pane_id):
        return None

    def enrich_snapshot(self, snapshot):
        return copy.deepcopy(snapshot)

    def enrich_workspaces(self, snapshot, workspaces):
        return workspaces


class PaneLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.client = LifecycleClient(self.temporary.name)
        self.semantic = LifecycleSemantic()
        self.service = HerdrService(client=self.client, pi_semantic=self.semantic, environ={})
        self.lifecycle = self.service.pane_lifecycle
        self.lifecycle.quit_timeout = 0
        self.addCleanup(self.lifecycle.close)

    def retire(self, request_id="request-1"):
        return self.lifecycle.retire("w1:p1", request_id=request_id, terminal_id="term_1", session_id="synthetic-session-1")

    def methods(self):
        return [method for method, _ in self.client.requests]

    def test_replacement_precedes_quit_and_close_and_retains_container_ids(self):
        result = self.retire()
        methods = self.methods()
        self.assertLess(methods.index("pane.split"), methods.index("pane.send_input"))
        self.assertLess(methods.index("pane.send_input"), methods.index("pane.close"))
        self.assertEqual((result["workspaceId"], result["tabId"], result["nextPaneId"]), ("w1", "w1:t1", "w1:p2"))
        self.assertTrue(result["reservedShell"])
        self.assertEqual(self.service.snapshot_response()["snapshot"]["panes"][0]["reserved_shell"], True)
        self.assertTrue(self.service.workspaces_response()["workspaces"][0]["panes"][0]["reserved_shell"])
        self.assertEqual(self.client.requests[1][1]["cwd"], str(Path(self.temporary.name).resolve()))

    def test_all_panes_in_target_tab_count_not_just_chats(self):
        self.client.request("pane.split", {"cwd": self.temporary.name})
        self.client.requests.clear()
        result = self.retire()
        self.assertNotIn("pane.split", self.methods())
        self.assertFalse(result["reservedShell"])

    def test_other_tab_does_not_protect_the_target_tab(self):
        self.client.request("pane.split", {"cwd": self.temporary.name})
        self.client.last["panes"][-1]["tab_id"] = "w1:t2"
        self.client.requests.clear()
        self.retire()
        self.assertIn("pane.split", self.methods())

    def test_split_failure_does_not_quit_or_close(self):
        self.client.fail_method = "pane.split"
        with self.assertRaises(HerdrClientError):
            self.retire()
        self.assertNotIn("pane.send_input", self.methods())
        self.assertNotIn("pane.close", self.methods())

    def test_unknown_split_response_is_not_guessed(self):
        original = self.client.request
        def request(method, params):
            value = original(method, params)
            return {"type": "ok"} if method == "pane.split" else value
        with patch.object(self.client, "request", side_effect=request):
            with self.assertRaisesRegex(HerdrClientError, "could not be identified"):
                self.retire()
        self.assertNotIn("pane.send_input", self.methods())
        self.assertNotIn("pane.close", self.methods())

    def test_quit_disconnect_without_process_exit_does_not_close(self):
        self.client.quit_mode = "keep"
        def hook(method, params):
            if method == "pane.send_input":
                self.semantic.connected = False
        self.client.hook = hook
        with self.assertRaisesRegex(HerdrClientError, "Pi did not exit"):
            self.retire()
        self.assertNotIn("pane.close", self.methods())
        self.assertEqual(len(self.client.last["panes"]), 2)

    def test_command_only_pi_exit_preserves_tab_without_extra_close(self):
        self.client.quit_mode = "exit"
        result = self.retire()
        self.assertTrue(result["reservedShell"])
        self.assertNotIn("pane.close", self.methods())

    def test_disconnected_former_pi_shell_gets_fresh_replacement(self):
        self.semantic.connected = False
        self.client.processes["w1:p1"] = shell_process("w1:p1")
        result = self.retire()
        self.assertTrue(result["reservedShell"])
        self.assertNotIn("pane.send_input", self.methods())

    def test_disconnected_live_pi_is_not_killed(self):
        self.semantic.connected = False
        with self.assertRaises(HerdrClientError):
            self.retire()
        self.assertNotIn("pane.split", self.methods())
        self.assertNotIn("pane.close", self.methods())

    def test_stale_terminal_and_session_are_rejected_before_split(self):
        self.semantic.session_id = "another-session"
        with self.assertRaises(HerdrClientError):
            self.retire()
        self.assertNotIn("pane.split", self.methods())
        self.semantic.session_id = "synthetic-session-1"
        self.client.last["panes"][0]["terminal_id"] = "different-terminal"
        with self.assertRaises(HerdrClientError):
            self.retire("request-2")
        self.assertNotIn("pane.split", self.methods())

    def test_unrelated_foreground_process_never_receives_quit(self):
        self.client.processes["w1:p1"]["foreground_processes"][0].update(name="vim", argv=["vim"])
        with self.assertRaises(HerdrClientError):
            self.retire()
        self.assertNotIn("pane.send_input", self.methods())

    def test_pi_exec_as_shell_pid_is_not_mistaken_for_shell(self):
        info = pi_process("w1:p1")
        info["shell_pid"] = 200
        self.assertFalse(PaneLifecycle._is_shell(info))

    def test_missing_process_evidence_fails_closed(self):
        self.client.fail_method = "pane.process_info"
        with self.assertRaises(HerdrClientError):
            self.retire()
        self.assertNotIn("pane.split", self.methods())

    def test_session_changed_after_quit_does_not_close(self):
        def hook(method, params):
            if method == "pane.send_input":
                self.semantic.session_id = "new-session"
        self.client.hook = hook
        with self.assertRaisesRegex(HerdrClientError, "session changed"):
            self.retire()
        self.assertNotIn("pane.close", self.methods())

    def test_moved_original_is_not_closed(self):
        def hook(method, params):
            if method == "pane.send_input":
                self.client.last["panes"][0]["tab_id"] = "w1:t2"
        self.client.hook = hook
        with self.assertRaisesRegex(HerdrClientError, "pane moved"):
            self.retire()
        self.assertNotIn("pane.close", self.methods())

    def test_lost_replacement_after_quit_does_not_close_last_pane(self):
        def hook(method, params):
            if method == "pane.send_input":
                self.client.last["panes"] = self.client.last["panes"][:1]
        self.client.hook = hook
        with self.assertRaisesRegex(HerdrClientError, "No surviving pane"):
            self.retire()
        self.assertNotIn("pane.close", self.methods())

    def test_successful_duplicate_does_not_repeat_native_mutations(self):
        first = self.retire()
        before = list(self.client.requests)
        self.assertEqual(self.retire(), first)
        self.assertEqual(self.client.requests, before)
        with self.assertRaises(HerdrClientError):
            self.lifecycle.retire("w1:p9", request_id="request-1", terminal_id="term_1", session_id=None)

    def test_failed_duplicate_does_not_repeat_uncertain_split(self):
        self.client.fail_method = "pane.split"
        with self.assertRaises(HerdrClientError):
            self.retire()
        before = list(self.client.requests)
        with self.assertRaises(HerdrClientError):
            self.retire()
        self.assertEqual(self.client.requests, before)

    def test_reservation_identity_and_idempotency_survive_companion_restart(self):
        path = str(Path(self.temporary.name) / "lifecycle.sqlite3")
        self.lifecycle = PaneLifecycle(self.service, path)
        self.service._pane_lifecycle = self.lifecycle
        result = self.retire()
        self.lifecycle.close()
        self.lifecycle = PaneLifecycle(self.service, path)
        self.service._pane_lifecycle = self.lifecycle
        self.addCleanup(self.lifecycle.close)
        self.assertEqual(self.retire(), result)
        self.assertTrue(self.lifecycle.reservation(self.client.last["panes"][0]))
        self.assertEqual(Path(path).stat().st_mode & 0o777, 0o600)

    def test_reservation_never_attaches_to_reused_pane_id(self):
        self.retire()
        self.client.last["panes"][0]["terminal_id"] = "other-terminal"
        self.service.refresh_snapshot(force=True)
        self.assertFalse(self.lifecycle.reservation(self.client.last["panes"][0]))

    def test_open_shell_consumes_reservation_without_new_pane(self):
        result = self.retire()
        pane = self.client.last["panes"][0]
        self.client.requests.clear()
        self.lifecycle.open_reserved_shell(result["nextPaneId"], terminal_id=pane["terminal_id"])
        self.assertFalse(self.lifecycle.reservation(pane))
        self.assertNotIn("pane.split", self.methods())

    def test_open_shell_reveals_external_work_without_interrupting_it(self):
        self.retire()
        pane = self.client.last["panes"][0]
        self.client.processes[pane["pane_id"]] = pi_process(pane["pane_id"])
        self.client.requests.clear()
        self.lifecycle.open_reserved_shell(pane["pane_id"], terminal_id=pane["terminal_id"])
        self.assertFalse(self.lifecycle.reservation(pane))
        self.assertEqual(self.client.requests, [])

    def test_new_pi_reuses_reserved_shell_and_double_launch_is_rejected(self):
        result = self.retire()
        pane = self.client.last["panes"][0]
        self.client.requests.clear()
        self.lifecycle.open_reserved_shell(result["nextPaneId"], terminal_id=pane["terminal_id"], action="pi")
        self.assertNotIn("pane.split", self.methods())
        self.assertEqual(self.methods().count("agent.start"), 1)
        with self.assertRaises(HerdrClientError):
            self.lifecycle.open_reserved_shell(result["nextPaneId"], terminal_id=pane["terminal_id"], action="pi")
        self.assertEqual(self.methods().count("agent.start"), 1)

    def test_reserved_shell_with_foreground_work_is_not_reused(self):
        self.retire()
        pane = self.client.last["panes"][0]
        self.client.processes[pane["pane_id"]] = pi_process(pane["pane_id"])
        with self.assertRaises(HerdrClientError):
            self.lifecycle.open_reserved_shell(pane["pane_id"], terminal_id=pane["terminal_id"], action="pi")
        self.assertNotIn("agent.start", self.methods())

    def test_direct_input_releases_reservation(self):
        result = self.retire()
        self.service.invoke("pane.send_text", {"pane_id": result["nextPaneId"], "text": "pwd"})
        self.assertFalse(self.lifecycle.reservation(self.client.last["panes"][0]))

    def test_only_proven_chat_derived_tab_title_is_reset(self):
        self.lifecycle.record_tab_rename("w1:t1", "w1:p1", "Old chat", "Project")
        self.client.last["tabs"][0]["label"] = "Old chat"
        self.retire()
        self.assertEqual(self.client.last["tabs"][0]["label"], "Project")

    def test_explicit_tab_title_is_preserved(self):
        self.lifecycle.record_tab_rename("w1:t1", "w1:p1", "Old chat", "Project")
        self.client.last["tabs"][0]["label"] = "My chosen name"
        self.retire()
        self.assertEqual(self.client.last["tabs"][0]["label"], "My chosen name")

    def test_quick_pi_reuses_reserved_slot_instead_of_splitting(self):
        self.retire()
        self.client.requests.clear()
        with patch.object(self.service, "pi_extension_args", return_value=[]):
            result = self.service.quick_pi_session("New chat", workspace_id="w1", tab_id="w1:t1", cwd=self.temporary.name)
        self.assertEqual(result["pane_id"], "w1:p2")
        self.assertNotIn("pane.split", self.methods())
        self.assertEqual(self.methods().count("agent.start"), 1)

    def test_failed_quick_pi_launch_never_rolls_back_reserved_anchor(self):
        self.retire()
        self.client.requests.clear()
        self.client.fail_method = "agent.start"
        with patch.object(self.service, "pi_extension_args", return_value=[]):
            with self.assertRaises(HerdrClientError):
                self.service.quick_pi_session("New chat", workspace_id="w1", tab_id="w1:t1", cwd=self.temporary.name)
        self.assertNotIn("pane.close", self.methods())
        self.assertNotIn("tab.close", self.methods())
        self.assertNotIn("workspace.close", self.methods())
        self.assertEqual(len(self.client.last["panes"]), 1)

    def test_competing_requests_cannot_split_or_close_the_same_chat_twice(self):
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.retire(), range(2)))
        self.assertEqual(results[0], results[1])
        self.assertEqual(self.methods().count("pane.split"), 1)
        self.assertEqual(self.methods().count("pane.close"), 1)

    def test_reservation_persistence_failure_leaves_original_chat_untouched(self):
        original = self.lifecycle._put
        def put(key, value):
            if key.startswith("reserved:"):
                raise OSError("synthetic disk full")
            original(key, value)
        with patch.object(self.lifecycle, "_put", side_effect=put):
            with self.assertRaises(OSError):
                self.retire()
        self.assertNotIn("pane.send_input", self.methods())
        self.assertNotIn("pane.close", self.methods())

    def test_close_timeout_after_success_is_reconciled_not_repeated(self):
        original = self.client.request
        def request(method, params):
            value = original(method, params)
            if method == "pane.close":
                raise HerdrClientError("timeout", code="herdr_timeout")
            return value
        with patch.object(self.client, "request", side_effect=request):
            self.assertTrue(self.retire()["ok"])
        self.assertEqual(self.methods().count("pane.close"), 1)
