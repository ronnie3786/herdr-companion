"""``herdr-code-factory`` subcommands with a fake process runner, a fake pipeline and a temp ledger."""
from __future__ import annotations

import contextlib
import fcntl
import io
import json
import socket
import tempfile
import threading
import time
import unittest
import urllib.request
from pathlib import Path
from types import SimpleNamespace

from herdr_harness.code_factory import cli
from herdr_harness.code_factory.dashboard import DashboardServer
from herdr_harness.code_factory.store import CodeFactoryStore

REPO = "owner/repo"
GIB = 1024 ** 3


class ScriptedRunner:
    """Answers subprocess calls by argv prefix; unknown commands succeed silently."""

    def __init__(self):
        self.calls: list[dict] = []
        self.scripts: list[tuple[tuple[str, ...], dict]] = []

    def on(self, *prefix: str, stdout: str = "", returncode: int = 0, stderr: str = "", raise_error: BaseException | None = None):
        self.scripts.append((prefix, {"stdout": stdout, "returncode": returncode, "stderr": stderr, "raise": raise_error}))
        return self

    def __call__(self, argv, **kwargs):
        argv = [str(item) for item in argv]
        self.calls.append({"argv": argv, **kwargs})
        for prefix, reply in reversed(self.scripts):
            if tuple(argv[:len(prefix)]) == prefix:
                if reply["raise"] is not None:
                    raise reply["raise"]
                return SimpleNamespace(returncode=reply["returncode"], stdout=reply["stdout"], stderr=reply["stderr"])
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    def argv_with(self, *prefix: str) -> list[list[str]]:
        return [call["argv"] for call in self.calls if tuple(call["argv"][:len(prefix)]) == prefix]


class FakeFactory:
    """Mimics the pipeline's public surface: ``action`` updates the ledger the way the real one does."""

    def __init__(self):
        self.calls: list[tuple] = []
        self.store: CodeFactoryStore | None = None
        self.release_result: dict = {"ok": True, "tag": "macos-v0.20.1-beta.1", "issues": [13]}

    def start(self):
        self.calls.append(("start",))

    def stop(self, *, wait=False, timeout=None):
        self.calls.append(("stop",))

    def wait_idle(self, timeout=None):
        return True

    def poll_once(self):
        self.calls.append(("poll_once",))
        return {"discovered": 1, "dispatched": 1}

    def run_issue(self, number):
        self.calls.append(("run_issue", number))

    def run_release_batch(self):
        self.calls.append(("run_release_batch",))
        return self.release_result

    def action(self, number, action):
        self.calls.append(("action", number, action))
        if number is None:
            return {"ok": True, "action": action, "issue": None, "releaseStarted": True}
        queued = False
        if self.store is not None:
            issue = self.store.get_issue(number)
            if action == "retry":
                self.store.update_issue(number, status="active", error=None, blockedReason=None)
                queued = issue is not None and issue["stage"] == "release"  # a release retry runs the batch itself
            elif action == "skip":
                self.store.update_issue(number, status="skipped")
        return {"ok": True, "action": action, "issue": {"number": number}, "queued": queued}


class LingeringFactory(FakeFactory):
    """``stop()`` leaves a worker that writes to the ledger shortly afterwards (a stage finishing its step)."""

    def __init__(self):
        super().__init__()
        self.outcome: dict = {}
        self.worker: threading.Thread | None = None

    def stop(self, *, wait=False, timeout=None):
        self.calls.append(("stop", wait))

        def finish_step():
            time.sleep(0.3)
            try:
                assert self.store is not None
                self.store.set_daemon("last_poll_at", "2026-09-18T12:34:56Z")
                self.outcome["written"] = True
            except Exception as exc:  # pragma: no cover - the assertion below reports it
                self.outcome["error"] = repr(exc)

        self.worker = threading.Thread(target=finish_step, name="lingering-stage")
        self.worker.start()
        if wait:
            self.worker.join(timeout)

    def wait_idle(self, timeout=None):
        if self.worker is None:
            return True
        self.worker.join(timeout)
        return not self.worker.is_alive()


class CliTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.state = self.root / "state"
        self.checkout = self.root / "checkout"
        (self.checkout / ".git").mkdir(parents=True)
        self.config = self.root / "config.toml"
        self.write_config("version = 1\n\n[deployment.macos_release]\nsigning_mode = \"developer-id\"\n")
        self.runner = ScriptedRunner()
        self.runner.on("git", "-C", str(self.checkout), "remote", "get-url", "origin", stdout="https://github.com/owner/repo.git\n")
        self.factory = FakeFactory()
        self.builders: list[dict] = []
        self.dashboards: list[dict] = []
        self.out = io.StringIO()
        self.err = io.StringIO()
        self.deps = cli.Dependencies(
            runner=self.runner,
            popen=self._forbidden_popen,
            factory_builder=self._build_factory,
            disk_usage=lambda path: SimpleNamespace(total=100 * GIB, used=50 * GIB, free=50 * GIB),
            stdout=self.out,
            stderr=self.err,
            wait=lambda: None,
        )
        self.environ = {
            "HOME": str(self.home),
            "PATH": "/usr/bin",
            "HERDR_STATE_DIR": str(self.state),
            "HERDR_CODE_FACTORY_REPOSITORY": REPO,
            "HERDR_CODE_FACTORY_CHECKOUT": str(self.checkout),
            "HERDR_CODE_FACTORY_DASHBOARD_HOST": "127.0.0.1",
            "OLLAMA_API_KEY": "provider-secret",
        }

    def _forbidden_popen(self, *args, **kwargs):  # pragma: no cover - guards against launching pi
        raise AssertionError("the CLI tests must never launch pi")

    def _build_factory(self, settings, store, *, github, git, pi, log):
        self.builders.append({"settings": settings, "store": store, "github": github, "git": git, "pi": pi})
        self.factory.store = store
        return self.factory

    def _build_dashboard(self, store, factory, *, host, port, token, settings, log, allowed_hosts=()):
        """Bind an ephemeral loopback port whatever the configured host says (no port races in tests)."""
        server = DashboardServer(store, factory, host="127.0.0.1", port=0, token=token, settings=settings, log=log,
                                 allowed_hosts=allowed_hosts)
        self.dashboards.append({"host": host, "port": port, "server": server, "allowed_hosts": tuple(allowed_hosts)})
        return server

    def write_config(self, text: str) -> None:
        self.config.write_text(text)
        self.config.chmod(0o600)

    def run_cli(self, *argv: str, environ: dict | None = None) -> int:
        with contextlib.redirect_stderr(self.err):
            return cli.main(["--config", str(self.config), *argv], environ=environ or self.environ, deps=self.deps)

    def output(self):
        return json.loads(self.out.getvalue())

    def reset_output(self):
        self.out.truncate(0)
        self.out.seek(0)

    def open_store(self) -> CodeFactoryStore:
        return CodeFactoryStore(self.state / "code-factory" / "code-factory.sqlite3")

    def daemon_info(self) -> dict:
        store = self.open_store()
        try:
            return store.daemon_info()
        finally:
            store.close()

    def seed_issue(self, number=12, **extra):
        store = self.open_store()
        try:
            record = {
                "number": number, "title": "Crash when opening the HUD", "kind": "bug", "author": "your-username",
                "url": f"https://github.com/owner/repo/issues/{number}", "labels": ["bug", "herdr-autofix"],
            }
            record.update(extra)
            return store.upsert_issue(record)
        finally:
            store.close()

    def hold_daemon_lock(self, pid=4242, command="run"):
        """Take the daemon lock the way another ``herdr-code-factory`` process would."""
        path = self.state / "code-factory" / cli.DAEMON_LOCK_NAME
        path.parent.mkdir(parents=True, exist_ok=True)
        handle = open(path, "w", encoding="utf-8")
        self.addCleanup(handle.close)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        handle.write(json.dumps({"pid": pid, "command": command, "startedAt": "2026-09-18T12:00:00Z"}))
        handle.flush()
        return handle

    def lock_is_free(self) -> bool:
        path = self.state / "code-factory" / cli.DAEMON_LOCK_NAME
        if not path.exists():
            return True
        with open(path, "r+", encoding="utf-8") as handle:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return False
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            return True


class ArgumentTests(CliTestCase):
    def test_missing_command_is_a_usage_error(self):
        self.assertEqual(self.run_cli(), 2)
        self.assertIn("usage:", self.err.getvalue())

    def test_unknown_command_and_bad_action_are_usage_errors(self):
        self.assertEqual(self.run_cli("bogus"), 2)
        self.assertEqual(self.run_cli("action", "12", "explode"), 2)
        self.assertEqual(self.run_cli("action", "zero", "retry"), 2)
        self.assertEqual(self.run_cli("enqueue", "-3"), 2)
        self.assertEqual(self.run_cli("status", "--issue", "0"), 2)
        self.assertEqual(self.factory.calls, [])

    def test_help_exits_zero(self):
        with contextlib.redirect_stdout(self.out):
            self.assertEqual(self.run_cli("--help"), 0)
        self.assertIn("herdr-code-factory", self.out.getvalue())

    def test_missing_repository_is_a_configuration_error(self):
        environ = dict(self.environ)
        del environ["HERDR_CODE_FACTORY_REPOSITORY"]
        self.assertEqual(self.run_cli("status", environ=environ), 2)
        self.assertIn("code_factory.repository", self.err.getvalue())

    def test_unreadable_configuration_is_reported(self):
        self.assertEqual(cli.main(["--config", str(self.root / "missing.toml"), "status"], environ=self.environ, deps=self.deps), 2)
        self.assertIn("error:", self.err.getvalue())

    def test_missing_checkout_fails_commands_that_need_it(self):
        environ = dict(self.environ)
        del environ["HERDR_CODE_FACTORY_CHECKOUT"]
        self.assertEqual(self.run_cli("once", environ=environ), 1)
        self.assertIn("code_factory.checkout", self.err.getvalue())
        self.assertEqual(self.factory.calls, [])


class StatusTests(CliTestCase):
    def test_status_prints_the_snapshot(self):
        self.seed_issue(12, stage="review", prNumber=34)
        self.assertEqual(self.run_cli("status"), 0)
        snapshot = self.output()
        self.assertTrue(snapshot["ok"])
        self.assertEqual(snapshot["stats"]["active"], 1)
        self.assertEqual(snapshot["issues"][0]["number"], 12)
        self.assertEqual(snapshot["issues"][0]["stageLabel"], "Reviewing (Astra)")
        self.assertNotIn("planJson", snapshot["issues"][0])
        self.assertEqual(self.builders, [])

    def test_status_issue_detail_and_unknown(self):
        self.seed_issue(12)
        self.assertEqual(self.run_cli("status", "--issue", "12"), 0)
        detail = self.output()
        self.assertEqual(detail["number"], 12)
        self.assertIn("events", detail)
        self.assertEqual(self.run_cli("status", "--issue", "99"), 1)
        self.assertIn("#99 is not tracked", self.err.getvalue())

    def test_status_works_without_a_checkout(self):
        environ = dict(self.environ)
        del environ["HERDR_CODE_FACTORY_CHECKOUT"]
        self.assertEqual(self.run_cli("status", environ=environ), 0)
        self.assertEqual(self.output()["issues"], [])

    def test_status_does_not_need_the_daemon_lock(self):
        self.hold_daemon_lock()
        self.assertEqual(self.run_cli("status"), 0)
        self.assertTrue(self.output()["ok"])


