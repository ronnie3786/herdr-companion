import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

from herdr_harness import first_mate_archive as archive
from herdr_harness.first_mate_runtime import FirstMateRuntime
from herdr_harness.first_mate_store import FirstMateStore
from herdr_harness.server import make_handler


class FirstMateArchiveHTTPTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name).resolve()
        self.store = FirstMateStore(root / "ledger.sqlite")
        self.addCleanup(self.store.close)
        self.runtime = FirstMateRuntime(self.store, runtime_root=root / "runtime", environ={})
        self.wakes = []
        service = SimpleNamespace(environ={"HERDR_HARNESS_API_TOKEN": "synthetic-main-token",
            "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": "synthetic-manage-token"},
            first_mate_store=self.store, first_mate=self.runtime, first_mate_changed=self.wakes.append)
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def stop():
            server.shutdown()
            server.server_close()
            thread.join()

        self.addCleanup(stop)
        self.origin = f"http://127.0.0.1:{server.server_port}"
        self.feature = self.store.create_feature({"title": "Synthetic archive", "goal": "Document the garden", "cwd": str(root), "request_id": "create"})
        self.path = "/api/v1/first-mate/features/" + self.feature["id"]

    def request(self, path, body=None, token="synthetic-main-token"):
        headers = {"Content-Type": "application/json"}
        if token: headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(self.origin + path, data=json.dumps(body).encode() if body is not None else None, headers=headers)
        try:
            response = urllib.request.urlopen(request, timeout=5)
        except urllib.error.HTTPError as exc:
            response = exc
        with response:
            return response.status, json.loads(response.read())

    def archived(self):
        self.store._db.execute("UPDATE fm_features SET status='completed' WHERE id=?", (self.feature["id"],))
        preview = self.request(self.path + "/archive-preview")[1]["preview"]
        self.request(self.path + "/actions", {"action": "archive", "request_id": "archive",
            "expected_revision": preview["feature_revision"], "preview_token": preview["token"],
            "cleanup_options": preview["cleanup_options"]})
        for _ in range(4): self.runtime.cleanup.tick([])

    def test_archive_queue_report_search_and_idempotent_retry(self):
        self.archived()
        self.assertIn(self.feature["id"], self.wakes)
        status, page = self.request(self.path + "/archive-record?length=40")
        self.assertEqual(status, 200)
        self.assertEqual(page["next_offset"], 40)
        status, second = self.request(self.path + "/archive-record?offset=40&sha256=" + page["sha256"])
        self.assertEqual(status, 200)
        self.assertEqual(page["report"] + second["report"], archive.report(self.store, self.feature["id"]))
        self.assertEqual(self.request("/api/v1/first-mate/history?q=garden")[1]["records"][0]["feature_id"], self.feature["id"])
        self.assertEqual(self.request(self.path + "/archive-cleanup/retry", {"request_id": "retry"})[0], 200)
        self.assertEqual(self.request(self.path + "/archive-cleanup/retry", {"request_id": "retry"})[1]["cleanup"]["attempt"], 2)
        self.assertEqual(self.request(self.path + "/archive-record?sha256=" + page["sha256"])[0], 409)

    def test_sensitive_history_and_all_mutations_require_full_auth(self):
        for token in (None, "synthetic-manage-token"):
            for path, body in (("/api/v1/first-mate/history", None),
                               (self.path + "/archive-preview", None),
                               (self.path + "/archive-progress", None),
                               (self.path + "/archive-record", None),
                               (self.path + "/archive-cleanup/retry", {"request_id": "retry"}),
                               (self.path + "/resources", {"request_id": "allocate", "kind": "cache"})):
                self.assertIn(self.request(path, body, token=token)[0], (401, 403))

    def test_bounds_and_unsupported_deletion_paths_are_rejected(self):
        self.archived()
        for query in ("length=80001", "offset=-1", "offset=no", "id=a&id=b", "id=" + "a" * 129,
                      "sha256=short", "path=/tmp"):
            self.assertEqual(self.request(self.path + "/archive-record?" + query)[0], 400)
        for query in ("limit=51", "offset=-1", "limit=no", "q=a&q=b"):
            self.assertEqual(self.request("/api/v1/first-mate/history?" + query)[0], 400)
        self.assertEqual(self.request(self.path + "/resources", {"kind": "cache", "path": "/tmp", "request_id": "allocate"})[0], 400)
        self.assertEqual(self.request(self.path + "/resources", {"kind": {}, "request_id": "allocate"})[0], 400)
        self.assertEqual(self.request(self.path + "/archive-cleanup/retry", {"request_id": "retry", "force": True})[0], 400)
        for query in ("after=-1", "limit=201", "limit=no", "archive_id=a&archive_id=b", "id=wrong-field"):
            self.assertEqual(self.request(self.path + "/archive-progress?" + query)[0], 400)

    def test_allocation_is_available_only_on_owning_server_for_open_tasks(self):
        code, result = self.request(self.path + "/resources", {"kind": "temporary_build", "request_id": "build"})
        self.assertEqual(code, 201)
        self.assertTrue(Path(result["resource"]["path"]).is_relative_to(self.runtime.root))
        self.assertEqual(self.request(self.path + "/resources", {"kind": "temporary_build", "request_id": "build"})[1], result)
        self.archived()
        self.assertEqual(self.request(self.path + "/resources", {"kind": "cache", "request_id": "late"})[0], 409)

    def test_new_history_and_cleanup_fail_closed_in_unauthenticated_dev_mode(self):
        service = SimpleNamespace(environ={}, first_mate_store=self.store, first_mate=self.runtime,
                                  first_mate_changed=self.wakes.append)
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.origin = f"http://127.0.0.1:{server.server_port}"
        try:
            self.store._db.execute("UPDATE fm_features SET status='completed' WHERE id=?", (self.feature["id"],))
            for path, body in (("/api/v1/first-mate/history", None), (self.path + "/archive-record", None),
                               (self.path + "/resources", {"kind": "cache", "request_id": "space"}),
                               (self.path + "/archive-preview", None),
                               (self.path + "/archive-progress", None),
                               (self.path + "/archive-cleanup/retry", {"request_id": "retry"})):
                code, value = self.request(path, body, token=None)
                self.assertEqual(code, 503)
                self.assertEqual(value["error"]["code"], "api_token_required")
            code, _ = self.request(self.path + "/actions",
                                   {"action": "archive", "request_id": "legacy-hide"}, token=None)
            self.assertEqual(code, 200)
            self.assertIsNotNone(self.store.get_feature(self.feature["id"])["archived_at"])
            self.assertIsNone(archive.summary(self.store, self.feature["id"]))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_reviewed_archive_returns_pinned_confirmation_and_structured_progress(self):
        self.store._db.execute("UPDATE fm_features SET status='completed' WHERE id=?", (self.feature["id"],))
        status, value = self.request(self.path + "/archive-preview")
        self.assertEqual(status, 200)
        preview = value["preview"]
        self.assertTrue(preview["eligible"])
        self.assertIsNone(preview["ineligible_reason"])
        self.assertEqual(preview["feature_id"], self.feature["id"])
        body = {"action": "archive", "request_id": "reviewed", "expected_revision": preview["feature_revision"],
                "preview_token": preview["token"], "cleanup_options": preview["cleanup_options"]}
        status, confirmation = self.request(self.path + "/actions", body)
        self.assertEqual(status, 200)
        self.assertEqual(confirmation["archive_id"], confirmation["cleanup"]["id"])
        archive_id = confirmation["archive_id"]
        for _ in range(4):
            self.runtime.cleanup.tick([])
        status, progress = self.request(self.path + "/archive-progress?archive_id=" + archive_id + "&limit=1")
        self.assertEqual(status, 200)
        self.assertEqual(progress["archive_id"], archive_id)
        self.assertEqual(len(progress["logs"]), 1)
        self.assertIsNotNone(progress["next_after"])
        status, missing = self.request(self.path + "/archive-progress?archive_id=archive_missing")
        self.assertEqual(status, 404)
        self.assertEqual(missing["error"]["code"], "not_found")

    def test_enhanced_archive_replay_keeps_its_original_generation(self):
        self.store._db.execute("UPDATE fm_features SET status='completed' WHERE id=?", (self.feature["id"],))
        preview = self.request(self.path + "/archive-preview")[1]["preview"]
        first_body = {"action": "archive", "request_id": "lost-response",
                      "expected_revision": preview["feature_revision"], "preview_token": preview["token"],
                      "cleanup_options": preview["cleanup_options"]}
        first = self.request(self.path + "/actions", first_body)[1]
        first_id = first["archive_id"]
        self.request(self.path + "/actions", {"action": "unarchive", "request_id": "other-unarchive"})
        second_preview = self.request(self.path + "/archive-preview")[1]["preview"]
        second_body = {"action": "archive", "request_id": "other-archive",
                       "expected_revision": second_preview["feature_revision"],
                       "preview_token": second_preview["token"],
                       "cleanup_options": second_preview["cleanup_options"]}
        second = self.request(self.path + "/actions", second_body)[1]
        self.assertNotEqual(first_id, second["archive_id"])
        replay = self.request(self.path + "/actions", first_body)[1]
        self.assertEqual(replay["archive_id"], first_id)
        self.assertEqual(replay["cleanup"]["id"], first_id)
        self.assertEqual(replay["feature"]["archive_cleanup"]["id"], second["archive_id"])
