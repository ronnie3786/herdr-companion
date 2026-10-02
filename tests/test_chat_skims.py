import concurrent.futures
import json
import unittest

from herdr_harness.agent_runs import AgentRunError
from herdr_harness.skim_chat_store import ChatSkimStore
from herdr_harness.skim_service import SkimService, SkimSettings
from tests.test_skim_service import SkimFixture, REPLY, QUESTION, wait_until


class ChatSkimTests(SkimFixture, unittest.TestCase):
    def test_chat_uses_same_worker_and_survives_cache_reopen_without_regeneration(self):
        manager = self.manager()
        path = str(self.directory / "chat-skims.sqlite3")
        service = SkimService(SkimSettings(model="synthetic-provider/fast-model"),
                              agent_runs=lambda: manager, chat_store_path=path)
        self.addCleanup(service.stop)
        initial = service.request_chat(reply=REPLY, question=QUESTION)
        identifier = initial["id"]
        ready = wait_until(lambda: (value if (value := service.chat(identifier))["skim"]["status"] == "ready" else None))
        self.assertEqual(ready["skim"]["prompt_version"], "skim-v6")
        self.assertIn("reply_sha256", ready["skim"])
        self.assertEqual(service.request_chat(reply=REPLY, question=QUESTION), ready)
        reopened = ChatSkimStore(path)
        self.assertEqual(reopened.get(identifier)["status"], "ready")
        self.assertEqual(reopened.pending(), [])
        self.assertIsNone(reopened._db.execute("SELECT source FROM chat_skims WHERE id = ?", (identifier,)).fetchone()[0])

    def test_simultaneous_requests_share_one_job(self):
        service = self.service(self.manager())
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: service.request_chat(reply=REPLY, question=QUESTION), range(8)))
        self.assertEqual(len({result["id"] for result in results}), 1)
        identifier = results[0]["id"]
        wait_until(lambda: service.chat(identifier)["skim"]["status"] == "ready")
        self.assertEqual(service._chats.get(identifier)["attempts"], 1)

    def test_question_changes_cache_identity_and_short_or_disabled_replies_are_skipped(self):
        service = self.service(self.manager())
        self.assertIsNone(service.request_chat(reply="Done.")["skim"])
        first = service.request_chat(reply=REPLY, question=QUESTION)
        second = service.request_chat(reply=REPLY, question="What should happen next?")
        self.assertNotEqual(first["id"], second["id"])
        disabled = SkimService(SkimSettings(enabled=False), agent_runs=lambda: None)
        self.assertIsNone(disabled.request_chat(reply=REPLY)["skim"])

    def test_unknown_and_oversized_requests_fail_without_model_work(self):
        service = self.service(self.manager())
        with self.assertRaises(AgentRunError) as missing:
            service.chat("not-cached")
        self.assertEqual(missing.exception.status, 404)
        with self.assertRaises(AgentRunError) as oversized:
            service.request_chat(reply="word " * 27000)
        self.assertEqual(oversized.exception.status, 413)

    def test_interrupted_jobs_are_bounded_and_the_pending_queue_has_a_limit(self):
        store = ChatSkimStore()
        state = {"status": "pending"}
        for n in range(32):
            store.create(str(n), state, QUESTION, REPLY)
        with self.assertRaises(AgentRunError) as full:
            store.create("overflow", state, QUESTION, REPLY)
        self.assertEqual(full.exception.status, 429)
        self.assertIsNotNone(store.begin("0"))
        self.assertIsNotNone(store.begin("0"))
        self.assertIsNone(store.begin("0"))
        self.assertEqual(store.get("0")["status"], "failed")
        self.assertNotIn("0", store.pending())