class OnceTests(CliTestCase):
    def test_once_polls_then_runs_each_runnable_issue_and_the_release_batch(self):
        self.seed_issue(12, stage="plan")
        self.seed_issue(13, stage="release")
        self.seed_issue(14, status="blocked", stage="implement")
        self.seed_issue(15, status="done", stage="done")
        self.assertEqual(self.run_cli("once"), 0)
        self.assertEqual(self.factory.calls, [("poll_once",), ("run_issue", 12), ("run_release_batch",)])
        payload = self.output()
        self.assertEqual(payload["poll"], {"discovered": 1, "dispatched": 1})
        self.assertEqual(payload["processed"], [12])
        self.assertTrue(payload["releaseBatch"])
        self.assertEqual(payload["release"]["tag"], "macos-v0.20.1-beta.1")
        self.assertEqual(payload["errors"], [])
        built = self.builders[0]
        self.assertEqual(built["settings"].repository, REPO)
        self.assertEqual(built["github"].repository, REPO)
        self.assertEqual(built["git"].checkout, self.checkout)
        self.assertEqual(built["pi"].binary, "pi")
        self.assertTrue(self.lock_is_free(), "the daemon lock is released when the command finishes")

    def test_once_skips_the_release_batch_when_releases_are_disabled(self):
        self.seed_issue(13, stage="release")
        environ = dict(self.environ, HERDR_CODE_FACTORY_RELEASE_ENABLED="false")
        self.assertEqual(self.run_cli("once", environ=environ), 0)
        self.assertEqual(self.factory.calls, [("poll_once",)])
        self.assertFalse(self.output()["releaseBatch"])
        self.assertIsNone(self.output()["release"])

    def test_once_reports_a_failed_release_batch(self):
        self.seed_issue(13, stage="release")
        self.factory.release_result = {"ok": False, "tag": "macos-v0.20.1-beta.1",
                                       "error": "prepare failed: no signing identity", "issues": [13]}
        self.assertEqual(self.run_cli("once"), 1)
        payload = self.output()
        self.assertFalse(payload["ok"])
        self.assertTrue(payload["releaseBatch"])
        self.assertEqual(payload["release"]["error"], "prepare failed: no signing identity")
        self.assertEqual(payload["errors"], [{"release": True, "error": "prepare failed: no signing identity",
                                              "code": "release_failed", "tag": "macos-v0.20.1-beta.1"}])
        self.reset_output()
        self.factory.release_result = {"ok": False, "reason": "release_disabled", "issues": [13]}
        self.assertEqual(self.run_cli("once"), 1)
        self.assertIn("release_disabled", self.output()["errors"][0]["error"])

    def test_once_refuses_while_the_daemon_is_running(self):
        self.seed_issue(12, stage="implement")
        self.hold_daemon_lock(pid=4242, command="run")
        self.assertEqual(self.run_cli("once"), 1)
        message = self.err.getvalue()
        self.assertIn("error: another herdr-code-factory process is running (pid 4242, command run)", message)
        self.assertIn("running once", message)
        self.assertEqual(self.factory.calls, [])


