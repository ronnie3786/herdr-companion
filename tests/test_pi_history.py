import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from herdr_harness.pi_history import PiSavedHistory
from herdr_harness.pi_semantic import PI_SEMANTIC_PROTOCOL, PiSemanticManager


def message(entry_id, parent, role="user", text="hello"):
    return {"type": "message", "id": entry_id, "parentId": parent,
            "timestamp": "2026-01-01T00:00:00Z", "message": {"role": role, "content": text}}


class PiSavedHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "session.jsonl"
        self.history = PiSavedHistory()

    def write(self, entries, *, session_id="session-one", version=3):
        values = [{"type": "session", "id": session_id, "version": version}, *entries]
        self.path.write_text("".join(json.dumps(item) + "\n" for item in values))

    def snapshot(self, leaf, entries=None):
        return {"session": {"id": "session-one", "file": str(self.path), "leafId": leaf},
                "entries": entries or [], "truncated": True, "cursor": 42,
                "latest_cursor": 57, "oldest_cursor": 12, "connected": True,
                "state": {"working": True, "context": {"tokens": 2000}},
                "pending_interactions": [{"id": "prompt-one"}]}

    def test_restores_conversation_larger_than_bridge_budget_and_oversized_entry(self):
        # One tool result alone used to erase an entire earlier conversation.
        entries = [message("prompt", None, text="Original requirement"),
                   message("answer", "prompt", "assistant", "Initial answer"),
                   message("tool", "answer", "toolResult", "large output " * 50_000),
                   message("latest", "tool", "assistant", "Finished")]
        self.write(entries)
        snapshot = self.snapshot("latest", entries[-1:])
        restored = self.history.restore(snapshot)
        self.assertEqual(restored["entries"], entries)
        self.assertFalse(restored["truncated"])
        self.assertTrue(restored["history"]["complete"])
        for key in ("cursor", "latest_cursor", "oldest_cursor", "state", "session", "pending_interactions"):
            self.assertEqual(restored[key], snapshot[key])
        self.assertEqual(snapshot["entries"], entries[-1:])
        self.assertTrue(snapshot["truncated"])

    def test_compaction_and_context_edits_do_not_remove_reader_history(self):
        entries = [message("old", None, text="Keep the original words"),
                   message("reply", "old", "assistant", "Original answer"),
                   {"type": "compaction", "id": "compact", "parentId": "reply",
                    "summary": "Short summary", "firstKeptEntryId": "compact", "tokensBefore": 50000,
                    "systemMessage": {"content": "PRIVATE SETUP"}},
                   {"type": "context_edit", "id": "edit", "parentId": "compact", "targetId": "old", "replacement": None},
                   message("new", "edit", text="Next requirement")]
        self.write(entries)
        result = self.history.restore(self.snapshot("new", entries[-1:]))
        self.assertEqual([e["id"] for e in result["entries"]], ["old", "reply", "compact", "new"])
        self.assertEqual(result["entries"][0]["message"]["content"], "Keep the original words")
        self.assertNotIn("PRIVATE SETUP", json.dumps(result))
        # Compaction often omitted history without even setting truncated=true.
        snapshot = self.snapshot("new", entries[-1:])
        snapshot["truncated"] = False
        self.assertEqual(self.history.restore(snapshot)["entries"], result["entries"])

    def test_exact_leaf_excludes_abandoned_branches_and_not_yet_replayed_turns(self):
        entries = [message("root", None), message("other", "root", text="Abandoned"),
                   message("selected", "root", text="Selected"),
                   message("future", "selected", text="Arrives over SSE")]
        self.write(entries)
        with self.path.open("ab") as handle:
            handle.write(b'{"type":"message","unfinished":')
        result = self.history.restore(self.snapshot("selected"))
        self.assertEqual([e["id"] for e in result["entries"]], ["root", "selected"])
        self.assertEqual(result["cursor"], 42)
        # Navigating to an earlier branch in the same session must replace it.
        result = self.history.restore(self.snapshot("other"))
        self.assertEqual([e["id"] for e in result["entries"]], ["root", "other"])
        self.assertEqual(self.history.restore(self.snapshot(None))["entries"], [])

    def test_filters_hidden_setup_metadata_signatures_and_binary_payloads(self):
        entries = [message("system", None, "system", "PRIVATE SYSTEM"),
                   {"type": "custom", "id": "state", "parentId": "system", "data": "PRIVATE STATE"},
                   {"type": "custom_message", "id": "hidden", "parentId": "state", "display": False, "content": "PRIVATE HIDDEN"},
                   {"type": "custom_message", "id": "visible", "parentId": "hidden", "display": True,
                    "customType": "Notice", "content": "A visible notice", "details": "PRIVATE DETAILS"},
                   message("user", "visible", text="Visible prompt"),
                   message("assistant", "user", "assistant", [{"type": "text", "text": "Visible answer", "textSignature": "PRIVATE SIGNATURE"}]),
                   message("tool", "assistant", "toolResult", [{"type": "image", "data": "x" * 20_000}])]
        entries[-2]["message"]["providerMetadata"] = "PRIVATE PROVIDER"
        entries[-1]["message"]["details"] = {"nested": {"thinking_signature": "PRIVATE NESTED"}, "artifact": {"id": "artifact-one"}}
        self.write(entries)
        result = self.history.restore(self.snapshot("tool"))
        encoded = json.dumps(result)
        self.assertNotIn("PRIVATE", encoded)
        self.assertNotIn("x" * 20_000, encoded)
        self.assertIn("artifact-one", encoded)
        self.assertEqual([e["id"] for e in result["entries"]], ["visible", "user", "assistant", "tool"])
        self.assertIn("provider_signature", encoded)
        self.assertIn("binary_payload", encoded)

    def test_preserves_model_change_notices_and_default_visible_custom_messages(self):
        self.write([
            {"type": "model_change", "id": "model", "parentId": None, "provider": "example", "modelId": "model-one", "privateMetadata": "PRIVATE"},
            {"type": "model_change", "id": "abandoned", "parentId": "model", "provider": "example", "modelId": "other-model"},
            {"type": "custom_message", "id": "notice", "parentId": "model", "customType": "Notice", "content": "Visible by default"},
        ], version=2)
        result = self.history.restore(self.snapshot("notice"))
        self.assertEqual([e["id"] for e in result["entries"]], ["model", "notice"])
        self.assertEqual(result["entries"][0]["modelId"], "model-one")
        self.assertNotIn("PRIVATE", json.dumps(result))

    def test_missing_mismatched_and_malformed_history_never_claims_complete(self):
        fallback = message("fallback", None)
        cases = [
            [],
            [message("leaf", "missing")],
            [message("leaf", "leaf")],
            [message("a", "leaf"), message("leaf", "a")],
            [message("a", None), message("a", None), message("leaf", "a")],
        ]
        for entries in cases:
            with self.subTest(entries=entries):
                self.write(entries)
                result = self.history.restore(self.snapshot("leaf", [fallback]))
                self.assertEqual(result["entries"], [fallback])
                self.assertTrue(result["truncated"])
                self.assertFalse(result["history"]["complete"])
        for version, session_id in [(1, "session-one"), (3, "different-session")]:
            self.write([message("leaf", None)], session_id=session_id, version=version)
            self.assertFalse(self.history.restore(self.snapshot("leaf"))["history"]["complete"])
        self.path.unlink()
        self.assertFalse(self.history.restore(self.snapshot("leaf"))["history"]["complete"])
        self.path.write_bytes(b'{"type":"session"}\nnot json\n')
        self.assertFalse(self.history.restore(self.snapshot("leaf"))["history"]["complete"])

    def test_rejects_unsafe_or_unidentified_files_and_keeps_legacy_snapshots(self):
        self.write([message("leaf", None)])
        snapshot = self.snapshot("leaf")
        for session in [None, {}, {"id": "session-one", "file": str(self.path)},
                        {"id": "session-one", "file": "relative.jsonl", "leafId": "leaf"}]:
            old = {**snapshot, "session": session}
            self.assertEqual(self.history.restore(old), old)
        target = self.path.with_name("target.jsonl")
        self.path.rename(target)
        self.path.symlink_to(target)
        self.assertFalse(self.history.restore(snapshot)["history"]["complete"])
        self.path.unlink()
        os.mkfifo(self.path)
        self.assertFalse(self.history.restore(snapshot)["history"]["complete"])
        self.path.unlink()
        self.path.mkdir()
        self.assertFalse(self.history.restore(snapshot)["history"]["complete"])

    def test_cache_is_bounded_and_does_not_share_mutable_responses(self):
        self.write([message("leaf", None)])
        snapshot = self.snapshot("leaf")
        with patch.object(self.history, "_read_branch", wraps=self.history._read_branch) as read:
            first = self.history.restore(snapshot)
            first["entries"][0]["message"]["content"] = "mutation"
            self.assertEqual(self.history.restore(snapshot)["entries"][0]["message"]["content"], "hello")
            self.assertEqual(read.call_count, 1)
            self.write([message("leaf", None, text="Changed on disk")])
            self.assertEqual(self.history.restore(snapshot)["entries"][0]["message"]["content"], "Changed on disk")
            self.assertEqual(read.call_count, 2)
        with patch("herdr_harness.pi_history._CACHE_BYTES", 1):
            uncached = PiSavedHistory()
            self.assertTrue(uncached.restore(snapshot)["history"]["complete"])
            self.assertEqual(len(uncached._cache), 0)
        with patch("herdr_harness.pi_history._CACHE_FILES", 2):
            for index in range(5):
                self.write([message("leaf", None, text=str(index))])
                self.history.restore(snapshot)
            self.assertLessEqual(len(self.history._cache), 2)

    def test_empty_and_multiple_roots(self):
        self.write([])
        result = self.history.restore(self.snapshot(None))
        self.assertTrue(result["history"]["complete"])
        self.write([message("first", None), message("second", None)])
        self.assertEqual([e["id"] for e in self.history.restore(self.snapshot("second"))["entries"]], ["second"])

    def test_rejects_ancestry_changed_between_index_and_projection(self):
        self.write([message("leaf", None)])
        original = self.path.read_bytes()

        class RewrittenFile(io.BytesIO):
            def seek(self, offset, whence=0):
                if offset > 0 and b'"leaf"' in self.getvalue():
                    position = self.tell()
                    self.getbuffer()[:] = original.replace(b'"leaf"', b'"fake"')
                    super().seek(position)
                return super().seek(offset, whence)

        with self.assertRaisesRegex(ValueError, "changed during read"):
            PiSavedHistory._read_branch(RewrittenFile(original), "session-one", "leaf")

    def test_oversized_or_incomplete_record_is_not_silently_skipped(self):
        self.write([message("leaf", None, text="x" * 500)])
        with patch("herdr_harness.pi_history._MAX_RECORD_BYTES", 200):
            self.assertFalse(self.history.restore(self.snapshot("leaf"))["history"]["complete"])
        self.path.write_bytes(self.path.read_bytes().rstrip(b"\n"))
        self.assertFalse(self.history.restore(self.snapshot("leaf"))["history"]["complete"])

    def test_manager_recovers_existing_bridge_without_reload_or_cursor_changes(self):
        entries = [message("old", None, text="Original prompt"), message("leaf", "old", "assistant", "Answer")]
        self.write(entries)
        manager = PiSemanticManager(str(Path(self.temp.name) / "terminal.sock"), environ={})
        self.addCleanup(manager.close)
        manager._known_pi_panes.add("w1:p1")
        snapshot = self.snapshot("leaf", entries[-1:])
        manager.journal.ingest("w1:p1", {
            "protocol": PI_SEMANTIC_PROTOCOL, "kind": "snapshot", "pane_id": "w1:p1",
            "instance_id": "bridge-one", "sequence": 10, "session_id": "session-one", "snapshot": snapshot,
        }, namespace=manager.namespace)
        checkpoint = manager.journal.snapshot("w1:p1", namespace=manager.namespace)
        restored = manager.snapshot_response("w1:p1")
        self.assertEqual(restored["entries"], entries)
        self.assertFalse(restored["truncated"])
        self.assertEqual(restored["cursor"], checkpoint["cursor"])
        self.assertEqual(restored["latest_cursor"], checkpoint["latest_cursor"])
        # Journal remains small and model-facing session-context limits unchanged.
        self.assertEqual(manager.journal.snapshot("w1:p1", namespace=manager.namespace)["entries"], entries[-1:])


if __name__ == "__main__":
    unittest.main()
