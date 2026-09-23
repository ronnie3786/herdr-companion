"""CRUD, snapshot contract, stats and durability of the Code Factory ledger."""
from __future__ import annotations

import tempfile
import threading
import unittest
import sqlite3
from pathlib import Path

from herdr_harness.code_factory.errors import CodeFactoryError
from herdr_harness.code_factory.store import STAGE_LABELS, STAGE_ORDER, CodeFactoryStore

SNAPSHOT_KEYS = {"ok", "generatedAt", "stats", "issues", "releases", "daemon"}
ISSUE_KEYS = {
    "number", "title", "kind", "author", "url", "labels", "status", "stage", "stageLabel", "stageIndex",
    "attempts", "reviewRound", "ciFailures", "ciRerunRequested", "branch", "worktreePath", "worktreeCleaned", "prNumber", "prUrl", "headSha",
    "rebaseAttempts", "failureRetries",
    "ciStatus", "mergeSha", "releaseTag", "releaseVersion", "releaseUrl", "error", "blockedReason",
    "planSummary", "createdAt", "updatedAt", "claimedAt", "finishedAt", "sessions", "events",
}
STATS_KEYS = {"active", "blocked", "failed", "done", "skipped", "released", "worktreesPending"}
SESSION_KEYS = {"id", "role", "model", "thinking", "startedAt", "finishedAt", "exitCode", "costUSD", "summary"}
EVENT_KEYS = {"at", "stage", "kind", "message"}
RELEASE_KEYS = {"tag", "version", "channel", "status", "sourceSha", "url", "issueNumbers", "error", "startedAt", "finishedAt"}
DAEMON_KEYS = {"startedAt", "lastPollAt", "dashboardUrl", "version"}


class FakeClock:
    def __init__(self):
        self.tick = 0

    def __call__(self) -> str:
        self.tick += 1
        return f"2026-09-18T12:00:{self.tick:02d}Z"


class StoreTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "ledger" / "code-factory.sqlite3"
        self.clock = FakeClock()
        self.store = CodeFactoryStore(self.path, clock=self.clock)
        self.addCleanup(self.store.close)

    def issue(self, number=12, **extra):
        record = {
            "number": number, "title": "Crash when opening the HUD", "kind": "bug", "author": "your-username",
            "url": f"https://github.com/owner/repo/issues/{number}", "labels": ["bug", "herdr-autofix"],
        }
        record.update(extra)
        return self.store.upsert_issue(record)


