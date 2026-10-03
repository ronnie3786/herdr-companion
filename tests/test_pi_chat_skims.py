"""Background Main Chat skims use synthetic Pi checkpoints and a fake model."""
import json
import queue
import threading
import unittest
from unittest.mock import patch

from herdr_harness.pi_semantic import pi_semantic_socket_path
from herdr_harness.service import HerdrService
from herdr_harness.skim_pi import settled_reply
from tests.test_herdr_service import FakeClient, FakePush, snapshot_with_status
from tests.test_pi_semantic import FakeExtensionSocket, bridge_record
from tests.test_skim_service import SkimFixture, REPLY, QUESTION, wait_until


def checkpoint(*, question=QUESTION, replies=None, idle=True, stop_reason="stop"):
    return {
        "session": {"id": "synthetic-session"},
        "state": {"idle": idle, "working": not idle, "isStreaming": not idle},
        "entries": [
            {"type": "message", "id": "user", "message": {"role": "user", "content": question}},
            {"type": "message", "id": "answer", "message": {
                "role": "assistant", "stopReason": stop_reason,
                "content": [{"type": "text", "text": text} for text in (replies or [REPLY])],
            }},
        ],
    }


class CheckpointSocket(FakeExtensionSocket):
    """A controlled authenticated bridge, with no HTTP reader connected."""

    def __init__(self, path, pane_id):
        self.records = queue.Queue()
        self.subscribed = threading.Event()
        super().__init__(path, pane_id)

    def send(self, kind, **values):
        self.records.put(bridge_record(self.pane_id, kind, **values))

    def _handle(self, connection):
        with connection:
            request = connection.makefile("rb").readline()
            if not request:
                return
            if json.loads(request).get("type") != "subscribe":
                return
            hello = bridge_record(self.pane_id, "hello", session_id="synthetic-session")
            connection.sendall(json.dumps(hello).encode() + b"\n")
            self.subscribed.set()
            while not self.stop_event.is_set():
                try:
                    record = self.records.get(timeout=0.05)
                except queue.Empty:
                    continue
                try:
                    connection.sendall(json.dumps(record).encode() + b"\n")
                except OSError:
                    return


class PiSkimSelectionTests(unittest.TestCase):
    def test_parts_and_question_match_native_reader_without_image_data(self):
        question = [{"type": "text", "text": "  Explain this.\n"},
                    {"type": "image", "data": "synthetic-image-data"},
                    {"type": "text", "text": "Keep the line breaks."}]
        snapshot = checkpoint(question=question, replies=[REPLY, "  Another answer.\n"])
        self.assertEqual(settled_reply(snapshot),
                         ("  Explain this.\n\n[Image]\nKeep the line breaks.", [REPLY, "  Another answer.\n"]))

    def test_only_the_latest_turns_concluding_answer_is_selected(self):
        snapshot = checkpoint(question="Old question", replies=["Old answer"])
        latest = checkpoint()
        latest["entries"].insert(1, {"type": "message", "message": {
            "role": "assistant", "stopReason": "toolUse",
            "content": [{"type": "text", "text": "Working commentary"},
                        {"type": "toolCall", "id": "tool-1"}],
        }})
        latest["entries"].insert(2, {"type": "message", "message": {
            "role": "toolResult", "content": [{"type": "text", "text": "Tool result"}],
        }})
        snapshot["entries"].extend(latest["entries"])
        self.assertEqual(settled_reply(snapshot), (QUESTION, [REPLY]))
        snapshot["entries"].append({"type": "message", "message": {"role": "user", "content": "Next"}})
        self.assertIsNone(settled_reply(snapshot))

    def test_streaming_compacting_queued_and_unknown_state_are_ineligible(self):
        for state in ({}, {"idle": False}, {"idle": True, "working": True},
                      {"idle": True, "isStreaming": True}, {"idle": True, "isCompacting": True},
                      {"idle": True, "pendingMessages": True}):
            with self.subTest(state=state):
                snapshot = checkpoint()
                snapshot["state"] = state
                self.assertIsNone(settled_reply(snapshot))

    def test_errors_cancellation_tool_use_and_truncation_stops_are_ineligible(self):
        for reason in ("error", "aborted", "cancelled", "toolUse", "length", "unknown", {}):
            with self.subTest(reason=reason):
                self.assertIsNone(settled_reply(checkpoint(stop_reason=reason)))
        snapshot = checkpoint()
        snapshot["entries"][-1]["message"]["content"].append({"type": "toolCall", "id": "tool-1"})
        self.assertIsNone(settled_reply(snapshot))
        snapshot = checkpoint()
        snapshot["entries"].append({"type": "message", "message": {"role": "toolResult", "content": []}})
        self.assertIsNone(settled_reply(snapshot))

    def test_legacy_missing_stop_and_trailing_neutral_notices_match_reader(self):
        snapshot = checkpoint(stop_reason=None)
        self.assertEqual(settled_reply(snapshot), (QUESTION, [REPLY]))
        snapshot["entries"].append({"type": "model_change", "modelId": "synthetic"})
        self.assertIsNone(settled_reply(snapshot))
        snapshot["entries"][-2]["message"]["stopReason"] = "stop"
        self.assertEqual(settled_reply(snapshot), (QUESTION, [REPLY]))


