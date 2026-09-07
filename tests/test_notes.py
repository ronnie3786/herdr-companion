import concurrent.futures
import io
import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from types import SimpleNamespace

from herdr_harness.events import EventBroker
from herdr_harness.notes import NotesError, NotesStore, SWIFT_EPOCH
from herdr_harness.server import make_server
from scripts.herdr_notes_cli import main


def note(**changes):
    return {"id": str(uuid.uuid4()), "title": "Release notes", "body": "Check the HUD",
            "color": "yellow", "createdAt": 800_000_000, "updatedAt": 800_000_010,
            "richBody": {"futureEncoding": ["bold", "Check the HUD"]},
            "previousVersion": {"title": "Draft", "body": "Earlier", "richBody": {"opaque": True}, "replacedAt": 800_000_005},
            "actions": [], "links": [], **changes}


class NotesStoreTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.store = NotesStore(callback=self.events.append, clock=lambda: SWIFT_EPOCH + 900_000_000)
        self.addCleanup(self.store.close)

    def test_create_import_and_retry_preserve_ids_and_canonical_content(self):
        original = note()
        first = self.store.create(original)
        retry = self.store.create({**original, "body": "stale"})
        self.assertTrue(first["created"])
        self.assertFalse(retry["created"])
        self.assertEqual(first["note"], retry["note"])
        self.assertEqual(self.store.import_notes([original])["createdCount"], 0)
        self.assertEqual(len(self.events), 1)

    def test_patch_preserves_rich_content_and_plain_body_change_clears_only_current_format(self):
        original = self.store.create(note())["note"]
        colored = self.store.mutate(original["id"], original["revision"], changes={"color": "blue"})["note"]
        self.assertEqual(colored["richBody"], original["richBody"])
        self.assertEqual(colored["previousVersion"], original["previousVersion"])
        self.assertEqual(colored["updatedAt"], 900_000_000)
        rewritten = self.store.mutate(original["id"], colored["revision"], changes={"body": "New plain text"})["note"]
        self.assertNotIn("richBody", rewritten)
        self.assertEqual(rewritten["previousVersion"], original["previousVersion"])
        rich = self.store.mutate(original["id"], rewritten["revision"], changes={"body": "Formatted", "richBody": ["new", {}]})["note"]
        self.assertEqual(rich["richBody"], ["new", {}])

    def test_unchanged_body_and_timestamp_do_not_flatten_or_advance_revision(self):
        original = self.store.create(note())["note"]
        result = self.store.mutate(original["id"], original["revision"], changes={"body": original["body"], "updatedAt": 1})
        self.assertEqual(result["note"], original)
        self.assertEqual(len(self.events), 1)

    def test_stale_patch_returns_current_note_and_does_not_write(self):
        original = self.store.create(note())["note"]
        newer = self.store.mutate(original["id"], original["revision"], changes={"title": "Agent edit"})["note"]
        with self.assertRaises(NotesError) as caught:
            self.store.mutate(original["id"], original["revision"], changes={"title": "Offline Mac edit"})
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(caught.exception.current_note, newer)

    def test_deleted_note_cannot_resurrect_via_import_create_or_stale_patch(self):
        original = self.store.create(note())["note"]
        self.store.mutate(original["id"], original["revision"], delete=True)
        result = self.store.import_notes([original])
        self.assertEqual(result["notes"], [])
        self.assertIn(original["id"], result["deletedIDs"])
        for operation in [lambda: self.store.create(original),
                          lambda: self.store.mutate(original["id"], original["revision"], changes={"body": "offline"})]:
            with self.assertRaises(NotesError) as caught:
                operation()
            self.assertEqual(caught.exception.status, 409)
            self.assertIsNone(caught.exception.current_note)
        self.assertTrue(self.store.mutate(original["id"], original["revision"], delete=True)["deleted"])

    def test_full_collection_rejects_new_notes_without_eviction_or_partial_import(self):
        self.store.import_notes([note(title=str(index)) for index in range(99)])
        with self.assertRaises(NotesError):
            self.store.import_notes([note(), note()])
        self.assertEqual(len(self.store.list()["notes"]), 99)
        self.assertEqual(self.store.list()["revision"], 99)

    def test_search_reads_plain_text_case_insensitively_without_sql_interpretation(self):
        original = self.store.create(note(title="Café", body="Ship the BLUE HUD"))["note"]
        self.assertEqual(self.store.list("blue")["notes"], [original])
        self.assertEqual(self.store.list("CAFÉ")["notes"], [original])
        self.assertEqual(self.store.list("' OR 1=1")["notes"], [])

    def test_invalid_scalar_types_and_missing_revisions_do_not_poison_collection(self):
        invalid = [note(createdAt=None), note(updatedAt=None), note(body=42), note(color=[]), note(createdAt=float("nan")),
                   note(actions=[{"id": str(uuid.uuid4()), "title": "Action", "prompt": "do it", "status": []}]),
                   note(actions=[{"id": str(uuid.uuid4()), "title": "Action", "prompt": "do it", "error": {}}]),
                   note(links=[{"id": str(uuid.uuid4()), "title": "Link", "paneID": "p1", "machineID": "m1", "createdAt": 1, "actionTitle": []}])]
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(NotesError):
                    self.store.create(value)
        self.assertEqual(self.store.list()["notes"], [])
        original = self.store.create(note())["note"]
        for revision in [None, True, 0, "1"]:
            with self.assertRaises(NotesError) as caught:
                self.store.mutate(original["id"], revision, changes={"title": "invalid"})
            self.assertEqual(caught.exception.status, 428)

    def test_two_process_connections_cannot_both_win_same_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "notes.sqlite3"
            first, second = NotesStore(path), NotesStore(path)
            try:
                original = first.create(note())["note"]
                barrier = threading.Barrier(2)
                def update(store, title):
                    barrier.wait()
                    try:
                        store.mutate(original["id"], original["revision"], changes={"title": title})
                        return "won"
                    except NotesError as exc:
                        return exc.code
                with concurrent.futures.ThreadPoolExecutor(2) as executor:
                    futures = [executor.submit(update, first, "First"), executor.submit(update, second, "Second")]
                    self.assertCountEqual([future.result(timeout=5) for future in futures], ["won", "note_conflict"])
                winner = first.get(original["id"])["note"]
                self.assertEqual(winner["revision"], 2)
            finally:
                first.close()
                second.close()
            reopened = NotesStore(path)
            try:
                self.assertEqual(reopened.get(original["id"])["note"], winner)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            finally:
                reopened.close()


