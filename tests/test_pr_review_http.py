"""The PR Review routes retain the main-token and durable-store contract."""
import base64
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from contextlib import contextmanager
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

from herdr_harness.pr_review_runtime import PRReviewDocumentContent, parse_pr_url
from herdr_harness.pr_review_store import PRReviewError, PRReviewStore
from herdr_harness.server import make_handler


class FakeRuntime:
    def __init__(self, store, root):
        self.store = store
        self.root = Path(root)
        self.refreshes = []

    def capabilities(self):
        return {"available": True, "gh_available": True, "runner": "synthetic", "runner_available": True, "pi_available": True, "workspace_label": "PR Reviews", "auto_rank": False, "sync_viewed_to_github": True, "reason": None}

    def create_review(self, url, request_id, skill_ids, actor):
        parsed = parse_pr_url(url)
        review = self.store.create_review({**parsed, "request_id": request_id})
        self.store.update_review(review["id"], status="ready", checkout_path=str(self.root))
        self.store.upsert_files(review["id"], [{"path": "Sources/Garden.py", "status": "modified", "additions": 2, "deletions": 1}])
        return self.store.get_review(review["id"], True)

    def refresh_review(self, review_id, request_id):
        self.refreshes.append((review_id, request_id))
        return self.store.get_review(review_id, True)

    def schedule_review_status_refresh(self, *, force=False):
        self.refreshes.append(("viewer-review-status", force))
        return True

    def diff(self, review_id, path):
        return {"review_id": review_id, "base_sha": "base", "head_sha": "head", "truncated": False, "files": [item for item in self.store.files(review_id) if path in (None, item["path"])]}

    def file_text(self, review_id, path, side, start, end):
        if path == "raise-github":
            raise PRReviewError("Synthetic GitHub failure", code="github_failed", status=502)
        return {"path": path, "side": side, "start_line": start, "end_line": min(end, 2), "total_lines": 2, "text": "one\ntwo\n"}

    def findings_for_path(self, review_id, path):
        return {"path": path, "text": "Synthetic finding", "document_ids": []}

    def start_run(self, review_id, skill_id, request_id, actor=""):
        return self.store.create_run(review_id, skill_id, request_id, actor)

    def finish_run(self, review_id, run_id, state, note, request_id):
        if state not in {"finished", "failed"}:
            raise PRReviewError("Invalid finish state", code="invalid_request", status=400)
        return self.store.update_run(review_id, run_id, state=state, note=note)

    def run_output(self, review_id, run_id, lines):
        self.store.run(review_id, run_id)
        return {"run_id": run_id, "lines": [], "source": "none"}

    def rank_review(self, review_id, request_id):
        return self.store.set_ranking_state(review_id, "done")

    def set_rankings(self, review_id, files, request_id):
        return self.store.set_rankings(review_id, files, request_id)

    def set_viewed(self, review_id, paths, viewed, _sync, request_id):
        return self.store.set_viewed(review_id, paths, viewed, request_id)

    def sync_viewed(self, review_id, request_id):
        return self.store.files(review_id)

    def add_document_upload(self, review_id, filename, media_type, encoded, title, origin, request_id):
        raw = base64.b64decode(encoded, validate=True)
        path = self.root / ("upload-" + filename)
        path.write_bytes(raw)
        return self.store.add_document(review_id, {"kind": "upload", "title": title or filename, "media_type": media_type, "filename": filename, "stored_path": str(path), "byte_size": len(raw), "origin": origin, "request_id": request_id})

    def add_document_link(self, review_id, url, title, origin, request_id):
        return self.store.add_document(review_id, {"kind": "link", "title": title or url, "url": url, "origin": origin, "request_id": request_id})

    def add_document_path(self, review_id, path, title, origin, request_id):
        return self.add_document_upload(review_id, Path(path).name, "text/plain", base64.b64encode(b"path document").decode(), title, origin, request_id)

    @contextmanager
    def open_document(self, review_id, document_id):
        document = self.store.document(review_id, document_id, include_storage=True)
        if document["kind"] == "link":
            raise PRReviewError("Linked documents cannot be downloaded", code="document_not_downloadable", status=409)
        handle = Path(document["stored_path"]).open("rb")
        try:
            yield PRReviewDocumentContent(document, handle, int(document["byte_size"]), document["media_type"])
        finally:
            handle.close()


class PRReviewHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = PRReviewStore(Path(self.temp.name) / "reviews.sqlite3")
        runtime = FakeRuntime(self.store, self.temp.name)
        self.service = SimpleNamespace(
            environ={"HERDR_HARNESS_API_TOKEN": "synthetic-main-token", "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": "synthetic-ingest-token"},
            pr_review_store=self.store,
            pr_review=runtime,
            pr_review_changed=lambda _review_id: None,
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.store.close()
        self.temp.cleanup()

    def request(self, path, body=None, token="synthetic-main-token", method=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(self.origin + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers=headers)
        try:
            response = urllib.request.urlopen(request)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            content_type = response.headers.get("Content-Type", "")
            return response.status, json.loads(raw) if "application/json" in content_type else raw, response.headers

    def create(self, request_id="create-one"):
        status, body, _ = self.request("/api/v1/pr-reviews", {"url": "https://github.com/example-owner/garden/pull/42", "request_id": request_id}, method="POST")
        self.assertEqual(status, 201)
        return body["review"]["id"]

    def test_auth_capabilities_creation_and_snapshot(self):
        for token in (None, "synthetic-ingest-token"):
            self.assertEqual(self.request("/api/v1/pr-reviews", token=token)[0], 401)
        status, capabilities, _ = self.request("/api/v1/pr-reviews/capabilities")
        self.assertEqual(status, 200)
        self.assertIn("pr-review-v1", capabilities["capabilities"])
        status, root, _ = self.request("/api/v1")
        self.assertIn("pr-review-v1", root["capabilities"])
        self.assertEqual(root["endpoints"]["prReviews"], "/api/v1/pr-reviews")

        review_id = self.create()
        status, replay, _ = self.request("/api/v1/pr-reviews", {"url": "https://github.com/example-owner/garden/pull/42", "request_id": "create-one"}, method="POST")
        self.assertEqual(status, 201)
        self.assertEqual(replay["review"]["id"], review_id)
        self.assertEqual(self.request("/api/v1/pr-reviews", {"url": "https://github.com/example-owner/garden/pull/42", "request_id": "bad", "extra": True}, method="POST")[0], 400)
        status, invalid, _ = self.request("/api/v1/pr-reviews", {"url": "https://example.test/not-a-pr", "request_id": "invalid"}, method="POST")
        self.assertEqual(status, 400)
        self.assertEqual(invalid["error"]["code"], "invalid_pr_url")
        _, snapshot, _ = self.request("/api/v1/pr-reviews/" + review_id)
        self.assertTrue({"review", "files", "skills", "runs", "documents", "events"}.issubset(snapshot))

    def test_dashboard_status_refresh_preserves_auth_and_validates_body(self):
        path = "/api/v1/pr-reviews/review-status/refresh"
        for token in (None, "synthetic-ingest-token"):
            self.assertEqual(self.request(path, {"request_id": "refresh"}, token=token, method="POST")[0], 401)
        for body in ({}, {"request_id": ""}, {"request_id": "refresh", "extra": True}):
            self.assertEqual(self.request(path, body, method="POST")[0], 400)
        status, body, _ = self.request(path, {"request_id": "refresh"}, method="POST")
        self.assertEqual(status, 202)
        self.assertTrue(body["refreshing"])
        self.assertEqual(self.service.pr_review.refreshes, [("viewer-review-status", True)])
        self.create()
        _, listed, _ = self.request("/api/v1/pr-reviews")
        self.assertEqual(listed["reviews"][0]["viewer_review"]["state"], "unknown")
        self.assertEqual(listed["reviews"][0]["skill_runs"], [])

    def test_mutations_documents_events_and_path_validation(self):
        review_id = self.create()
        archive = f"/api/v1/pr-reviews/{review_id}/archive"
        self.assertEqual(self.request(archive, {"request_id": "archive"}, method="POST")[0], 200)
        self.assertIsNotNone(self.store.get_review(review_id)["archived_at"])
        self.assertEqual(self.request(archive.replace("archive", "unarchive"), {"request_id": "unarchive"}, method="POST")[0], 200)
        self.assertIsNone(self.store.get_review(review_id)["archived_at"])
        self.assertEqual(self.request(f"/api/v1/pr-reviews/{review_id}/refresh", {"request_id": "refresh"}, method="POST")[0], 202)

        status, run, _ = self.request(f"/api/v1/pr-reviews/{review_id}/runs", {"skill_id": "comprehensive-pr-review", "request_id": "run"}, method="POST")
        self.assertEqual(status, 202)
        run_id = run["run"]["id"]
        self.assertEqual(self.request(f"/api/v1/pr-reviews/{review_id}/runs/{run_id}/finish", {"state": "finished", "request_id": "finish"}, method="POST")[0], 200)
        self.assertEqual(self.request(f"/api/v1/pr-reviews/{review_id}/skills/comprehensive-pr-review/mark", {"state": "ran", "request_id": "mark"}, method="POST")[0], 200)
        self.assertEqual(self.request(f"/api/v1/pr-reviews/{review_id}/rank", {"request_id": "rank"}, method="POST")[0], 202)
        self.assertEqual(self.request(f"/api/v1/pr-reviews/{review_id}/rankings", {"files": [{"path": "Sources/Garden.py", "impact": "high"}], "request_id": "rankings"}, method="PUT")[0], 200)
        self.assertEqual(self.request(f"/api/v1/pr-reviews/{review_id}/viewed", {"paths": ["Sources/Garden.py"], "viewed": True, "request_id": "viewed"}, method="POST")[0], 200)
        self.assertEqual(self.request(f"/api/v1/pr-reviews/{review_id}/viewed/sync", {"request_id": "sync"}, method="POST")[0], 200)
        self.assertEqual(self.request(f"/api/v1/pr-reviews/{review_id}/file?path=../x")[0], 400)
        self.assertEqual(self.request(f"/api/v1/pr-reviews/{review_id}/file?path=raise-github")[0], 502)

        upload = {"filename": "findings.md", "content_type": "text/markdown", "data_base64": base64.b64encode(b"# findings\n").decode(), "request_id": "upload"}
        status, document, _ = self.request(f"/api/v1/pr-reviews/{review_id}/documents", upload, method="POST")
        self.assertEqual(status, 201)
        document_id = document["document"]["id"]
        status, content, headers = self.request(f"/api/v1/pr-reviews/{review_id}/documents/{document_id}/content")
        self.assertEqual(status, 200)
        self.assertEqual(content, b"# findings\n")
        self.assertEqual(headers["Content-Length"], str(len(content)))
        self.assertTrue(headers["Content-Disposition"].startswith("inline"))
        status, link, _ = self.request(f"/api/v1/pr-reviews/{review_id}/documents", {"url": "https://example.test/reference", "title": "Reference", "request_id": "link"}, method="POST")
        self.assertEqual(status, 201)
        self.assertEqual(self.request(f"/api/v1/pr-reviews/{review_id}/documents/{link['document']['id']}/content")[0], 409)
        status, _, _ = self.request(f"/api/v1/pr-reviews/{review_id}/documents", {"path": "/synthetic/path.md", "request_id": "path"}, method="POST")
        self.assertEqual(status, 201)
        _, events, _ = self.request(f"/api/v1/pr-reviews/{review_id}/events?after=0")
        self.assertGreater(events["cursor"], 0)
        _, later, _ = self.request(f"/api/v1/pr-reviews/{review_id}/events?after={events['cursor']}")
        self.assertEqual(later["events"], [])

    def test_document_upload_limit_link_title_and_content_type_validation(self):
        review_id = self.create("upload-limit")
        payload = base64.b64encode(b"x" * (1024 * 1024 + 32)).decode()
        status, document, _ = self.request(f"/api/v1/pr-reviews/{review_id}/documents", {"filename": "large.md", "content_type": "text/markdown", "data_base64": payload, "request_id": "large-upload"}, method="POST")
        self.assertEqual(status, 201)
        self.assertGreater(document["document"]["byte_size"], 1024 * 1024)
        status, link, _ = self.request(f"/api/v1/pr-reviews/{review_id}/documents", {"url": "https://example.test/no-title", "request_id": "empty-title"}, method="POST")
        self.assertEqual(status, 201)
        self.assertEqual(link["document"]["title"], "https://example.test/no-title")
        self.assertEqual(self.request(f"/api/v1/pr-reviews/{review_id}/documents", {"filename": "bad.md", "content_type": "text/plain\r\nX-Test: injected", "data_base64": base64.b64encode(b"x").decode(), "request_id": "unsafe-type"}, method="POST")[0], 400)


if __name__ == "__main__":
    unittest.main()