class PiChatSkimTests(SkimFixture, unittest.TestCase):
    def connect_companion(self, skims):
        topology = snapshot_with_status("working")
        topology["panes"][0]["agent"] = "pi"
        client = FakeClient([topology])
        client.socket_path = str(self.directory / "herdr.sock")
        companion = HerdrService(client, environ={}, push=FakePush())
        companion._skims = skims
        path = pi_semantic_socket_path(client.socket_path, "w1:p1")
        bridge = CheckpointSocket(path, "w1:p1").start()
        self.addCleanup(bridge.stop)
        self.addCleanup(companion.stop)
        companion.refresh_snapshot()
        companion.pi_semantic.start()
        self.assertTrue(bridge.subscribed.wait(2))
        return companion, bridge

    def test_unopened_chat_is_skimmed_after_durable_settle_and_reader_reuses_it(self):
        manager = self.manager()
        skims = self.service(manager)
        companion, bridge = self.connect_companion(skims)
        observed = []
        original = companion.pi_semantic._on_snapshot

        def observe(snapshot):
            # Callback must see the same committed checkpoint, not the old
            # snapshot that is still current when agent_settled is dispatched.
            self.assertEqual(companion.pi_semantic.snapshot_response("w1:p1")["entries"], snapshot["entries"])
            original(snapshot)
            observed.append(snapshot)

        companion.pi_semantic._on_snapshot = observe
        bridge.send("snapshot", snapshot=checkpoint(idle=False))
        wait_until(lambda: len(observed) == 1)
        self.assertEqual(skims._chats.pending(), [])
        bridge.send("event", sequence=1, session_id="synthetic-session", event={"type": "agent_settled"})
        wait_until(lambda: companion.pi_semantic.bounds("w1:p1")[1] >= 2)
        self.assertEqual(skims._chats.pending(), [])
        bridge.send("snapshot", sequence=1, snapshot=checkpoint())
        wait_until(lambda: len(observed) == 2)
        identifier = skims._chats._db.execute("SELECT id FROM chat_skims").fetchone()[0]
        ready = wait_until(lambda: (state if (state := skims.chat(identifier))["skim"]["status"] == "ready" else None))
        # No HTTP request or mounted chat row was needed to produce the skim.
        self.assertEqual(skims.request_chat(reply=REPLY, question=QUESTION), ready)
        bridge.send("snapshot", sequence=1, snapshot=checkpoint())
        wait_until(lambda: len(observed) == 3)
        self.assertEqual(skims._chats.get(identifier)["attempts"], 1)

    def test_reconnect_checkpoint_prepares_completed_reply_without_settled_event(self):
        skims = self.service(self.manager())
        companion, bridge = self.connect_companion(skims)
        bridge.send("snapshot", snapshot=checkpoint())
        identifier = wait_until(lambda: skims._chats._db.execute("SELECT id FROM chat_skims").fetchone())[0]
        wait_until(lambda: skims.chat(identifier)["skim"]["status"] == "ready")
        self.assertEqual(skims._chats.get(identifier)["attempts"], 1)
        self.assertTrue(companion.pi_semantic.capability("w1:p1")["connected"])

    def test_optional_observer_failure_keeps_bridge_and_later_checkpoints_working(self):
        skims = self.service(self.manager())
        companion, bridge = self.connect_companion(skims)
        observe = companion.pi_semantic._on_snapshot
        calls = []

        def fail_once(snapshot):
            calls.append(snapshot)
            if len(calls) == 1:
                raise RuntimeError("synthetic text must not be logged")
            observe(snapshot)

        companion.pi_semantic._on_snapshot = fail_once
        with self.assertLogs("herdr_harness.pi_semantic", level="WARNING") as logs:
            bridge.send("snapshot", snapshot=checkpoint())
            wait_until(lambda: logs.output)
        self.assertNotIn("synthetic text", " ".join(logs.output))
        self.assertTrue(companion.pi_semantic.capability("w1:p1")["connected"])
        bridge.send("snapshot", snapshot=checkpoint())
        identifier = wait_until(lambda: skims._chats._db.execute("SELECT id FROM chat_skims").fetchone())[0]
        wait_until(lambda: skims.chat(identifier)["skim"]["status"] == "ready")

    def test_short_disabled_oversized_and_busy_preparation_do_not_start_model_work(self):
        skims = self.service(self.manager())
        with patch.object(skims, "_infer") as infer:
            skims.observe_pi_snapshot(checkpoint(replies=["Done."]))
            skims.observe_pi_snapshot(checkpoint(replies=["word " * 27000]))
            skims.observe_pi_snapshot(checkpoint(question="x" * 16001))
            self.assertEqual(skims._chats.pending(), [])
            for n in range(32):
                skims._chats.create(str(n), {"status": "pending"}, QUESTION, REPLY)
            skims.observe_pi_snapshot(checkpoint())
            self.assertEqual(len(skims._chats.pending()), 32)
            infer.assert_not_called()
        disabled = self.service(self.manager(), enabled=False)
        disabled.observe_pi_snapshot(checkpoint())
        self.assertEqual(disabled._chats.pending(), [])

    def test_multipart_answer_shares_cache_with_reader_and_discards_raw_source(self):
        skims = self.service(self.manager())
        question = [{"type": "text", "text": QUESTION}, {"type": "image", "data": "private-synthetic-data"},
                    {"type": "text", "text": "Attachment: `/tmp/synthetic/note.txt`"}]
        skims.observe_pi_snapshot(checkpoint(question=question, replies=[REPLY, "Done."]))
        identifier = skims._chats._db.execute("SELECT id FROM chat_skims").fetchone()[0]
        wait_until(lambda: skims.chat(identifier)["skim"]["status"] == "ready")
        reader = skims.request_chat(reply=REPLY, question=QUESTION + "\n[Image]\nAttachment: `/tmp/synthetic/note.txt`")
        self.assertEqual(reader["id"], identifier)
        self.assertEqual(reader["skim"]["status"], "ready")
        self.assertEqual(skims._chats.get(identifier)["attempts"], 1)
        source = skims._chats._db.execute("SELECT source FROM chat_skims WHERE id = ?", (identifier,)).fetchone()[0]
        self.assertIsNone(source)
        prompt = json.loads((self.directory / "capture.json").read_text())["prompt"]
        self.assertNotIn("private-synthetic-data", prompt)
        self.assertNotIn("/tmp/synthetic/note.txt", prompt)
