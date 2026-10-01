"""The lead First Mate (first-mate-lead-v1): one conversation across every feature.

Store rules, the lead's tools and handoff through real detached processes with a
synthetic Pi, and the authenticated HTTP surface. Synthetic data only.
"""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from types import SimpleNamespace
from unittest.mock import patch

from herdr_harness.first_mate_runtime import (LEAD_CHECKPOINT_MESSAGES, LEAD_PROMPT, FirstMateRuntime,
                                              _locked, _read_json, _write_json)
from herdr_harness.first_mate_store import LEAD_KIND, FirstMateError, FirstMateStore, lead_context
from herdr_harness.server import make_handler
from tests.test_first_mate_runtime import FAKE_PI

# The runtime tests' synthetic Pi, taught the lead's turn: read the fleet, then
# relay, read one feature, or answer from the fleet. It also records the
# supervisor's compaction setting.
LEAD_FAKE_PI = FAKE_PI.replace(
    "  if job['kind']=='coordinator':\n   snapshot=tool('fm_status',{},'status')",
    """  if job.get('lead'):
   fleet=tool('fm_fleet',{},'fleet')
   text=job['claim']['text']
   ids=[item['feature_id'] for item in fleet['features']]
   if 'relay' in text and ids:
    tool('fm_relay',{'feature_id':ids[0],'text':'Go with option B for the export format.'},'relay')
    response='Passed that to '+fleet['features'][0]['label']+'.'
   elif 'status of' in text and ids:
    status=tool('fm_feature_status',{'feature_id':ids[0]},'feature-status')
    response=status['feature']['label']+' is '+status['feature']['hud_status']+'.'
   else:
    response='You have '+str(len(ids))+' active features.'
  elif job['kind']=='coordinator':
   snapshot=tool('fm_status',{},'status')""", 1).replace(
    " elif name=='abort':",
    """ elif name=='set_auto_compaction':
  (root/'auto-compaction.json').write_text(json.dumps(command))
  emit({'type':'response','command':name,'success':True,'id':command.get('id')})
 elif name=='abort':""", 1)
assert "fm_fleet" in LEAD_FAKE_PI and "auto-compaction.json" in LEAD_FAKE_PI


class LeadStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = FirstMateStore(self.root / "store.sqlite3")
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.store.close)

    def feature(self, title="Receipt export", request_id="create"):
        return self.store.create_feature({"title": title, "goal": "Export synthetic receipts",
                                          "cwd": str(self.root), "request_id": request_id})

    def reply(self, feature_id, text, owner="coordinator"):
        message = self.store.claim_message(feature_id, owner)
        return self.store.finish_message(message["id"], owner, text)

    def test_the_lead_is_created_once_and_is_never_a_feature(self):
        self.assertIsNone(self.store.lead())
        feature = self.feature()
        lead = self.store.ensure_lead(str(self.root))
        self.assertEqual(lead["kind"], LEAD_KIND)
        self.assertEqual(lead["status"], "ready")
        self.assertEqual(self.store.ensure_lead(str(self.root))["id"], lead["id"])
        self.assertEqual(self.store.lead()["id"], lead["id"])
        self.assertEqual(self.store.snapshot(lead["id"])["messages"], [])
        for view in ("active", "archived", "all"):
            self.assertNotIn(lead["id"], [item["id"] for item in self.store.list_features(view)])
            self.assertNotIn(lead["id"], [row["id"] for row in self.store.fleet_rows(view)])
        self.assertEqual([item["id"] for item in self.store.list_features()], [feature["id"]])
        self.assertIn(lead["id"], [item["id"] for item in self.store.list_features("all", include_lead=True)])
        self.assertEqual(self.store.get_feature(feature["id"])["kind"], "feature")
        self.assertIsNone(self.store.link_discovery_context(lead["id"]))
        self.assertIsNotNone(self.store.link_discovery_context(feature["id"]))

    def test_one_lead_per_ledger_is_enforced_by_the_database(self):
        self.store.ensure_lead(str(self.root))
        with self.assertRaises(sqlite3.IntegrityError):
            self.store._db.execute(
                "INSERT INTO fm_features(id,title,goal,cwd,status,revision,kind,created_at,updated_at) "
                "VALUES('fmf_second','First Mate','goal','/',"
                "'ready',1,'lead','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
        version = self.store._db.execute("SELECT max(version) FROM fm_schema").fetchone()[0]
        self.assertGreaterEqual(version, 16)

    def test_existing_ledgers_gain_the_kind_column_with_every_row_a_feature(self):
        path = self.root / "legacy.sqlite3"
        legacy = FirstMateStore(path)
        feature = legacy.create_feature({"title": "Older feature", "goal": "Synthetic",
                                         "cwd": str(self.root), "request_id": "legacy"})
        legacy.close()
        # Rebuild the table without the column, as a pre-lead companion wrote it.
        db = sqlite3.connect(path)
        db.execute("PRAGMA foreign_keys=OFF")
        columns = [row[1] for row in db.execute("PRAGMA table_info(fm_features)") if row[1] != "kind"]
        db.execute("DROP INDEX IF EXISTS fm_features_lead")
        db.execute(f"CREATE TABLE fm_features_old AS SELECT {','.join(columns)} FROM fm_features")
        db.execute("DROP TABLE fm_features")
        db.execute("ALTER TABLE fm_features_old RENAME TO fm_features")
        db.execute("DELETE FROM fm_schema WHERE version=16")
        db.commit()
        db.close()
        upgraded = FirstMateStore(path)
        self.addCleanup(upgraded.close)
        self.assertEqual(upgraded.get_feature(feature["id"])["kind"], "feature")
        self.assertEqual([item["id"] for item in upgraded.list_features()], [feature["id"]])
        self.assertIsNone(upgraded.lead())

    def test_the_lead_has_no_workflow_presentation_or_archive(self):
        lead = self.store.ensure_lead(str(self.root))
        for call in (
            lambda: self.store.set_archived(lead["id"], True, {"request_id": "archive"}),
            lambda: self.store.set_presentation(lead["id"], {"label": "Boss"}),
            lambda: self.store.feature_action(lead["id"], "pause", "pause"),
            lambda: self.store.start_visit(lead["id"], "planning", "Plan", "visit", 1, "fmm_x"),
        ):
            with self.assertRaises(FirstMateError) as raised:
                call()
            self.assertEqual(raised.exception.code, "lead_unsupported")

    def test_the_lead_conversation_uses_ordinary_messages_and_its_own_read_marker(self):
        lead = self.store.ensure_lead(str(self.root))
        message = self.store.append_human_message(lead["id"], "What needs me?", "ask")
        self.assertEqual(message["status"], "queued")
        self.assertFalse(self.store.lead_unread(lead["id"]))
        answer = self.store.snapshot(lead["id"])["messages"]
        self.assertEqual(len(answer), 1)
        reply = self.reply(lead["id"], "Receipt export needs your call on the format.")
        latest = [m for m in self.store.snapshot(lead["id"])["messages"] if m["role"] == "assistant"][-1]
        self.assertEqual(reply["status"], "done")
        self.assertTrue(self.store.lead_unread(lead["id"]))
        self.store.mark_read(lead["id"], latest["id"])
        self.assertFalse(self.store.lead_unread(lead["id"]))

    def test_relay_posts_the_humans_words_once_and_marks_the_feature_read(self):
        lead = self.store.ensure_lead(str(self.root))
        feature = self.feature()
        self.reply(feature["id"], "Which export format should I use, CSV or JSON?")
        self.assertTrue(self.store.fleet_row(feature["id"])["first_mate_id"])
        entry_before = self.store.fleet_row(feature["id"])
        self.assertIsNone(entry_before["read_through_message_id"])
        relayed = self.store.relay_human_message(feature["id"], "Use CSV.", lead_message_id="fmm_turn",
                                                 request_id="relay-1")
        again = self.store.relay_human_message(feature["id"], "Use CSV.", lead_message_id="fmm_turn",
                                               request_id="relay-1")
        self.assertEqual(relayed["id"], again["id"])
        self.assertEqual(relayed["role"], "user")
        self.assertEqual(relayed["status"], "queued")
        self.assertEqual(relayed["metadata"], {"relayed_by": LEAD_KIND, "lead_message_id": "fmm_turn"})
        users = [m for m in self.store.snapshot(feature["id"])["messages"] if m["text"] == "Use CSV."]
        self.assertEqual(len(users), 1)
        row = self.store.fleet_row(feature["id"])
        self.assertEqual(row["read_through_message_id"], row["first_mate_id"])
        events = [e["summary"] for e in self.store.snapshot(feature["id"])["events"]]
        self.assertIn("Human direction relayed by the lead First Mate", events)
        with self.assertRaises(FirstMateError):
            self.store.relay_human_message(lead["id"], "Loop", lead_message_id="fmm_turn", request_id="self")
        with self.assertRaises(FirstMateError):
            self.store.relay_human_message(feature["id"], "", lead_message_id="fmm_turn", request_id="empty")

    def test_other_machines_context_is_bounded_private_and_lead_only(self):
        lead = self.store.ensure_lead(str(self.root))
        feature = self.feature()
        context = {"machines": [{"name": "Synthetic devbox", "features": [
            {"label": "Calendar export", "status": "blocked", "step": "QA", "now": "x" * 900, "unread": True,
             "private_path": "/synthetic/private/notes", "latest": "Which calendar format?"},
            {"status": "working"},
        ] + [{"label": f"Feature {index}"} for index in range(60)]}] * 12}
        normalized = lead_context(context)
        self.assertEqual(len(normalized["machines"]), 8)
        features = normalized["machines"][0]["features"]
        self.assertEqual(len(features), 39)  # the label-less entry is dropped from the first 40
        self.assertEqual(features[0]["now"], "x" * 200)
        self.assertNotIn("private_path", features[0])
        self.assertTrue(features[0]["unread"])
        message = self.store.append_human_message(lead["id"], "What needs me?", "ask", context=context)
        self.assertEqual(self.store.append_human_message(lead["id"], "What needs me?", "ask", context=context)["id"], message["id"])
        self.assertEqual(self.store.message_context(message["id"]), normalized)
        # Never repeated in the conversation the clients poll.
        shown = next(m for m in self.store.snapshot(lead["id"])["messages"] if m["id"] == message["id"])
        self.assertEqual(shown["metadata"], {})
        self.assertIsNone(self.store.message_context(self.store.append_human_message(lead["id"], "Thanks", "thanks")["id"]))
        with self.assertRaises(FirstMateError):
            self.store.append_human_message(feature["id"], "Hello", "feature-context", context=context)
        for malformed in ({}, {"machines": "all"}, {"machines": [{"features": []}]}, {"machines": [{"name": "x", "features": ["x"]}]}):
            with self.assertRaises(FirstMateError):
                lead_context(malformed)

    def test_mark_latest_read_moves_forward_only(self):
        feature = self.feature()
        self.assertEqual(self.store.mark_latest_read(feature["id"])["read_through_message_id"], None)
        self.reply(feature["id"], "Plan drafted.")
        marked = self.store.mark_latest_read(feature["id"])
        self.assertEqual(marked["read_through_message_id"], self.store.fleet_row(feature["id"])["first_mate_id"])


class LeadRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.cwd = self.root / "project"
        self.cwd.mkdir()
        (self.cwd / "README.md").write_text("Synthetic project\n")
        for args in (["init"], ["config", "user.email", "test@example.invalid"], ["config", "user.name", "Test"],
                     ["add", "."], ["commit", "-m", "Synthetic baseline"]):
            subprocess.run(["git", "-C", str(self.cwd), *args], capture_output=True, check=True)
        self.home = self.root / "home"
        self.home.mkdir()
        self.fake = self.root / "pi"
        self.fake.write_text(LEAD_FAKE_PI.replace("#!PYTHON", "#!" + sys.executable, 1))
        self.fake.chmod(0o700)
        self.store = FirstMateStore(self.root / "store.sqlite3")
        self.environ = {"HERDR_HARNESS_AGENT_PI_BIN": str(self.fake), "PATH": os.environ.get("PATH", ""),
                        "HOME": str(self.home), "HERDR_FIRST_MATE_MODEL": "synthetic/lead-model",
                        "HERDR_FIRST_MATE_COORDINATOR_THINKING": "high"}
        self.runtime = FirstMateRuntime(self.store, environ=self.environ, runtime_root=self.root / "runtime")
        self.children = []
        popen = subprocess.Popen

        def record_supervisor(*args, **kwargs):
            child = popen(*args, **kwargs)
            directory = kwargs.get("env", {}).get("HERDR_FIRST_MATE_JOB_DIR")
            if directory and Path(directory).resolve().is_relative_to(self.root.resolve()):
                self.children.append((child, Path(directory)))
            return child

        spawn = patch("herdr_harness.first_mate_runtime.subprocess.Popen", side_effect=record_supervisor)
        spawn.start()
        self.addCleanup(spawn.stop)

    def tearDown(self):
        self.runtime.stop()
        for child, directory in self.children:
            if child.poll() is None:
                _write_json(directory / "controls" / "test-stop.json", {"action": "abort"})
        deadline = time.monotonic() + 20
        while any(child.poll() is None for child, _ in self.children) and time.monotonic() < deadline:
            time.sleep(.03)
        for child, _ in self.children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=2)
        self.store.close()
        for _, directory in self.children:
            self.assertFalse(_locked(directory / "writer.lock"))
        self.temp.cleanup()

    def until(self, predicate, timeout=45):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.runtime.reconcile()
            if predicate():
                return
            time.sleep(.08)
        errors = {str(p): p.read_text() for p in (self.root / "runtime").rglob("*error*.json")}
        self.fail(f"Condition not reached. Errors: {errors}")

    def feature(self, title="Receipt export"):
        feature = self.store.create_feature({"title": title, "goal": "Export synthetic receipts",
                                            "cwd": str(self.cwd), "request_id": "create-" + title})
        # Settle the feature's own first turn so only the lead runs below.
        message = self.store.claim_message(feature["id"], "settled")
        self.store.finish_message(message["id"], "settled", "Which export format should I use?")
        return feature

    def lead_replies(self, lead_id):
        return [m["text"] for m in self.store.snapshot(lead_id)["messages"] if m["role"] == "assistant"]

    def lead_job(self):
        return next(job for job in self.runtime._jobs() if job.get("lead"))

    def test_a_lead_turn_runs_with_the_lead_charter_and_the_host_first_mate_model(self):
        self.feature()
        summary = self.runtime.ensure_lead()
        lead_id = summary["feature"]["id"]
        self.assertEqual(Path(self.store.get_feature(lead_id)["cwd"]), self.home)
        self.store.append_human_message(lead_id, "What needs me?", "ask")
        self.until(lambda: bool(self.lead_replies(lead_id)))
        self.assertEqual(self.lead_replies(lead_id), ["You have 1 active features."])
        job = self.lead_job()
        self.assertEqual(job["kind"], "coordinator")
        self.assertEqual(job["charter"], LEAD_PROMPT)
        directory = self.runtime._job_dir(job)
        argv = json.loads((directory / "argv.json").read_text())
        self.assertEqual(argv[argv.index("--system-prompt") + 1], LEAD_PROMPT)
        self.assertEqual(argv[argv.index("--model") + 1], "synthetic/lead-model")
        self.assertEqual(argv[argv.index("--thinking") + 1], "high")
        self.assertFalse((directory / "auto-compaction.json").exists(), "Lead sessions must not persist a shared Pi compaction toggle")
        # A ready feature that asked a question is idle, with an unread message.
        self.assertIn("Features on this machine right now: 1 moving, 1 with an unread message.", job["prompt"])
        self.until(lambda: self.store.get_feature(lead_id)["coordinator_owner"] is None)
        summary = self.runtime.lead()
        self.assertTrue(summary["unread"])
        self.assertFalse(summary["working_on_reply"])
        self.assertEqual(summary["latest_message"]["text"], "You have 1 active features.")
        self.assertEqual(summary["feature"]["model_selection"]["requested_model"], "synthetic/lead-model")
        detail = self.runtime.feature(lead_id)
        self.assertEqual(detail["coordinator_context"]["handoff_target_tokens"], 150000)

    def test_the_lead_relays_the_humans_decision_to_the_feature(self):
        feature = self.feature()
        lead_id = self.runtime.ensure_lead()["feature"]["id"]
        self.store.append_human_message(lead_id, "relay: option B for the export", "decide")
        self.until(lambda: any(m["role"] == "user" and (m.get("metadata") or {}).get("relayed_by") == LEAD_KIND
                               for m in self.store.snapshot(feature["id"])["messages"]))
        relayed = [m for m in self.store.snapshot(feature["id"])["messages"]
                   if (m.get("metadata") or {}).get("relayed_by") == LEAD_KIND]
        self.assertEqual([m["text"] for m in relayed], ["Go with option B for the export format."])
        self.assertEqual(relayed[0]["metadata"]["lead_message_id"],
                         next(m["id"] for m in self.store.snapshot(lead_id)["messages"] if m["role"] == "user"))
        self.until(lambda: bool(self.lead_replies(lead_id)))
        self.assertEqual(self.lead_replies(lead_id), ["Passed that to Receipt export."])
        row = self.store.fleet_row(feature["id"])
        self.assertEqual(row["read_through_message_id"], row["first_mate_id"])

    def test_the_lead_turn_carries_the_other_machines_snapshot(self):
        self.feature()
        lead_id = self.runtime.ensure_lead()["feature"]["id"]
        self.store.append_human_message(lead_id, "What needs me everywhere?", "everywhere", context={"machines": [
            {"name": "Synthetic devbox", "features": [{"label": "Calendar export", "status": "blocked", "step": "QA"}]}]})
        self.until(lambda: bool(self.lead_replies(lead_id)))
        prompt = self.lead_job()["prompt"]
        self.assertIn("Features on the human's other machines", prompt)
        self.assertIn('"Calendar export"', prompt)

    def test_feature_status_reads_one_feature_for_the_lead(self):
        self.feature()
        lead_id = self.runtime.ensure_lead()["feature"]["id"]
        self.store.append_human_message(lead_id, "What's the status of receipts?", "status")
        self.until(lambda: bool(self.lead_replies(lead_id)))
        self.assertEqual(self.lead_replies(lead_id), ["Receipt export is idle."])

    def test_lead_tools_refuse_feature_workflow_and_background_relays(self):
        feature = self.feature()
        lead_id = self.runtime.ensure_lead()["feature"]["id"]
        self.store.append_human_message(lead_id, "Hello", "hello")
        claim = self.store.claim_message(lead_id, self.runtime.owner)
        job = self.runtime._new_job(self.store.get_feature(lead_id), kind="coordinator", prompt="Hello", claim=claim)
        self.assertTrue(job["lead"])
        for action in ("fm_status", "fm_delegate", "fm_begin_stage", "fm_complete_stage", "fm_notify_human"):
            with self.assertRaises(FirstMateError) as raised:
                self.runtime._tool(job, action, {}, "request-" + action)
            self.assertEqual(raised.exception.code, "lead_unsupported")
        with self.assertRaises(FirstMateError):
            self.runtime._tool(job, "fm_feature_status", {"feature_id": lead_id}, "self-status")
        fleet = self.runtime._tool(job, "fm_fleet", {}, "fleet")
        self.assertEqual([item["label"] for item in fleet["features"]], ["Receipt export"])
        self.assertEqual(fleet["features"][0]["hud_status"], "idle")
        self.assertTrue(fleet["features"][0]["unread"])
        self.assertEqual(fleet["features"][0]["latest_message"]["text"], "Which export format should I use?")
        background = {**job, "claim": {**job["claim"], "role": "system"}}
        with self.assertRaises(FirstMateError) as raised:
            self.runtime._tool(background, "fm_relay", {"feature_id": feature["id"], "text": "Ship it"}, "bg-relay")
        self.assertEqual(raised.exception.code, "lead_unauthorized")
        with self.assertRaises(FirstMateError):
            self.runtime._tool(job, "fm_create_feature", {"title": "New", "goal": "Synthetic",
                                                         "cwd": str(self.root / "missing")}, "create-missing")
        created = self.runtime._tool(job, "fm_create_feature", {"title": "Calendar export", "goal": "Synthetic goal",
                                                               "cwd": str(self.cwd)}, "create")
        self.assertEqual(self.store.get_feature(created["feature_id"])["title"], "Calendar export")
        stale = {**job, "owner": "someone-else"}
        with self.assertRaises(FirstMateError) as raised:
            self.runtime._tool(stale, "fm_fleet", {}, "stale")
        self.assertEqual(raised.exception.code, "stale_owner")

    def test_the_lead_hands_off_at_the_context_target_with_its_recent_conversation(self):
        lead_id = self.runtime.ensure_lead()["feature"]["id"]
        for index in range(LEAD_CHECKPOINT_MESSAGES):
            self.store.append_human_message(lead_id, f"Question {index} " + "x" * 5000, f"q{index}")
            claim = self.store.claim_message(lead_id, "earlier")
            self.store.finish_message(claim["id"], "earlier", f"Answer {index}")
        self.store.append_human_message(lead_id, "Latest question", "latest")
        claim = self.store.claim_message(lead_id, self.runtime.owner)
        job = self.runtime._new_job(self.store.get_feature(lead_id), kind="coordinator", prompt="Latest", claim=claim)
        self.runtime._bind(job, "synthetic-lead-native", job["session_file"])
        (self.runtime._job_dir(job) / "telemetry.jsonl").write_text(json.dumps({
            "type": "context_usage", "native_session_id": "synthetic-lead-native", "time": "2026-09-28T12:00:00Z",
            "payload": {"tokens": 151000, "contextWindow": 1000000}}) + "\n")
        self.assertEqual(self.runtime.feature(lead_id)["coordinator_context"]["handoff_target_tokens"], 150000)
        self.runtime._finish(job, {"ended": True, "response": "Latest answer"})
        self.assertIsNone(self.store.get_feature(lead_id)["native_session_id"])
        checkpoint = _read_json(self.runtime.root / "checkpoints" / (lead_id + ".json"))
        self.assertEqual(checkpoint["predecessor_session_id"], "synthetic-lead-native")
        self.assertNotIn("router_state", checkpoint)
        self.assertNotIn("human_directives", checkpoint)
        recent = checkpoint["recent_conversation"]
        self.assertEqual(len(recent), LEAD_CHECKPOINT_MESSAGES)
        self.assertEqual((recent[-1]["role"], recent[-1]["text"]), ("assistant", "Latest answer"))
        self.assertTrue(all(len(message["text"]) <= 4000 for message in recent))
        self.store.append_human_message(lead_id, "After the handoff", "after")
        successor_claim = self.store.claim_message(lead_id, self.runtime.owner)
        successor = self.runtime._new_job(self.store.get_feature(lead_id), kind="coordinator",
                                          prompt="After", claim=successor_claim)
        self.assertNotEqual(successor["session_file"], job["session_file"])
        self.assertIn("Retained First Mate checkpoint", successor["prompt"])
        self.assertIn("Latest answer", successor["prompt"])


class LeadHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.store = FirstMateStore(root / "work.sqlite3")
        self.runtime = FirstMateRuntime(self.store, environ={"HOME": str(root), "PATH": os.environ.get("PATH", ""),
                                                             "HERDR_HARNESS_AGENT_PI_BIN": str(root / "missing-pi")},
                                        runtime_root=root / "runtime")
        self.wakes = []
        service = SimpleNamespace(environ={"HERDR_HARNESS_API_TOKEN": "synthetic-main-token"},
                                  first_mate_store=self.store, first_mate=self.runtime,
                                  first_mate_changed=self.wakes.append)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.store.close()
        self.temp.cleanup()

    def request(self, path, body=None, token="synthetic-main-token"):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(self.origin + path, headers=headers,
                                         data=json.dumps(body).encode() if body is not None else None)
        try:
            response = urllib.request.urlopen(request)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.loads(response.read())

    def test_lead_routes_are_authenticated_additive_and_idempotent(self):
        status, _ = self.request("/api/v1/first-mate/lead", token=None)
        self.assertEqual(status, 401)
        status, capabilities = self.request("/api/v1/first-mate/capabilities")
        self.assertIn("first-mate-lead-v1", capabilities["capabilities"])
        self.assertEqual(self.request("/api/v1/first-mate/lead"), (200, {"ok": True, "lead": None}))
        status, created = self.request("/api/v1/first-mate/lead", {"request_id": "ensure-1"})
        self.assertEqual(status, 201)
        lead = created["lead"]
        self.assertEqual(lead["feature"]["kind"], LEAD_KIND)
        self.assertFalse(lead["unread"])
        self.assertIsNone(lead["latest_message"])
        status, again = self.request("/api/v1/first-mate/lead", {})
        self.assertEqual(status, 200)
        self.assertEqual(again["lead"]["feature"]["id"], lead["feature"]["id"])
        self.assertEqual(self.request("/api/v1/first-mate/lead", {"surprise": True})[0], 400)
        status, listed = self.request("/api/v1/first-mate/features?view=all")
        self.assertEqual(listed["features"], [])
        status, fleet = self.request("/api/v1/first-mate/fleet?view=all")
        self.assertEqual(fleet["features"], [])
        lead_id = lead["feature"]["id"]
        status, sent = self.request(f"/api/v1/first-mate/features/{lead_id}/messages",
                                    {"text": "What needs me?", "request_id": "ask"})
        self.assertEqual(status, 202)
        self.assertEqual(self.wakes, [lead_id])
        status, detail = self.request(f"/api/v1/first-mate/features/{lead_id}")
        self.assertEqual([m["text"] for m in detail["messages"]], ["What needs me?"])
        status, current = self.request("/api/v1/first-mate/lead")
        self.assertTrue(current["lead"]["working_on_reply"])
        self.assertEqual(current["lead"]["latest_message"]["text"], "What needs me?")
        context = {"machines": [{"name": "Synthetic devbox", "features": [{"label": "Calendar export", "status": "turn"}]}]}
        status, _ = self.request(f"/api/v1/first-mate/features/{lead_id}/messages",
                                 {"text": "And elsewhere?", "request_id": "ask-context", "context": context})
        self.assertEqual(status, 202)
        feature = self.store.create_feature({"title": "Synthetic feature", "goal": "Synthetic goal",
                                            "cwd": self.temp.name, "request_id": "create-feature"})
        status, _ = self.request(f"/api/v1/first-mate/features/{feature['id']}/messages",
                                 {"text": "Hello", "request_id": "feature-context", "context": context})
        self.assertEqual(status, 400)
        status, refused = self.request(f"/api/v1/first-mate/features/{lead_id}/actions",
                                       {"action": "archive", "request_id": "archive-lead"})
        self.assertEqual(status, 409)
        self.assertEqual(refused["error"]["code"], "lead_unsupported")


if __name__ == "__main__":
    unittest.main()
