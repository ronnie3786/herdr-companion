"""The issue-report surface keeps the companion's bearer boundary and error mapping."""
import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from types import SimpleNamespace

from herdr_harness.issue_reports import IssueReportError
from herdr_harness.server import make_handler

TOKEN = "synthetic-main-token"


class FakeIssueReports:
    """Stand-in reporter: records payloads and returns scripted results."""

    def __init__(self):
        self.submitted = []
        self.error = None

    def capabilities(self):
        return {"ok": True, "available": True, "repository": "example-owner/example-repo", "reason": None, "maxAttachments": 6}

    def submit(self, payload):
        self.submitted.append(payload)
        if self.error is not None:
            raise self.error
        return {"ok": True, "report": {"id": "isr_0123456789ab", "issueNumber": 7, "issueUrl": "https://github.com/example-owner/example-repo/issues/7", "kind": payload.get("kind"), "title": payload.get("title")}}


class IssueReportHTTPTests(unittest.TestCase):
    def setUp(self):
        self.issue_reports = FakeIssueReports()
        self.service = SimpleNamespace(
            environ={"HERDR_HARNESS_API_TOKEN": TOKEN, "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": "synthetic-ingest-token"},
            issue_reports=self.issue_reports,
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, path, body=None, token=TOKEN, method=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.origin + path, data=data, headers=headers, method=method)
        try:
            response = urllib.request.urlopen(req)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            return response.status, json.loads(raw) if "application/json" in response.headers.get("Content-Type", "") else raw

    def test_bearer_token_is_required(self):
        for token in (None, "synthetic-ingest-token", "wrong-token"):
            with self.subTest(token=token):
                code, body = self.request("/api/v1/issue-reports/capabilities", token=token)
                self.assertEqual(code, 401)
                self.assertEqual(body["error"]["code"], "unauthorized")
                code, _ = self.request("/api/v1/issue-reports", {"kind": "bug", "title": "t", "body": "b"}, token=token)
                self.assertEqual(code, 401)
        self.assertEqual(self.issue_reports.submitted, [])

    def test_capabilities_are_served_from_the_reporter(self):
        code, body = self.request("/api/v1/issue-reports/capabilities")
        self.assertEqual(code, 200)
        self.assertEqual(body, self.issue_reports.capabilities())

    def test_submit_returns_201_with_the_reporter_result(self):
        payload = {"kind": "feature", "title": "Add a mute toggle", "body": "Please add it\n", "autofix": False, "attachments": []}
        code, body = self.request("/api/v1/issue-reports", payload)
        self.assertEqual(code, 201)
        self.assertTrue(body["ok"])
        self.assertEqual(body["report"]["issueNumber"], 7)
        self.assertEqual(body["report"]["title"], "Add a mute toggle")
        self.assertEqual(self.issue_reports.submitted, [payload])

    def test_issue_report_errors_map_to_their_status_and_code(self):
        self.issue_reports.error = IssueReportError("title is required")
        code, body = self.request("/api/v1/issue-reports", {"kind": "bug", "body": "b"})
        self.assertEqual(code, 400)
        self.assertEqual(body["ok"], False)
        self.assertEqual(body["error"], {"code": "invalid_issue_report", "message": "title is required"})
        self.issue_reports.error = IssueReportError("gh issue create failed: HTTP 502", code="github_failed", status=502)
        code, body = self.request("/api/v1/issue-reports", {"kind": "bug", "title": "t", "body": "b"})
        self.assertEqual(code, 502)
        self.assertEqual(body["error"], {"code": "github_failed", "message": "gh issue create failed: HTTP 502"})
        # A failure after the report was stored names the record so the operator
        # can find report.json and any assets left on the release.
        self.issue_reports.error = IssueReportError(
            "gh issue create failed: HTTP 502", code="github_failed", status=502, report_id="isr_0123456789ab",
        )
        code, body = self.request("/api/v1/issue-reports", {"kind": "bug", "title": "t", "body": "b"})
        self.assertEqual(code, 502)
        self.assertEqual(body["error"], {"code": "github_failed", "message": "gh issue create failed: HTTP 502", "reportId": "isr_0123456789ab"})
        self.issue_reports.error = IssueReportError("report is too long for a GitHub issue", code="issue_report_too_long", status=413)
        code, body = self.request("/api/v1/issue-reports", {"kind": "bug", "title": "t", "body": "b"})
        self.assertEqual(code, 413)
        self.assertEqual(body["error"]["code"], "issue_report_too_long")

    def test_unknown_methods_and_paths_are_not_routed_to_the_reporter(self):
        code, _ = self.request("/api/v1/issue-reports", method="GET")
        self.assertEqual(code, 404)
        code, _ = self.request("/api/v1/issue-reports/capabilities", {"kind": "bug"})
        self.assertEqual(code, 404)
        code, _ = self.request("/api/v1/issue-reports/isr_0123456789ab")
        self.assertEqual(code, 404)
        self.assertEqual(self.issue_reports.submitted, [])

    def test_non_object_bodies_are_rejected_before_the_reporter(self):
        req = urllib.request.Request(
            self.origin + "/api/v1/issue-reports", data=b"[1, 2]",
            headers={"Content-Type": "application/json", "Authorization": "Bearer " + TOKEN}, method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(req)
        self.assertEqual(raised.exception.code, 400)
        self.assertEqual(self.issue_reports.submitted, [])

    def test_api_description_lists_the_capability_and_endpoints(self):
        code, body = self.request("/api/v1")
        self.assertEqual(code, 200)
        self.assertIn("issue-reports-v1", body["capabilities"])
        self.assertEqual(body["endpoints"]["issueReports"], "/api/v1/issue-reports")
        self.assertEqual(body["endpoints"]["issueReportCapabilities"], "/api/v1/issue-reports/capabilities")


if __name__ == "__main__":
    unittest.main()