class IssueTests(StoreTestCase):
    def test_upsert_inserts_with_defaults(self):
        issue = self.issue()
        self.assertEqual(issue["number"], 12)
        self.assertEqual(issue["status"], "active")
        self.assertEqual(issue["stage"], "intake")
        self.assertEqual(issue["stageLabel"], "Picked up")
        self.assertEqual(issue["stageIndex"], 0)
        self.assertEqual(issue["labels"], ["bug", "herdr-autofix"])
        self.assertEqual(issue["attempts"], 0)
        self.assertEqual(issue["reviewRound"], 0)
        self.assertEqual(issue["ciFailures"], 0)
        self.assertIsNone(issue["ciRerunRequested"])
        self.assertFalse(issue["worktreeCleaned"])
        self.assertIsNone(issue["prNumber"])
        self.assertIsNone(issue["planJson"])
        self.assertEqual(issue["createdAt"], issue["updatedAt"])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.store.schema_version, 1)

    def test_upsert_updates_existing_fields_only(self):
        first = self.issue()
        second = self.store.upsert_issue({"number": 12, "title": "Crash (renamed)", "stage": "plan"})
        self.assertEqual(second["title"], "Crash (renamed)")
        self.assertEqual(second["stage"], "plan")
        self.assertEqual(second["labels"], ["bug", "herdr-autofix"])
        self.assertEqual(second["createdAt"], first["createdAt"])
        self.assertGreater(second["updatedAt"], first["updatedAt"])

    def test_get_and_list(self):
        self.assertIsNone(self.store.get_issue(99))
        self.issue(1)
        self.issue(2, status="done", stage="done")
        self.issue(3)
        self.assertEqual([item["number"] for item in self.store.list_issues()], [3, 2, 1])
        self.assertEqual([item["number"] for item in self.store.list_issues(status="done")], [2])
        self.store.update_issue(1, title="Touched")
        self.assertEqual(self.store.list_issues()[0]["number"], 1)
        with self.assertRaises(CodeFactoryError):
            self.store.list_issues(status="weird")

    def test_update_accepts_camel_and_snake_case(self):
        self.issue()
        updated = self.store.update_issue(
            12, prNumber=34, pr_url="https://github.com/owner/repo/pull/34", headSha="abc123", ciStatus="success",
            worktreeCleaned=True, planJson={"summary": "Fix", "progress": {"t1": "done"}}, labels=["bug"],
            stage="review", reviewRound=1, ciFailures=2, ci_rerun_requested="abcdef1234", status="active", planSummary="Fix the crash",
        )
        self.assertEqual(updated["prNumber"], 34)
        self.assertEqual(updated["prUrl"], "https://github.com/owner/repo/pull/34")
        self.assertEqual(updated["headSha"], "abc123")
        self.assertEqual(updated["ciStatus"], "success")
        self.assertTrue(updated["worktreeCleaned"])
        self.assertEqual(updated["planJson"], {"summary": "Fix", "progress": {"t1": "done"}})
        self.assertEqual(updated["labels"], ["bug"])
        self.assertEqual(updated["stageLabel"], STAGE_LABELS["review"])
        self.assertEqual(updated["stageIndex"], STAGE_ORDER.index("review"))
        self.assertEqual(updated["reviewRound"], 1)
        self.assertEqual(updated["ciFailures"], 2)
        self.assertEqual(updated["ciRerunRequested"], "abcdef1234")
        self.assertEqual(self.store.get_issue(12)["planSummary"], "Fix the crash")

    def test_update_validation(self):
        self.issue()
        with self.assertRaises(CodeFactoryError) as caught:
            self.store.update_issue(99, title="x")
        self.assertEqual(caught.exception.code, "not_found")
        for fields in ({"bogus": 1}, {"status": "weird"}, {"stage": "nowhere"}, {"kind": "chore"},
                       {"prNumber": "34"}, {"worktreeCleaned": "yes"}, {"planJson": "text"}, {"attempts": -1},
                       {"ciFailures": -1}):
            with self.subTest(fields=fields), self.assertRaises(CodeFactoryError) as caught:
                self.store.update_issue(12, **fields)
            self.assertEqual(caught.exception.code, "invalid_request")
        with self.assertRaises(CodeFactoryError):
            self.store.upsert_issue({"number": 0})
        with self.assertRaises(CodeFactoryError):
            self.store.upsert_issue({"number": True})