class EnqueueTests(CliTestCase):
    def issue_reply(self, state="OPEN", labels=("enhancement", "herdr-app-report")):
        return json.dumps({
            "number": 21, "title": "Add a dark mode toggle", "body": "please", "state": state,
            "author": {"login": "your-username"}, "labels": [{"name": name} for name in labels],
            "url": "https://github.com/owner/repo/issues/21", "createdAt": "2026-09-18T10:00:00Z",
            "updatedAt": "2026-09-18T10:00:00Z",
        })

    def test_enqueue_tracks_and_processes_an_open_issue(self):
        self.runner.on("gh", "issue", "view", "21", stdout=self.issue_reply())
        self.assertEqual(self.run_cli("enqueue", "21"), 0)
        payload = self.output()
        self.assertTrue(payload["processed"])
        self.assertEqual(payload["issue"]["kind"], "feature")
        self.assertEqual(payload["issue"]["author"], "your-username")
        self.assertEqual(payload["issue"]["labels"], ["enhancement", "herdr-app-report"])
        self.assertEqual(self.factory.calls, [("run_issue", 21)])
        view = self.runner.argv_with("gh", "issue", "view")[0]
        self.assertEqual(view[:6], ["gh", "issue", "view", "21", "--repo", REPO])
        store = self.open_store()
        try:
            events = store.list_events(21)
        finally:
            store.close()
        self.assertEqual(events[0]["message"], "Enqueued manually with herdr-code-factory enqueue")

    def test_queue_only_records_without_processing(self):
        self.runner.on("gh", "issue", "view", "21", stdout=self.issue_reply(labels=("bug",)))
        self.assertEqual(self.run_cli("enqueue", "21", "--queue-only"), 0)
        payload = self.output()
        self.assertFalse(payload["processed"])
        self.assertEqual(payload["issue"]["kind"], "bug")
        self.assertEqual(self.factory.calls, [])

    def test_closed_issues_are_refused(self):
        self.runner.on("gh", "issue", "view", "21", stdout=self.issue_reply(state="CLOSED"))
        self.assertEqual(self.run_cli("enqueue", "21"), 1)
        self.assertIn("only open issues", self.err.getvalue())
        self.assertEqual(self.factory.calls, [])

    def test_enqueue_reactivates_a_failed_issue_but_not_a_done_one(self):
        self.seed_issue(21, status="failed", stage="implement", error="pi exited with status 1")
        self.runner.on("gh", "issue", "view", "21", stdout=self.issue_reply())
        self.assertEqual(self.run_cli("enqueue", "21", "--queue-only"), 0)
        issue = self.output()["issue"]
        self.assertEqual(issue["status"], "active")
        self.assertEqual(issue["stage"], "implement")
        self.assertIsNone(issue["error"])
        self.seed_issue(21, status="done", stage="done")
        self.reset_output()
        self.assertEqual(self.run_cli("enqueue", "21", "--queue-only"), 1)
        self.assertIn("already done", self.err.getvalue())

    def test_enqueue_processes_an_already_active_issue_when_no_daemon_runs(self):
        self.seed_issue(21, status="active", stage="implement")
        self.runner.on("gh", "issue", "view", "21", stdout=self.issue_reply())
        self.assertEqual(self.run_cli("enqueue", "21"), 0)
        self.assertEqual(self.factory.calls, [("run_issue", 21)])
        self.assertEqual(self.output()["issue"]["stage"], "implement")

    def test_enqueue_restarts_a_skipped_issue_whose_worktree_is_gone(self):
        plan = {"summary": "Guard the nil window", "risk": "low", "needs_human": False, "human_question": None,
                "tasks": [{"id": "t1", "title": "Guard nil"}, {"id": "t2", "title": "Add a test"}],
                "progress": {"t1": {"done": True, "sha": "abc123", "summary": "guarded"}}}
        self.seed_issue(21, status="skipped", stage="implement", branch="codefactory/issue-21",
                        worktreePath=str(self.root / "worktrees" / "issue-21"), worktreeCleaned=True, planJson=plan,
                        finishedAt="2026-09-18T11:00:00Z", headSha="abc123", ciStatus="pending")
        self.runner.on("gh", "issue", "view", "21", stdout=self.issue_reply())
        self.assertEqual(self.run_cli("enqueue", "21", "--queue-only"), 0)
        issue = self.output()["issue"]
        self.assertEqual(issue["status"], "active")
        self.assertEqual(issue["stage"], "implement")
        self.assertNotIn("progress", issue["planJson"])
        self.assertEqual([task["id"] for task in issue["planJson"]["tasks"]], ["t1", "t2"])
        self.assertIsNone(issue["finishedAt"])
        self.assertIsNone(issue["headSha"])
        self.assertIsNone(issue["ciStatus"])
        self.assertTrue(issue["worktreeCleaned"], "the worktree is recreated by the pipeline, not the CLI")
        store = self.open_store()
        try:
            messages = [event["message"] for event in store.list_events(21)]
        finally:
            store.close()
        self.assertIn("Re-enqueued after the worktree was removed; implementation restarts from the saved plan", messages)

    def test_enqueue_of_a_skipped_issue_without_an_accepted_plan_restarts_from_the_worktree(self):
        plan = {"summary": "?", "needs_human": True, "human_question": "Which window?", "tasks": [], "progress": {}}
        self.seed_issue(21, status="skipped", stage="plan", worktreePath=str(self.root / "w21"), worktreeCleaned=True,
                        planJson=plan, finishedAt="2026-09-18T11:00:00Z")
        self.runner.on("gh", "issue", "view", "21", stdout=self.issue_reply())
        self.assertEqual(self.run_cli("enqueue", "21", "--queue-only"), 0)
        issue = self.output()["issue"]
        self.assertEqual(issue["stage"], "worktree")
        self.assertIsNone(issue["planJson"])
        self.assertIsNone(issue["finishedAt"])

    def test_enqueue_leaves_issues_alone_when_the_worktree_still_exists(self):
        self.seed_issue(21, status="blocked", stage="review", worktreePath=str(self.root / "w21"), worktreeCleaned=False,
                        prNumber=34, planJson={"tasks": [{"id": "t1"}], "progress": {"t1": {"done": True}}})
        self.runner.on("gh", "issue", "view", "21", stdout=self.issue_reply())
        self.assertEqual(self.run_cli("enqueue", "21", "--queue-only"), 0)
        issue = self.output()["issue"]
        self.assertEqual(issue["stage"], "review")
        self.assertEqual(issue["planJson"]["progress"], {"t1": {"done": True}})

    def test_enqueue_refuses_a_skipped_issue_that_already_has_a_pull_request(self):
        self.seed_issue(21, status="skipped", stage="review", worktreePath=str(self.root / "w21"), worktreeCleaned=True,
                        prNumber=34, planJson={"tasks": [{"id": "t1"}], "progress": {}})
        self.runner.on("gh", "issue", "view", "21", stdout=self.issue_reply())
        self.assertEqual(self.run_cli("enqueue", "21", "--queue-only"), 1)
        self.assertIn("PR #34", self.err.getvalue())
        self.assertEqual(self.factory.calls, [])
        store = self.open_store()
        try:
            self.assertEqual(store.get_issue(21)["status"], "skipped")
        finally:
            store.close()

    def test_enqueue_refuses_to_process_while_the_daemon_is_running_but_can_queue(self):
        self.runner.on("gh", "issue", "view", "21", stdout=self.issue_reply())
        self.hold_daemon_lock(pid=4242, command="run")
        self.assertEqual(self.run_cli("enqueue", "21"), 1)
        self.assertIn("pid 4242", self.err.getvalue())
        self.assertIn("--queue-only", self.err.getvalue())
        self.assertEqual(self.factory.calls, [])
        self.assertEqual(self.runner.argv_with("gh", "issue", "view"), [])
        self.assertEqual(self.run_cli("enqueue", "21", "--queue-only"), 0)
        self.assertFalse(self.output()["processed"])

    def test_gh_failure_is_reported(self):
        self.runner.on("gh", "issue", "view", "21", returncode=1, stderr="GraphQL: Could not resolve to an Issue")
        self.assertEqual(self.run_cli("enqueue", "21"), 1)
        self.assertIn("Could not resolve", self.err.getvalue())


