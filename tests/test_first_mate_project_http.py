"""Project and directory routes enforce full companion authentication."""
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

from herdr_harness.control_store import ControlStore
from herdr_harness.first_mate_store import FirstMateStore
from herdr_harness.server import make_handler


class FirstMateProjectHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.folder = self.root / "Garden iOS"
        self.folder.mkdir()
        self.store = FirstMateStore(self.root / "work.sqlite3")
        self.addCleanup(self.store.close)
        self.control = ControlStore(self.root / "control.sqlite3")
        self.addCleanup(self.control.close)
        self.wakes = []
        self.service = SimpleNamespace(
            environ={"HOME": str(self.root), "HERDR_HARNESS_API_TOKEN": "synthetic-main-token",
                     "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": "synthetic-manage-token",
                     "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": "synthetic-ingest-token"},
            first_mate_store=self.store, control_store=self.control, first_mate_changed=self.wakes.append,
            first_mate=SimpleNamespace(capabilities=lambda: {"available": True}, health=lambda: {"status": "ready"}))
        self.start_server()

    def start_server(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def stop():
            server.shutdown()
            server.server_close()
            thread.join()

        self.addCleanup(stop)
        self.origin = f"http://127.0.0.1:{server.server_port}"

    def request(self, path, body=None, *, method=None, token="synthetic-main-token"):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(self.origin + path, method=method,
            data=json.dumps(body).encode() if body is not None else None, headers=headers)
        try:
            response = urllib.request.urlopen(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.loads(response.read())

    def project(self):
        code, result = self.request("/api/v1/first-mate/projects", {
            "name": "Garden iOS", "cwd": "~/Garden iOS", "request_id": "project-one"})
        self.assertEqual(code, 201, result)
        return result["project"]

    def test_project_flow_and_prompt_retry_are_atomic_and_preserve_owner_snapshot(self):
        project = self.project()
        code, listing = self.request("/api/v1/first-mate/projects")
        self.assertEqual(code, 200)
        self.assertEqual(listing["projects"], [project])
        self.assertEqual(listing["server_id"], self.control.server_id)
        self.assertEqual(self.wakes, [])
        body = {"title": "Watering schedule", "goal": "  Work on SYNTH-31.\nStart with research.  ",
                "project_id": project["id"], "expected_project_revision": 1, "request_id": "start-once"}
        code, started = self.request("/api/v1/first-mate/features", body)
        self.assertEqual(code, 201, started)
        feature = started["feature"]
        self.assertEqual((feature["cwd"], feature["project_name"], feature["project_revision"]),
                         (str(self.folder), "Garden iOS", 1))
        path = "/api/v1/first-mate/projects/" + project["id"]
        code, edited = self.request(path, {"name": "Renamed garden", "cwd": str(self.folder),
            "expected_revision": 1, "request_id": "edit"}, method="PATCH")
        self.assertEqual(code, 200, edited)
        self.assertEqual(self.request(path + "/archive", {
            "archived": True, "expected_revision": 2, "request_id": "archive"})[0], 200)
        self.folder.rmdir()
        code, retried = self.request("/api/v1/first-mate/features", body)
        self.assertEqual(code, 201, retried)
        self.assertEqual(retried["feature"]["id"], feature["id"])
        self.assertEqual([message["text"] for message in self.store.snapshot(feature["id"])["messages"]], [body["goal"]])
        self.assertEqual(self.request("/api/v1/first-mate/projects")[1]["projects"], [])
        self.assertEqual(len(self.request("/api/v1/first-mate/projects?scope=archived")[1]["projects"]), 1)

    def test_all_new_routes_reject_missing_and_scoped_tokens_including_encoded_paths(self):
        project = self.project()
        paths = [("GET", "/api/v1/directories", None), ("GET", "/api/v1/%64irectories", None),
                 ("GET", "/api/v1/first-mate/projects", None), ("GET", "/api/v1/first-mate/%70rojects", None),
                 ("POST", "/api/v1/first-mate/projects", {"name": "Garden", "cwd": str(self.folder), "request_id": "p"}),
                 ("PATCH", "/api/v1/first-mate/projects/" + project["id"], {}),
                 ("POST", "/api/v1/first-mate/projects/" + project["id"] + "/archive", {}),
                 ("POST", "/api/v1/first-mate/features", {"title": "A", "goal": "Plan", "project_id": project["id"],
                     "expected_project_revision": 1, "request_id": "f"})]
        for token in (None, "synthetic-ingest-token", "synthetic-manage-token"):
            for method, path, body in paths:
                with self.subTest(token=token, method=method, path=path):
                    self.assertEqual(self.request(path, body, method=method, token=token)[0], 401)
        self.assertEqual(self.store.list_features(), [])

    def test_no_token_configuration_fails_closed_but_legacy_manual_creation_still_works(self):
        self.service.environ.pop("HERDR_HARNESS_API_TOKEN")
        self.start_server()
        for path in ("/api/v1/directories", "/api/v1/first-mate/projects", "/api/v1/first-mate/%70rojects"):
            code, result = self.request(path, token=None)
            self.assertEqual((code, result["error"]["code"]), (503, "api_token_required"))
        body = {"title": "Legacy", "goal": "Keep manual sessions available", "cwd": str(self.folder), "request_id": "legacy"}
        code, result = self.request("/api/v1/first-mate/features", body, token=None)
        self.assertEqual(code, 201, result)
        self.assertIsNone(result["feature"]["project_id"])
        code, result = self.request("/api/v1/first-mate/features", {
            "title": "Project", "goal": "Plan", "project_id": "missing", "expected_project_revision": 1,
            "request_id": "new"}, token=None)
        self.assertEqual((code, result["error"]["code"]), (503, "api_token_required"))

    def test_directory_contract_query_validation_and_capabilities(self):
        for path in ("/api/v1", "/api/v1/first-mate/capabilities"):
            code, result = self.request(path)
            self.assertEqual(code, 200)
            self.assertIn("first-mate-projects-v1", result["capabilities"])
            self.assertIn("directory-browser-v1", result["capabilities"])
        self.assertEqual(self.request("/api/v1/first-mate/capabilities")[1]["server_id"], self.control.server_id)
        code, result = self.request("/api/v1/directories")
        self.assertEqual(code, 200, result)
        self.assertEqual(result["path"], str(self.root))
        entry = next(item for item in result["entries"] if item["name"] == "Garden iOS")
        self.assertEqual(set(entry), {"name", "path", "resolved_path", "is_symlink", "can_open"})
        query = urllib.parse.urlencode({"path": str(self.folder / "missing")})
        code, result = self.request("/api/v1/directories?" + query)
        self.assertEqual((code, result["error"]["code"]), (404, "directory_missing"))
        for query in ("path=a&path=b", "host=other", "show_hidden=maybe", "cursor=!"):
            self.assertEqual(self.request("/api/v1/directories?" + query)[0], 400)
        self.assertEqual(self.request("/api/v1/directories", {}, method="POST")[0], 405)
        self.assertEqual(self.request("/api/v1/first-mate/projects?scope=unknown")[0], 400)

    def test_project_feature_rejects_conflicting_directory_without_side_effects(self):
        project = self.project()
        body = {"title": "Conflict", "goal": "Plan", "project_id": project["id"], "expected_project_revision": 1,
                "cwd": str(self.folder), "request_id": "conflict"}
        self.assertEqual(self.request("/api/v1/first-mate/features", body)[0], 400)
        self.assertEqual(self.store.list_features(), [])
        self.assertEqual(self.wakes, [])


if __name__ == "__main__":
    unittest.main()