class NotesHTTPAndCLITests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.broker = EventBroker()
        self.store = NotesStore(callback=lambda payload: self.broker.publish("notes.changed", payload))
        service = SimpleNamespace(environ={"HOME": self.directory.name,
            "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": "manage-only", "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": "ingest-only"},
            notes=self.store, broker=self.broker)
        self.server = make_server(service, host="127.0.0.1", port=0, api_token="notes-main-secret")
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.addCleanup(self.stop)

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.store.close()
        self.directory.cleanup()

    def request(self, method="GET", path="", payload=None, token="notes-main-secret"):
        request = urllib.request.Request(self.base + "/api/v1/notes" + path,
            data=json.dumps(payload).encode() if payload is not None else None, method=method,
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as response:
            with response:
                return response.code, json.load(response)

    def cli(self, args, *, stdin="", environ=None):
        output, error = io.StringIO(), io.StringIO()
        status = main(["--base-url", self.base, *args], environ=environ or {"HERDR_HARNESS_API_TOKEN": "notes-main-secret"},
                      stdin=io.StringIO(stdin), stdout=output, stderr=error)
        return status, output.getvalue(), error.getvalue()

    def test_main_token_required_scoped_tokens_cannot_read_or_mutate_notes(self):
        for token in ["", "wrong", "manage-only", "ingest-only"]:
            for method, payload in [("GET", None), ("POST", {"note": note()})]:
                self.assertEqual(self.request(method, payload=payload, token=token)[0], 401)
        self.assertEqual(self.request()[0], 200)
        self.assertEqual(self.store.list()["notes"], [])

    def test_http_conflict_includes_current_note_and_events_omit_body(self):
        original = self.request("POST", payload={"note": note()})[1]["note"]
        path = "/" + original["id"]
        status, newer = self.request("PATCH", path, {"expectedRevision": original["revision"], "changes": {"body": "edited"}})
        self.assertEqual(status, 200)
        status, conflict = self.request("PATCH", path, {"expectedRevision": original["revision"], "changes": {"body": "stale"}})
        self.assertEqual(status, 409)
        self.assertEqual(conflict["currentNote"], newer["note"])
        self.assertEqual(set(self.broker.after(0)[-1]["data"]), {"id", "revision"})

    def test_import_supports_full_existing_hud_collection_larger_than_default_http_limit(self):
        notes = [note(body="x" * 20_000, richBody=None) for _ in range(55)]
        status, imported = self.request("POST", "/import", {"notes": notes})
        self.assertEqual(status, 200)
        self.assertEqual(imported["createdCount"], 55)
        self.assertEqual(len(imported["notes"]), 55)

    def test_cli_create_search_patch_and_delete_use_selected_backend(self):
        code, output, error = self.cli(["create", "--title", "Agent note", "--body-file", "-", "--color", "blue"], stdin="Two\nlines")
        self.assertEqual((code, error), (0, ""))
        original = json.loads(output)["note"]
        code, output, _ = self.cli(["search", "two"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output)["notes"][0]["id"], original["id"])
        code, output, _ = self.cli(["update", original["id"], "--title", "Changed"])
        self.assertEqual(code, 0)
        newer = json.loads(output)["note"]
        self.assertEqual(newer["body"], "Two\nlines")
        code, _, error = self.cli(["update", original["id"], "--expected-revision", str(original["revision"]), "--body", "stale"])
        self.assertEqual(code, 4)
        self.assertIn("note_conflict", error)
        code, _, _ = self.cli(["delete", original["id"], "--expected-revision", str(newer["revision"])])
        self.assertEqual(code, 0)
        self.assertEqual(self.store.list()["notes"], [])

    def test_cli_import_snapshot_and_token_file_keep_private_formatting(self):
        token = Path(self.directory.name) / "token"
        token.write_text("notes-main-secret\n")
        token.chmod(0o600)
        original = note()
        code, output, error = self.cli(["--token-file", str(token), "import", "-"], stdin=json.dumps({"version": 1, "notes": [original]}))
        self.assertEqual((code, error), (0, ""))
        self.assertEqual(json.loads(output)["notes"][0]["richBody"], original["richBody"])
        token.chmod(0o644)
        code, output, error = self.cli(["--token-file", str(token), "list"])
        self.assertNotEqual(code, 0)
        self.assertNotIn("notes-main-secret", output + error)

    def test_cli_discovery_is_compact_and_get_can_explicitly_return_raw_formatting(self):
        original = self.store.create(note(body="x" * 1000))["note"]
        code, output, _ = self.cli(["list"])
        self.assertEqual(code, 0)
        result = json.loads(output)
        self.assertEqual(result["count"], 1)
        self.assertEqual(len(result["notes"][0]["preview"]), 160)
        self.assertNotIn("richBody", output)
        self.assertNotIn("previousVersion", output)
        code, output, _ = self.cli(["get", original["id"]])
        self.assertEqual(code, 0)
        self.assertEqual(len(json.loads(output)["note"]["body"]), 1000)
        self.assertNotIn("richBody", output)
        code, output, _ = self.cli(["get", original["id"], "--raw"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output)["note"]["richBody"], original["richBody"])

    def test_cli_rejects_remote_http_and_never_follows_redirects_with_token(self):
        code, output, error = self.cli(["--base-url", "http://example.com", "list"])
        self.assertNotEqual(code, 0)
        self.assertNotIn("notes-main-secret", output + error)
        calls = []
        def redirect(request, timeout):
            calls.append(request.full_url)
            raise urllib.error.HTTPError(request.full_url, 302, "redirect", {}, io.BytesIO(b""))
        output, error = io.StringIO(), io.StringIO()
        code = main(["list"], environ={"HERDR_HARNESS_API_TOKEN": "notes-main-secret"}, opener=redirect, stdout=output, stderr=error)
        self.assertNotEqual(code, 0)
        self.assertEqual(len(calls), 1)
        self.assertNotIn("notes-main-secret", error.getvalue())
