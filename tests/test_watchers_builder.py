"""Durable builder turns, feature charter, and agent dispatch idempotency."""
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from herdr_harness.watchers.builder import WatchersBuilder
from herdr_harness.watchers.errors import WatchersError
from herdr_harness.watchers.store import WatchersStore
from herdr_harness.watchers.validation import example


class AgentRuns:
    def __init__(self):
        self.requests, self.runs = [], {}
    def start(self, **values):
        self.requests.append(values)
        run = {"id": f"run-{len(self.requests)}", "status": "running", "response": "", "steps": []}
        self.runs[run["id"]] = run
        return {"ok": True, "run": run}
    def get(self, run_id):
        return {"ok": True, "run": self.runs[run_id]}


class WatchersBuilderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = WatchersStore(Path(self.tmp.name) / "watchers.sqlite3", Path(self.tmp.name) / "watchers", "example")
        self.agents = AgentRuns()
        self.service = SimpleNamespace(watchers=SimpleNamespace(store=self.store), agent_runs=self.agents, watchers_machine={"id": "example", "name": "Example"}, environ={}, broker=SimpleNamespace(publish=Mock()))
        self.builder = WatchersBuilder(self.service)

    def tearDown(self):
        self.tmp.cleanup()

    def test_create_and_message_retry_do_not_duplicate_agent_dispatch(self):
        session = self.builder.create("session-request")
        self.assertEqual(self.builder.create("session-request"), session)
        result = self.builder.message(session["session_id"], "message-one", "Check example files every hour.")
        replay = self.builder.message(session["session_id"], "message-one", "Check example files every hour.")
        self.assertEqual(replay["messages"], result["messages"])
        self.assertEqual(len(self.agents.requests), 1)
        with self.assertRaises(WatchersError) as caught:
            self.builder.message(session["session_id"], "message-one", "Different request")
        self.assertEqual(caught.exception.code, "idempotency_conflict")
        with self.assertRaises(WatchersError) as caught:
            self.builder.message(session["session_id"], "message-two", "One more request")
        self.assertEqual(caught.exception.code, "builder_busy")

    def test_charter_context_and_continuation_are_server_owned(self):
        session = self.builder.create("session-request")
        first = self.builder.message(session["session_id"], "message-one", "Help create my watcher")
        request = self.agents.requests[0]
        self.assertIn("inside Herdr's Watchers feature", request["system_prompt"])
        self.assertIn("Ask concise clarification questions", request["system_prompt"])
        self.assertIn("Do not activate", request["system_prompt"])
        self.assertIn(session["session_id"], request["system_prompt"])
        self.assertEqual(request["_assistant"], {"profile": "watcher-builder-v1"})
        self.agents.runs[first["turn_id"]].update(status="completed", response="Which timezone should I use?")
        second = self.builder.message(session["session_id"], "message-two", "Use UTC.")
        self.assertEqual(self.agents.requests[1]["continue_from_run_id"], first["turn_id"])
        self.assertEqual(len(second["messages"]), 3)

    def test_draft_projection_survives_builder_recreation(self):
        session = self.builder.create("session-request")
        value = example()
        value["definition"]["builder_session_id"] = session["session_id"]
        draft = self.store.create(value["definition"], scripts=value["scripts"], request_id="draft")
        reconstructed = WatchersBuilder(self.service)
        snapshot = reconstructed.snapshot(session["session_id"])
        self.assertEqual(snapshot["draft"]["id"], draft["id"])
        self.assertEqual(snapshot["draft"]["state"], "draft")
        self.assertEqual(Path(self.builder._path(session["session_id"])).stat().st_mode & 0o777, 0o600)

    def test_remote_builder_preserves_creator_timezone_and_rejects_changed_retry(self):
        session = self.builder.create("remote-session", creator_timezone="America/Chicago")
        self.builder.message(session["session_id"], "timezone-message", "Check at nine each morning")
        self.assertIn('"creator_timezone": "America/Chicago"', self.agents.requests[0]["system_prompt"])
        with self.assertRaises(WatchersError) as caught:
            self.builder.create("remote-session", creator_timezone="Europe/London")
        self.assertEqual(caught.exception.code, "idempotency_conflict")
        with self.assertRaises(WatchersError):
            self.builder.create("bad-timezone", creator_timezone="invalid/zone")
        with self.assertRaises(WatchersError):
            self.builder.create("bad-id", watcher_id=[])

    def test_uncertain_dispatch_is_not_repeated_by_request_retry(self):
        session = self.builder.create("session-request")
        self.agents.start = Mock(side_effect=RuntimeError("dispatch interrupted"))
        with self.assertRaises(RuntimeError):
            self.builder.message(session["session_id"], "message-one", "Create a watcher.")
        retry = WatchersBuilder(self.service).message(session["session_id"], "message-one", "Create a watcher.")
        self.assertEqual(retry["status"], "failed")
        self.assertIn("interrupted", retry["messages"][-1]["text"])
        self.agents.start.assert_called_once()

    def test_edit_builder_stages_a_draft_and_keeps_the_original_scheduled(self):
        value = example()
        original = self.store.create(value["definition"], scripts=value["scripts"])
        original = self.store.transition(original["id"], "active", confirmed_by="user")
        session = self.builder.create("e" * 200, original["id"])
        draft = session["draft"]
        self.assertNotEqual(draft["id"], original["id"])
        self.assertEqual(draft["state"], "draft")
        self.assertEqual(draft["edit_target_id"], original["id"])
        self.assertEqual(self.store.get(original["id"])["revision"], original["revision"])
        self.builder.message(session["session_id"], "edit-prompt", "Make it every hour")
        context = self.agents.requests[-1]["system_prompt"]
        self.assertIn(draft["id"], context)
        self.assertIn("never the original", context)
        self.assertEqual(len(self.store.list(state="active")), 1)