class EventAndSessionTests(StoreTestCase):
    def test_events_are_newest_first_and_bounded(self):
        self.issue()
        before = self.store.get_issue(12)["updatedAt"]
        for index in range(5):
            event = self.store.add_event(12, "plan", "info", f"step {index}", {"index": index})
            self.assertEqual(event["issueNumber"], 12)
        events = self.store.list_events(12, limit=3)
        self.assertEqual([event["message"] for event in events], ["step 4", "step 3", "step 2"])
        self.assertEqual(events[0]["detail"], {"index": 4})
        self.assertEqual(events[0]["stage"], "plan")
        self.assertGreater(self.store.get_issue(12)["updatedAt"], before)
        with self.assertRaises(CodeFactoryError):
            self.store.add_event(12, "plan", "loud", "bad kind")
        with self.assertRaises(CodeFactoryError):
            self.store.add_event(12, "nowhere", "info", "bad stage")
        with self.assertRaises(CodeFactoryError):
            self.store.add_event(12, "plan", "info", "")
        with self.assertRaises(CodeFactoryError):
            self.store.add_event(12, "plan", "info", "detail", ["not", "a", "mapping"])

    def test_sessions_lifecycle(self):
        self.issue()
        session = self.store.add_session(
            "sess-1", 12, "planner", "openai-codex/gpt-6-astra", "xhigh", log_path="/tmp/synthetic/plan.log",
        )
        self.assertEqual(session["role"], "planner")
        self.assertIsNone(session["finishedAt"])
        self.assertIsNone(session["costUSD"])
        finished = self.store.finish_session("sess-1", 0, 0.125, "Planned 2 tasks", session_file="/tmp/synthetic/s.jsonl")
        self.assertEqual(finished["exitCode"], 0)
        self.assertAlmostEqual(finished["costUSD"], 0.125)
        self.assertEqual(finished["summary"], "Planned 2 tasks")
        self.assertEqual(finished["sessionFile"], "/tmp/synthetic/s.jsonl")
        self.assertIsNotNone(finished["finishedAt"])
        self.store.add_session("sess-2", 12, "implementer", "ollama-cloud/deepseek-v4.1-flash:cloud", "max")
        self.store.add_session("sess-r", None, "release_author", "ollama-cloud/deepseek-v4.1-flash:cloud", "max")
        self.assertEqual([item["id"] for item in self.store.list_sessions(12)], ["sess-1", "sess-2"])
        self.assertEqual([item["id"] for item in self.store.list_sessions(None)], ["sess-r"])
        with self.assertRaises(CodeFactoryError) as caught:
            self.store.finish_session("missing", 0, 0.0, None)
        self.assertEqual(caught.exception.code, "not_found")
        with self.assertRaises(CodeFactoryError):
            self.store.finish_session("sess-1", "zero", 0.0, None)


class ReleaseAndDaemonTests(StoreTestCase):
    def test_release_upsert_update_list(self):
        release = self.store.upsert_release("macos-v0.20.1-beta.1", version="0.20.1-beta.1", channel="preview",
                                            issueNumbers=[12, 13], sourceSha="abc")
        self.assertEqual(release["status"], "pending")
        self.assertEqual(release["issueNumbers"], [12, 13])
        self.assertIsNotNone(release["startedAt"])
        updated = self.store.update_release("macos-v0.20.1-beta.1", status="published",
                                            url="https://github.com/owner/repo/releases/tag/macos-v0.20.1-beta.1",
                                            finished_at="2026-09-18T13:00:00Z")
        self.assertEqual(updated["status"], "published")
        self.assertEqual(updated["finishedAt"], "2026-09-18T13:00:00Z")
        self.store.upsert_release("macos-v0.21.0-beta.1", version="0.21.0-beta.1", channel="preview", status="failed",
                                  error="notes missing")
        self.assertEqual([item["tag"] for item in self.store.list_releases()], ["macos-v0.21.0-beta.1", "macos-v0.20.1-beta.1"])
        self.assertEqual(self.store.get_release("macos-v0.21.0-beta.1")["error"], "notes missing")
        self.assertIsNone(self.store.get_release("nope"))
        with self.assertRaises(CodeFactoryError) as caught:
            self.store.update_release("nope", status="x")
        self.assertEqual(caught.exception.code, "not_found")
        with self.assertRaises(CodeFactoryError):
            self.store.upsert_release("tag", issueNumbers=["12"])
        with self.assertRaises(CodeFactoryError):
            self.store.upsert_release("tag", bogus="x")

    def test_daemon_info(self):
        info = self.store.daemon_info()
        self.assertEqual(info, {"startedAt": None, "lastPollAt": None, "dashboardUrl": None, "version": 1})
        self.store.set_daemon("started_at", "2026-09-18T12:00:00Z")
        self.store.set_daemon("dashboard_url", "http://127.0.0.1:9097/")
        self.store.set_daemon("last_poll_at", "2026-09-18T12:00:05Z")
        info = self.store.daemon_info()
        self.assertEqual(info["startedAt"], "2026-09-18T12:00:00Z")
        self.assertEqual(info["dashboardUrl"], "http://127.0.0.1:9097/")
        self.assertEqual(info["lastPollAt"], "2026-09-18T12:00:05Z")
        self.assertEqual(info["version"], 1)


