import unittest
from unittest.mock import patch

from herdr_harness.agent_activity import AgentActivityManager, LIVE_PANE_LIMIT, LIVE_TOOL_LIMIT
from herdr_harness.service import HerdrService
from tests.test_agent_activity import FakeBroker, FakeRepo, envelope
from tests.test_herdr_service import FakeClient, FakePush, snapshot_with_status


class SessionActivityTests(unittest.TestCase):
    def setUp(self):
        self.repo = FakeRepo()
        self.repo.return_none = True
        self.updates = []
        self.manager = AgentActivityManager(self.repo, FakeBroker(), environ={}, model_url="",
                                            on_session_activity=self.updates.append)

    def event(self, event_type, pane="p1", **payload):
        self.manager.handle_event(envelope(pane, {"type": event_type, **payload}))

    def test_unregistered_pi_sessions_have_truthful_current_tool_activity(self):
        with patch.object(self.manager, "_model_phrase") as ai:
            self.event("tool_execution_start", toolName="bash", args={"command": "git push origin main"})
            self.assertEqual(self.manager.session_activity("p1", status="working"), "pushing")
            self.event("tool_execution_start", toolName="read", args={"path": "app.swift"})
            self.assertEqual(self.manager.session_activity("p1", status="working"), "reading files")
            self.event("tool_execution_end")
            self.assertEqual(self.manager.session_activity("p1", status="working"), "working")
            ai.assert_not_called()
        self.assertEqual(self.repo.calls, [])

    def test_parallel_tool_completion_returns_to_the_tool_still_running(self):
        self.event("tool_execution_start", toolName="read", toolCallId="read-1")
        self.event("tool_execution_start", toolName="test", toolCallId="test-1")
        self.event("tool_execution_end", toolCallId="test-1")
        self.assertEqual(self.manager.session_activity("p1", status="working"), "reading files")
        self.event("message_update", assistantMessageEvent={"type": "thinking_delta", "delta": "text"})
        self.assertEqual(self.manager.session_activity("p1", status="working"), "reading files")
        self.event("tool_execution_end", toolCallId="read-1")
        self.event("message_update", assistantMessageEvent={"type": "text_delta", "delta": "text"})
        self.assertEqual(self.manager.session_activity("p1", status="working"), "writing response")

    def test_stop_and_session_boundaries_clear_activity(self):
        for event_type in ["agent_settled", "agent_end", "session_start", "session_shutdown", "session_tree", "stream.reset"]:
            with self.subTest(event=event_type):
                self.event("tool_execution_start", toolName="edit", toolCallId="edit-1")
                self.event(event_type)
                self.assertIsNone(self.manager.session_activity("p1", status="working"))
                self.assertNotIn("p1", self.manager._live_tools)
        self.event("agent_start")
        self.event("bridge.connection", connected=False)
        self.assertIsNone(self.manager.session_activity("p1", status="working"))

    def test_native_blocked_done_idle_and_removed_panes_cannot_retain_working_text(self):
        for status in ["blocked", "done", "idle", "unknown"]:
            self.manager.sync_session_activity({"p1": "working"})
            self.event("tool_execution_start", toolName="test")
            self.assertIsNone(self.manager.session_activity("p1", status=status))
            self.manager.sync_session_activity({"p1": status})
            self.assertIsNone(self.manager.session_activity("p1", status="working"))
        self.manager.sync_session_activity({})
        self.assertNotIn("p1", self.manager._live_activity)

    def test_session_identity_change_clears_previous_tool_without_boundary_event(self):
        first = envelope("p1", {"type": "tool_execution_start", "toolName": "read", "toolCallId": "old"})
        first["session_id"] = "first-session"
        self.manager.handle_event(first)
        second = envelope("p1", {"type": "message_update", "assistantMessageEvent": {"type": "thinking_start"}})
        second["session_id"] = "second-session"
        self.manager.handle_event(second)
        self.assertEqual(self.manager.session_activity("p1", status="working"), "thinking")
        self.assertNotIn("p1", self.manager._live_tools)
        self.manager.sync_session_activity({})
        self.assertNotIn("p1", self.manager._live_session_ids)

    def test_current_tool_survives_unchanged_native_status_until_working_catches_up(self):
        self.manager.sync_session_activity({"p1": "idle"})
        self.event("agent_start")
        self.event("tool_execution_start", toolName="read", toolCallId="read-1")
        self.manager.sync_session_activity({"p1": "idle"})
        self.assertIsNone(self.manager.session_activity("p1", status="idle"))
        self.manager.sync_session_activity({"p1": "working"})
        self.assertEqual(self.manager.session_activity("p1", status="working"), "reading files")
        self.manager.sync_session_activity({"p1": "blocked"})
        self.assertIsNone(self.manager.session_activity("p1", status="working"))

    def test_first_native_snapshot_after_tool_start_does_not_erase_observed_work(self):
        for status in ["idle", "done"]:
            pane = f"first-{status}"
            with self.subTest(status=status):
                self.event("tool_execution_start", pane=pane, toolName="read", toolCallId="read-1")
                self.manager.sync_session_activity({pane: status})
                self.assertIsNone(self.manager.session_activity(pane, status=status))
                self.manager.sync_session_activity({pane: "working"})
                self.assertEqual(self.manager.session_activity(pane, status="working"), "reading files")
                self.manager.sync_session_activity({pane: "done"})
                self.assertIsNone(self.manager.session_activity(pane, status="working"))

    def test_xcodebuild_does_not_claim_to_run_tests_without_knowing_its_action(self):
        for command in ["xcodebuild -scheme App build", "xcodebuild -scheme App archive",
                        "xcodebuild -scheme Test -list", "xcodebuild -scheme App test"]:
            with self.subTest(command=command):
                self.event("tool_execution_start", toolName="bash", args={"command": command})
                self.assertEqual(self.manager.session_activity("p1", status="working"), "running command")
        self.event("tool_execution_start", toolName="xcodebuild")
        self.assertEqual(self.manager.session_activity("p1", status="working"), "running command")
        self.event("tool_execution_start", toolName="bash", args={"command": "pytest tests"})
        self.assertEqual(self.manager.session_activity("p1", status="working"), "running tests")

    def test_unknown_tool_ends_without_leaving_its_fallback_after_completion(self):
        self.event("tool_execution_start", toolName="custom_tool", toolCallId="custom-1")
        self.assertEqual(self.manager.session_activity("p1", status="working"), "using tools")
        self.event("tool_execution_end", toolCallId="custom-1")
        self.assertEqual(self.manager.session_activity("p1", status="working"), "working")
        self.event("bridge.connection", connected=False)
        self.event("tool_execution_end", toolCallId="unobserved-after-reconnect")
        self.assertIsNone(self.manager.session_activity("p1", status="working"))

    def test_compaction_end_cannot_keep_claiming_context_is_compacting(self):
        for event_type in ["session_compact", "session_compact_end"]:
            self.event("session_before_compact")
            self.assertEqual(self.manager.session_activity("p1", status="working"), "compacting context")
            self.event(event_type)
            self.assertIsNone(self.manager.session_activity("p1", status="working"))

    def test_token_stream_updates_are_coalesced_without_ai_or_one_event_per_token(self):
        with patch("herdr_harness.agent_activity.time.monotonic", return_value=100.0), patch.object(self.manager, "_model_phrase") as ai:
            self.event("agent_start")
            for _ in range(1000):
                self.event("message_update", assistantMessageEvent={"type": "thinking_delta", "delta": "content"})
            self.event("message_update", assistantMessageEvent={"type": "text_start"})
            self.assertEqual(self.updates, ["p1"])
            self.assertEqual(self.manager.session_activity("p1", status="working"), "writing response")
            ai.assert_not_called()
        with patch("herdr_harness.agent_activity.time.monotonic", return_value=101.0):
            self.manager._flush_live_activity()
        self.assertEqual(self.updates, ["p1", "p1"])

    def test_live_tracking_is_bounded(self):
        for index in range(LIVE_PANE_LIMIT + 20):
            self.event("tool_execution_start", pane=f"p{index}", toolName="read")
        self.assertLessEqual(len(self.manager._live_activity), LIVE_PANE_LIMIT)
        self.assertLessEqual(len(self.manager._live_tools), LIVE_PANE_LIMIT)
        self.assertLessEqual(len(self.manager._live_emitted_at), LIVE_PANE_LIMIT)
        for index in range(LIVE_TOOL_LIMIT + 20):
            self.event("tool_execution_start", pane="current", toolName="read", toolCallId=str(index))
        self.assertEqual(len(self.manager._live_tools["current"]), LIVE_TOOL_LIMIT)

    def test_callback_failure_does_not_interrupt_current_activity(self):
        def fail(_pane):
            raise RuntimeError("broker closed")
        self.manager._on_session_activity = fail
        self.event("tool_execution_start", toolName="read")
        self.assertEqual(self.manager.session_activity("p1", status="working"), "reading files")

    def test_service_projects_activity_separately_from_actual_chat_title(self):
        snapshot = snapshot_with_status("working")
        snapshot["panes"][0]["agent"] = "pi"
        snapshot["agents"][0]["agent"] = "pi"
        client = FakeClient([snapshot])
        service = HerdrService(client, environ={"HERDR_HARNESS_ACTIVITY_MODEL_URL": ""}, push=FakePush())
        self.addCleanup(service.stop)
        service.refresh_snapshot()
        service._dispatch_pi_event(envelope("w1:p1", {"type": "tool_execution_start", "toolName": "read"}))
        pane = service.workspaces_response()["workspaces"][0]["panes"][0]
        self.assertEqual(pane["title"], "Implement settings")
        self.assertEqual(pane["session_activity"], "reading files")
        self.assertEqual(service.snapshot_response()["snapshot"]["panes"][0]["session_activity"], "reading files")
        service._dispatch_pi_event(envelope("w1:p1", {"type": "agent_settled"}))
        self.assertIsNone(service.workspaces_response()["workspaces"][0]["panes"][0]["session_activity"])
