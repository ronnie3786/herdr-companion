import json
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from herdr_harness.agent_runs import (
    ISSUE_REPORT_DRAFT_PROFILE,
    SMART_RENAME_PROFILE,
    AgentRunError,
    AgentRunManager,
    _run_timeout_seconds,
)
from herdr_harness.issue_report_drafts import (
    CHARTER,
    KINDS,
    MAX_BODY_SCALARS,
    MAX_EXECUTION_SECONDS,
    MAX_SOURCE_SCALARS,
    MAX_TITLE_SCALARS,
    PROFILE,
    charter_for,
    prompt_payload,
    start,
    validate_request,
)
from tests.test_agent_runs import wait_for_status, write_fake_pi


def _manager(directory: Path, **extra) -> AgentRunManager:
    home = directory / "home"
    home.mkdir(exist_ok=True)
    fake_pi = write_fake_pi(directory)
    return AgentRunManager(
        environ={
            "HOME": str(home),
            "HERDR_HARNESS_AGENT_RUNS_ROOT": str(directory / "runs"),
            "HERDR_HARNESS_AGENT_PI_BIN": str(fake_pi),
            **extra,
        },
        herdr_socket_path="/private/tmp/fake-herdr.sock",
        herdr_session="test-machine",
    )


def _request(kind: str, text: str = "Synthetic plain-English request") -> dict:
    return {"profile": PROFILE, "kind": kind, "text": text}