class ActionTests(CliTestCase):
    def test_action_routes_to_the_factory(self):
        self.seed_issue(12, status="blocked", stage="plan")
        for action in ("retry", "skip", "cleanup"):
            self.reset_output()
            self.assertEqual(self.run_cli("action", "12", action), 0)
            self.assertEqual(self.output()["action"], action)
            self.assertEqual(self.output()["issue"]["number"], 12)
        self.assertEqual(self.factory.calls, [("action", 12, "retry"), ("run_issue", 12), ("action", 12, "skip"),
                                              ("action", 12, "cleanup")])

    def test_action_retry_processes_the_issue_inline(self):
        self.seed_issue(12, status="failed", stage="implement", error="pi exited with status 1")
        self.assertEqual(self.run_cli("action", "12", "retry"), 0)
        payload = self.output()
        self.assertTrue(payload["processed"])
        self.assertEqual(payload["issue"]["status"], "active")
        self.assertEqual(self.factory.calls, [("action", 12, "retry"), ("run_issue", 12)])

    def test_action_retry_at_the_release_stage_is_not_run_as_an_issue(self):
        self.seed_issue(12, status="failed", stage="release", error="release failed")
        self.assertEqual(self.run_cli("action", "12", "retry"), 0)
        payload = self.output()
        self.assertFalse(payload["processed"])
        self.assertEqual(self.factory.calls, [("action", 12, "retry")])

    def test_action_on_unknown_issue(self):
        self.assertEqual(self.run_cli("action", "77", "retry"), 1)
        self.assertIn("#77 is not tracked", self.err.getvalue())
        self.assertEqual(self.factory.calls, [])

    def test_action_refuses_while_the_daemon_is_running(self):
        self.seed_issue(12, status="failed", stage="implement")
        self.hold_daemon_lock(pid=4242, command="run")
        self.assertEqual(self.run_cli("action", "12", "cleanup"), 1)
        self.assertIn("pid 4242", self.err.getvalue())
        self.assertEqual(self.factory.calls, [])

    def test_release_now_runs_the_batch_and_prints_its_result(self):
        self.assertEqual(self.run_cli("release-now"), 0)
        self.assertEqual(self.factory.calls, [("run_release_batch",)])
        payload = self.output()
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["action"], "release_now")
        self.assertEqual(payload["result"]["tag"], "macos-v0.20.1-beta.1")

    def test_release_now_reports_a_failed_batch(self):
        self.factory.release_result = {"ok": False, "tag": "macos-v0.20.1-beta.1", "error": "Verify failure on main commit abc", "issues": [13]}
        self.assertEqual(self.run_cli("release-now"), 1)
        payload = self.output()
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"]["error"], "Verify failure on main commit abc")
        self.assertEqual(payload["error"]["code"], "release_failed")
        self.reset_output()
        self.factory.release_result = {"ok": False, "reason": "busy", "issues": []}
        self.assertEqual(self.run_cli("release-now"), 1)
        self.assertEqual(self.output()["error"]["error"], "release batch did not run (busy)")

    def test_release_now_refuses_while_the_daemon_is_running(self):
        self.hold_daemon_lock(pid=4242, command="run")
        self.assertEqual(self.run_cli("release-now"), 1)
        self.assertIn("use the dashboard", self.err.getvalue())
        self.assertEqual(self.factory.calls, [])


