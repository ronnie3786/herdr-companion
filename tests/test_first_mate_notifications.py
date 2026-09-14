import tempfile
import unittest
from pathlib import Path

from herdr_harness.first_mate_notifications import FirstMateNotifications
from herdr_harness.first_mate_store import FirstMateStore


class FirstMateNotificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = FirstMateStore(Path(self.temp.name) / "work.sqlite3")
        self.feature = self.store.create_feature({"title": "Garden timer", "goal": "Plan a timer", "cwd": self.temp.name, "request_id": "garden"})
        self.store.append_event(self.feature["id"], "visit.awaiting_direction", "Planning complete. Awaiting your direction.", {"visit_id": "synthetic-plan"}, request_id="stage-checkpoint")
        self.calls = []
        self.env = {"HERDR_FIRST_MATE_MESSAGE_HUB_URL": "https://message.example.invalid/api/v1/messages", "HERDR_STATE_DIR": self.temp.name,
                    "HERDR_FIRST_MATE_APP_URL": "https://companion.example.invalid/first-mate/"}
        self.notifiers = []

    def tearDown(self):
        for notifier in self.notifiers:
            notifier.stop()
        self.store.close()
        self.temp.cleanup()

    def notifier(self, transport=None):
        def send(payload):
            self.calls.append(payload)
            return {"id": "synthetic-receipt", "notification": {"delivered": True}}
        notifier = FirstMateNotifications(self.store, self.env, transport=transport or send)
        self.notifiers.append(notifier)
        return notifier

    def test_one_stage_notification_survives_restart_without_duplicate(self):
        first = self.notifier()
        first.process()
        first.process()
        first.stop()
        second = self.notifier()
        second.process()
        self.assertEqual(len(self.calls), 1)
        self.assertIn("feature=" + self.feature["id"], self.calls[0]["link"])
        self.assertTrue(self.calls[0]["notify"])
        events = self.store.get_events(self.feature["id"])["events"]
        self.assertEqual(sum(e["type"] == "notification.delivered" for e in events), 1)

    def test_ambiguous_delivery_is_logged_and_never_blindly_retried(self):
        def uncertain(payload):
            self.calls.append(payload)
            raise TimeoutError("remote may have accepted")
        notifier = self.notifier(uncertain)
        notifier.process()
        notifier.process()
        self.assertEqual(len(self.calls), 1)
        self.assertTrue(any(e["type"] == "notification.unknown" for e in self.store.get_events(self.feature["id"])["events"]))

    def test_phone_failure_is_not_reported_as_delivered(self):
        notifier = self.notifier(lambda _: {"id": "saved-on-mac", "notification": {"delivered": False}})
        notifier.process()
        kinds = [e["type"] for e in self.store.get_events(self.feature["id"])["events"]]
        self.assertIn("notification.mac_only", kinds)
        self.assertNotIn("notification.delivered", kinds)

    def test_unconfigured_notifications_never_contact_a_private_default(self):
        notifier = FirstMateNotifications(self.store, {})
        self.notifiers.append(notifier)
        self.assertFalse(notifier.configured)
        notifier.process()

    def test_receipt_work_log_is_recovered_after_restart(self):
        notifier = self.notifier()
        original = self.store.append_event
        def unavailable(*args, **kwargs):
            raise RuntimeError("synthetic interruption before work-log commit")
        self.store.append_event = unavailable
        with self.assertRaises(RuntimeError):
            notifier.process()
        self.store.append_event = original
        notifier.stop()
        restarted = self.notifier()
        restarted.process()
        self.assertEqual(len(self.calls), 1)
        events = self.store.get_events(self.feature["id"])["events"]
        self.assertEqual(sum(e["type"] == "notification.delivered" for e in events), 1)


if __name__ == "__main__":
    unittest.main()
