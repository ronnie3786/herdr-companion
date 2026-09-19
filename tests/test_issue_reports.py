"""Issue reports file verbatim notes through a fake ``gh`` without touching the network."""
import base64
import json
import stat
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from herdr_harness import agent_runs, issue_reports
from herdr_harness.issue_reports import IssueReportError, IssueReporter, parse_report_marker

REPOSITORY = "example-owner/example-repo"
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 16
CLIENT_ID = "client-0001-abcd"


def encoded(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


class FakeGh:
    """Record every ``gh`` invocation and script its exit status per sub-command.

    ``failures`` is keyed by ``(group, verb)`` or, more specifically, by
    ``(group, verb, first argument)`` such as ``("label", "create", "bug")``.
    """

    def __init__(self):
        self.calls = []
        self.environments = []
        self.cwds = []
        self.failures = {}
        self.release_exists = True
        # Kind labels that already exist: creating them without --force fails.
        self.existing_labels = set()
        self.issue_number = 42
        # Rows returned by ``gh issue list --json number,url,body``.
        self.search_results = []
        # For each upload: [(asset name, file existed in cwd at upload time)].
        self.upload_snapshots = []

    def __call__(self, argv, **kwargs):
        self.calls.append(list(argv))
        self.environments.append(dict(kwargs.get("env") or {}))
        self.cwds.append(kwargs.get("cwd"))
        assert argv[0] == "gh"
        assert kwargs.get("capture_output") is True and kwargs.get("text") is True
        assert kwargs.get("timeout") == issue_reports.GH_TIMEOUT_SECONDS
        key = tuple(argv[1:3])
        failure = self.failures.get(tuple(argv[1:4]), self.failures.get(key))
        if failure is not None:
            return SimpleNamespace(returncode=1, stdout="", stderr=failure)
        if key == ("label", "create") and argv[3] in self.existing_labels and "--force" not in argv:
            return SimpleNamespace(
                returncode=1, stdout="",
                stderr=f'label with name "{argv[3]}" already exists; use `--force` to update its color and description\n',
            )
        if key == ("release", "view"):
            if self.release_exists:
                return SimpleNamespace(returncode=0, stdout='{"tagName":"issue-attachments"}\n', stderr="")
            return SimpleNamespace(returncode=1, stdout="", stderr="release not found")
        if key == ("release", "upload"):
            cwd = Path(kwargs.get("cwd") or ".")
            names = argv[argv.index("--clobber") + 1:]
            self.upload_snapshots.append([(name, (cwd / name).is_file()) for name in names])
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if key == ("issue", "create"):
            return SimpleNamespace(
                returncode=0,
                stdout=f"\nCreating issue in {REPOSITORY}\n\nhttps://github.com/{REPOSITORY}/issues/{self.issue_number}\n",
                stderr="",
            )
        if key == ("issue", "list"):
            return SimpleNamespace(returncode=0, stdout=json.dumps(self.search_results), stderr="")
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    def commands(self, *prefix):
        return [call for call in self.calls if tuple(call[1:1 + len(prefix)]) == prefix]


class IssueReporterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "issue-reports"
        self.gh = FakeGh()
        self.environ = {
            "HOME": self.temp.name,
            "PATH": "/usr/bin:/bin",
            "HERDR_REVIEW_REPOSITORY": REPOSITORY,
            "HERDR_HARNESS_API_TOKEN": "synthetic-control-token",
            "HERDR_STATE_DIR": str(Path(self.temp.name) / "state"),
            "GH_TOKEN": "synthetic-provider-token",
        }
        self.clock = lambda: datetime(2026, 9, 18, 12, 30, 45, 123456, tzinfo=timezone.utc)
        self.reporter = IssueReporter(self.environ, runner=self.gh, root=self.root, clock=self.clock)

    def payload(self, **overrides):
        base = {
            "kind": "bug",
            "title": "HUD orb stops pulsing after sleep",
            "body": "  Steps:\n1. Sleep the Mac\n2. Wake it\n\n**Expected** the orb keeps pulsing 🎯 | it stops\n",
            "autofix": True,
            "environment": {"app_version": "0.20.0", "macos": "26.0"},
            "attachments": [
                {"filename": "Screen Shot.png", "contentType": "image/png", "dataBase64": encoded(PNG)},
                {"filename": "herdr.log", "contentType": "text/plain", "dataBase64": encoded(b"log line\n")},
            ],
        }
        base.update(overrides)
        return base

    def reporter_id(self):
        entries = [entry.name for entry in self.root.iterdir() if entry.name.startswith("isr_")]
        self.assertEqual(len(entries), 1)
        return entries[0]

    def record(self, report_id):
        return json.loads((self.root / report_id / "report.json").read_text(encoding="utf-8"))

    # -- validation ----------------------------------------------------------

    def assertRejected(self, payload, *, code="invalid_issue_report", status=400, fragment=None):
        with self.assertRaises(IssueReportError) as raised:
            self.reporter.submit(payload)
        self.assertEqual(raised.exception.code, code)
        self.assertEqual(raised.exception.status, status)
        self.assertIsNone(raised.exception.report_id)
        if fragment:
            self.assertIn(fragment, str(raised.exception))
        self.assertEqual(self.gh.calls, [], "invalid reports never reach gh")
        self.assertFalse(self.root.exists(), "invalid reports are never stored")

    def test_validation_rejects_malformed_reports_before_any_gh_call(self):
        self.assertRejected("not an object")
        self.assertRejected(self.payload(kind="task"), fragment="kind")
        self.assertRejected(self.payload(kind=None), fragment="kind")
        self.assertRejected(self.payload(title=""), fragment="title")
        self.assertRejected(self.payload(title="   "), fragment="title")
        self.assertRejected(self.payload(title="\t \t"), fragment="title")
        self.assertRejected(self.payload(title="two\nlines"), fragment="single line")
        self.assertRejected(self.payload(title="bell\x07"), fragment="single line")
        self.assertRejected(self.payload(title="x" * (issue_reports.MAX_TITLE_CHARS + 1)), fragment="title")
        self.assertRejected(self.payload(body=""), fragment="body")
        self.assertRejected(self.payload(body="\n\n"), fragment="body")
        self.assertRejected(self.payload(body="x" * (issue_reports.MAX_BODY_CHARS + 1)), fragment="body")
        self.assertRejected(self.payload(body="bad\x00byte"), fragment="control")
        self.assertRejected(self.payload(autofix="yes"), fragment="autofix")
        self.assertRejected(self.payload(extra="field"), fragment="extra")
        self.assertRejected(self.payload(environment=["not", "a", "dict"]), fragment="environment")
        self.assertRejected(self.payload(environment={"k": 1}), fragment="environment")
        self.assertRejected(self.payload(environment={"k": "v\nnewline"}), fragment="environment")
        self.assertRejected(self.payload(environment={"k" * 65: "v"}), fragment="environment")
        self.assertRejected(self.payload(environment={"k": "v" * 513}), fragment="environment")
        self.assertRejected(self.payload(environment={f"key{i}": "v" for i in range(41)}), fragment="environment")
        self.assertRejected(self.payload(clientReportId="short"), fragment="clientReportId")
        self.assertRejected(self.payload(clientReportId="has space 00"), fragment="clientReportId")
        self.assertRejected(self.payload(clientReportId="../../etc/passwd"), fragment="clientReportId")
        self.assertRejected(self.payload(clientReportId="x" * 65), fragment="clientReportId")
        self.assertRejected(self.payload(clientReportId=12345678), fragment="clientReportId")

    def test_tabs_in_titles_and_escape_sequences_in_bodies_are_accepted(self):
        # The Mac composer folds newlines but lets a pasted tab through, and the
        # note is sent verbatim, so a log with ANSI colour codes must not 400.
        body = "log:\n\x1b[31mred\x1b[0m\x0cform feed\x0bvt\x07bell\x7fdel\tend"
        result = self.reporter.submit(self.payload(title="\tcol1\tcol2 ", body=body + "\n", attachments=[], environment={}))
        self.assertEqual(result["report"]["title"], "col1 col2")
        create = self.gh.commands("issue", "create")[0]
        self.assertEqual(create[create.index("--title") + 1], "col1 col2")
        issue_body = (self.root / self.reporter_id() / "issue-body.md").read_text(encoding="utf-8")
        self.assertTrue(issue_body.startswith(body + "\n\n<!-- herdr-issue-report "), issue_body)
        self.assertEqual(self.record(self.reporter_id())["body"], body)

    def test_attachment_validation(self):
        attachment = {"filename": "shot.png", "contentType": "image/png", "dataBase64": encoded(PNG)}
        self.assertRejected(self.payload(attachments={"filename": "x"}), fragment="attachments")
        self.assertRejected(self.payload(attachments=[attachment] * 7), fragment="at most 6")
        self.assertRejected(self.payload(attachments=[{**attachment, "dataBase64": "@@@@"}]), fragment="base64")
        self.assertRejected(self.payload(attachments=[{**attachment, "dataBase64": ""}]), fragment="dataBase64")
        self.assertRejected(self.payload(attachments=[{**attachment, "filename": "payload.exe"}]), fragment="not supported")
        self.assertRejected(self.payload(attachments=[{**attachment, "filename": "../shot.png"}]), fragment="filename")
        self.assertRejected(self.payload(attachments=[{**attachment, "filename": "dir/shot.png"}]), fragment="filename")
        self.assertRejected(self.payload(attachments=[{**attachment, "filename": "a" * 201 + ".png"}]), fragment="filename")
        self.assertRejected(self.payload(attachments=[{**attachment, "contentType": "image/png\n"}]), fragment="contentType")
        self.assertRejected(self.payload(attachments=[{**attachment, "surprise": 1}]), fragment="attachment")
        self.assertRejected(self.payload(attachments=[{"filename": "shot.png"}]), fragment="dataBase64")
        oversized = {"filename": "big.bin.png", "contentType": "image/png", "dataBase64": "A" * (((issue_reports.MAX_ATTACHMENT_BYTES + 2) // 3) * 4 + 4)}
        self.assertRejected(self.payload(attachments=[oversized]), code="issue_attachment_too_large", status=413)
        too_large = encoded(b"\x00" * (issue_reports.MAX_ATTACHMENT_BYTES + 1))
        self.assertRejected(
            self.payload(attachments=[{**attachment, "dataBase64": too_large}]),
            code="issue_attachment_too_large", status=413,
        )
        # Two files at the per-file limit sum to exactly the total limit, so the
        # aggregate check is exercised with a lowered ceiling instead of 40 MiB of data.
        with mock.patch.object(issue_reports, "MAX_TOTAL_ATTACHMENT_BYTES", 1024):
            chunk = encoded(b"\x00" * 600)
            self.assertRejected(
                self.payload(attachments=[{**attachment, "dataBase64": chunk}, {**attachment, "filename": "b.png", "dataBase64": chunk}]),
                code="issue_attachment_too_large", status=413, fragment="in total",
            )

    def test_reports_that_render_beyond_githubs_body_limit_are_rejected_before_storage(self):
        # Every field is within its own limit, yet the rendered body repeats the
        # environment (table plus marker JSON) and would be refused by GitHub after
        # the attachments had already been published.
        ascii_environment = {f"{index:02d}" + "k" * 62: "v" * 512 for index in range(40)}
        accented_environment = {f"{index:02d}" + "k" * 62: "é" * 512 for index in range(40)}
        for environment, body in ((ascii_environment, "x" * issue_reports.MAX_BODY_CHARS), (accented_environment, "hello")):
            with self.subTest(body=body[:5]):
                self.assertRejected(
                    self.payload(body=body, environment=environment),
                    code="issue_report_too_long", status=413, fragment="too long",
                )
        # The same environment with a short body fits and is filed normally.
        self.reporter.submit(self.payload(body="short", environment=ascii_environment, attachments=[]))
        self.assertEqual(len(self.gh.commands("issue", "create")), 1)

    def test_unavailable_without_a_repository(self):
        for environ in ({"HOME": self.temp.name}, {"HOME": self.temp.name, "HERDR_REVIEW_REPOSITORY": "not a repo"}):
            with self.subTest(environ=environ):
                reporter = IssueReporter(environ, runner=self.gh, root=self.root)
                capabilities = reporter.capabilities()
                self.assertTrue(capabilities["ok"])
                self.assertFalse(capabilities["available"])
                self.assertIsNone(capabilities["repository"])
                self.assertTrue(capabilities["reason"])
                with self.assertRaises(IssueReportError) as raised:
                    reporter.submit(self.payload())
                self.assertEqual(raised.exception.code, "issue_reports_unavailable")
                self.assertEqual(raised.exception.status, 503)
        self.assertEqual(self.gh.calls, [])
        self.assertFalse(self.root.exists())

    def test_capabilities_do_not_shell_out(self):
        capabilities = self.reporter.capabilities()
        self.assertEqual(self.gh.calls, [])
        self.assertEqual(capabilities, {
            "ok": True,
            "available": True,
            "repository": REPOSITORY,
            "reason": None,
            "maxAttachments": 6,
            "maxAttachmentBytes": 20 * 1024 * 1024,
            "maxTotalAttachmentBytes": 40 * 1024 * 1024,
            "attachmentHosting": "release-assets",
            "publicRepository": True,
            "clientReportIdSupported": True,
            "labels": {"report": "herdr-app-report", "autofix": "herdr-autofix", "kinds": {"bug": "bug", "feature": "enhancement"}},
        })
        self.assertEqual(issue_reports.MAX_ISSUE_REPORT_JSON_BYTES, 60 * 1024 * 1024)
        self.assertIs(issue_reports.ALLOWED_EXTENSIONS, agent_runs.ATTACHMENT_EXTENSIONS)

    def test_code_factory_repository_takes_precedence(self):
        reporter = IssueReporter({**self.environ, "HERDR_CODE_FACTORY_REPOSITORY": "factory-owner/factory-repo"}, runner=self.gh, root=self.root)
        self.assertEqual(reporter.capabilities()["repository"], "factory-owner/factory-repo")

    # -- GitHub pipeline -----------------------------------------------------

    def test_submit_files_issue_with_exact_gh_argv_and_layout(self):
        result = self.reporter.submit(self.payload())
        self.assertTrue(result["ok"])
        report = result["report"]
        report_id = report["id"]
        self.assertRegex(report_id, r"^isr_[0-9a-f]{12}$")
        self.assertEqual(report["kind"], "bug")
        self.assertEqual(report["title"], "HUD orb stops pulsing after sleep")
        self.assertTrue(report["autofix"])
        self.assertEqual(report["issueNumber"], 42)
        self.assertEqual(report["issueUrl"], f"https://github.com/{REPOSITORY}/issues/42")
        self.assertEqual(report["repository"], REPOSITORY)
        self.assertEqual(report["createdAt"], "2026-09-18T12:30:45.123Z")
        base = f"https://github.com/{REPOSITORY}/releases/download/issue-attachments/"
        self.assertEqual(report["attachments"], [
            {"filename": "Screen Shot.png", "url": base + f"{report_id}-Screen_Shot.png", "contentType": "image/png", "size": len(PNG)},
            {"filename": "herdr.log", "url": base + f"{report_id}-herdr.log", "contentType": "text/plain", "size": 9},
        ])

        directory = self.root / report_id
        self.assertEqual(self.gh.calls[0], [
            "gh", "label", "create", "herdr-app-report", "--repo", REPOSITORY,
            "--color", "8A7FD8", "--description", "Filed from the Herdr Mac app", "--force",
        ])
        self.assertEqual(self.gh.calls[1], [
            "gh", "label", "create", "bug", "--repo", REPOSITORY,
            "--color", "d73a4a", "--description", "Something isn't working",
        ])
        self.assertEqual(self.gh.calls[2], [
            "gh", "label", "create", "herdr-autofix", "--repo", REPOSITORY,
            "--color", "AAA6F4", "--description", "Code Factory may implement and release this automatically", "--force",
        ])
        self.assertEqual(self.gh.calls[3], ["gh", "release", "view", "issue-attachments", "--repo", REPOSITORY, "--json", "tagName"])
        self.assertEqual(self.gh.calls[4], [
            "gh", "release", "upload", "issue-attachments", "--repo", REPOSITORY, "--clobber",
            f"{report_id}-Screen_Shot.png", f"{report_id}-herdr.log",
        ])
        self.assertEqual(self.gh.calls[5], [
            "gh", "issue", "create", "--repo", REPOSITORY, "--title", "HUD orb stops pulsing after sleep",
            "--body-file", "issue-body.md",
            "--label", "herdr-app-report", "--label", "bug", "--label", "herdr-autofix",
        ])
        self.assertEqual(len(self.gh.calls), 6)
        # File-reading steps run inside the report directory; the others need no cwd.
        self.assertEqual(self.gh.cwds, [None, None, None, None, str(directory), str(directory)])

        issue_body = (directory / "issue-body.md").read_text(encoding="utf-8")
        expected_prefix = (
            "  Steps:\n1. Sleep the Mac\n2. Wake it\n\n**Expected** the orb keeps pulsing 🎯 | it stops\n\n"
            "### Attachments\n"
            f"- [Screen Shot.png]({base}{report_id}-Screen_Shot.png)\n"
            f"![Screen Shot.png]({base}{report_id}-Screen_Shot.png)\n"
            f"- [herdr.log]({base}{report_id}-herdr.log)\n\n"
            "<details>\n<summary>Environment</summary>\n\n"
            "| Key | Value |\n| --- | --- |\n| app_version | 0.20.0 |\n| macos | 26.0 |\n</details>\n\n"
            "<!-- herdr-issue-report "
        )
        self.assertTrue(issue_body.startswith(expected_prefix), issue_body)
        self.assertTrue(issue_body.endswith(" -->\n"))
        marker_line = issue_body.splitlines()[-1]
        self.assertEqual(issue_body.count("<!-- herdr-issue-report"), 1)
        self.assertEqual(marker_line, "<!-- herdr-issue-report " + json.dumps({
            "schema": 1, "reportId": report_id, "kind": "bug", "autofix": True,
            "attachments": [
                {"name": "Screen Shot.png", "asset": f"{report_id}-Screen_Shot.png", "url": base + f"{report_id}-Screen_Shot.png", "contentType": "image/png", "size": len(PNG)},
                {"name": "herdr.log", "asset": f"{report_id}-herdr.log", "url": base + f"{report_id}-herdr.log", "contentType": "text/plain", "size": 9},
            ],
            "environment": {"app_version": "0.20.0", "macos": "26.0"},
        }, sort_keys=True, separators=(",", ":")) + " -->")
        marker = parse_report_marker(issue_body)
        self.assertEqual(marker["reportId"], report_id)
        self.assertEqual(marker["schema"], 1)
        self.assertEqual(marker["kind"], "bug")
        self.assertTrue(marker["autofix"])
        self.assertEqual([item["asset"] for item in marker["attachments"]], [f"{report_id}-Screen_Shot.png", f"{report_id}-herdr.log"])
        self.assertEqual(marker["environment"], {"app_version": "0.20.0", "macos": "26.0"})

    def test_body_is_posted_verbatim(self):
        body = "   leading spaces\n\n- list | pipe\n\t# not a heading\n```swift\nlet x = 1\n```\n😀 emoji <!-- comment -->\n\n\n"
        self.reporter.submit(self.payload(body=body, attachments=[], environment={}))
        issue_body = (self.root / self.reporter_id() / "issue-body.md").read_text(encoding="utf-8")
        verbatim = body.rstrip("\r\n")
        self.assertTrue(issue_body.startswith(verbatim + "\n\n<!-- herdr-issue-report "), issue_body)
        self.assertNotIn("### Attachments", issue_body)
        self.assertNotIn("<summary>Environment</summary>", issue_body)
        self.assertEqual(self.record(self.reporter_id())["body"], verbatim)

    def test_feature_requests_without_autofix_skip_the_autofix_label(self):
        self.reporter.submit(self.payload(kind="feature", autofix=False, attachments=[]))
        labels = self.gh.commands("label", "create")
        self.assertEqual([call[3] for call in labels], ["herdr-app-report", "enhancement"])
        self.assertEqual(self.gh.commands("release"), [])
        create = self.gh.commands("issue", "create")[0]
        self.assertEqual(create[create.index("--label"):], ["--label", "herdr-app-report", "--label", "enhancement"])

    def test_autofix_defaults_to_true(self):
        payload = self.payload(attachments=[])
        del payload["autofix"]
        result = self.reporter.submit(payload)
        self.assertTrue(result["report"]["autofix"])
        self.assertIn("herdr-autofix", self.gh.commands("issue", "create")[0])

    def test_labels_are_created_once_per_reporter(self):
        self.reporter.submit(self.payload(attachments=[]))
        self.reporter.submit(self.payload(attachments=[]))
        self.reporter.submit(self.payload(kind="feature", attachments=[]))
        self.assertEqual([call[3] for call in self.gh.commands("label", "create")],
                         ["herdr-app-report", "bug", "herdr-autofix", "enhancement"])
        self.assertEqual(len(self.gh.commands("issue", "create")), 3)

    def test_label_creation_is_retried_after_a_failure(self):
        self.gh.failures[("label", "create")] = "HTTP 500"
        with self.assertRaises(IssueReportError):
            self.reporter.submit(self.payload(attachments=[]))
        del self.gh.failures[("label", "create")]
        self.reporter.submit(self.payload(attachments=[]))
        self.assertEqual(len(self.gh.commands("label", "create")), 4)

    def test_kind_labels_are_created_when_missing_and_left_alone_when_present(self):
        self.gh.existing_labels = {"bug"}
        self.reporter.submit(self.payload(attachments=[]))
        # No --force: an operator's own colour and description survive, and gh's
        # "already exists" answer counts as success.
        self.assertEqual(self.gh.commands("label", "create", "bug"), [[
            "gh", "label", "create", "bug", "--repo", REPOSITORY, "--color", "d73a4a", "--description", "Something isn't working",
        ]])
        self.assertEqual(len(self.gh.commands("issue", "create")), 1)
        self.reporter.submit(self.payload(kind="feature", attachments=[]))
        self.assertEqual(self.gh.commands("label", "create", "enhancement"), [[
            "gh", "label", "create", "enhancement", "--repo", REPOSITORY, "--color", "a2eeef", "--description", "New feature or request",
        ]])
        self.reporter.submit(self.payload(attachments=[]))
        self.assertEqual(len(self.gh.commands("label", "create", "bug")), 1, "kind labels are cached like the others")
        self.assertEqual(len(self.gh.commands("issue", "create")), 3)

    def test_kind_label_failures_other_than_already_exists_are_github_failures(self):
        self.gh.failures[("label", "create", "bug")] = "HTTP 403: Resource not accessible by integration"
        with self.assertRaises(IssueReportError) as raised:
            self.reporter.submit(self.payload())
        self.assertEqual(raised.exception.code, "github_failed")
        self.assertEqual(raised.exception.status, 502)
        self.assertIn("gh label create failed: HTTP 403: Resource not accessible by integration", str(raised.exception))
        self.assertEqual(self.gh.commands("release"), [], "nothing is uploaded when a label cannot be ensured")
        self.assertEqual(self.gh.commands("issue"), [])
        del self.gh.failures[("label", "create", "bug")]
        self.reporter.submit(self.payload(attachments=[]))
        self.assertEqual(len(self.gh.commands("label", "create", "bug")), 2, "a failed kind label is retried")

    def test_release_is_created_when_missing_then_assets_uploaded(self):
        self.gh.release_exists = False
        result = self.reporter.submit(self.payload())
        report_id = result["report"]["id"]
        self.assertEqual([call[1:3] for call in self.gh.calls], [
            ["label", "create"], ["label", "create"], ["label", "create"], ["release", "view"], ["release", "create"],
            ["release", "upload"], ["issue", "create"],
        ])
        self.assertEqual(self.gh.calls[4], [
            "gh", "release", "create", "issue-attachments", "--repo", REPOSITORY, "--target", "main",
            "--prerelease", "--latest=false", "--title", "Issue attachments",
            "--notes", "Files attached to issues filed from the Herdr app. This release is not an application download.",
        ])
        upload = self.gh.calls[5]
        self.assertEqual(upload[7:], [f"{report_id}-Screen_Shot.png", f"{report_id}-herdr.log"])
        # The files existed, in the cwd gh was given, while the upload ran.
        self.assertEqual(self.gh.cwds[5], str(self.root / report_id))
        self.assertEqual(self.gh.upload_snapshots, [[(f"{report_id}-Screen_Shot.png", True), (f"{report_id}-herdr.log", True)]])

    def test_release_view_failures_other_than_not_found_are_surfaced(self):
        self.gh.failures[("release", "view")] = "HTTP 403: API rate limit exceeded for user ID 1"
        with self.assertRaises(IssueReportError) as raised:
            self.reporter.submit(self.payload())
        self.assertEqual(raised.exception.code, "github_failed")
        self.assertEqual(raised.exception.status, 502)
        self.assertIn("gh release view failed: HTTP 403: API rate limit exceeded", str(raised.exception))
        self.assertEqual(self.gh.commands("release", "create"), [], "no doomed release create after a transient failure")
        self.assertEqual(self.gh.commands("release", "upload"), [])
        self.assertEqual(self.gh.commands("issue"), [])
        for stderr in ("release not found", "HTTP 404: Not Found (https://api.github.com/repos/x/y/releases/tags/issue-attachments)"):
            with self.subTest(stderr=stderr):
                self.gh.failures[("release", "view")] = stderr
                self.gh.calls.clear()
                self.reporter.submit(self.payload())
                self.assertEqual([call[1:3] for call in self.gh.calls],
                                 [["release", "view"], ["release", "create"], ["release", "upload"], ["issue", "create"]])

    def test_asset_names_are_url_safe_and_unique_within_a_report(self):
        result = self.reporter.submit(self.payload(attachments=[
            {"filename": "Écran 1.PNG", "contentType": "image/png", "dataBase64": encoded(PNG)},
            {"filename": "Ecran_1.png", "contentType": "image/png", "dataBase64": encoded(PNG)},
            {"filename": "notes [draft].md", "contentType": "text/markdown", "dataBase64": encoded(b"# notes")},
            {"filename": "label #3.png", "contentType": "image/png", "dataBase64": encoded(PNG)},
        ]))
        report_id = result["report"]["id"]
        names = [item["url"].rsplit("/", 1)[1] for item in result["report"]["attachments"]]
        self.assertEqual(names, [f"{report_id}-Ecran_1.png", f"{report_id}-Ecran_1-1.png", f"{report_id}-notes_draft.md", f"{report_id}-label_3.png"])
        for name in names:
            # gh would read anything after "#" as a display label.
            self.assertRegex(name, r"^isr_[0-9a-f]{12}-[A-Za-z0-9_-]+\.[a-z]+$")
        issue_body = (self.root / report_id / "issue-body.md").read_text(encoding="utf-8")
        self.assertIn(f"- [notes \\[draft\\].md](https://github.com/{REPOSITORY}/releases/download/issue-attachments/{report_id}-notes_draft.md)", issue_body)
        self.assertNotIn(f"![notes \\[draft\\].md]", issue_body)
        self.assertIn(f"![Écran 1.PNG]", issue_body)

    def test_gh_never_receives_the_storage_path(self):
        # "#" in the state directory would truncate an absolute upload path, and
        # gh error text would otherwise echo the companion's filesystem layout.
        root = Path(self.temp.name) / "state #1" / "issue-reports"
        reporter = IssueReporter(self.environ, runner=self.gh, root=root, clock=self.clock)
        result = reporter.submit(self.payload())
        directory = root / result["report"]["id"]
        for call, cwd in zip(self.gh.calls, self.gh.cwds):
            with self.subTest(call=call[1:3]):
                self.assertFalse([argument for argument in call if "#" in argument or str(root) in argument], call)
                if call[1:3] in (["release", "upload"], ["issue", "create"]):
                    self.assertEqual(cwd, str(directory))
                else:
                    self.assertIsNone(cwd)
        self.assertEqual(self.gh.upload_snapshots[0], [(name, True) for name in self.gh.commands("release", "upload")[0][7:]])

        self.gh.failures[("issue", "create")] = f"open {directory / 'issue-body.md'}: permission denied"
        with self.assertRaises(IssueReportError) as raised:
            reporter.submit(self.payload(attachments=[]))
        message = str(raised.exception)
        self.assertNotIn(str(root), message)
        self.assertNotIn(self.temp.name, message)
        self.assertIn("gh issue create failed: open <issue-reports>/", message)
        self.assertIn("permission denied", message)

    def test_stored_files_are_private_and_record_the_outcome(self):
        result = self.reporter.submit(self.payload())
        report_id = result["report"]["id"]
        directory = self.root / report_id
        self.assertEqual(stat.S_IMODE(self.root.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        for name in ("report.json", "issue-body.md"):
            with self.subTest(name=name):
                self.assertEqual(stat.S_IMODE((directory / name).stat().st_mode), 0o600)
        record = self.record(report_id)
        self.assertEqual(record["status"], "filed")
        self.assertEqual(record["issueNumber"], 42)
        self.assertEqual(record["issueUrl"], f"https://github.com/{REPOSITORY}/issues/42")
        self.assertEqual(record["title"], "HUD orb stops pulsing after sleep")
        self.assertEqual(record["environment"], {"app_version": "0.20.0", "macos": "26.0"})
        self.assertIsNone(record["clientReportId"])
        self.assertNotIn("dataBase64", json.dumps(record))
        self.assertNotIn(base64.b64encode(PNG).decode(), json.dumps(record))
        self.assertNotIn("orphanedAssets", record)
        self.assertEqual([item["asset"] for item in record["attachments"]], [f"{report_id}-Screen_Shot.png", f"{report_id}-herdr.log"])
        self.assertNotIn("path", record["attachments"][0], "report.json never records local paths")

    def test_attachment_bytes_are_discarded_once_the_report_is_filed(self):
        result = self.reporter.submit(self.payload())
        report_id = result["report"]["id"]
        directory = self.root / report_id
        # Present while gh uploaded them, gone afterwards: GitHub holds the copy.
        self.assertEqual(self.gh.upload_snapshots, [[(f"{report_id}-Screen_Shot.png", True), (f"{report_id}-herdr.log", True)]])
        self.assertEqual(sorted(entry.name for entry in directory.iterdir()), ["issue-body.md", "report.json"])
        record = self.record(report_id)
        self.assertEqual([item["size"] for item in record["attachments"]], [len(PNG), 9])

    def test_attachment_bytes_are_discarded_when_filing_fails(self):
        self.gh.failures[("label", "create")] = "HTTP 500"
        with self.assertRaises(IssueReportError):
            self.reporter.submit(self.payload())
        directory = self.root / self.reporter_id()
        self.assertEqual(sorted(entry.name for entry in directory.iterdir()), ["issue-body.md", "report.json"])
        self.assertEqual(self.gh.commands("release"), [], "nothing was uploaded, so nothing is deleted")
        record = self.record(self.reporter_id())
        self.assertEqual(record["status"], "failed")
        self.assertNotIn("orphanedAssets", record)

    def test_default_root_derives_from_state_dir_then_home(self):
        with_state = IssueReporter(self.environ, runner=self.gh)
        self.assertEqual(with_state.root, Path(self.temp.name) / "state" / "issue-reports")
        without_state = IssueReporter({"HOME": self.temp.name, "HERDR_REVIEW_REPOSITORY": REPOSITORY}, runner=self.gh)
        self.assertEqual(without_state.root, Path(self.temp.name) / ".local" / "share" / "herdr-companion" / "issue-reports")
        self.assertFalse(with_state.root.exists())

    def test_github_failures_map_to_502_with_trimmed_stderr(self):
        self.gh.failures[("issue", "create")] = "GraphQL: " + "x" * 1000 + " " + self.environ["GH_TOKEN"] + "\n"
        with self.assertRaises(IssueReportError) as raised:
            self.reporter.submit(self.payload(attachments=[]))
        self.assertEqual(raised.exception.code, "github_failed")
        self.assertEqual(raised.exception.status, 502)
        self.assertEqual(raised.exception.report_id, self.reporter_id())
        message = str(raised.exception)
        self.assertIn("gh issue create failed", message)
        self.assertLessEqual(len(message) - len("gh issue create failed: "), issue_reports.MAX_STDERR_CHARS)
        self.assertNotIn("synthetic-provider-token", message)
        self.assertNotIn("synthetic-control-token", message)
        record = self.record(self.reporter_id())
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["error"]["code"], "github_failed")
        self.assertIsNone(record["issueNumber"])

    def test_failed_issue_creation_removes_the_assets_it_published(self):
        self.gh.failures[("issue", "create")] = "HTTP 502: bad gateway"
        with self.assertRaises(IssueReportError) as raised:
            self.reporter.submit(self.payload())
        report_id = self.reporter_id()
        self.assertEqual(raised.exception.code, "github_failed")
        self.assertEqual(raised.exception.report_id, report_id)
        self.assertEqual([call[1:3] for call in self.gh.calls], [
            ["label", "create"], ["label", "create"], ["label", "create"], ["release", "view"], ["release", "upload"],
            ["issue", "create"], ["release", "delete-asset"], ["release", "delete-asset"],
        ])
        self.assertEqual(self.gh.calls[6], [
            "gh", "release", "delete-asset", "issue-attachments", f"{report_id}-Screen_Shot.png", "--repo", REPOSITORY, "--yes",
        ])
        self.assertEqual(self.gh.calls[7], [
            "gh", "release", "delete-asset", "issue-attachments", f"{report_id}-herdr.log", "--repo", REPOSITORY, "--yes",
        ])
        record = self.record(report_id)
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["error"]["code"], "github_failed")
        self.assertEqual(record["orphanedAssets"], [])
        self.assertEqual(sorted(entry.name for entry in (self.root / report_id).iterdir()), ["issue-body.md", "report.json"])

    def test_assets_that_cannot_be_removed_are_recorded_as_orphaned(self):
        self.gh.failures[("issue", "create")] = "HTTP 502: bad gateway"
        self.gh.failures[("release", "delete-asset")] = "HTTP 500"
        with self.assertRaises(IssueReportError) as raised:
            self.reporter.submit(self.payload())
        report_id = self.reporter_id()
        # The original failure is reported, not the cleanup failure.
        self.assertIn("gh issue create failed: HTTP 502: bad gateway", str(raised.exception))
        self.assertEqual(raised.exception.report_id, report_id)
        self.assertEqual(len(self.gh.commands("release", "delete-asset")), 2)
        record = self.record(report_id)
        self.assertEqual(record["orphanedAssets"], [f"{report_id}-Screen_Shot.png", f"{report_id}-herdr.log"])
        self.assertEqual([item["url"] for item in record["attachments"]], [
            f"https://github.com/{REPOSITORY}/releases/download/issue-attachments/{report_id}-Screen_Shot.png",
            f"https://github.com/{REPOSITORY}/releases/download/issue-attachments/{report_id}-herdr.log",
        ])

    def test_unexpected_errors_after_upload_still_remove_the_assets(self):
        def exploding(argv, **kwargs):
            if argv[1:3] == ["issue", "create"]:
                raise RuntimeError("boom")
            return self.gh(argv, **kwargs)

        reporter = IssueReporter(self.environ, runner=exploding, root=self.root, clock=self.clock)
        with self.assertRaises(RuntimeError):
            reporter.submit(self.payload())
        report_id = self.reporter_id()
        self.assertEqual([call[4] for call in self.gh.commands("release", "delete-asset")],
                         [f"{report_id}-Screen_Shot.png", f"{report_id}-herdr.log"])
        self.assertEqual(sorted(entry.name for entry in (self.root / report_id).iterdir()), ["issue-body.md", "report.json"])

    def test_missing_gh_binary_and_timeouts_map_to_github_failed(self):
        import subprocess

        def missing(argv, **kwargs):
            raise FileNotFoundError(argv[0])

        def slow(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, kwargs.get("timeout"))

        for runner, fragment in ((missing, "not installed"), (slow, "timed out")):
            with self.subTest(fragment=fragment):
                reporter = IssueReporter(self.environ, runner=runner, root=self.root)
                with self.assertRaises(IssueReportError) as raised:
                    reporter.submit(self.payload(attachments=[]))
                self.assertEqual(raised.exception.code, "github_failed")
                self.assertEqual(raised.exception.status, 502)
                self.assertIn(fragment, str(raised.exception))

    def test_unparseable_issue_url_is_a_github_failure(self):
        self.gh.issue_number = "pending"
        with self.assertRaises(IssueReportError) as raised:
            self.reporter.submit(self.payload(attachments=[]))
        self.assertEqual(raised.exception.code, "github_failed")

    def test_gh_environment_omits_every_herdr_setting(self):
        self.reporter.submit(self.payload())
        self.assertTrue(self.gh.environments)
        for environment in self.gh.environments:
            self.assertFalse([name for name in environment if name.startswith("HERDR_")], environment)
            self.assertEqual(environment["GH_TOKEN"], "synthetic-provider-token")
            self.assertEqual(environment["HOME"], self.temp.name)

    def test_marker_survives_hostile_environment_values(self):
        environment = {"note": "a --> b | c", "path": "x\\y", "tail": "z} --> <!-- herdr-issue-report {"}
        result = self.reporter.submit(self.payload(attachments=[], environment=environment))
        report_id = result["report"]["id"]
        issue_body = (self.root / report_id / "issue-body.md").read_text(encoding="utf-8")
        marker_line = issue_body.splitlines()[-1]
        self.assertEqual(marker_line.count("-->"), 1)
        self.assertTrue(marker_line.endswith(" -->"))
        self.assertIn("| note | a --> b \\| c |", issue_body)
        marker = parse_report_marker(issue_body)
        self.assertEqual(marker["reportId"], report_id)
        self.assertEqual(marker["environment"], environment)

    # -- idempotent retries --------------------------------------------------

    def test_client_report_id_replays_a_filed_report_instead_of_filing_twice(self):
        payload = self.payload(clientReportId=CLIENT_ID)
        first = self.reporter.submit(payload)
        calls = len(self.gh.calls)
        second = self.reporter.submit(payload)
        self.assertEqual(second, first)
        self.assertEqual(len(self.gh.calls), calls, "a replay never reaches gh")
        self.assertEqual(self.reporter_id(), first["report"]["id"])
        index = self.root / "clients" / CLIENT_ID
        self.assertEqual(index.read_text(encoding="utf-8"), first["report"]["id"])
        self.assertEqual(stat.S_IMODE(index.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(index.stat().st_mode), 0o600)
        self.assertEqual(self.record(first["report"]["id"])["clientReportId"], CLIENT_ID)
        # A different key is a different report.
        third = self.reporter.submit(self.payload(clientReportId="client-0002-abcd", attachments=[]))
        self.assertNotEqual(third["report"]["id"], first["report"]["id"])
        self.assertEqual(len(self.gh.commands("issue", "create")), 2)

    def test_client_report_id_recovers_an_issue_created_despite_a_failed_response(self):
        payload = self.payload(clientReportId=CLIENT_ID, attachments=[])
        self.gh.failures[("issue", "create")] = "gh issue create timed out"
        with self.assertRaises(IssueReportError) as raised:
            self.reporter.submit(payload)
        first_id = raised.exception.report_id
        del self.gh.failures[("issue", "create")]
        marker = {"schema": 1, "reportId": first_id, "kind": "bug", "autofix": True, "attachments": [], "environment": {}}
        self.gh.search_results = [
            {"number": 77, "url": f"https://github.com/{REPOSITORY}/issues/77", "body": "unrelated issue mentioning " + first_id},
            {"number": 78, "url": f"https://github.com/{REPOSITORY}/issues/78",
             "body": issue_reports.render_issue_body(body="note", attachments=[], environment={}, marker=marker)},
        ]
        result = self.reporter.submit(payload)
        self.assertEqual(result["report"]["id"], first_id)
        self.assertEqual(result["report"]["issueNumber"], 78)
        self.assertEqual(result["report"]["issueUrl"], f"https://github.com/{REPOSITORY}/issues/78")
        self.assertEqual(len(self.gh.commands("issue", "create")), 1, "the existing issue is reused")
        self.assertEqual(self.gh.commands("issue", "list"), [[
            "gh", "issue", "list", "--repo", REPOSITORY, "--label", "herdr-app-report", "--state", "all",
            "--search", f"{first_id} in:body", "--limit", "10", "--json", "number,url,body",
        ]])
        record = self.record(first_id)
        self.assertEqual(record["status"], "filed")
        self.assertEqual(record["issueNumber"], 78)
        self.assertNotIn("error", record)
        # Filed now, so the next replay is served from disk.
        calls = len(self.gh.calls)
        self.assertEqual(self.reporter.submit(payload), result)
        self.assertEqual(len(self.gh.calls), calls)

    def test_client_report_id_files_anew_when_the_earlier_attempt_left_no_issue(self):
        payload = self.payload(clientReportId=CLIENT_ID, attachments=[])
        self.gh.failures[("issue", "create")] = "HTTP 502"
        with self.assertRaises(IssueReportError) as raised:
            self.reporter.submit(payload)
        first_id = raised.exception.report_id
        del self.gh.failures[("issue", "create")]
        result = self.reporter.submit(payload)
        self.assertNotEqual(result["report"]["id"], first_id)
        self.assertEqual(result["report"]["issueNumber"], 42)
        self.assertEqual(len(self.gh.commands("issue", "list")), 1)
        self.assertEqual(len(self.gh.commands("issue", "create")), 2)
        self.assertEqual((self.root / "clients" / CLIENT_ID).read_text(encoding="utf-8"), result["report"]["id"])
        self.assertEqual(self.record(first_id)["status"], "failed")


class ParseReportMarkerTests(unittest.TestCase):
    def test_returns_none_without_a_valid_marker(self):
        self.assertIsNone(parse_report_marker(None))
        self.assertIsNone(parse_report_marker(""))
        self.assertIsNone(parse_report_marker("plain issue text"))
        self.assertIsNone(parse_report_marker("<!-- herdr-issue-report {not json} -->"))
        self.assertIsNone(parse_report_marker('<!-- herdr-issue-report {"schema":2,"reportId":"isr_x"} -->'))
        self.assertIsNone(parse_report_marker('<!-- herdr-issue-report {"schema":1} -->'))

    def test_last_marker_wins_over_text_typed_by_the_reporter(self):
        forged = '<!-- herdr-issue-report {"schema":1,"reportId":"isr_forged00000","kind":"feature","autofix":false} -->'
        genuine = '<!-- herdr-issue-report {"autofix":true,"kind":"bug","reportId":"isr_genuine0000","schema":1} -->'
        body = f"Look: {forged}\n\nmore text\n\n{genuine}\n"
        self.assertEqual(parse_report_marker(body)["reportId"], "isr_genuine0000")
        self.assertEqual(parse_report_marker(forged)["reportId"], "isr_forged00000")

    def test_an_unclosed_opener_in_the_note_cannot_hide_or_replace_the_genuine_marker(self):
        forged = '<!-- herdr-issue-report {"schema":1,"reportId":"isr_forged00000","kind":"feature","autofix":false} -->'
        marker = {
            "schema": 1, "reportId": "isr_genuine0000", "kind": "bug", "autofix": True, "attachments": [],
            "environment": {"note": "x} --> y", "path": "a\\b"},
        }
        for note in (
            "unclosed: <!-- herdr-issue-report {\n\nmore",
            f"{forged}\n\nunclosed: <!-- herdr-issue-report {{\n\nmore",
            'Repro:\n<!-- herdr-issue-report {"schema":1,"reportId":"isr_forged00000"\nmore text',
            "<!-- a comment the reporter never closed\n\n" + forged,
        ):
            with self.subTest(note=note):
                body = issue_reports.render_issue_body(body=note, attachments=[], environment=marker["environment"], marker=marker)
                self.assertEqual(parse_report_marker(body), marker)

    def test_markers_are_matched_on_a_single_line(self):
        self.assertIsNone(parse_report_marker('<!-- herdr-issue-report {\n"schema":1,"reportId":"isr_x"} -->'))
        self.assertIsNone(parse_report_marker('<!-- herdr-issue-report {"schema":1,"reportId":"isr_x"}\n-->'))
        self.assertEqual(parse_report_marker('<!--\therdr-issue-report\t{"schema":1,"reportId":"isr_x"}\t-->\r\n')["reportId"], "isr_x")

    def test_round_trip_through_render_issue_body(self):
        marker = {"schema": 1, "reportId": "isr_0123456789ab", "kind": "bug", "autofix": True, "attachments": [], "environment": {}}
        body = issue_reports.render_issue_body(body="note", attachments=[], environment={}, marker=marker)
        self.assertEqual(body, "note\n\n<!-- herdr-issue-report " + json.dumps(marker, sort_keys=True, separators=(",", ":")) + " -->\n")
        self.assertEqual(parse_report_marker(body), marker)


if __name__ == "__main__":
    unittest.main()
