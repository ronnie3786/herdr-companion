import json
import os
import stat
import subprocess
import tempfile
import time
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


def _manager(
    directory: Path,
    *,
    default_model: bool = True,
    settings_root: str | None = None,
    home_dir: Path | None = None,
    **extra,
) -> AgentRunManager:
    home = home_dir if home_dir is not None else directory / "home"
    home.mkdir(parents=True, exist_ok=True)
    if default_model or settings_root is not None:
        root = Path(settings_root) if settings_root else home / ".pi" / "agent"
        root.mkdir(parents=True, exist_ok=True)
        (root / "settings.json").write_text(
            json.dumps({"defaultProvider": "openai-codex", "defaultModel": "gpt-5.6-luna"}),
            encoding="utf-8",
        )
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
        # Joiners (Cf) and Unicode line/paragraph separators (Zl/Zp) are not
        # controls: they are ordinary plain-English input the source rule keeps.
        joined = "Add \U0001F469\u200d\U0001F4BB shortcuts"
        self.assertEqual(validate_request(_request("feature", joined)), ("feature", joined))
        self.assertEqual(
            validate_request(_request("bug", "first\u2028second\u2029third")),
            ("bug", "first\u2028second\u2029third"),
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
                    self.assertEqual(
                        capture["argv"][capture["argv"].index("--model") + 1],
                        "openai-codex/gpt-5.6-luna",
                    )
                    self.assertIn("--no-context-files", capture["argv"])
                    self.assertIn("--no-extensions", capture["argv"])
                    self.assertIn("--no-skills", capture["argv"])
                    self.assertIn("--approve", capture["argv"])
                    self.assertNotIn("--no-approve", capture["argv"])
                    self.assertEqual(
                        Path(capture["cwd"]).resolve().parent,
                        Path(tempfile.gettempdir()).resolve(),
                    )
                    self.assertTrue(Path(capture["cwd"]).name.startswith("herdr-issue-draft-"))
                    self.assertEqual(capture["argv"][capture["argv"].index("--thinking") + 1], "off")
                    self.assertEqual(capture["herdrAgentRunProfile"], PROFILE)
                    self.assertNotIn(text, " ".join(capture["argv"]))
                    self.assertEqual(
                        capture["prompt"],
                        json.dumps({"kind": kind, "text": text}, ensure_ascii=False, separators=(",", ":")),
                    )
                    # The drafting system prompt is exclusively server-owned:
                    # Pi's own prompt and any discovered SYSTEM.md/APPEND_SYSTEM.md
                    # are replaced/suppressed, so no companion-private prompt can
                    # enter the provider request.
                    self.assertIn("--system-prompt", capture["argv"])
                    self.assertEqual(capture["argv"][capture["argv"].index("--append-system-prompt") + 1], "")
                    charter = capture["argv"][capture["argv"].index("--system-prompt") + 1]
                    self.assertIn(kind, charter)
                    self.assertIn("exactly two string fields", charter)
                    self.assertNotIn("snapshot", charter.lower())
                    self.assertNotIn("herdr-companion-awareness", charter)
                    self.assertNotIn("Synthetic tone", charter)
                    self.assertNotIn("Synthetic tone", capture["effectiveSystemPrompt"])
                    self.assertIn("exactly two string fields", capture["effectiveSystemPrompt"])

                    # Profile-local settings disable agent/provider retries and
                    # automatic compaction recovery without touching operator
                    # settings; one draft is one provider invocation. The
                    # provider-bound prompt exposes only the neutral temporary
                    # workspace cwd that Pi itself appends.
                    settings = capture["effectiveSettings"]
                    self.assertEqual(settings["retry"]["enabled"], False)
                    self.assertEqual(settings["retry"]["maxRetries"], 0)
                    self.assertEqual(settings["retry"]["provider"]["maxRetries"], 0)
                    self.assertEqual(settings["compaction"]["enabled"], False)
                    self.assertEqual(settings["cacheWarming"], "off")
                    workspace = Path(capture["cwd"])
                    self.assertEqual(workspace.resolve().parent, Path(tempfile.gettempdir()).resolve())
                    self.assertTrue(workspace.name.startswith("herdr-issue-draft-"))
                    self.assertIn("<cwd>", capture["effectiveSystemPrompt"])
                    self.assertIn(
                        workspace.as_posix(),
                        capture["effectiveSystemPrompt"].replace("\\", "/"),
                    )
                    self.assertNotIn("draft-workspace", capture["effectiveSystemPrompt"])

                    # A restricted one-shot draft never receives the pinned
                    # agent profile snapshot, and its private store stays 0700/0600.
                    self.assertNotIn("agentProfileSnapshot", manager._read(run["id"]))
                    self.assertNotIn("draftWorkspace", run)
                    run_dir = directory / "runs" / run["id"]
                    self.assertEqual(stat.S_IMODE(run_dir.stat().st_mode), 0o700)
                    self.assertEqual(stat.S_IMODE((run_dir / "run.json").stat().st_mode), 0o600)
                finally:
                    manager.stop()

    def test_default_model_is_pinned_and_must_be_configured_and_available(self):
        # No configured default at all: fail closed instead of letting Pi
        # choose an implicit startup model.
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = _manager(directory, default_model=False)
            try:
                with self.assertRaises(AgentRunError) as raised:
                    start(manager, request=_request("bug", "plain request"), cwd=str(directory / "home"))
                self.assertEqual(raised.exception.code, "issue_report_draft_model_unavailable")
                self.assertEqual(raised.exception.status, 422)
                self.assertIn("default model", raised.exception.args[0])
                self.assertEqual(list((directory / "runs").glob("agr_*")), [])
            finally:
                manager.stop()

        # A configured default that the companion cannot offer fails closed
        # even though another provider/model is available.
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = _manager(directory)
            settings_path = directory / "home" / ".pi" / "agent" / "settings.json"
            settings_path.write_text(
                json.dumps({"defaultProvider": "other", "defaultModel": "retired-model"}),
                encoding="utf-8",
            )
            try:
                with self.assertRaises(AgentRunError) as raised:
                    start(manager, request=_request("feature", "plain request"), cwd=str(directory / "home"))
                self.assertEqual(raised.exception.code, "issue_report_draft_model_unavailable")
                self.assertIn("other/retired-model", raised.exception.args[0])
                self.assertEqual(list((directory / "runs").glob("agr_*")), [])
            finally:
                manager.stop()

        # The configured default is honored exactly and pinned on the run.
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = _manager(directory)
            settings_path = directory / "home" / ".pi" / "agent" / "settings.json"
            settings_path.write_text(
                json.dumps({"defaultProvider": "other", "defaultModel": "million"}),
                encoding="utf-8",
            )
            try:
                started = start(manager, request=_request("bug", "plain request"), cwd=str(directory / "home"))
                run = wait_for_status(manager, started["run"]["id"], {"completed"})["run"]
                self.assertEqual(run["model"], "other/million")
            finally:
                manager.stop()

        # A caller-supplied model may only repeat the pinned default.
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = _manager(directory)
            try:
                with self.assertRaises(AgentRunError) as raised:
                    manager.start(
                        prompt="plain request",
                        label="Issue draft",
                        cwd=str(directory / "home"),
                        topology={},
                        model="other/million",
                        thinking_level="off",
                        _assistant={"profile": PROFILE, "reportKind": "bug"},
                    )
                self.assertEqual(raised.exception.code, "invalid_issue_report_draft")
                self.assertEqual(raised.exception.status, 400)
                self.assertEqual(list((directory / "runs").glob("agr_*")), [])
            finally:
                manager.stop()

    def test_custom_pi_configuration_directory_is_respected(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            custom_root = directory / "custom-pi" / "agent"
            manager = _manager(
                directory,
                settings_root=str(custom_root),
                PI_CODING_AGENT_DIR=str(custom_root),
            )
            try:
                started = start(manager, request=_request("bug", "plain request"), cwd=str(directory / "home"))
                run = wait_for_status(manager, started["run"]["id"], {"completed"})["run"]
                self.assertEqual(run["model"], "openai-codex/gpt-5.6-luna")
            finally:
                manager.stop()

    def test_discovered_private_system_prompts_cannot_reach_a_draft(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            capture_path = directory / "capture.json"
            manager = _manager(directory, FAKE_AGENT_CAPTURE=str(capture_path))
            agent_dir = directory / "home" / ".pi" / "agent"
            (agent_dir / "SYSTEM.md").write_text(
                "SYNTHETIC-PRIVATE-BASE-SENTINEL: unrelated private instructions",
                encoding="utf-8",
            )
            (agent_dir / "APPEND_SYSTEM.md").write_text(
                "SYNTHETIC-PRIVATE-APPEND-SENTINEL: more unrelated private instructions",
                encoding="utf-8",
            )
            try:
                started = start(manager, request=_request("bug", "plain request"), cwd=str(directory / "home"))
                run = wait_for_status(manager, started["run"]["id"], {"completed"})["run"]
                capture = json.loads(capture_path.read_text(encoding="utf-8"))
                effective = capture["effectiveSystemPrompt"]
                self.assertIn("exactly two string fields", effective)
                self.assertNotIn("SYNTHETIC-PRIVATE-BASE-SENTINEL", effective)
                self.assertNotIn("SYNTHETIC-PRIVATE-APPEND-SENTINEL", effective)
                self.assertNotIn("SYNTHETIC-PRIVATE-BASE-SENTINEL", " ".join(capture["argv"]))
                self.assertNotIn("SYNTHETIC-PRIVATE-APPEND-SENTINEL", " ".join(capture["argv"]))
                self.assertNotEqual(run["status"], "failed")
            finally:
                manager.stop()

    def test_provider_prompt_never_contains_private_home_or_run_store_paths(self):
        # Pi appends the process cwd to the provider-bound system prompt even
        # when --system-prompt replaces the base prompt, so a workspace below
        # HOME or the private run store would leak the operator's path.
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            home = directory / "SYNTHETIC-HOME-SENTINEL"
            runs = directory / "SYNTHETIC-RUNSTORE-SENTINEL"
            capture_path = directory / "capture.json"
            manager = _manager(
                directory,
                home_dir=home,
                HERDR_HARNESS_AGENT_RUNS_ROOT=str(runs),
                FAKE_AGENT_CAPTURE=str(capture_path),
            )
            try:
                started = start(manager, request=_request("bug", "plain request"), cwd=str(home))
                wait_for_status(manager, started["run"]["id"], {"completed"})
                capture = json.loads(capture_path.read_text(encoding="utf-8"))
                effective = capture["effectiveSystemPrompt"]
                charter = capture["argv"][capture["argv"].index("--system-prompt") + 1]
                workspace = Path(capture["cwd"])
                self.assertEqual(workspace.resolve().parent, Path(tempfile.gettempdir()).resolve())
                self.assertTrue(workspace.name.startswith("herdr-issue-draft-"))
                self.assertIn("<cwd>", effective)
                self.assertIn(workspace.as_posix(), effective.replace("\\", "/"))
                for sentinel in ("SYNTHETIC-HOME-SENTINEL", "SYNTHETIC-RUNSTORE-SENTINEL"):
                    with self.subTest(sentinel=sentinel):
                        self.assertNotIn(sentinel, effective)
                        self.assertNotIn(sentinel, charter)
                        self.assertNotIn(sentinel, capture["prompt"])
                        self.assertNotIn(sentinel, str(workspace))
            finally:
                manager.stop()

    def test_draft_workspace_is_neutral_temporary_with_restricted_settings(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            home = directory / "SYNTHETIC-HOME-SENTINEL"
            runs = directory / "SYNTHETIC-RUNSTORE-SENTINEL"
            manager = _manager(
                directory,
                home_dir=home,
                HERDR_HARNESS_AGENT_RUNS_ROOT=str(runs),
            )
            try:
                run_id = "agr_0123456789ab"
                manager._write({"id": run_id, "status": "running", "cwd": str(home)})
                workspace = manager._prepare_issue_draft_workspace(run_id)

                self.assertEqual(workspace.resolve().parent, Path(tempfile.gettempdir()).resolve())
                self.assertTrue(workspace.name.startswith("herdr-issue-draft-"))
                self.assertNotIn("SYNTHETIC-HOME-SENTINEL", str(workspace))
                self.assertNotIn("SYNTHETIC-RUNSTORE-SENTINEL", str(workspace))
                self.assertEqual(stat.S_IMODE(workspace.stat().st_mode), 0o700)
                config_dir = workspace / ".pi"
                self.assertEqual(stat.S_IMODE(config_dir.stat().st_mode), 0o700)
                settings_path = config_dir / "settings.json"
                self.assertEqual(stat.S_IMODE(settings_path.stat().st_mode), 0o600)
                settings = json.loads(settings_path.read_text(encoding="utf-8"))
                self.assertNotIn("defaultProvider", settings)
                self.assertEqual(settings["retry"]["enabled"], False)
                self.assertEqual(settings["retry"]["maxRetries"], 0)
                self.assertEqual(settings["retry"]["provider"]["maxRetries"], 0)
                self.assertEqual(settings["compaction"]["enabled"], False)
                self.assertEqual(settings["cacheWarming"], "off")
                self.assertEqual(manager._read(run_id)["draftWorkspace"], str(workspace))
                # The temporary path stays private: it is not part of the
                # public run shape returned to clients.
                self.assertNotIn("draftWorkspace", manager.get(run_id)["run"])

                manager._discard_issue_draft_workspace(run_id)
                self.assertFalse(workspace.exists())
            finally:
                manager.stop()

    def test_completed_or_cancelled_drafts_remove_their_temporary_workspace(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = _manager(directory)
            try:
                started = start(manager, request=_request("feature"), cwd=str(directory / "home"))
                run_id = wait_for_status(manager, started["run"]["id"], {"completed"})["run"]["id"]
                workspace = Path(manager._read(run_id)["draftWorkspace"])
                deadline = time.monotonic() + 5
                while workspace.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(workspace.exists())
            finally:
                manager.stop()

        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = _manager(directory, FAKE_AGENT_MODE="hang")
            try:
                started = start(manager, request=_request("bug"), cwd=str(directory / "home"))
                run_id = started["run"]["id"]
                deadline = time.monotonic() + 5
                workspace = None
                while time.monotonic() < deadline:
                    value = manager._read(run_id).get("draftWorkspace")
                    if value:
                        workspace = Path(value)
                        break
                    time.sleep(0.01)
                self.assertIsNotNone(workspace)
                self.assertTrue(workspace.exists())
                self.assertEqual(manager.cancel(run_id)["run"]["status"], "cancelled")
                deadline = time.monotonic() + 5
                while workspace.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(workspace.exists())
            finally:
                manager.stop()

    def test_restart_recovery_removes_a_stale_draft_workspace(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = _manager(directory)
            run_id = "agr_0123456789ab"
            try:
                manager._write({"id": run_id, "status": "running", "cwd": str(directory / "home")})
                workspace = manager._prepare_issue_draft_workspace(run_id)
                self.assertTrue(workspace.exists())
            finally:
                manager.stop()
            # A crashed harness leaves the workspace and a running record; the
            # next manager must fail the record and remove the workspace.
            self.assertTrue(workspace.exists())
            restarted = _manager(directory)
            try:
                self.assertEqual(restarted._read(run_id)["status"], "failed")
                self.assertFalse(workspace.exists())
            finally:
                restarted.stop()

    def test_profile_runtime_overrides_yield_one_provider_invocation(self):
        # The probe counts the provider calls Pi would make with the effective
        # merged settings, so this asserts one inference under transient
        # failure and context overflow rather than merely one manager.start.
        for probe in ("transient", "overflow"):
            with self.subTest(probe=probe), tempfile.TemporaryDirectory() as raw_directory:
                directory = Path(raw_directory)
                capture_path = directory / "capture.json"
                manager = _manager(directory, FAKE_AGENT_CAPTURE=str(capture_path), FAKE_AGENT_PROBE=probe)
                try:
                    started = start(manager, request=_request("feature", "plain request"), cwd=str(directory / "home"))
                    wait_for_status(manager, started["run"]["id"], {"completed", "failed"})
                    capture = json.loads(capture_path.read_text(encoding="utf-8"))
                    self.assertEqual(capture["providerInvocations"], 1)
                finally:
                    manager.stop()

        # Control: the same probe reports extra provider calls when retries
        # and compaction recovery are actually enabled.
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            workspace = directory / "workspace"
            (workspace / ".pi").mkdir(parents=True)
            (workspace / ".pi" / "settings.json").write_text(
                json.dumps({"retry": {"enabled": True, "maxRetries": 3, "provider": {"maxRetries": 2}}}),
                encoding="utf-8",
            )
            fake_pi = write_fake_pi(directory)
            sessions = directory / "sessions"
            sessions.mkdir()
            capture_path = directory / "probe-capture.json"
            completed = subprocess.run(
                [
                    str(fake_pi),
                    "-p",
                    "--append-system-prompt",
                    "unused",
                    "--session-dir",
                    str(sessions),
                    "--session-id",
                    "synthetic-probe-session",
                ],
                cwd=str(workspace),
                input="{}",
                text=True,
                capture_output=True,
                env={
                    **os.environ,
                    "HOME": str(directory / "home"),
                    "FAKE_AGENT_CAPTURE": str(capture_path),
                    "FAKE_AGENT_PROBE": "transient",
                },
                timeout=10,
            )
            self.assertEqual(completed.returncode, 0)
            self.assertGreater(json.loads(capture_path.read_text(encoding="utf-8"))["providerInvocations"], 1)

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
                    {"model": "other/million"},
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