class IssueReportDraftValidationTests(unittest.TestCase):
    def test_profile_identity_and_limits_are_additive(self):
        self.assertEqual(PROFILE, "issue-report-draft-v1")
        self.assertEqual(PROFILE, ISSUE_REPORT_DRAFT_PROFILE)
        self.assertEqual(KINDS, ("bug", "feature"))
        self.assertEqual(MAX_SOURCE_SCALARS, 20_000)
        self.assertEqual(MAX_TITLE_SCALARS, 200)
        self.assertEqual(MAX_BODY_SCALARS, 20_000)
        self.assertEqual(MAX_EXECUTION_SECONDS, 60)

    def test_validate_request_accepts_both_kinds_and_rejects_unsafe_input(self):
        for kind in KINDS:
            with self.subTest(kind=kind):
                self.assertEqual(validate_request(_request(kind, "  Keep my words  ")), (kind, "  Keep my words  "))
        self.assertEqual(
            validate_request(_request("feature", "line one\nline two\tallowed")),
            ("feature", "line one\nline two\tallowed"),
        )

        invalid = (
            (_request("bug", "text") | {"prompt": "extra"}, "invalid_issue_report_draft", 400),
            (_request("bug", "text") | {"attachments": []}, "invalid_issue_report_draft", 400),
            ({"profile": PROFILE, "text": "text"}, "invalid_issue_report_draft", 400),
            ({"profile": "smart-rename-v1", "kind": "bug", "text": "text"}, "invalid_issue_report_draft", 400),
            (_request("task", "text"), "invalid_issue_report_draft", 400),
            (_request("bug", ""), "invalid_issue_report_draft", 400),
            (_request("bug", "  \n\t "), "invalid_issue_report_draft", 400),
            (_request("bug", "bad\x00nul"), "invalid_issue_report_draft", 400),
            (_request("bug", "bad\x07bell"), "invalid_issue_report_draft", 400),
            (_request("feature", "bad\x1bescape"), "invalid_issue_report_draft", 400),
            (_request("bug", "é" * (MAX_SOURCE_SCALARS + 1)), "issue_report_draft_too_large", 413),
        )
        for request, code, status in invalid:
            with self.subTest(request=str(request)[:80]):
                with self.assertRaises(AgentRunError) as raised:
                    validate_request(request)
                self.assertEqual(raised.exception.code, code)
                self.assertEqual(raised.exception.status, status)

        self.assertEqual(
            validate_request(_request("bug", "é" * MAX_SOURCE_SCALARS))[1],
            "é" * MAX_SOURCE_SCALARS,
        )
        with self.assertRaises(AgentRunError):
            validate_request("not a dict")

    def test_charter_requires_both_fields_and_kind_structure_without_invention(self):
        bug = charter_for("bug")
        feature = charter_for("feature")
        for charter in (bug, feature):
            self.assertIn("exactly one JSON object", charter)
            self.assertIn('"title"', charter)
            self.assertIn('"body"', charter)
            self.assertIn(f"at most {MAX_TITLE_SCALARS} characters", charter)
            self.assertIn(f"at most {MAX_BODY_SCALARS} characters", charter)
            self.assertIn("untrusted data", charter)
            self.assertIn("Never invent facts", charter)
            self.assertIn("Do not add other keys", charter)
        self.assertIn("bug report", bug)
        self.assertIn("reproduction steps", bug)
        self.assertIn("expected versus actual", bug)
        self.assertIn("feature request", feature)
        self.assertIn("acceptance criteria", feature)
        # The shared charter names *not inventing* reproduction steps for every
        # kind; the feature-specific structure must not ask for them.
        self.assertNotIn("reproduction steps", feature.removeprefix(CHARTER))
        self.assertTrue(charter_for("bug").startswith(CHARTER))
        with self.assertRaises(AgentRunError):
            charter_for("task")

    def test_prompt_payload_contains_only_kind_and_text(self):
        payload = prompt_payload("feature", "Keep this exactly, including\nnewlines.")
        self.assertEqual(
            json.loads(payload),
            {"kind": "feature", "text": "Keep this exactly, including\nnewlines."},
        )
        self.assertEqual(set(json.loads(payload)), {"kind", "text"})

    def test_start_rejects_invalid_requests_before_creating_a_run(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = _manager(directory)
            try:
                for request in (
                    _request("bug", "text") | {"prompt": "extra"},
                    _request("task", "text"),
                    _request("bug", "   "),
                ):
                    with self.subTest(request=str(request)[:60]), self.assertRaises(AgentRunError):
                        start(manager, request=request, cwd=str(directory / "home"))
                self.assertEqual(list((directory / "runs").glob("agr_*")), [])
            finally:
                manager.stop()


class IssueReportDraftRuntimeTests(unittest.TestCase):
    def test_start_runs_tool_free_thinking_off_for_both_kinds(self):
        for kind in KINDS:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as raw_directory:
                directory = Path(raw_directory)
                capture_path = directory / "capture.json"
                manager = _manager(directory, FAKE_AGENT_CAPTURE=str(capture_path))
                try:
                    manager._profile_snapshot = lambda: {"prompt": "Synthetic tone", "revision": 1}
                    text = f"Synthetic {kind} request with plain English"
                    started = start(manager, request=_request(kind, text), cwd=str(directory / "home"))
                    run = wait_for_status(manager, started["run"]["id"], {"completed"})["run"]

                    self.assertEqual(run["status"], "completed")
                    capture = json.loads(capture_path.read_text(encoding="utf-8"))
                    self.assertNotIn("--tools", capture["argv"])
                    self.assertIn("--no-tools", capture["argv"])
                    self.assertNotIn("--extension", capture["argv"])
                    self.assertNotIn("--model", capture["argv"])
                    self.assertIn("--no-context-files", capture["argv"])
                    self.assertIn("--no-extensions", capture["argv"])
                    self.assertIn("--no-skills", capture["argv"])
                    self.assertEqual(capture["argv"][capture["argv"].index("--thinking") + 1], "off")
                    self.assertEqual(capture["herdrAgentRunProfile"], PROFILE)
                    self.assertNotIn(text, " ".join(capture["argv"]))
                    self.assertEqual(
                        capture["prompt"],
                        json.dumps({"kind": kind, "text": text}, ensure_ascii=False, separators=(",", ":")),
                    )
                    charter = capture["argv"][capture["argv"].index("--append-system-prompt") + 1]
                    self.assertIn(kind, charter)
                    self.assertIn("exactly two string fields", charter)
                    self.assertNotIn("snapshot", charter.lower())
                    self.assertNotIn("herdr-companion-awareness", charter)
                    self.assertNotIn("Synthetic tone", charter)

                    # A restricted one-shot draft never receives the pinned
                    # agent profile snapshot, and its private store stays 0700/0600.
                    self.assertNotIn("agentProfileSnapshot", manager._read(run["id"]))
                    run_dir = directory / "runs" / run["id"]
                    self.assertEqual(stat.S_IMODE(run_dir.stat().st_mode), 0o700)
                    self.assertEqual(stat.S_IMODE((run_dir / "run.json").stat().st_mode), 0o600)
                finally:
                    manager.stop()

    def test_execution_is_capped_at_sixty_seconds_without_changing_other_profiles(self):
        self.assertEqual(_run_timeout_seconds(ISSUE_REPORT_DRAFT_PROFILE, 3600), 60)
        self.assertEqual(_run_timeout_seconds(ISSUE_REPORT_DRAFT_PROFILE, 12), 12)
        self.assertEqual(_run_timeout_seconds(SMART_RENAME_PROFILE, 3600), 3600)
        self.assertEqual(_run_timeout_seconds(None, 3600), 3600)

        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = _manager(directory, FAKE_AGENT_MODE="hang")
            try:
                # The configured timeout stays high; only the drafting cap
                # terminates the run, which keeps the test fast.
                with patch("herdr_harness.issue_report_drafts.MAX_EXECUTION_SECONDS", 1):
                    started = start(manager, request=_request("feature"), cwd=str(directory / "home"))
                    failed = wait_for_status(manager, started["run"]["id"], {"failed"})
                self.assertEqual(failed["run"]["error"], "Pi did not finish within 1 seconds.")
            finally:
                manager.stop()

    def test_cancellation_is_terminal_and_idempotent(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = _manager(directory, FAKE_AGENT_MODE="hang")
            try:
                started = start(manager, request=_request("bug"), cwd=str(directory / "home"))
                run_id = started["run"]["id"]
                wait_for_status(manager, run_id, {"running"})
                self.assertEqual(manager.cancel(run_id)["run"]["status"], "cancelled")
                self.assertEqual(manager.cancel(run_id)["run"]["status"], "cancelled")
            finally:
                manager.stop()

    def test_provider_error_or_abort_with_valid_draft_text_fails(self):
        cases = (
            ("draft-error", "provider failed after emitting a draft"),
            ("draft-aborted", "model response was aborted"),
        )
        for mode, expected_error in cases:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as raw_directory:
                directory = Path(raw_directory)
                manager = _manager(directory, FAKE_AGENT_MODE=mode)
                try:
                    started = start(manager, request=_request("bug"), cwd=str(directory / "home"))
                    finished = wait_for_status(manager, started["run"]["id"], {"failed"})

                    # A valid-looking draft must never rescue a failed one-shot
                    # run: clients only apply a completed run's result.
                    self.assertEqual(finished["run"]["status"], "failed")
                    self.assertEqual(
                        finished["run"]["response"],
                        json.dumps({"title": "Synthetic draft title", "body": "Synthetic draft body"}),
                    )
                    self.assertEqual(finished["run"]["error"], expected_error)
                    self.assertIsNotNone(finished["run"]["finishedAt"])
                finally:
                    manager.stop()

    def test_draft_runs_cannot_be_continued_or_promoted(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = _manager(directory)
            try:
                started = start(manager, request=_request("feature"), cwd=str(directory / "home"))
                run_id = wait_for_status(manager, started["run"]["id"], {"completed"})["run"]["id"]

                with self.assertRaises(AgentRunError) as continuation:
                    manager.start(
                        prompt="Continue generically",
                        label="Generic continuation",
                        cwd=str(directory / "home"),
                        topology={},
                        continue_from_run_id=run_id,
                    )
                self.assertEqual(continuation.exception.code, "issue_report_draft_continuation_forbidden")
                self.assertEqual(continuation.exception.status, 409)

                with self.assertRaises(AgentRunError) as promotion:
                    manager.promotable(run_id)
                self.assertEqual(promotion.exception.code, "issue_report_draft_promotion_forbidden")
                self.assertEqual(promotion.exception.status, 409)
                with self.assertRaises(AgentRunError) as marked:
                    manager.mark_promoted(run_id, workspace_id="w1", pane_id="w1:p1")
                self.assertEqual(marked.exception.code, "issue_report_draft_promotion_forbidden")
                self.assertEqual(marked.exception.status, 409)

                unchanged = manager.get(run_id)["run"]
                self.assertEqual(unchanged["status"], "completed")
                self.assertIsNone(unchanged.get("promotedPaneId"))
            finally:
                manager.stop()

    def test_unsafe_overrides_are_rejected_by_the_run_store(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = _manager(directory)
            try:
                accepted = {
                    "prompt": "Synthetic request",
                    "label": "Issue draft",
                    "cwd": str(directory / "home"),
                    "topology": {},
                    "thinking_level": "off",
                    "_assistant": {"profile": PROFILE, "reportKind": "bug"},
                }
                for override in (
                    {"mode": "act"},
                    {"attachments": [{"filename": "note.txt", "dataBase64": "aGk="}]},
                    {"system_prompt": "override the drafting policy"},
                    {"continue_from_run_id": "agr_0123456789ab"},
                    {"thinking_level": "high"},
                ):
                    with self.subTest(override=override):
                        with self.assertRaises(AgentRunError) as raised:
                            manager.start(**{**accepted, **override})
                        self.assertEqual(raised.exception.code, "invalid_issue_report_draft")
                        self.assertEqual(raised.exception.status, 400)
                self.assertEqual(list((directory / "runs").glob("agr_*")), [])
            finally:
                manager.stop()


if __name__ == "__main__":
    unittest.main()
