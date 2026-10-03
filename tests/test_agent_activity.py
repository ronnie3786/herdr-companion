import threading
import unittest
from unittest.mock import patch

from herdr_harness.agent_activity import AgentActivityManager
from herdr_harness.service import HerdrService


def envelope(pane_id, event):
    return {"pane_id": pane_id, "event": event}


class FakeBroker:
    def __init__(self):
        self.events = []

    def publish(self, name, payload):
        self.events.append((name, payload))


class FakeHerdrClient:
    socket_path = "/tmp/synthetic-activity.sock"


class AgentActivityWiringTests(unittest.TestCase):
    def test_dispatcher_preserves_pi_events_and_current_chat_activity(self):
        broker = FakeBroker()
        service = HerdrService(FakeHerdrClient(), environ={}, broker=broker)
        self.addCleanup(service.stop)
        event = envelope("w1:p1", {"type": "tool_execution_start", "toolName": "read"})
        service._dispatch_pi_event(event)
        self.assertEqual(service.agent_activity.session_activity("w1:p1", status="working"), "reading files")
        self.assertTrue(any(name == "snapshot.updated" and body["change"] == "session_activity"
                            for name, body in broker.events))
        settled = envelope("w1:p1", {"type": "agent_settled"})
        service._dispatch_pi_event(settled)
        self.assertIn(("pi.agent_settled", settled), broker.events)
        self.assertIsNone(service.agent_activity.session_activity("w1:p1", status="working"))

    def test_malformed_events_are_ignored(self):
        manager = AgentActivityManager()
        for value in (None, [], {}, {"pane_id": "p1"}, {"pane_id": 3, "event": {}}, {"pane_id": "p1", "event": []}):
            manager.handle_event(value)
        self.assertIsNone(manager.session_activity("p1", status="working"))

    def test_start_stop_and_restart_preserve_pending_activity_notifications(self):
        updates = []
        received = threading.Event()
        def on_update(pane):
            updates.append(pane)
            received.set()
        manager = AgentActivityManager(on_session_activity=on_update)
        self.addCleanup(manager.stop)
        manager.start()
        manager.start()
        manager.stop()
        manager.stop()
        self.assertIsNone(manager._thread)
        # Hold a coalesced change until the timer runs after restart.
        with patch("herdr_harness.agent_activity.time.monotonic", return_value=100):
            manager.handle_event(envelope("p1", {"type": "agent_start"}))
            manager.handle_event(envelope("p1", {"type": "tool_execution_start", "toolName": "read"}))
        self.assertEqual(updates, ["p1"])
        received.clear()
        # Keep both sides of the restart on the controlled clock. A fresh CI
        # host can have a real monotonic clock below the synthetic value 100.
        with patch("herdr_harness.agent_activity.time.monotonic", return_value=101):
            manager.start()
            self.assertTrue(received.wait(2))
        self.assertEqual(updates, ["p1", "p1"])
        manager.stop()
        self.assertIsNone(manager._thread)
