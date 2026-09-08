"""Regression checks for ticket paths whose graph differs from display order."""

import copy
import tempfile
import unittest
from pathlib import Path

from herdr_harness.active_work import ActiveWorkError
from herdr_harness.active_work_store import ActiveWorkRepository
from herdr_harness.workflows import parse_workflow_config


class ActiveWorkDynamicReviewTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = ActiveWorkRepository(Path(temporary.name) / "work.sqlite3", environ={})
        self.addCleanup(self.repo.close)
        self.config = {
            "workflow": "garden-review", "version": 1, "title": "Garden review",
            "phases": [{"key": "work", "title": "Work"}],
            "stages": [
                {"key": "start", "title": "Start", "phase": "work", "next": ["code"]},
                {"key": "finish", "title": "Finish", "phase": "work", "next": []},
                {"key": "review", "title": "Review", "phase": "work", "checkpoint": "human", "next": ["finish", "code", "archive"]},
                {"key": "code", "title": "Code", "phase": "work", "next": ["review"]},
                {"key": "archive", "title": "Archive", "phase": "work", "next": []},
            ],
        }
        self.repo.apply_workflow(parse_workflow_config(self.config))
        self.item = self.repo.create_item({"title": "Garden path", "workflow": "garden-review"})

    def move(self, target, **fields):
        self.item = self.repo.transition(self.item["id"], {
            "expected_revision": self.item["revision"], "to_stage_key": target, **fields,
        })
        return self.item

    def enter_review(self):
        self.move("code")
        self.move("review")

    def test_unvisited_onward_edge_requires_approval_despite_lower_display_sequence(self):
        self.enter_review()
        revision = self.item["revision"]
        with self.assertRaises(ActiveWorkError) as caught:
            self.move("finish", note="Finish the reviewed work")
        self.assertEqual(caught.exception.code, "active_work_checkpoint_required")
        self.assertEqual(self.repo.item_projection(self.item["id"])["revision"], revision)
        self.move("review", checkpoint_state="approved")
        self.move("finish")
        review_visit = next(visit for visit in self.item["path"]["visits"] if visit["stage_key"] == "review")
        self.assertEqual(review_visit["outcome"], "complete")

    def test_revisit_requires_a_reason_and_is_rework_despite_higher_display_sequence(self):
        self.enter_review()
        with self.assertRaises(ActiveWorkError) as caught:
            self.move("code")
        self.assertEqual(caught.exception.code, "active_work_transition_note_required")
        self.move("code", note="Review requested clearer watering instructions")
        visits = self.item["path"]["visits"]
        self.assertEqual(len([visit for visit in visits if visit["stage_key"] == "code"]), 2)
        review_visit = next(visit for visit in visits if visit["stage_key"] == "review")
        self.assertEqual(review_visit["outcome"], "rework")

    def test_agent_cannot_approve_the_current_human_checkpoint(self):
        self.enter_review()
        with self.assertRaises(ActiveWorkError) as caught:
            self.repo.transition(self.item["id"], {
                "expected_revision": self.item["revision"], "to_stage_key": "review",
                "checkpoint_state": "approved", "note": "Review complete",
            }, actor="agent:reviewer")
        self.assertEqual(caught.exception.code, "active_work_checkpoint_required")

    def test_later_attempt_cannot_treat_previously_visited_onward_step_as_rework(self):
        stages = [
            {"key": "code", "title": "Code", "phase": "work", "next": ["review"]},
            {"key": "review", "title": "Review", "phase": "work", "checkpoint": "human", "next": ["code", "proof"]},
            {"key": "proof", "title": "Proof", "phase": "work", "checkpoint": "human", "next": ["code", "finish"]},
            {"key": "finish", "title": "Finish", "phase": "work", "next": []},
        ]
        config = {**self.config, "workflow": "garden-second-pass", "stages": stages}
        self.repo.apply_workflow(parse_workflow_config(config))
        self.item = self.repo.create_item({"title": "Garden second pass", "workflow": "garden-second-pass"})
        self.move("review")
        self.move("review", checkpoint_state="approved")
        self.move("proof")
        self.move("code", note="Proof found a missing watering timer")
        self.move("review", note="Review the timer fix")
        with self.assertRaises(ActiveWorkError) as caught:
            self.move("proof", note="Continue after review")
        self.assertEqual(caught.exception.code, "active_work_checkpoint_required")
        self.move("review", checkpoint_state="approved")
        self.move("proof", note="The second review passed")
        self.assertEqual(self.item["path"]["visits"][-2]["outcome"], "complete")

    def test_each_terminal_branch_can_complete_independent_of_display_position(self):
        for target in ("finish", "archive"):
            with self.subTest(target=target):
                self.item = self.repo.create_item({"title": "Garden branch", "workflow": "garden-review"})
                self.enter_review()
                self.move("review", checkpoint_state="approved")
                self.move(target)
                completed = self.repo.patch_item(self.item["id"], {
                    "expected_revision": self.item["revision"], "lifecycle": "done",
                })
                self.assertEqual(completed["lifecycle"], "done")
                self.assertEqual(completed["loop"]["status"], "done")

    def test_completed_import_uses_graph_terminal_when_last_displayed_step_is_not_terminal(self):
        config = {**self.config, "workflow": "garden-terminal-order", "stages": [
            {"key": "start", "title": "Start", "phase": "work", "next": ["review"]},
            {"key": "finish", "title": "Finish", "phase": "work", "next": []},
            {"key": "review", "title": "Review", "phase": "work", "next": ["start", "finish"]},
        ]}
        self.repo.apply_workflow(parse_workflow_config(config))
        for explicit in ({}, {"current_stage_key": "finish"}):
            with self.subTest(explicit=explicit):
                item = self.repo.create_item({
                    "title": "Completed garden", "workflow": "garden-terminal-order", "lifecycle": "done", **explicit,
                })
                self.assertEqual(item["current_stage_key"], "finish")
                self.assertEqual(item["path"]["available_next"], [])

    def test_forward_only_branches_enforce_their_edges_before_customization(self):
        config = {**self.config, "workflow": "garden-forward-branch", "stages": [
            {"key": "start", "title": "Start", "phase": "work", "next": ["choice"]},
            {"key": "choice", "title": "Choice", "phase": "work", "checkpoint": "human", "next": ["left", "right"]},
            {"key": "left", "title": "Left", "phase": "work", "next": ["finish"]},
            {"key": "right", "title": "Right", "phase": "work", "next": ["finish"]},
            {"key": "finish", "title": "Finish", "phase": "work", "next": []},
        ]}
        self.repo.apply_workflow(parse_workflow_config(config))
        self.item = self.repo.create_item({"title": "Choose a garden", "workflow": "garden-forward-branch"})
        self.assertEqual(self.item["path"]["mode"], "dynamic")
        with self.assertRaises(ActiveWorkError) as caught:
            self.move("finish")
        self.assertEqual(caught.exception.code, "active_work_invalid_transition")
        self.move("choice")
        with self.assertRaises(ActiveWorkError) as caught:
            self.move("left")
        self.assertEqual(caught.exception.code, "active_work_checkpoint_required")

    def test_api_path_changes_require_a_nonblank_reason(self):
        for note in (None, "", "  "):
            with self.subTest(note=note):
                payload = {"expected_revision": self.item["revision"], "stages": copy.deepcopy(self.config["stages"])}
                if note is not None:
                    payload["note"] = note
                with self.assertRaises(ActiveWorkError):
                    self.repo.update_path(self.item["id"], payload)
        self.assertEqual(self.repo.item_projection(self.item["id"])["revision"], self.item["revision"])


if __name__ == "__main__":
    unittest.main()