class CleanupTests(CliTestCase):
    def test_cleanup_removes_pending_worktrees_of_finished_issues(self):
        pending = str(self.root / "worktrees" / "issue-12")
        self.seed_issue(12, status="done", stage="done", branch="codefactory/issue-12", worktreePath=pending)
        self.seed_issue(13, status="skipped", stage="plan", branch="codefactory/issue-13",
                        worktreePath=str(self.root / "worktrees" / "issue-13"), worktreeCleaned=True)
        self.seed_issue(14, status="active", stage="review", branch="codefactory/issue-14",
                        worktreePath=str(self.root / "worktrees" / "issue-14"))
        self.assertEqual(self.run_cli("cleanup"), 0)
        payload = self.output()
        self.assertEqual(payload, {"ok": True, "removed": [12], "failed": []})
        removes = self.runner.argv_with("git", "-C", str(self.checkout), "worktree", "remove")
        self.assertEqual(removes, [["git", "-C", str(self.checkout), "worktree", "remove", "--force", pending]])
        self.assertEqual(self.runner.argv_with("git", "-C", str(self.checkout), "branch", "-D"),
                         [["git", "-C", str(self.checkout), "branch", "-D", "codefactory/issue-12"]])
        self.assertEqual(len(self.runner.argv_with("git", "-C", str(self.checkout), "worktree", "prune")), 1)
        store = self.open_store()
        try:
            self.assertTrue(store.get_issue(12)["worktreeCleaned"])
            self.assertFalse(store.get_issue(14)["worktreeCleaned"])
            self.assertEqual(store.list_events(12)[0]["message"], "Worktree removed by herdr-code-factory cleanup")
        finally:
            store.close()
        for call in self.runner.calls:
            self.assertFalse([key for key in call["env"] if key.startswith("HERDR_")], call["argv"])

    def test_cleanup_reports_failures_and_continues(self):
        bad = self.root / "worktrees" / "issue-12"
        bad.mkdir(parents=True)
        (bad / "file.txt").write_text("stale")
        self.seed_issue(12, status="done", stage="done", branch="codefactory/issue-12", worktreePath=str(bad))
        self.seed_issue(13, status="done", stage="done", branch="codefactory/issue-13", worktreePath=str(self.root / "w13"))
        self.runner.on("git", "-C", str(self.checkout), "worktree", "remove", "--force", str(bad),
                       returncode=128, stderr="fatal: is not a working tree")
        self.assertEqual(self.run_cli("cleanup"), 1)
        payload = self.output()
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["removed"], [13])
        self.assertEqual(payload["failed"][0]["number"], 12)
        self.assertIn("not a working tree", payload["failed"][0]["error"])

    def test_cleanup_refuses_while_the_daemon_is_running(self):
        self.seed_issue(12, status="done", stage="done", branch="codefactory/issue-12", worktreePath=str(self.root / "w12"))
        self.hold_daemon_lock(pid=4242, command="run")
        self.assertEqual(self.run_cli("cleanup"), 1)
        self.assertIn("pid 4242", self.err.getvalue())
        self.assertEqual(self.runner.argv_with("git", "-C", str(self.checkout), "worktree"), [])


