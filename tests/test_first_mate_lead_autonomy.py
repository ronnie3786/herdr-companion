"""Lead actions keep one durable effect across a continued human turn."""
import json
from pathlib import Path
import tempfile
import unittest

from herdr_harness.first_mate_runtime import FirstMateRuntime, _write_json
from herdr_harness.first_mate_store import FirstMateError, FirstMateStore


class FirstMateLeadAutonomyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.open_runtime()
        self.lead = self.store.ensure_lead(str(self.root))
        self.store.append_human_message(self.lead["id"], "Relay my decision and start the requested feature", "human-turn")

    def open_runtime(self):
        self.store = FirstMateStore(self.root / "state.sqlite3")
        self.runtime = FirstMateRuntime(self.store, environ={"PATH": "/usr/bin:/bin"},
                                        runtime_root=self.root / "runtime")

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def feature(self, title="Synthetic export"):
        feature = self.store.create_feature({"title": title, "goal": "Export synthetic receipts",
            "cwd": str(self.root), "request_id": "create-" + title})
        claim = self.store.claim_message(feature["id"], "feature-owner")
        self.store.finish_message(claim["id"], "feature-owner", "Choose CSV or JSON")
        return feature

    def coordinator(self):
        claim = self.store.claim_message(self.lead["id"], "lead-owner")
        job = self.runtime._new_job(self.lead, kind="coordinator", claim=claim,
                                    prompt="Complete the human's requested actions")
        directory = self.runtime._job_dir(job)
        (directory / "effects.jsonl").write_text(json.dumps(
            {"type": "ledger_ready", "version": 1, "job_id": job["id"]}) + "\n")
        return job

    def action(self, job, action, params, tool_id):
        # Retain the same real store effect and request/response receipts used
        # by the service, without launching an external model process.
        result = self.runtime._tool(job, action, params, tool_id)
        directory = self.runtime._job_dir(job)
        _write_json(directory / "requests" / (tool_id + ".json"),
                    {"action": action, "params": params, "request_id": tool_id})
        _write_json(directory / "responses" / (tool_id + ".json"), {"ok": True, "result": result})
        return result

    def interrupt(self, job):
        self.runtime._finish(job, {"ended": True, "error": "Connection reset after tool completion"})
        self.assertEqual(self.store.pending_messages(self.lead["id"])[0]["status"], "queued")
        self.assertEqual(self.replies(), [])

    def replies(self):
        return [message for message in self.store.snapshot(self.lead["id"])["messages"]
                if message["role"] == "assistant"]

    def relays(self, feature):
        return [message for message in self.store.snapshot(feature["id"])["messages"]
                if message.get("metadata", {}).get("relayed_by") == "lead"]

    def test_relay_survives_restart_and_timeout_with_new_job_and_tool_id_once(self):
        feature = self.feature()
        direction = "Use CSV.\n" + "Keep the synthetic column order. " * 300
        params = {"feature_id": feature["id"], "text": direction}
        first = self.coordinator()
        original = self.action(first, "fm_relay", params, "first-tool")
        self.interrupt(first)
        self.store.close()
        self.open_runtime()
        second = self.coordinator()
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(first["claim"]["id"], second["claim"]["id"])
        self.assertIn(original["message_id"], second["prompt"])
        self.assertIn(feature["id"], second["prompt"])
        self.assertNotIn(direction, second["prompt"])
        # A second timeout before any new tool call must not discard the first
        # attempt's committed relay from the final continuation's evidence.
        self.interrupt(second)
        third = self.coordinator()
        self.assertNotEqual(second["id"], third["id"])
        self.assertIn(original["message_id"], third["prompt"])
        duplicate = self.action(third, "fm_relay", {"text": direction, "feature_id": feature["id"]}, "third-tool")
        self.assertEqual(original, duplicate)
        self.assertEqual([message["text"] for message in self.relays(feature)], [direction])
        self.runtime._finish(third, {"ended": True, "response": "Passed your decision on."})
        self.assertEqual(len(self.replies()), 1)

    def test_create_survives_timeout_with_normalized_directory_and_one_reply(self):
        params = {"title": "Synthetic calendar", "goal": "Export the requested synthetic calendar",
                  "cwd": str(self.root) + "/."}
        first = self.coordinator()
        original = self.action(first, "fm_create_feature", params, "first-create")
        self.interrupt(first)
        second = self.coordinator()
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(first["claim"]["id"], second["claim"]["id"])
        self.assertIn(original["feature_id"], second["prompt"])
        duplicate = self.action(second, "fm_create_feature", {**params, "cwd": str(self.root)}, "second-create")
        self.assertEqual(original, duplicate)
        self.assertEqual([feature["id"] for feature in self.store.list_features()], [original["feature_id"]])
        self.runtime._finish(second, {"ended": True, "response": "Started the requested feature."})
        self.assertEqual(len(self.replies()), 1)

    def test_distinct_relay_text_targets_and_later_human_turns_remain_distinct(self):
        feature, other = self.feature(), self.feature("Synthetic calendar")
        job = self.coordinator()
        self.action(job, "fm_relay", {"feature_id": feature["id"], "text": "Use CSV."}, "csv")
        self.action(job, "fm_relay", {"feature_id": feature["id"], "text": "Use JSON."}, "json")
        self.action(job, "fm_relay", {"feature_id": other["id"], "text": "Use CSV."}, "other")
        self.runtime._finish(job, {"ended": True, "response": "Passed those decisions on."})
        self.store.append_human_message(self.lead["id"], "Tell the export feature to use CSV again", "later-human-turn")
        later = self.coordinator()
        self.action(later, "fm_relay", {"feature_id": feature["id"], "text": "Use CSV."}, "later-csv")
        self.assertEqual([message["text"] for message in self.relays(feature)], ["Use CSV.", "Use JSON.", "Use CSV."])
        self.assertEqual(len(self.relays(other)), 1)

    def test_distinct_create_goals_and_later_human_turns_remain_distinct(self):
        params = {"title": "Synthetic calendar", "goal": "Export CSV", "cwd": str(self.root)}
        job = self.coordinator()
        first = self.action(job, "fm_create_feature", params, "csv")
        other = self.action(job, "fm_create_feature", {**params, "goal": "Export JSON"}, "json")
        self.runtime._finish(job, {"ended": True, "response": "Started the requested features."})
        self.store.append_human_message(self.lead["id"], "Create another calendar export feature", "later-human-turn")
        later = self.coordinator()
        third = self.action(later, "fm_create_feature", params, "later-csv")
        self.assertEqual(len({first["feature_id"], other["feature_id"], third["feature_id"]}), 3)

    def test_role_and_owner_fences_still_reject_actions(self):
        feature = self.feature()
        job = self.coordinator()
        for action, params in (("fm_relay", {"feature_id": feature["id"], "text": "Use CSV."}),
                               ("fm_create_feature", {"title": "Synthetic calendar", "goal": "Export", "cwd": str(self.root)})):
            with self.subTest(action=action):
                for invalid, code in (({**job, "owner": "stale"}, "stale_owner"),
                                      ({**job, "claim": {**job["claim"], "role": "system"}}, "lead_unauthorized")):
                    with self.assertRaises(FirstMateError) as raised:
                        self.runtime._tool(invalid, action, params, "refused")
                    self.assertEqual(raised.exception.code, code)
        self.assertEqual(self.relays(feature), [])
        self.assertEqual(len(self.store.list_features()), 1)

    def test_retry_receipt_keeps_bounded_references_and_omits_full_results(self):
        job = self.coordinator()
        directory = self.runtime._job_dir(job)
        _write_json(directory / "requests" / "create.json", {"action": "fm_create_feature", "request_id": "create",
            "params": {"title": "Synthetic calendar", "goal": "g" * 20000, "opaque": "private-marker" * 1000}})
        _write_json(directory / "responses" / "create.json", {"ok": True,
            "result": {"feature_id": "synthetic-created-feature", "status": "ready", "history": "old-history" * 20000}})
        self.interrupt(job)
        successor = self.coordinator()
        self.assertIn('"feature_id": "synthetic-created-feature"', successor["prompt"])
        self.assertIn('"goal_characters": 20000', successor["prompt"])
        self.assertNotIn("g" * 241, successor["prompt"])
        self.assertNotIn("private-marker", successor["prompt"])
        self.assertNotIn("old-history", successor["prompt"])
        self.assertLess(len(successor["prompt"]), 2500)


if __name__ == "__main__":
    unittest.main()
