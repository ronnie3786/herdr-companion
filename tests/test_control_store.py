import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from herdr_harness.control_store import ControlStore
from herdr_harness.control_validation import ControlError, target, validate_json


CLIENT_ID = "ui_11111111-1111-4111-8111-111111111111"
INSTANCE_ONE = "22222222-2222-4222-8222-222222222222"
INSTANCE_TWO = "33333333-3333-4333-8333-333333333333"
CLIENT_TWO = "ui_44444444-4444-4444-8444-444444444444"
INSTANCE_THREE = "55555555-5555-4555-8555-555555555555"
TOKEN = "a" * 64
STATE = {"revision": 1, "window": "main", "segment": "chat", "enabled": True}
ACTIONS = [
    {
        "id": "ui.open",
        "title": "Open",
        "parameters": {
            "type": "object",
            "properties": {"view": {"type": "string", "enum": ["chat"]}},
            "required": ["view"],
            "additionalProperties": False,
        },
        "targetKinds": ["pane"],
        "effect": "navigation",
        "enabled": True,
    }
]
TARGET = {
    "kind": "pane",
    "workspaceId": "w1",
    "tabId": "t1",
    "paneId": "p1",
    "terminalId": "term1",
    "sessionId": "session1",
}


class MutableClock:
    def __init__(self, value=1_800_000_000.0):
        self.value = value

    def __call__(self):
        return self.value


