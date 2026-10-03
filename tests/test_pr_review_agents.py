"""Saved reviewers, exact revision membership, and durable consolidation."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid

from herdr_harness.agent_roles import AgentRoleError, AgentRoles, PR_REVIEW_BUILTIN_ID
from herdr_harness.agent_runs import AgentRunError, AgentRunManager, PR_REVIEW_AGENT_PROFILE
from herdr_harness.pr_review_agents import PRReviewAgents
from herdr_harness.pr_review_runtime import PRReviewRuntime
from herdr_harness.pr_review_store import PRReviewError, PRReviewStore
from tests.test_agent_roles import custom_role, skill_bundle
from tests.test_agent_runs import write_fake_pi


class FakeAgents:
    def __init__(self):
        self.runs, self.calls = {}, []

    def start(self, **arguments):
        run_id = "agr_" + arguments["_assistant"]["prReviewRunId"][5:]
        self.calls.append(arguments)
        self.runs.setdefault(run_id, {"id": run_id, "status": "running", "response": None, "sessionId": "synthetic-" + run_id})
        return {"run": self.runs[run_id]}

    def get(self, run_id):
        if run_id not in self.runs:
            raise AgentRunError("Missing synthetic session", code="agent_run_not_found", status=404)
        return {"run": self.runs[run_id]}


class SavedReviewerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.roles = AgentRoles(self.root / "roles.sqlite3", environ={})
        self.store = PRReviewStore(self.root / "reviews.sqlite3")
        self.addCleanup(self.roles.close)
        self.addCleanup(self.store.close)
        self.agents = FakeAgents()
        self.service = SimpleNamespace(agent_roles=self.roles, agent_runs=self.agents, pr_review_changed=lambda _: None)
        self.runtime = PRReviewRuntime(self.service, self.store, environ={"PATH": "/usr/bin:/bin", "HERDR_PR_REVIEW_AUTO_RANK": "false"}, runtime_root=self.root / "runs")
        self.addCleanup(self.join_launchers)
        self.checkout = self.root / "repo"
        self.checkout.mkdir()
        self.git("init", "--quiet")
        (self.checkout / "garden.py").write_text("value = 1\n")
        self.git("add", "garden.py")
        self.git("-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.test", "commit", "--quiet", "-m", "Seed")
        self.base = self.git("rev-parse", "HEAD").strip()
        (self.checkout / "garden.py").write_text("value = 2\n")
        self.git("-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.test", "commit", "--quiet", "-am", "Change")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.review = self.store.create_review({"url": "https://github.com/example-owner/garden/pull/42", "host": "github.com", "owner": "example-owner", "repo": "garden", "number": 42, "request_id": "create"})
        self.prepare()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.checkout), *args], check=True, capture_output=True, text=True).stdout

    def prepare(self):
        self.store.complete_preparation(self.review["id"], [{"path": "garden.py"}], status="ready", title="Synthetic change",
            body="Untrusted PR text", checkout_path=str(self.checkout), base_sha=self.base, head_sha=self.head, merge_base_sha=self.base)

    def join_launchers(self):
        self.runtime._stop.set()
        for thread in list(threading.enumerate()):
            if getattr(getattr(thread, "_target", None), "__self__", None) is self.runtime.agents:
                thread.join(timeout=5)

    def until(self, condition):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.01)
        self.fail("Synthetic reviewer did not reach expected state")

    def role(self, name="Architecture", **values):
        role = custom_role(name=name, purpose="pr_review", modelProfile="default", reviewPrompt="Verify {url}. Keep other {braces} literal.", **values)
        self.roles.mutate({"action": "save", "role": role, "expectedRevision": self.roles.overview()["revision"]})
        return role

    def queue(self, ids, request="queue"):
        runs = self.runtime.start_agent_runs(self.review["id"], ids, request)
        self.runtime.agents.reconcile()
        self.until(lambda: all(self.store.run(self.review["id"], run["id"]).get("dispatch_complete") and run["id"] not in self.runtime.agents._launching for run in runs))
        return [self.store.run(self.review["id"], run["id"]) for run in runs]

    def finish(self, run, *, status="completed", response="## Findings\n\nNo actionable findings in garden.py."):
        self.until(lambda: run["id"] not in self.runtime.agents._launching)
        agent_id = "agr_" + run["id"][5:]
        self.agents.runs[agent_id].update(status=status, response=response, sessionFile="/synthetic/session.jsonl")
        self.runtime.agents.reconcile()

    def consolidator(self):
        self.until(lambda: any(run.get("kind") == "consolidator" and run.get("dispatch_complete") for run in self.store.runs_for_review(self.review["id"])))
        return next(run for run in self.store.runs_for_review(self.review["id"]) if run.get("kind") == "consolidator")

    def test_all_selected_finish_once_with_bound_raw_and_final_reports(self):
        specialist = self.role()
        runs = self.queue([PR_REVIEW_BUILTIN_ID, specialist["id"]])
        self.assertNotEqual(self.agents.calls[0]["cwd"], self.agents.calls[1]["cwd"])
        self.assertTrue(all(call["cwd"] != str(self.checkout) for call in self.agents.calls))
        for call in self.agents.calls:
            packet = json.loads(call["prompt"].split("Server-owned review scope and untrusted PR metadata (JSON):\n", 1)[1])
            self.assertEqual(packet["review_id"], self.review["id"])
            self.assertEqual(packet["base_sha"], self.base)
            self.assertEqual(packet["head_sha"], self.head)
        self.finish(runs[0])
        self.assertEqual(self.store.consolidation(self.review["id"])["state"], "waiting")
        self.finish(runs[1])
        combined = self.consolidator()
        self.assertEqual(combined["input_run_ids"], [run["id"] for run in runs])
        self.finish(combined, response="## Verified findings\n\n<script>alert('untrusted')</script>\nNo supported findings.")
        summary = self.store.consolidation(self.review["id"])
        self.assertEqual(summary["state"], "finished")
        self.assertEqual(summary["incomplete_run_ids"], [])
        self.assertEqual(len(summary["document_ids"]), 2)
        self.assertEqual(len(self.store.documents(self.review["id"])), 4)
        html_id = summary["document_ids"][1]
        with self.runtime.open_document(self.review["id"], html_id) as document:
            markup = document.handle.read().decode()
        self.assertNotIn("<script>", markup)
        for run in runs:
            raw_id = self.store.run(self.review["id"], run["id"])["document_ids"][0]
            self.assertIn("herdr-pr-review-document:" + raw_id, markup)
            self.assertEqual(self.store.document(self.review["id"], raw_id)["run_id"], run["id"])
        revision = self.store.get_review(self.review["id"])["revision"]
        self.runtime.agents.reconcile()
        self.assertEqual(len(self.agents.calls), 3)
        self.assertEqual(self.store.get_review(self.review["id"])["revision"], revision)

    def test_add_agent_fences_running_consolidator_and_keeps_original_inputs(self):
        original = self.queue([PR_REVIEW_BUILTIN_ID])[0]
        self.finish(original)
        stale = self.consolidator()
        additional = self.role()
        added = self.queue([additional["id"]], "additional")[0]
        self.finish(stale)
        summary = self.store.consolidation(self.review["id"])
        self.assertEqual(summary["generation"], 2)
        self.assertEqual(summary["state"], "waiting")
        self.assertEqual(summary["document_ids"], [])
        self.finish(added)
        self.until(lambda: len([run for run in self.store.runs_for_review(self.review["id"]) if run.get("kind") == "consolidator" and run.get("dispatch_complete")]) == 2)
        newest = next(run for run in self.store.runs_for_review(self.review["id"]) if run.get("kind") == "consolidator")
        self.assertEqual(set(newest["input_run_ids"]), {original["id"], added["id"]})
        self.finish(newest)
        self.assertEqual(self.store.consolidation(self.review["id"])["run_id"], newest["id"])

    def test_failed_member_settles_with_explicit_incomplete_coverage(self):
        specialist = self.role()
        runs = self.queue([PR_REVIEW_BUILTIN_ID, specialist["id"]])
        self.finish(runs[0], status="failed", response="Partial analysis only")
        self.finish(runs[1])
        combined = self.consolidator()
        self.assertEqual(combined["incomplete_run_ids"], [runs[0]["id"]])
        self.finish(combined)
        summary = self.store.consolidation(self.review["id"])
        self.assertEqual(summary["state"], "finished")
        self.assertEqual(summary["incomplete_run_ids"], [runs[0]["id"]])
        with self.runtime.open_document(self.review["id"], summary["document_ids"][0]) as doc:
            self.assertIn(b"Incomplete reviewer runs", doc.handle.read())

    def test_rerun_replaces_only_its_member_and_receipt_does_not_repeat(self):
        specialist = self.role()
        original, retained = self.queue([PR_REVIEW_BUILTIN_ID, specialist["id"]])
        self.finish(original)
        self.finish(retained)
        repeat = self.queue([PR_REVIEW_BUILTIN_ID], "rerun")[0]
        again = self.runtime.start_agent_runs(self.review["id"], [PR_REVIEW_BUILTIN_ID], "rerun")
        self.assertEqual(again[0]["id"], repeat["id"])
        self.assertEqual(set(self.store.consolidation(self.review["id"])["input_run_ids"]), {repeat["id"], retained["id"]})
        with self.assertRaises(PRReviewError):
            self.runtime.start_agent_runs(self.review["id"], [specialist["id"]], "rerun")

    def test_revision_refresh_never_relabels_old_consolidation_current(self):
        reviewer = self.queue([PR_REVIEW_BUILTIN_ID])[0]
        self.finish(reviewer)
        stale = self.consolidator()
        (self.checkout / "garden.py").write_text("value = 3\n")
        self.git("-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.test", "commit", "--quiet", "-am", "Next")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.prepare()
        self.finish(stale)
        summary = self.store.consolidation(self.review["id"])
        self.assertEqual(summary["state"], "failed")
        self.assertEqual(summary["head_sha"], self.head)
        self.assertEqual(summary["document_ids"], [])
        self.assertIn("pull request changed", summary["error"])
        self.assertEqual(self.store.agent_run_snapshot(self.review["id"], stale["id"])["reviewScope"]["head_sha"], stale["head_sha"])

    def test_preparation_pins_queued_scope_and_role_edit_does_not_change_run(self):
        second = self.store.create_review({"url": "https://github.com/example-owner/garden/pull/43", "host": "github.com", "owner": "example-owner", "repo": "garden", "number": 43, "request_id": "create-second"})
        role = self.role()
        run = self.runtime.agents.queue(second["id"], [role["id"]], "before-prepare", preparing=True)[0]
        self.assertIsNone(run["head_sha"])
        self.roles.mutate({"action": "save", "role": {**role, "name": "Changed private profile"}, "expectedRevision": self.roles.overview()["revision"]})
        self.store.complete_preparation(second["id"], [], status="ready", base_sha=self.base, head_sha=self.head, merge_base_sha=self.base, title="Pinned title", body="Pinned body", checkout_path=str(self.checkout))
        pinned = self.store.agent_run_snapshot(second["id"], run["id"])
        self.assertEqual(pinned["name"], "Architecture")
        self.assertEqual(pinned["reviewScope"]["body"], "Pinned body")
        self.assertEqual(self.store.run(second["id"], run["id"])["head_sha"], self.head)
        self.assertEqual(self.store.consolidation(second["id"])["generation"], 1)

    def test_restart_reconciles_terminal_session_without_duplicate_dispatch(self):
        reviewer = self.queue([PR_REVIEW_BUILTIN_ID])[0]
        self.agents.runs[reviewer["agent_run_id"]].update(status="completed", response="No findings.")
        self.runtime.agents = PRReviewAgents(self.runtime)
        self.runtime.agents.reconcile()
        combined = self.consolidator()
        self.assertEqual(len([call for call in self.agents.calls if call["_assistant"]["prReviewRunId"] == reviewer["id"]]), 1)
        self.assertEqual(combined["input_run_ids"], [reviewer["id"]])

    def test_missing_selected_copy_fails_without_ambient_skill_fallback(self):
        role = self.role()
        sid = "skill_" + "a" * 64
        self.roles.mutate({"action": "save", "role": {**role, "skillIds": [sid]}, "skillBundles": [skill_bundle(sid)], "expectedRevision": self.roles.overview()["revision"]})
        Path(self.roles.snapshot(role["id"])["skillPaths"][0]).unlink()
        run = self.runtime.start_agent_runs(self.review["id"], [role["id"]], "missing")[0]
        self.runtime.agents.reconcile()
        self.until(lambda: self.store.run(self.review["id"], run["id"])["state"] == "failed")
        self.assertEqual(len(self.agents.calls), 0)
        self.assertIn("selected review skill", self.store.run(self.review["id"], run["id"])["error"])

    def test_generated_reports_are_bound_and_included_in_consolidation_inputs(self):
        reviewer = self.queue([PR_REVIEW_BUILTIN_ID])[0]
        output = self.runtime._review_dir(self.review["id"]) / "runs" / reviewer["id"] / "output"
        (output / "full-review.md").write_text("## Finding\n\ngarden.py changes persistent behavior.")
        self.finish(reviewer, response="I saved my full report in the output directory.")
        member = self.store.run(self.review["id"], reviewer["id"])
        self.assertEqual(len(member["document_ids"]), 2)
        artifact = self.store.document(self.review["id"], member["document_ids"][1])
        self.assertEqual(artifact["origin"], "review-agent-artifact")
        self.assertEqual(artifact["run_id"], reviewer["id"])
        combined = self.consolidator()
        input_path = self.runtime._review_dir(self.review["id"]) / "runs" / combined["id"] / "inputs" / (reviewer["id"] + "-1.md")
        self.assertIn("persistent behavior", input_path.read_text())

    def test_output_root_symlink_does_not_import_unrelated_reports(self):
        reviewer = self.queue([PR_REVIEW_BUILTIN_ID])[0]
        output = self.runtime._review_dir(self.review["id"]) / "runs" / reviewer["id"] / "output"
        output.rmdir()
        unrelated = self.root / "unrelated"
        unrelated.mkdir()
        (unrelated / "unrelated.md").write_text("Not produced by this review.")
        output.symlink_to(unrelated, target_is_directory=True)
        self.finish(reviewer)
        member = self.store.run(self.review["id"], reviewer["id"])
        self.assertEqual(member["state"], "failed")
        self.assertEqual(len(member["document_ids"]), 1)
        self.assertFalse(any(document["filename"].endswith("unrelated.md") for document in self.store.documents(self.review["id"])))
        self.assertEqual(self.consolidator()["incomplete_run_ids"], [reviewer["id"]])

    def test_damaged_source_settles_failed_and_other_reviewers_still_finish(self):
        specialist = self.role()
        broken, healthy = self.queue([PR_REVIEW_BUILTIN_ID, specialist["id"]])
        source = self.runtime._review_dir(self.review["id"]) / "runs" / broken["id"] / "source"
        (source / ".git").unlink()
        self.agents.runs[broken["agent_run_id"]].update(status="completed", response="Partial report from damaged source.")
        self.finish(healthy)
        self.assertEqual(self.store.run(self.review["id"], broken["id"])["state"], "failed")
        self.assertEqual(self.store.run(self.review["id"], healthy["id"])["state"], "finished")
        self.assertEqual(self.consolidator()["incomplete_run_ids"], [broken["id"]])

    def test_interrupted_input_staging_recovers_read_only_files_before_dispatch(self):
        reviewer = self.queue([PR_REVIEW_BUILTIN_ID])[0]
        with mock.patch.object(self.runtime.agents, "schedule"):
            self.finish(reviewer)
        combined = next(run for run in self.store.runs_for_review(self.review["id"]) if run.get("kind") == "consolidator")
        role = self.store.agent_run_snapshot(self.review["id"], combined["id"])
        source = self.runtime.agents._source(role["reviewScope"], combined)
        output = source.parent / "output"
        output.mkdir(mode=0o700)
        self.runtime.agents._prompt(role["reviewScope"], combined, role, source, output)
        inputs = list((source.parent / "inputs").glob("*.md"))
        self.assertTrue(inputs)
        self.assertEqual(inputs[0].stat().st_mode & 0o777, 0o400)
        self.store.update_run(self.review["id"], combined["id"], state="running", launch="managed")
        self.store.update_agent_run_metadata(self.review["id"], combined["id"], agent_run_id="agr_" + combined["id"][5:], dispatch_complete=False)
        self.runtime.agents = PRReviewAgents(self.runtime)
        self.runtime.agents.reconcile()
        self.until(lambda: self.store.run(self.review["id"], combined["id"]).get("dispatch_complete"))
        self.assertEqual(self.store.run(self.review["id"], combined["id"])["state"], "running")
        self.assertEqual(len([call for call in self.agents.calls if call["_assistant"]["prReviewRunId"] == combined["id"]]), 1)

    def test_managed_capacity_queue_remains_queued_without_duplicate_dispatch(self):
        second, third = self.role("Architecture"), self.role("Quality")
        original_start = self.agents.start
        def start_with_capacity(**arguments):
            result = original_start(**arguments)
            if arguments["label"] == "Quality":
                result["run"]["status"] = "queued"
            return result
        self.agents.start = start_with_capacity
        runs = self.queue([PR_REVIEW_BUILTIN_ID, second["id"], third["id"]])
        waiting = next(run for run in runs if run["agent_id"] == third["id"])
        self.assertEqual(waiting["state"], "queued")
        self.assertIsNone(waiting["started_at"])
        self.runtime.agents.reconcile()
        self.assertEqual(len(self.agents.calls), 3)
        self.assertEqual(self.store.consolidation(self.review["id"])["state"], "waiting")
        self.agents.runs[waiting["agent_run_id"]].update(status="running", startedAt="2026-01-01T00:00:00Z")
        self.runtime.agents.reconcile()
        now_running = self.store.run(self.review["id"], waiting["id"])
        self.assertEqual(now_running["state"], "running")
        self.assertEqual(now_running["started_at"], "2026-01-01T00:00:00Z")
        self.assertEqual(len(self.agents.calls), 3)

    def test_creation_receipt_fences_an_empty_selection_and_survives_profile_deletion(self):
        with mock.patch.object(self.runtime, "_schedule_preparation"):
            no_runs = self.runtime.create_review("https://github.com/example-owner/garden/pull/43", "empty-selection", agent_ids=[])
            with self.assertRaises(PRReviewError) as caught:
                self.runtime.create_review(no_runs["url"], "empty-selection", agent_ids=[PR_REVIEW_BUILTIN_ID])
            self.assertEqual(caught.exception.code, "idempotency_conflict")
            role = self.role()
            selected = self.runtime.create_review("https://github.com/example-owner/garden/pull/44", "selected-review", agent_ids=[role["id"]])
            self.roles.mutate({"action": "delete", "roleId": role["id"], "expectedRevision": self.roles.overview()["revision"]})
            replay = self.runtime.create_review(selected["url"], "selected-review", agent_ids=[role["id"]])
            self.assertEqual(replay["id"], selected["id"])
            self.assertEqual(len(self.store.runs_for_review(selected["id"])), 1)


class ReviewerProfileTests(unittest.TestCase):
    def test_catalog_migration_validation_and_worker_separation(self):
        roles = AgentRoles(environ={})
        self.addCleanup(roles.close)
        state = roles._state()
        del state["roles"][PR_REVIEW_BUILTIN_ID]
        for role in state["roles"].values():
            for key in ("purpose", "reviewPrompt", "group", "avatar"):
                role.pop(key)
        roles._db.execute("UPDATE agent_roles SET payload=?", (json.dumps(state),))
        overview = roles.overview()
        default = roles.snapshot(PR_REVIEW_BUILTIN_ID)
        self.assertIn("pr-review-agents-v1", overview["capabilities"])
        self.assertEqual(default["reviewPrompt"], "")
        self.assertEqual(default["skillPaths"], [])
        self.assertNotIn(PR_REVIEW_BUILTIN_ID, {role["id"] for role in roles.delegation_catalog()})
        self.assertEqual(default["modelProfile"], "default")
        editable = {key: value for key, value in default.items() if key not in {"revision", "skillPaths", "missingSkillIds"}}
        for fields in ({"skillIds": None}, {"allowDelegation": True}, {"avatar": "arbitrary-symbol"}, {"modelProfile": "execution"}, {"purpose": "worker"}):
            with self.subTest(fields=fields), self.assertRaises(AgentRoleError):
                roles.mutate({"action": "save", "role": {**editable, **fields}, "expectedRevision": 0})

    def test_teams_are_saved_by_id_and_survive_renames(self):
        roles = AgentRoles(environ={})
        self.addCleanup(roles.close)
        team_id, other_id = str(uuid.uuid4()), str(uuid.uuid4())
        roles.mutate({"action": "saveTeam", "team": {"id": team_id, "name": " Sample team "}, "expectedRevision": 0})
        overview = roles.overview()
        self.assertIn("pr-review-teams-v1", overview["capabilities"])
        self.assertEqual(overview["teams"], [{"id": team_id, "name": "Sample team"}])
        reviewer = custom_role(name="Atlas", purpose="pr_review", modelProfile="default", teamId=team_id)
        roles.mutate({"action": "save", "role": reviewer, "expectedRevision": 1})
        self.assertEqual(roles.snapshot(reviewer["id"])["group"], "Sample team")
        # A second team with the same name would make the drop-down ambiguous.
        with self.assertRaises(AgentRoleError):
            roles.mutate({"action": "saveTeam", "team": {"id": other_id, "name": "sample TEAM"}, "expectedRevision": 2})
        roles.mutate({"action": "saveTeam", "team": {"id": team_id, "name": "Renamed team"}, "expectedRevision": 2})
        saved = next(role for role in roles.review_catalog() if role["id"] == reviewer["id"])
        self.assertEqual((saved["teamId"], saved["group"]), (team_id, "Renamed team"))
        roles.mutate({"action": "saveTeam", "team": {"id": other_id, "name": "Sample team"}, "expectedRevision": 3})
        self.assertEqual(roles.snapshot(reviewer["id"])["teamId"], team_id)
        roles.mutate({"action": "deleteTeam", "teamId": team_id, "expectedRevision": 4})
        saved = roles.snapshot(reviewer["id"])
        self.assertEqual((saved["teamId"], saved["group"]), ("", ""))
        self.assertEqual([team["id"] for team in roles.overview()["teams"]], [other_id])
        with self.assertRaises(AgentRoleError) as caught:
            roles.mutate({"action": "save", "role": {**reviewer, "teamId": team_id}, "expectedRevision": 5})
        self.assertEqual(caught.exception.status, 409)
        for body in ({"action": "saveTeam", "team": {"id": "not-a-uuid", "name": "Team"}},
                     {"action": "saveTeam", "team": {"id": str(uuid.uuid4()), "name": "One\nTwo"}},
                     {"action": "saveTeam", "team": {"id": str(uuid.uuid4()), "name": "  "}},
                     {"action": "saveTeam", "team": {"id": str(uuid.uuid4()), "name": "Team", "extra": True}},
                     {"action": "deleteTeam", "teamId": team_id}):
            with self.subTest(body=body), self.assertRaises(AgentRoleError):
                roles.mutate({**body, "expectedRevision": 5})
        self.assertEqual(roles.overview()["revision"], 5)

    def test_team_names_from_earlier_companions_migrate_to_stable_ids(self):
        roles = AgentRoles(environ={})
        self.addCleanup(roles.close)
        first = custom_role(name="Atlas", purpose="pr_review", modelProfile="default")
        second = custom_role(name="Beacon", purpose="pr_review", modelProfile="default")
        roles.mutate({"action": "save", "role": first, "expectedRevision": 0})
        roles.mutate({"action": "save", "role": second, "expectedRevision": 1})
        state = roles._state()
        del state["teams"]
        for role, name in ((state["roles"][first["id"]], "Sample team"), (state["roles"][second["id"]], "sample team")):
            role.pop("teamId")
            role["group"] = name
        roles._db.execute("UPDATE agent_roles SET payload=?", (json.dumps(state),))
        teams = roles.overview()["teams"]
        self.assertEqual(len(teams), 1)
        self.assertEqual(teams, roles.overview()["teams"])
        self.assertEqual({roles.snapshot(rid)["teamId"] for rid in (first["id"], second["id"])}, {teams[0]["id"]})
        # Older Mac clients send only the name; it resolves to the saved team or creates one.
        legacy = {key: value for key, value in roles.snapshot(first["id"]).items()
                  if key not in {"revision", "skillPaths", "missingSkillIds", "teamId"}}
        roles.mutate({"action": "save", "role": {**legacy, "reviewPrompt": "Edited"}, "expectedRevision": 2})
        self.assertEqual(roles.snapshot(first["id"])["teamId"], teams[0]["id"])
        roles.mutate({"action": "save", "role": {**legacy, "group": "Another team"}, "expectedRevision": 3})
        self.assertEqual([team["name"] for team in roles.overview()["teams"]], ["Another team", "Sample team"])
        roles.mutate({"action": "save", "role": {**legacy, "group": ""}, "expectedRevision": 4})
        self.assertEqual(roles.snapshot(first["id"])["teamId"], "")
        self.assertEqual(len(roles.overview()["teams"]), 2)

    def test_managed_session_keeps_strict_skills_default_model_and_dispatch_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pi = write_fake_pi(root)
            capture = root / "capture.json"
            skill = root / "skill" / "SKILL.md"
            skill.parent.mkdir()
            skill.write_text("---\nname: synthetic\ndescription: Synthetic review.\n---\n")
            manager = AgentRunManager(environ={"HERDR_HARNESS_AGENT_RUNS_ROOT": str(root / "agents"), "HERDR_HARNESS_AGENT_PI_BIN": "/synthetic/unavailable-pi", "HERDR_PR_REVIEW_PI_BIN": str(pi),
                "PATH": os.environ.get("PATH", ""), "FAKE_AGENT_CAPTURE": str(capture)}, herdr_socket_path="/synthetic/socket", herdr_session="synthetic")
            self.addCleanup(manager.stop)
            args = {"prompt": "Review synthetic input", "label": "Reviewer", "cwd": str(root), "topology": {}, "mode": "act",
                    "_assistant": {"profile": PR_REVIEW_AGENT_PROFILE, "prReviewRunId": "prun_abcdef123456", "retainSession": True,
                                   "reviewRoleSnapshot": {"skillPaths": [str(skill)], "missingSkillIds": []}}}
            first = manager.start(**args)["run"]
            second = manager.start(**args)["run"]
            self.assertEqual(first["id"], second["id"])
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline and manager.get(first["id"])["run"]["status"] in {"queued", "running"}:
                time.sleep(0.01)
            run = manager.get(first["id"])["run"]
            self.assertEqual(run["status"], "completed", run.get("error"))
            self.assertTrue(run["sessionFile"])
            argv = json.loads(capture.read_text())["argv"]
            self.assertIn("--no-skills", argv)
            self.assertEqual(argv[argv.index("--skill") + 1], str(skill))
            self.assertNotIn("--model", argv)
            self.assertNotIn("--thinking", argv)
            self.assertIn("--no-extensions", argv)
            self.assertNotIn("--extension", argv)
            self.assertNotIn("herdr-companion-awareness", json.loads(capture.read_text())["effectiveSystemPrompt"])
            with self.assertRaises(AgentRunError):
                manager.start(prompt="Continue", label="Changed", cwd=str(root), topology={}, continue_from_run_id=first["id"])
            with self.assertRaises(AgentRunError):
                manager.promotable(first["id"])
            manager.stop()
