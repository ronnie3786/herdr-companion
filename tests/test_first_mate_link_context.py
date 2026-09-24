"""PR relevance and lossless cleanup using entirely synthetic feature evidence."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from herdr_harness.first_mate_link_context import PullRequestContext, repository_names
from herdr_harness.first_mate_link_discovery import FirstMateLinkDiscovery
from herdr_harness.first_mate_store import FirstMateStore
import test_first_mate_link_discovery as discovery_tests

REPO = "synthetic-owner/synthetic-repo"
PR = "https://github.com/" + REPO + "/pull/42"
OTHER = "https://github.com/" + REPO + "/pull/99"


class PullRequestContextTests(unittest.TestCase):
    def context(self, title="SYN-123 Add image paste", goal="Implement the ticket"):
        return PullRequestContext(title, goal, frozenset({REPO}))

    def test_named_target_requires_its_repository_and_overrides_looser_matches(self):
        context = self.context(goal="Review PR #42 (SYN-123); background PR #99")
        self.assertEqual(context.qualify(PR), {})
        self.assertIsNone(context.qualify(PR.replace(REPO, "synthetic-owner/unrelated")))
        self.assertIsNone(context.qualify(OTHER, f"Opened PR {OTHER} for SYN-123"))
        self.assertIsNone(context.qualify(OTHER, matched_ticket="SYN-123"))

    def test_exact_target_url_works_without_local_git_and_canonicalizes(self):
        context = PullRequestContext("Review the change", "Review " + PR + "/files#diff-1", frozenset())
        self.assertEqual(context.qualify(PR), {})
        self.assertIsNone(context.qualify(OTHER))

    def test_structured_metadata_matches_each_pr_title_or_branch_not_body(self):
        context = self.context()
        cases = [
            ({"url": PR, "title": "SYN-123 Image paste"}, True),
            ({"url": PR, "headRefName": "feature/syn-123-image-paste"}, True),
            ({"url": PR, "body": "Opened for SYN-123"}, False),
            ({"url": PR, "title": "SYN-1234 Something else"}, False),
            ({"url": OTHER, "title": "SYN-123 Image paste"}, False),
            ({"url": PR, "title": "Other task", "body": f"Opened {PR} for SYN-123"}, False),
        ]
        for entry, expected in cases:
            with self.subTest(entry=entry):
                self.assertEqual(context.qualify(PR, json.dumps(entry)) is not None, expected)
        data = [{"url": OTHER, "title": "SYN-123 Image paste"}, {"url": PR, "title": "Other task"}]
        self.assertIsNone(context.qualify(PR, json.dumps(data)))

    def test_delivery_statement_must_be_unambiguous_and_about_current_ticket(self):
        context = self.context()
        self.assertEqual(context.qualify(PR, f"Opened PR {PR} for SYN-123."), {"matched_ticket": "SYN-123"})
        for text in (f"SYN-123 research links: {PR}", f"Previous PR opened for SYN-123: {PR}",
                     f"Opened {PR} for SYN-123; related {OTHER}", f"Opened {PR} for SYN-999",
                     f"Updated the SYN-123 checklist. Discussion: {PR}"):
            with self.subTest(text=text):
                self.assertIsNone(context.qualify(PR, text))
        self.assertIsNone(context.qualify(PR, f"Opened PR {PR} for SYN-123.", allow_prose=False))

    def test_primary_ticket_and_no_context_fail_closed(self):
        self.assertIsNone(self.context(goal="Dependency ticket DEP-456").qualify(PR, f"Opened {PR} for DEP-456"))
        self.assertIsNone(self.context(title="A feature", goal="Implement it").qualify(PR, f"Opened {PR} for SYN-123"))
        self.assertIsNone(PullRequestContext("SYN-123", "Implement", frozenset()).qualify(PR, matched_ticket="SYN-123"))

    def test_local_repository_lookup_is_bounded_and_never_uses_a_remote_command(self):
        with patch("subprocess.run", return_value=Mock(stdout=(
                "remote.origin.url git@github.com:Synthetic-Owner/Synthetic-Repo.git\n"
                "remote.upstream.url https://github.com/synthetic-owner/upstream.git/\n"
                "remote.other.url https://github.com.evil.test/owner/repo.git\n"))) as run:
            self.assertEqual(repository_names("/synthetic/checkout"), frozenset({REPO, "synthetic-owner/upstream"}))
        args, kwargs = run.call_args
        self.assertEqual(args[0], ["git", "-C", "/synthetic/checkout", "config", "--local", "--get-regexp", r"^remote\..*\.url$"])
        self.assertEqual(kwargs["timeout"], 2)
        with patch("subprocess.run", side_effect=subprocess.TimeoutExpired("git", 2)):
            self.assertEqual(repository_names("/synthetic/checkout"), frozenset())


class ContextualDiscoveryTests(unittest.TestCase):
    visit = discovery_tests.FirstMateLinkDiscoveryTests.visit
    add_session = discovery_tests.FirstMateLinkDiscoveryTests.add_session
    add_job = discovery_tests.FirstMateLinkDiscoveryTests.add_job

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.root = self.base / "runtime"
        self.store = FirstMateStore(self.base / "store.sqlite3")
        self.feature = self.store.create_feature({"title": "SYN-123 Image paste", "goal": "Review PR #42",
                                                 "cwd": str(self.base.resolve()), "request_id": "create"})
        self.discovery = FirstMateLinkDiscovery(self.store, root=self.root, minimum_interval=0)
        repositories = patch("herdr_harness.first_mate_link_discovery.repository_names", return_value=frozenset({REPO}))
        repositories.start()
        self.addCleanup(repositories.stop)

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def links(self):
        return {link["url"]: link for link in self.store.list_links(self.feature["id"])}

    def change_goal(self, goal):
        self.store._db.execute("UPDATE fm_features SET goal=? WHERE id=?", (goal, self.feature["id"]))

    def test_target_pr_survives_twenty_seven_background_references(self):
        background = [f"https://github.com/synthetic-owner/analytics/pull/{i}" for i in range(1, 28)]
        self.add_session("native-context", [("toolResult", "\n".join([PR] + background)),
                                             ("assistant", "Review complete: " + PR)])
        self.discovery.scan_once(force=True)
        self.assertEqual(set(self.links()), {PR})
        self.assertFalse(self.links()[PR]["hidden"])

    def test_ticket_metadata_is_local_to_one_pr_and_prose_tool_results_do_not_match(self):
        self.change_goal("Implement the ticket")
        metadata = [{"url": PR, "title": "SYN-123 Image paste"},
                    {"url": OTHER, "title": "Other work", "body": "SYN-123"}]
        self.add_session("native-metadata", [("toolResult", json.dumps(metadata)),
                                               ("toolResult", f"Opened {OTHER} for SYN-123")])
        self.discovery.scan_once(force=True)
        self.assertEqual(set(self.links()), {PR})
        self.assertEqual(self.links()[PR]["provenance"]["matched_ticket"], "SYN-123")
        # Reconciliation survives a restart even without a readable transcript.
        self.discovery = FirstMateLinkDiscovery(self.store, root=self.root, minimum_interval=0)
        self.discovery.scan_once(force=True)
        self.assertFalse(self.links()[PR]["hidden"])

    def test_accepted_documents_and_outcomes_use_the_same_context_gate(self):
        evidence = self.add_session("native-doc-context", [("user", "Review the feature")])
        self.store.record_outcome(evidence["assignment"]["id"], evidence["claim"]["generation"],
                                 "native-doc-context", 1, "success", "Review complete: " + PR, "outcome",
                                 documents=[{"title": "Research", "content": "Background: " + OTHER}])
        self.discovery.scan_once(force=True)
        self.assertEqual(set(self.links()), {PR})

    def test_legacy_cleanup_preserves_user_saves_restores_and_hidden_choices(self):
        target = self.store.register_link(self.feature["id"], url=PR, source="discovery")
        unrelated = self.store.register_link(self.feature["id"], url=OTHER, source="discovery")
        saved_url, restored_url, manual_url = [OTHER + str(i) for i in range(3)]
        for url in (saved_url, restored_url):
            self.store.register_link(self.feature["id"], url=url, source="discovery")
        self.store.save_link(self.feature["id"], {"url": saved_url, "request_id": "save-existing"})
        restored = self.links()[restored_url]
        self.store.set_link_visibility(self.feature["id"], restored["id"], {"hidden": False, "request_id": "restore-existing"})
        self.store.save_link(self.feature["id"], {"url": manual_url, "request_id": "save-new"})
        self.store.set_link_visibility(self.feature["id"], target["id"], {"hidden": True, "request_id": "hide-target"})
        # Recreate the pre-upgrade schema while retaining its user-action receipts.
        self.store._db.execute("ALTER TABLE fm_links DROP COLUMN discovery_state")
        self.store._db.execute("DELETE FROM fm_schema WHERE version=9")
        self.store.close()
        self.store = FirstMateStore(self.base / "store.sqlite3")
        self.discovery = FirstMateLinkDiscovery(self.store, root=self.root, minimum_interval=0)
        self.discovery.scan_once(force=True)
        links = self.links()
        self.assertEqual(len(links), 5)
        self.assertTrue(links[PR]["hidden"])
        self.assertTrue(links[OTHER]["hidden"])
        for url in (saved_url, restored_url, manual_url):
            self.assertFalse(links[url]["hidden"])
        # Restoring a filtered link is explicit and survives every later scan.
        self.store.set_link_visibility(self.feature["id"], unrelated["id"], {"hidden": False, "request_id": "restore-filtered"})
        self.discovery.scan_once(force=True)
        self.assertFalse(self.links()[OTHER]["hidden"])
        self.assertEqual(links[OTHER]["id"], unrelated["id"])

    def test_changed_target_hides_old_auto_link_without_deleting_it(self):
        self.add_session("native-changed", [("assistant", "Review " + PR)])
        self.discovery.scan_once(force=True)
        self.change_goal("Review PR #99")
        self.discovery.scan_once(force=True)
        self.assertTrue(self.links()[PR]["hidden"])
        self.change_goal("Review PR #42")
        self.discovery.scan_once(force=True)
        self.assertFalse(self.links()[PR]["hidden"])

    def test_cursor_upgrade_rechecks_evidence_and_cleanup_is_idempotent(self):
        self.add_session("native-upgrade", [("assistant", "Review " + PR)])
        self.discovery.scan_once(force=True)
        state = json.loads(self.discovery.cursor_path.read_text())
        state["version"] = 2
        self.discovery.cursor_path.write_text(json.dumps(state))
        result = self.discovery.scan_once(force=True)
        self.assertGreater(result["saved"], 0)
        before = self.store.get_events(self.feature["id"])
        self.discovery.scan_once(force=True)
        self.assertEqual(before, self.store.get_events(self.feature["id"]))
        self.assertEqual(json.loads(self.discovery.cursor_path.read_text())["version"], 3)


if __name__ == "__main__":
    unittest.main()
