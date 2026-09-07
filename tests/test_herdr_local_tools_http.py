"""Exercise real Herdr routes with only Herdr running and native local tools."""
import base64
import copy
import json
import subprocess
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from herdr_harness.server import make_server
from herdr_harness.service import HerdrService
from tests.test_herdr_service import FakeClient, snapshot_with_status
from tests.test_herdr_voice import _wav


class HerdrLocalToolsHTTPTests(unittest.TestCase):
    TOKEN = "herdr-test-token"

    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Example Developer")
        self.git("config", "user.email", "developer@example.test")
        (self.root / "tracked.txt").write_text("before\n")
        self.git("add", "--", "tracked.txt")
        self.git("commit", "-qm", "Initial")
        self.commit = self.git("rev-parse", "HEAD").strip()
        (self.root / "tracked.txt").write_text("after\n")
        (self.root / "new.txt").write_text("new\n")
        nested = self.root / "Sources"
        nested.mkdir()
        snapshot = snapshot_with_status()
        snapshot["workspaces"][0]["worktree"] = {"checkout_path": str(self.root)}
        snapshot["panes"][0].update({"foreground_cwd": str(nested), "cwd": str(nested)})
        self.environ = {"HOME": self.temp.name, "HERDR_HARNESS_ATTACHMENTS_DIR": str(Path(self.temp.name) / "uploads")}
        self.service = HerdrService(FakeClient([snapshot]), environ=self.environ)
        self.service.refresh_snapshot()
        self.server = make_server(self.service, host="127.0.0.1", port=0, api_token=self.TOKEN)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.opener = urllib.request.build_opener()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True, check=True, timeout=15).stdout

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.service.stop()

    def request(self, path, *, method="GET", payload=None, token=TOKEN):
        data = None if payload is None else json.dumps(payload).encode()
        headers = {} if token is None else {"Authorization": f"Bearer {token}"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.url + path, data=data, method=method, headers=headers)
        try:
            with self.opener.open(request, timeout=3) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def test_git_routes_use_native_checkout_and_keep_api_contract(self):
        code, status = self.request("/api/v1/workspaces/w1/git")
        self.assertEqual(code, 200)
        self.assertEqual(status["root_path"], str(self.root.resolve()))
        self.assertEqual(status["unstaged"], [{"status": "M", "file": "tracked.txt"}])
        code, diff = self.request("/api/v1/workspaces/w1/git/diff?file=tracked.txt&section=unstaged")
        self.assertEqual(code, 200)
        self.assertIn("+after", diff["diff"])
        code, stage = self.request("/api/v1/workspaces/w1/git/stage", method="POST", payload={"file": "new.txt"})
        self.assertEqual((code, stage), (200, {"ok": True, "workspace_id": "w1", "file": "new.txt"}))
        self.assertIn("new.txt", self.git("diff", "--cached", "--name-only"))
        code, _ = self.request("/api/v1/workspaces/w1/git/unstage", method="POST", payload={"file": "new.txt"})
        self.assertEqual(code, 200)
        self.assertNotIn("new.txt", self.git("diff", "--cached", "--name-only"))

    def test_native_pane_git_normalizes_nested_cwd_and_checks_stale_root(self):
        code, status = self.request("/api/v1/panes/w1:p1/git")
        self.assertEqual(code, 200)
        self.assertEqual(status["root_path"], str(self.root.resolve()))
        code, body = self.request("/api/v1/panes/w1:p1/git/stage", method="POST", payload={"file": "new.txt", "expected_root": str(self.root / "other")})
        self.assertEqual(code, 409)
        self.assertEqual(body["error"]["code"], "git_repository_changed")
        self.assertNotIn("new.txt", self.git("diff", "--cached", "--name-only"))

    def test_git_traversal_invalid_section_and_unknown_workspace_fail(self):
        for route, expected in (("/api/v1/workspaces/w1/git/diff?file=..%2Fprivate.txt&section=unstaged", 400), ("/api/v1/workspaces/w1/git/diff?file=tracked.txt&section=invalid", 400), ("/api/v1/workspaces/unknown/git", 404)):
            with self.subTest(route=route):
                self.assertEqual(self.request(route)[0], expected)

    def test_workspace_attachments_need_only_existing_herdr_workspace(self):
        payload = {"filename": "notes.txt", "content_type": "text/plain", "data_base64": base64.b64encode(b"notes").decode()}
        code, body = self.request("/api/v1/workspaces/w1/attachments", method="POST", payload=payload)
        self.assertEqual(code, 200)
        attachment = body["attachment"]
        self.assertEqual(attachment["workspace_id"], "w1")
        self.assertEqual(Path(attachment["path"]).read_bytes(), b"notes")
        self.assertEqual(self.request("/api/v1/workspaces/unknown/attachments", method="POST", payload=payload)[0], 404)
        self.assertEqual(self.request("/api/v1/workspaces/w1/attachments", method="POST", payload={**payload, "data_base64": "invalid=="})[0], 400)

    def test_native_skills_and_file_search_keep_snake_case_contract(self):
        skill = self.root / ".claude" / "skills" / "review" / "SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text("# Review")
        code, skills = self.request("/api/v1/workspaces/w1/skills")
        self.assertEqual(code, 200)
        self.assertEqual(skills["project_skills"][0]["skill_file_path"], ".claude/skills/review/SKILL.md")
        code, files = self.request("/api/v1/workspaces/w1/files?q=tracked&limit=5")
        self.assertEqual(code, 200)
        self.assertEqual(files["files"], [{"path": "tracked.txt"}])

    def test_unconfigured_voice_never_contacts_any_provider(self):
        payload = {"filename": "voice.wav", "mime_type": "audio/wav", "data_base64": base64.b64encode(_wav()).decode()}
        with patch("urllib.request.build_opener", side_effect=AssertionError("unexpected provider")):
            code, body = self.request("/api/v1/voice/transcriptions", method="POST", payload=payload)
        self.assertEqual(code, 503)
        self.assertEqual(body["error"]["code"], "transcription_not_configured")
        payload["data_base64"] = base64.b64encode(b"not audio").decode()
        self.assertEqual(self.request("/api/v1/voice/transcriptions", method="POST", payload=payload)[0], 400)

    def test_all_native_routes_retain_herdr_bearer_auth(self):
        for route in ("/api/v1/workspaces/w1/git", "/api/v1/workspaces/w1/skills", "/api/v1/workspaces/w1/files?q=tracked", "/api/v1/work-inbox"):
            with self.subTest(route=route):
                self.assertEqual(self.request(route, token=None)[0], 401)
        self.assertEqual(self.request("/api/v1/workspaces/w1/attachments", method="POST", payload={}, token=None)[0], 401)
        self.assertEqual(self.request("/api/v1/voice/transcriptions", method="POST", payload={}, token=None)[0], 401)


if __name__ == "__main__":
    unittest.main()
