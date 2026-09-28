"""Synthetic repository receipts for exact workflow commit intervals."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from herdr_harness.first_mate_git_history import capture_baselines, capture_commits
from herdr_harness.first_mate_runtime import FirstMateRuntime
from herdr_harness.first_mate_store import FirstMateStore


class FirstMateGitHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git(str(self.repo), "init", "-b", "main")
        self.git(str(self.repo), "config", "user.name", "Synthetic Developer")
        self.git(str(self.repo), "config", "user.email", "developer@example.invalid")
        self.baseline = self.commit("baseline")
        self.store = FirstMateStore(self.root / "state.sqlite3")
        self.addCleanup(self.store.close)
        self.runtime = FirstMateRuntime(self.store, environ={}, runtime_root=self.root / "runtime")
        self.feature = self.store.create_feature({"title": "Synthetic work", "goal": "Build and review", "cwd": str(self.repo), "request_id": "feature"})
        self.human = self.store.claim_message(self.feature["id"], "coordinator")
        self.job = {"feature_id": self.feature["id"], "kind": "coordinator", "claim": self.human}

    def git(self, cwd, *args):
        return subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, text, path=None):
        path = path or self.repo
        (path / "source.txt").write_text(text)
        self.git(str(path), "add", "source.txt")
        self.git(str(path), "commit", "-m", text)
        return self.git(str(path), "rev-parse", "HEAD")

    def begin(self):
        return self.runtime._tool(self.job, "fm_begin_stage", {"stage_key": "build", "title": "Build"}, "begin")

    def assignment(self, visit, metadata=None):
        assignment = self.store.create_assignment(visit["id"], {"title": "Synthetic worker", "role": "coder", "prompt": "Build", "metadata": metadata or {}, "request_id": "worker"})
        claim = self.store.claim_assignment(assignment["id"], "worker")
        self.store.bind_session(assignment["id"], claim["generation"], "worker", "synthetic-session", str(self.root / "session.jsonl"))
        self.store.record_outcome(assignment["id"], claim["generation"], "synthetic-session", 1, "success", "Built", "outcome")
        return assignment

    def complete(self):
        with patch.object(self.runtime, "verification_assessment", return_value={"evidence_present": False}):
            return self.runtime._tool(self.job, "fm_complete_stage", {"summary": "Built", "recommendation": "Review"}, "complete")

    def test_stage_retains_every_commit_and_exact_prior_revision_across_restart(self):
        visit = self.begin()
        first = self.commit("first change")
        last = self.commit("second change")
        self.assignment(visit)
        result = self.complete()
        receipt = result["git_evidence"][0]
        self.assertEqual(receipt["workspace_id"], "project")
        self.assertEqual((receipt["start_sha"], receipt["end_sha"]), (self.baseline, last))
        self.assertEqual([c["sha"] for c in receipt["commits"]], [first, last])
        self.assertEqual(receipt["status"], "captured")
        self.commit("later unrelated change")
        self.assertEqual(self.complete()["git_evidence"], result["git_evidence"])
        reopened = FirstMateStore(self.root / "state.sqlite3")
        try:
            self.assertEqual(reopened.snapshot(self.feature["id"])["visits"][0]["git_evidence"], result["git_evidence"])
        finally:
            reopened.close()

    def test_new_assignment_uses_recorded_worktree_baseline_and_canonical_assignment_id(self):
        visit = self.begin()
        worktree = self.root / "worker"
        self.git(str(self.repo), "worktree", "add", "-b", "worker", str(worktree))
        first = self.commit("isolated first", worktree)
        last = self.commit("isolated last", worktree)
        assignment = self.assignment(visit, {"worktree_path": str(worktree), "base_revision": self.baseline})
        records = self.complete()["git_evidence"]
        evidence = next(row for row in records if row["workspace_id"] == assignment["id"])
        self.assertEqual([c["sha"] for c in evidence["commits"]], [first, last])
        self.assertEqual(records[0]["commits"], [])

    def test_target_baseline_precedes_workflow_start_and_survives_target_advancing(self):
        self.git(str(self.repo), "switch", "-c", "feature")
        existing = self.commit("feature work before workflow")
        visit = self.begin()
        baseline = visit["git_baselines"][0]
        self.assertEqual(baseline["start_sha"], existing)
        self.assertEqual(baseline["comparison_baseline_sha"], self.baseline)
        self.assertEqual(baseline["comparison_baseline_label"], "main")
        produced = self.commit("work produced by this step")
        self.git(str(self.repo), "update-ref", "refs/heads/main", produced)
        self.assignment(visit)
        evidence = self.complete()["git_evidence"][0]
        self.assertEqual(evidence["start_sha"], existing)
        self.assertEqual(evidence["comparison_baseline_sha"], self.baseline)
        self.assertEqual([commit["sha"] for commit in evidence["commits"]], [produced])
        next_baseline = capture_baselines(self.store.snapshot(self.feature["id"]), self.git)[0]
        self.assertEqual(next_baseline["start_sha"], produced)
        self.assertEqual(next_baseline["comparison_baseline_sha"], self.baseline)

    def test_new_assignment_freezes_target_baseline_separately_from_launch_revision(self):
        self.git(str(self.repo), "switch", "-c", "feature")
        existing = self.commit("existing feature change")
        visit = self.begin()
        self.git(str(self.repo), "update-ref", "refs/heads/main", existing)
        metadata = self.runtime._workspace(self.store.get_feature(self.feature["id"]),
                                           {"workspace_mode": "isolated"}, "isolated-plan")
        self.assertEqual(metadata["base_revision"], existing)
        self.assertEqual(metadata["comparison_baseline_sha"], self.baseline)
        worker_commit = self.commit("worker change", Path(metadata["worktree_path"]))
        self.git(str(self.repo), "update-ref", "refs/heads/main", worker_commit)
        replay = self.runtime._workspace(self.store.get_feature(self.feature["id"]),
                                         {"workspace_mode": "isolated"}, "isolated-plan")
        self.assertEqual(replay, metadata)
        assignment = self.assignment(visit, metadata)
        evidence = next(row for row in self.complete()["git_evidence"] if row["workspace_id"] == assignment["id"])
        self.assertEqual(evidence["start_sha"], existing)
        self.assertEqual(evidence["comparison_baseline_sha"], self.baseline)
        self.assertEqual([commit["sha"] for commit in evidence["commits"]], [worker_commit])

    def test_legacy_visit_does_not_adopt_current_history(self):
        visit = self.store.start_visit(self.feature["id"], "build", "Build", "legacy", 1, self.human["id"])
        self.commit("new change")
        self.assignment(visit, {"worktree_path": str(self.repo), "base_revision": self.baseline})
        evidence = self.complete()["git_evidence"][0]
        self.assertEqual(evidence["status"], "unavailable")
        self.assertIsNone(evidence["start_sha"])
        self.assertEqual(evidence["commits"], [])

    def test_selective_revision_retains_old_commits_and_starts_the_new_visit_at_the_same_tip(self):
        visit = self.begin()
        first = self.commit("first stage change")
        self.assignment(visit)
        self.store.finish_message(self.human["id"], "coordinator")
        self.store.append_human_message(self.feature["id"], "Revise the stage", "revise-human")
        self.job["claim"] = self.store.claim_message(self.feature["id"], "coordinator")
        with patch.object(self.runtime, "_save_job"), patch.object(self.runtime, "_quiesce", return_value=True):
            self.runtime._tool(self.job, "fm_revise", {"goal": "Build revised scope", "reason": "Human direction", "affected_assignment_ids": []}, "revise")
        visits = self.store.snapshot(self.feature["id"])["visits"]
        old = next(row for row in visits if row["id"] == visit["id"])
        new = next(row for row in visits if row["id"] != visit["id"])
        self.assertEqual(old["status"], "superseded")
        self.assertEqual([c["sha"] for c in old["git_evidence"][0]["commits"]], [first])
        self.assertEqual(new["git_baselines"][0]["start_sha"], first)
        second = self.commit("revised stage change")
        evidence = self.complete()["git_evidence"][0]
        self.assertEqual((evidence["start_sha"], evidence["end_sha"]), (first, second))
        self.assertEqual([c["sha"] for c in evidence["commits"]], [second])

    def test_rewritten_history_is_unavailable_instead_of_wrongly_attributed(self):
        self.commit("start of step")
        visit = self.begin()
        self.git(str(self.repo), "reset", "--hard", self.baseline)
        self.commit("rewritten step")
        self.assignment(visit)
        evidence = self.complete()["git_evidence"][0]
        self.assertEqual(evidence["status"], "unavailable")
        self.assertEqual(evidence["commits"], [])

    def test_shared_checkout_is_not_duplicated_and_missing_git_does_not_block_a_stage(self):
        snapshot = self.store.snapshot(self.feature["id"])
        snapshot["assignments"] = [{"id": "worker", "visit_id": "visit", "metadata": {"worktree_path": str(self.repo)}}]
        self.assertEqual(len(capture_baselines(snapshot, self.git)), 1)
        with patch.object(self.runtime, "_git", side_effect=OSError("Unavailable")):
            visit = self.begin()
        self.assertEqual(visit["git_baselines"], [{"workspace_id": "project", "start_sha": None}])
        records = capture_commits(snapshot, visit, self.git)
        self.assertEqual(records[0]["status"], "unavailable")


if __name__ == "__main__":
    unittest.main()