class ControlStoreTests(unittest.TestCase):
    def register(self, store, instance_id=INSTANCE_ONE):
        return store.register(
            client_id=CLIENT_ID,
            name="Synthetic Companion",
            receiver_token=TOKEN,
            instance_id=instance_id,
            state=STATE,
            actions=ACTIONS,
        )

    def enqueue(self, store, request_id="request-1", ttl=30):
        body = {
            "requestId": request_id,
            "action": "ui.open",
            "target": TARGET,
            "parameters": {"view": "chat"},
            "ttlSeconds": ttl,
        }
        return store.enqueue(
            client_id=CLIENT_ID,
            request_id=request_id,
            action="ui.open",
            target=TARGET,
            parameters={"view": "chat"},
            expected_revision=None,
            ttl_seconds=ttl,
            payload=body,
        )

    def test_receiver_secret_is_hashed_and_server_id_survives_reopen(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory) / "private-control"
            path = parent / "control.sqlite3"
            clock = MutableClock()
            first = ControlStore(path, clock=clock)
            server_id = first.server_id
            public = self.register(first)
            self.assertNotIn("receiverToken", public)
            self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            for sidecar in (Path(f"{path}-wal"), Path(f"{path}-shm")):
                if sidecar.exists():
                    self.assertEqual(stat.S_IMODE(sidecar.stat().st_mode), 0o600)
            first.close()
            self.assertNotIn(TOKEN.encode(), path.read_bytes())
            second = ControlStore(path, clock=clock)
            self.addCleanup(second.close)
            self.assertEqual(second.server_id, server_id)

    def test_symlink_database_destination_is_rejected(self):
        if not hasattr(os, "symlink"):
            self.skipTest("symlinks unavailable")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            real = root / "real.sqlite3"
            real.touch()
            destination = root / "control.sqlite3"
            destination.symlink_to(real)
            with self.assertRaises(ControlError) as raised:
                ControlStore(destination)
            self.assertEqual(raised.exception.code, "control_store_unsafe")

    def test_poll_claims_one_never_redispatches_and_expires_accepted(self):
        clock = MutableClock()
        store = ControlStore(":memory:", clock=clock)
        self.addCleanup(store.close)
        self.register(store)
        self.enqueue(store, "first")
        self.enqueue(store, "second", ttl=2)
        claimed = store.poll(
            client_id=CLIENT_ID,
            receiver_token=TOKEN,
            instance_id=INSTANCE_ONE,
            state=STATE,
            actions=None,
        )
        self.assertEqual(claimed["requestId"], "first")
        self.assertEqual(claimed["status"], "running")
        self.assertIsNone(
            store.poll(
                client_id=CLIENT_ID,
                receiver_token=TOKEN,
                instance_id=INSTANCE_ONE,
                state=STATE,
                actions=None,
            )
        )
        clock.value += 3
        self.assertEqual(store.command("second")["status"], "expired")

    def test_new_instance_invalidates_queued_and_running_receipts(self):
        clock = MutableClock()
        store = ControlStore(":memory:", clock=clock)
        self.addCleanup(store.close)
        self.register(store)
        self.enqueue(store, "running")
        store.poll(
            client_id=CLIENT_ID,
            receiver_token=TOKEN,
            instance_id=INSTANCE_ONE,
            state=STATE,
            actions=None,
        )
        self.enqueue(store, "queued")
        self.register(store, INSTANCE_TWO)
        self.assertEqual(store.command("running")["status"], "outcome_unknown")
        self.assertEqual(store.command("queued")["status"], "expired")

    def test_same_command_dedupes_before_offline_check_and_conflicting_body_fails(self):
        clock = MutableClock()
        store = ControlStore(":memory:", clock=clock)
        self.addCleanup(store.close)
        self.register(store)
        original = self.enqueue(store)
        clock.value += 16
        self.assertEqual(self.enqueue(store), original)
        with self.assertRaises(ControlError) as raised:
            store.enqueue(
                client_id=CLIENT_ID,
                request_id="request-1",
                action="ui.open",
                target=TARGET,
                parameters={"view": "terminal"},
                expected_revision=None,
                ttl_seconds=30,
                payload={
                    "requestId": "request-1",
                    "action": "ui.open",
                    "target": TARGET,
                    "parameters": {"view": "terminal"},
                },
            )
        self.assertEqual(raised.exception.code, "request_conflict")

    def test_request_id_is_bound_to_client_and_pending_queue_is_bounded(self):
        clock = MutableClock()
        store = ControlStore(":memory:", clock=clock)
        self.addCleanup(store.close)
        self.register(store)
        store.register(
            client_id=CLIENT_TWO,
            name="Second Synthetic Companion",
            receiver_token=TOKEN,
            instance_id=INSTANCE_THREE,
            state=STATE,
            actions=ACTIONS,
        )
        self.enqueue(store, "client-bound")
        body = {
            "requestId": "client-bound",
            "action": "ui.open",
            "target": TARGET,
            "parameters": {"view": "chat"},
            "ttlSeconds": 30,
        }
        with self.assertRaises(ControlError) as conflict:
            store.enqueue(
                client_id=CLIENT_TWO,
                request_id="client-bound",
                action="ui.open",
                target=TARGET,
                parameters={"view": "chat"},
                expected_revision=None,
                ttl_seconds=30,
                payload=body,
            )
        self.assertEqual(conflict.exception.code, "request_conflict")
        with patch("herdr_harness.control_store.MAX_PENDING_PER_CLIENT", 1):
            with self.assertRaises(ControlError) as full:
                self.enqueue(store, "queue-full")
        self.assertEqual(full.exception.code, "command_queue_full")

    def test_ack_retry_ignores_changed_ephemeral_state_but_not_changed_outcome(self):
        clock = MutableClock()
        store = ControlStore(":memory:", clock=clock)
        self.addCleanup(store.close)
        self.register(store)
        self.enqueue(store, "ack-retry")
        store.poll(
            client_id=CLIENT_ID,
            receiver_token=TOKEN,
            instance_id=INSTANCE_ONE,
            state=STATE,
            actions=None,
        )
        result = {"presentation": "main"}
        first = store.acknowledge(
            client_id=CLIENT_ID,
            request_id="ack-retry",
            receiver_token=TOKEN,
            instance_id=INSTANCE_ONE,
            status="completed",
            result=result,
            error=None,
            state={**STATE, "revision": 2},
            acknowledgement={"status": "completed", "result": result, "state": {**STATE, "revision": 2}},
        )
        retried = store.acknowledge(
            client_id=CLIENT_ID,
            request_id="ack-retry",
            receiver_token=TOKEN,
            instance_id=INSTANCE_ONE,
            status="completed",
            result=result,
            error=None,
            state={**STATE, "revision": 3},
            acknowledgement={"status": "completed", "result": result, "state": {**STATE, "revision": 3}},
        )
        self.assertEqual(retried, first)
        with self.assertRaises(ControlError) as conflict:
            store.acknowledge(
                client_id=CLIENT_ID,
                request_id="ack-retry",
                receiver_token=TOKEN,
                instance_id=INSTANCE_ONE,
                status="completed",
                result={"presentation": "hud"},
                error=None,
                state=STATE,
                acknowledgement={},
            )
        self.assertEqual(conflict.exception.code, "receipt_conflict")

    def test_current_selection_requires_matching_revision(self):
        clock = MutableClock()
        store = ControlStore(":memory:", clock=clock)
        self.addCleanup(store.close)
        selected_state = {**STATE, "selection": TARGET, "revision": 9}
        store.register(
            client_id=CLIENT_ID,
            name="Synthetic Companion",
            receiver_token=TOKEN,
            instance_id=INSTANCE_ONE,
            state=selected_state,
            actions=ACTIONS,
        )
        body = {
            "requestId": "current-1",
            "action": "ui.open",
            "target": TARGET,
            "parameters": {"view": "chat"},
        }
        with self.assertRaises(ControlError) as missing:
            store.enqueue(
                client_id=CLIENT_ID,
                request_id="current-1",
                action="ui.open",
                target=TARGET,
                parameters={"view": "chat"},
                expected_revision=None,
                ttl_seconds=30,
                payload=body,
            )
        self.assertEqual(missing.exception.code, "expected_revision_required")
        with self.assertRaises(ControlError) as stale:
            store.enqueue(
                client_id=CLIENT_ID,
                request_id="current-1",
                action="ui.open",
                target=TARGET,
                parameters={"view": "chat"},
                expected_revision=8,
                ttl_seconds=30,
                payload={**body, "expectedRevision": 8},
            )
        self.assertEqual(stale.exception.code, "stale_revision")

    def test_json_must_be_finite_and_server_url_must_be_an_origin(self):
        with self.assertRaises(ControlError):
            validate_json({"value": float("nan")}, "payload")
        normalized = target({"kind": "pane", "serverURL": "HTTPS://Example.Test:443/"})
        self.assertEqual(normalized["serverURL"], "https://example.test:443")
        for invalid in (
            "https://user@example.test",
            "https://example.test/path",
            "https://example.test?token=secret",
            "https://example.test:99999",
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ControlError):
                target({"kind": "pane", "serverURL": invalid})

    def test_capacity_never_evicts_young_operation_dedupe_receipts(self):
        clock = MutableClock()
        store = ControlStore(":memory:", clock=clock)
        self.addCleanup(store.close)
        payload = {"requestId": "kept", "action": "pane.rename", "parameters": {"name": "One"}}
        store.reserve_operation("kept", "pane.rename", payload)
        store.finish_operation("kept", status="completed", result={"target": TARGET})
        with patch("herdr_harness.control_store.MAX_OPERATIONS", 1):
            with self.assertRaises(ControlError) as full:
                store.reserve_operation(
                    "new",
                    "pane.rename",
                    {"requestId": "new", "action": "pane.rename", "parameters": {"name": "Two"}},
                )
            self.assertEqual(full.exception.code, "operation_capacity")
            self.assertEqual(store.operation("kept")["status"], "completed")
            clock.value += 30 * 24 * 60 * 60 + 1
            _, created = store.reserve_operation(
                "new",
                "pane.rename",
                {"requestId": "new", "action": "pane.rename", "parameters": {"name": "Two"}},
            )
            self.assertTrue(created)

    def test_reserved_resource_operation_recovers_as_outcome_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.sqlite3"
            clock = MutableClock()
            first = ControlStore(path, clock=clock)
            operation, created = first.reserve_operation(
                "mutation-1",
                "pane.rename",
                {"requestId": "mutation-1", "action": "pane.rename", "parameters": {"name": "New"}},
            )
            self.assertTrue(created)
            self.assertEqual(operation["status"], "outcome_unknown")
            first.close()
            second = ControlStore(path, clock=clock)
            self.addCleanup(second.close)
            recovered = second.operation("mutation-1")
            self.assertEqual(recovered["status"], "outcome_unknown")
            self.assertEqual(recovered["error"]["code"], "server_restarted")