class AggregateTests(StoreTestCase):
    def populate(self):
        self.issue(1, status="active", stage="review", worktreePath="/tmp/synthetic/wt-1")
        self.issue(2, status="blocked", stage="plan", blockedReason="human_question")
        self.issue(3, status="failed", stage="implement", error="boom", worktreePath="/tmp/synthetic/wt-3")
        self.issue(4, status="done", stage="done", releaseTag="macos-v0.20.1-beta.1", releaseVersion="0.20.1-beta.1",
                   worktreePath="/tmp/synthetic/wt-4", worktreeCleaned=True)
        self.issue(5, status="done", stage="done", releaseTag="macos-v0.20.1-beta.1")
        self.issue(6, status="done", stage="done")
        self.issue(7, status="skipped", stage="intake")

    def test_stats(self):
        self.populate()
        self.assertEqual(self.store.stats(), {
            "active": 1, "blocked": 1, "failed": 1, "done": 3, "skipped": 1, "released": 2, "worktreesPending": 2,
        })

    def test_snapshot_contract(self):
        self.populate()
        self.store.add_session("s1", 1, "planner", "openai-codex/gpt-6-astra", "xhigh")
        self.store.finish_session("s1", 0, 0.12, "ok")
        for index in range(25):
            self.store.add_event(1, "review", "info", f"event {index}")
        self.store.update_issue(1, planJson={"summary": "hidden from snapshot"})
        self.store.upsert_release("macos-v0.20.1-beta.1", version="0.20.1-beta.1", channel="preview", status="published",
                                  issueNumbers=[4, 5])
        self.store.set_daemon("dashboard_url", "http://127.0.0.1:9097/")

        snapshot = self.store.snapshot(events_per_issue=20)
        self.assertEqual(set(snapshot), SNAPSHOT_KEYS)
        self.assertIs(snapshot["ok"], True)
        self.assertTrue(snapshot["generatedAt"].endswith("Z"))
        self.assertEqual(set(snapshot["stats"]), STATS_KEYS)
        self.assertEqual(set(snapshot["daemon"]), DAEMON_KEYS)
        self.assertEqual(len(snapshot["issues"]), 7)
        first = next(item for item in snapshot["issues"] if item["number"] == 1)
        self.assertEqual(set(first), ISSUE_KEYS)
        self.assertEqual(first["stage"], "review")
        self.assertEqual(first["stageLabel"], "Reviewing (Astra)")
        self.assertEqual(first["stageIndex"], 6)
        self.assertEqual(len(first["events"]), 20)
        self.assertEqual(first["events"][0]["message"], "event 24")
        self.assertTrue(EVENT_KEYS <= set(first["events"][0]))
        self.assertEqual(len(first["sessions"]), 1)
        self.assertTrue(SESSION_KEYS <= set(first["sessions"][0]))
        self.assertEqual(first["sessions"][0]["costUSD"], 0.12)
        self.assertIsInstance(first["worktreeCleaned"], bool)
        for issue in snapshot["issues"]:
            self.assertEqual(set(issue), ISSUE_KEYS, issue["number"])
        self.assertEqual(len(snapshot["releases"]), 1)
        self.assertTrue(RELEASE_KEYS <= set(snapshot["releases"][0]))
        self.assertEqual(snapshot["releases"][0]["issueNumbers"], [4, 5])
        self.assertEqual(snapshot["daemon"]["dashboardUrl"], "http://127.0.0.1:9097/")
        self.assertEqual(self.store.snapshot(events_per_issue=0)["issues"][0]["events"], [])

    def test_issue_detail_includes_plan_and_all_events(self):
        self.issue(1)
        self.store.update_issue(1, planJson={"summary": "Fix"})
        for index in range(30):
            self.store.add_event(1, "implement", "info", f"e{index}")
        self.store.add_session("s1", 1, "implementer", "ollama-cloud/deepseek-v4.1-flash:cloud", "max")
        detail = self.store.issue_detail(1)
        self.assertEqual(detail["planJson"], {"summary": "Fix"})
        self.assertEqual(len(detail["events"]), 30)
        self.assertEqual(detail["events"][0]["message"], "e29")
        self.assertEqual(len(detail["sessions"]), 1)
        self.assertIsNone(self.store.issue_detail(404))