class DoctorTests(CliTestCase):
    def script_healthy(self, labels=("herdr-autofix", "herdr-app-report", "released")):
        self.runner.on("gh", "auth", "status", stderr="Logged in to github.com account your-username\n")
        self.runner.on("gh", "label", "list", stdout=json.dumps([{"name": name} for name in labels]))
        self.runner.on("pi", "--version", stdout="pi 0.60.0\n")
        self.runner.on("pi", "--list-models", "openai-codex/gpt-6-astra", stdout="openai-codex  gpt-6-astra  openai-codex/gpt-6-astra\n")
        self.runner.on("pi", "--list-models", "ollama-cloud/deepseek-v4.1-flash:cloud",
                       stdout="ollama-cloud  deepseek-v4.1-flash:cloud  ollama-cloud/deepseek-v4.1-flash:cloud\n")
        self.runner.on("tailscale", "ip", "-4", stdout="203.0.113.7\n")

    def checks(self):
        payload = self.output()
        return payload, {check["check"]: check for check in payload["checks"]}

    def test_doctor_reports_every_check_ok(self):
        self.script_healthy()
        self.assertEqual(self.run_cli("doctor"), 0)
        payload, checks = self.checks()
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["failures"], 0)
        expected = {"repository", "checkout", "gh_auth", "labels", "pi_binary", "planner_model", "implementer_model",
                    "ollama_api_key", "macos_release", "dashboard_host", "worktree_root"}
        self.assertEqual(set(checks), expected)
        for name, check in checks.items():
            self.assertTrue(check["ok"], name)
            self.assertEqual(set(check) - {"warning"}, {"check", "ok", "detail"})
        self.assertIn("owner/repo", checks["checkout"]["detail"])
        self.assertIn("your-username", checks["gh_auth"]["detail"])
        self.assertIn("pi 0.60.0", checks["pi_binary"]["detail"])
        self.assertIn("127.0.0.1", checks["dashboard_host"]["detail"])
        self.assertIn("50.0 GiB", checks["worktree_root"]["detail"])
        self.assertTrue((self.state / "code-factory" / "worktrees").is_dir())
        for call in self.runner.calls:
            self.assertFalse([key for key in call["env"] if key.startswith("HERDR_")], call["argv"])
        pi_calls = [call for call in self.runner.calls if call["argv"][0] == "pi"]
        self.assertEqual(pi_calls[0]["env"]["PI_SKIP_VERSION_CHECK"], "1")
        self.assertEqual(self.builders, [])

    def test_doctor_uses_tailscale_when_configured(self):
        self.script_healthy()
        environ = dict(self.environ, HERDR_CODE_FACTORY_DASHBOARD_HOST="tailscale",
                       HERDR_CODE_FACTORY_DASHBOARD_TOKEN="dashboard-secret")
        self.assertEqual(self.run_cli("doctor", environ=environ), 0)
        _, checks = self.checks()
        self.assertTrue(checks["dashboard_host"]["ok"])
        self.assertIn("203.0.113.7", checks["dashboard_host"]["detail"])
        tailscale_calls = [call for call in self.runner.calls if call["argv"] == ["tailscale", "ip", "-4"]]
        self.assertEqual(len(tailscale_calls), 1)
        self.assertIn("env", tailscale_calls[0])
        self.assertEqual([key for key in tailscale_calls[0]["env"] if key.startswith("HERDR_")], [])
        self.assertEqual(tailscale_calls[0]["env"]["PATH"], "/usr/bin")
        for call in self.runner.calls:
            self.assertFalse([key for key in call["env"] if key.startswith("HERDR_")], call["argv"])

    def test_doctor_reports_failures_and_warnings(self):
        self.script_healthy(labels=("herdr-autofix",))
        self.runner.on("gh", "auth", "status", returncode=1, stderr="You are not logged into any GitHub hosts")
        self.runner.on("pi", "--list-models", "ollama-cloud/deepseek-v4.1-flash:cloud", stdout="")
        self.runner.on("tailscale", "ip", "-4", raise_error=FileNotFoundError("tailscale"))
        self.runner.on("/Applications/Tailscale.app/Contents/MacOS/Tailscale", raise_error=FileNotFoundError("Tailscale"))
        self.runner.on("git", "-C", str(self.checkout), "remote", "get-url", "origin", stdout="git@github.com:someone/else.git\n")
        self.write_config("version = 1\n")
        environ = dict(self.environ, HERDR_CODE_FACTORY_DASHBOARD_HOST="tailscale")
        del environ["OLLAMA_API_KEY"]
        self.deps.disk_usage = lambda path: SimpleNamespace(total=10 * GIB, used=9 * GIB, free=1 * GIB)
        self.assertEqual(self.run_cli("doctor", environ=environ), 1)
        payload, checks = self.checks()
        self.assertFalse(payload["ok"])
        self.assertFalse(checks["checkout"]["ok"])
        self.assertIn("someone/else", checks["checkout"]["detail"])
        self.assertFalse(checks["gh_auth"]["ok"])
        self.assertFalse(checks["labels"]["ok"])
        self.assertIn("herdr-app-report", checks["labels"]["detail"])
        self.assertIn("released", checks["labels"]["detail"])
        self.assertTrue(checks["planner_model"]["ok"])
        self.assertFalse(checks["implementer_model"]["ok"])
        self.assertFalse(checks["ollama_api_key"]["ok"])
        self.assertTrue(checks["ollama_api_key"]["warning"])
        self.assertFalse(checks["macos_release"]["ok"])
        self.assertFalse(checks["dashboard_host"]["ok"])
        self.assertFalse(checks["worktree_root"]["ok"])
        self.assertIn("need at least 5 GiB", checks["worktree_root"]["detail"])
        self.assertEqual(payload["warnings"], 1)
        self.assertEqual(payload["failures"], 7)

    def test_doctor_fix_creates_missing_labels(self):
        self.script_healthy(labels=("released",))
        self.assertEqual(self.run_cli("doctor", "--fix"), 0)
        _, checks = self.checks()
        self.assertTrue(checks["labels"]["ok"])
        self.assertIn("created labels: herdr-autofix, herdr-app-report", checks["labels"]["detail"])
        creates = self.runner.argv_with("gh", "label", "create")
        self.assertEqual([call[3] for call in creates], ["herdr-autofix", "herdr-app-report"])
        self.assertIn("--force", creates[0])
        self.assertEqual(creates[0][creates[0].index("--color") + 1], "AAA6F4")

    def test_doctor_fix_reports_exactly_one_labels_entry_when_a_creation_fails(self):
        self.script_healthy(labels=("released",))
        self.runner.on("gh", "label", "create", "herdr-app-report", returncode=1, stderr="HTTP 403: API rate limit exceeded")
        self.assertEqual(self.run_cli("doctor", "--fix"), 1)
        payload = self.output()
        labels = [check for check in payload["checks"] if check["check"] == "labels"]
        self.assertEqual(len(labels), 1, payload["checks"])
        self.assertFalse(labels[0]["ok"])
        self.assertIn("could not create herdr-app-report", labels[0]["detail"])
        self.assertIn("rate limit", labels[0]["detail"])
        self.assertIn("created: herdr-autofix", labels[0]["detail"])
        self.assertEqual(payload["failures"], 1)
        self.reset_output()
        self.runner.calls.clear()
        self.runner.on("gh", "label", "create", "herdr-autofix", returncode=1, stderr="HTTP 403: API rate limit exceeded")
        self.assertEqual(self.run_cli("doctor", "--fix"), 1)
        labels = [check for check in self.output()["checks"] if check["check"] == "labels"]
        self.assertEqual(len(labels), 1)
        self.assertFalse(labels[0]["ok"])
        self.assertNotIn("all labels present", labels[0]["detail"])
        self.assertEqual([call[3] for call in self.runner.argv_with("gh", "label", "create")], ["herdr-autofix"])

    def test_doctor_without_a_checkout_or_releases(self):
        self.script_healthy()
        environ = dict(self.environ, HERDR_CODE_FACTORY_RELEASE_ENABLED="no")
        del environ["HERDR_CODE_FACTORY_CHECKOUT"]
        self.assertEqual(self.run_cli("doctor", environ=environ), 1)
        _, checks = self.checks()
        self.assertFalse(checks["checkout"]["ok"])
        self.assertIn("not configured", checks["checkout"]["detail"])
        self.assertTrue(checks["macos_release"]["ok"])
        self.assertEqual(checks["macos_release"]["detail"], "releases are disabled")


class RunTests(CliTestCase):
    def test_run_without_dashboard_starts_and_stops_the_factory(self):
        with contextlib.redirect_stdout(self.out):
            self.assertEqual(self.run_cli("run", "--no-dashboard"), 0)
        self.assertEqual(self.factory.calls, [("start",), ("stop",)])
        text = self.out.getvalue()
        self.assertIn("Herdr Code Factory: owner/repo", text)
        self.assertIn("disabled (--no-dashboard)", text)
        info = self.daemon_info()
        self.assertIsNotNone(info["startedAt"])
        self.assertIsNone(info["dashboardUrl"])
        self.assertIsNone(info["dashboardBindUrl"])
        self.assertTrue(self.lock_is_free())

    def test_run_serves_the_dashboard_and_records_its_url(self):
        self.deps.dashboard_builder = self._build_dashboard
        environ = dict(self.environ, HERDR_CODE_FACTORY_DASHBOARD_TOKEN="secret")
        seen = {}

        def wait():
            seen["info"] = self.daemon_info()
            seen["lock_free"] = self.lock_is_free()
            url = self.dashboards[0]["server"].url
            with urllib.request.urlopen(url, timeout=5) as response:
                seen["status"] = response.status
                seen["csp"] = response.headers.get("Content-Security-Policy")
                seen["frame"] = response.headers.get("X-Frame-Options")

        self.deps.wait = wait
        with contextlib.redirect_stdout(self.out):
            self.assertEqual(self.run_cli("run", environ=environ), 0)
        server = self.dashboards[0]["server"]
        self.assertEqual(self.dashboards[0]["host"], "127.0.0.1")
        self.assertEqual(self.dashboards[0]["port"], 9097)
        self.assertEqual(self.dashboards[0]["allowed_hosts"], ("127.0.0.1",))
        self.assertEqual(seen["info"]["dashboardBindUrl"], server.url)
        self.assertIsNone(seen["info"]["dashboardUrl"], "a loopback/tailnet address is never recorded for publication")
        self.assertIsNotNone(seen["info"]["startedAt"])
        self.assertFalse(seen["lock_free"], "run holds the daemon lock while it serves")
        self.assertEqual(seen["status"], 200)
        self.assertIn("default-src 'none'", seen["csp"])
        self.assertEqual(seen["frame"], "DENY")
        self.assertIn(f"Dashboard:  {server.url}", self.out.getvalue())
        self.assertNotIn("dashboard_token is empty", self.err.getvalue())
        self.assertEqual(self.factory.calls, [("start",), ("stop",)])
        self.assertFalse(server.running)
        self.assertTrue(self.lock_is_free())

    def test_run_never_records_a_tailnet_address_for_publication(self):
        self.deps.dashboard_builder = self._build_dashboard
        self.runner.on("tailscale", "ip", "-4", stdout="203.0.113.7\n")
        environ = dict(self.environ, HERDR_CODE_FACTORY_DASHBOARD_HOST="tailscale",
                       HERDR_CODE_FACTORY_DASHBOARD_TOKEN="dashboard-secret")
        seen = {}
        self.deps.wait = lambda: seen.update(info=self.daemon_info())
        with contextlib.redirect_stdout(self.out):
            self.assertEqual(self.run_cli("run", environ=environ), 0)
        self.assertEqual(self.dashboards[0]["host"], "203.0.113.7")
        self.assertIsNone(seen["info"]["dashboardUrl"])
        self.assertEqual(seen["info"]["dashboardBindUrl"], self.dashboards[0]["server"].url)
        tailscale_calls = [call for call in self.runner.calls if call["argv"] == ["tailscale", "ip", "-4"]]
        self.assertEqual(len(tailscale_calls), 1)
        self.assertEqual([key for key in tailscale_calls[0]["env"] if key.startswith("HERDR_")], [])

    def test_run_reports_a_busy_dashboard_port_cleanly(self):
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(("127.0.0.1", 0))
            probe.listen(1)
            port = probe.getsockname()[1]
            environ = dict(self.environ, HERDR_CODE_FACTORY_DASHBOARD_PORT=str(port))
            with contextlib.redirect_stdout(self.out):
                self.assertEqual(self.run_cli("run", environ=environ), 1)
        message = self.err.getvalue()
        self.assertIn(f"error: could not bind the dashboard on 127.0.0.1:{port}", message)
        self.assertNotIn("Traceback", message)
        self.assertEqual(self.factory.calls, [], "the pipeline is not started when the dashboard cannot bind")
        self.assertIsNone(self.daemon_info()["startedAt"], "no start is recorded for a daemon that never ran")
        self.assertTrue(self.lock_is_free())

    def test_run_refuses_when_another_process_holds_the_daemon_lock(self):
        self.hold_daemon_lock(pid=4242, command="run")
        with contextlib.redirect_stdout(self.out):
            self.assertEqual(self.run_cli("run", "--no-dashboard"), 1)
        self.assertIn("pid 4242, command run", self.err.getvalue())
        self.assertEqual(self.factory.calls, [])
        self.assertIsNone(self.daemon_info()["startedAt"])

    def test_run_waits_for_running_stages_before_closing_the_ledger(self):
        self.factory = LingeringFactory()
        with contextlib.redirect_stdout(self.out):
            self.assertEqual(self.run_cli("run", "--no-dashboard"), 0)
        self.assertEqual(self.factory.calls, [("start",), ("stop", True)])
        self.assertIsNone(self.factory.outcome.get("error"), self.factory.outcome)
        self.assertTrue(self.factory.outcome.get("written"))
        self.assertEqual(self.daemon_info()["lastPollAt"], "2026-09-18T12:34:56Z")
        self.assertNotIn("ledger updates may be lost", self.err.getvalue())


if __name__ == "__main__":
    unittest.main()