class DurabilityTests(StoreTestCase):
    def test_reopen_keeps_state(self):
        self.issue(12, stage="merge", mergeSha="abc")
        self.store.add_event(12, "merge", "success", "Merged")
        self.store.set_daemon("started_at", "2026-09-18T12:00:00Z")
        self.store.close()
        reopened = CodeFactoryStore(self.path)
        self.addCleanup(reopened.close)
        issue = reopened.get_issue(12)
        self.assertEqual(issue["mergeSha"], "abc")
        self.assertEqual(reopened.list_events(12)[0]["message"], "Merged")
        self.assertEqual(reopened.daemon_info()["startedAt"], "2026-09-18T12:00:00Z")
        self.assertEqual(reopened.schema_version, 1)

    def test_concurrent_writers(self):
        self.issue(12)
        errors: list[BaseException] = []

        def worker(index: int) -> None:
            try:
                for step in range(20):
                    self.store.add_event(12, "implement", "info", f"worker {index} step {step}")
                    self.store.update_issue(12, attempts=index)
            except BaseException as exc:  # pragma: no cover - surfaced through the assertion below
                errors.append(exc)

        threads = [threading.Thread(target=worker, args=(index,)) for index in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(errors, [])
        self.assertEqual(len(self.store.list_events(12, limit=500)), 80)

    def test_memory_store(self):
        store = CodeFactoryStore(":memory:")
        self.addCleanup(store.close)
        store.upsert_issue({"number": 1, "title": "x"})
        self.assertEqual(store.stats()["active"], 1)

    def test_reopen_migrates_legacy_issue_columns(self):
        legacy_path = Path(self.temp.name) / "legacy.sqlite3"
        legacy = sqlite3.connect(legacy_path)
        legacy.executescript("""
            CREATE TABLE issues(
             number INTEGER PRIMARY KEY, title TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT 'bug',
             author TEXT, url TEXT, labels_json TEXT NOT NULL DEFAULT '[]',
             status TEXT NOT NULL DEFAULT 'active', stage TEXT NOT NULL DEFAULT 'intake',
             attempts INTEGER NOT NULL DEFAULT 0, review_round INTEGER NOT NULL DEFAULT 0,
             branch TEXT, worktree_path TEXT, worktree_cleaned INTEGER NOT NULL DEFAULT 0,
             pr_number INTEGER, pr_url TEXT, head_sha TEXT, ci_status TEXT, merge_sha TEXT,
             release_tag TEXT, release_version TEXT, release_url TEXT, error TEXT, blocked_reason TEXT,
             plan_summary TEXT, plan_json TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
             claimed_at TEXT, finished_at TEXT);
        """)
        legacy.execute("INSERT INTO issues(number, title, created_at, updated_at) VALUES(?, ?, ?, ?)",
                       (12, "Legacy issue", "2026-09-18T12:00:00Z", "2026-09-18T12:00:00Z"))
        legacy.commit()
        legacy.close()
        migrated = CodeFactoryStore(legacy_path)
        self.addCleanup(migrated.close)
        updated = migrated.update_issue(12, ciFailures=1)
        self.assertEqual(updated["ciFailures"], 1)
        self.assertIsNone(updated["ciRerunRequested"])


if __name__ == "__main__":
    unittest.main()
