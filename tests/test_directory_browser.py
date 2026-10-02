"""Directory enumeration never interprets paths as commands or opens files."""
import errno
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from herdr_harness.directory_browser import DirectoryBrowserError, browse_directories, canonical_directory


class DirectoryBrowserTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def assert_error(self, code, operation):
        with self.assertRaises(DirectoryBrowserError) as error:
            operation()
        self.assertEqual(error.exception.code, code)

    def test_directories_only_hidden_opt_in_literal_names_and_server_home(self):
        for name in ("Garden iOS", "Web $(touch should-not-exist)", "日本語", ".private-garden"):
            (self.root / name).mkdir()
        (self.root / "notes.txt").write_text("Synthetic private content")
        page = browse_directories(home=self.root)
        self.assertEqual(page["path"], str(self.root))
        self.assertEqual(page["home_path"], str(self.root))
        self.assertEqual(len(page["entries"]), 3)
        self.assertNotIn("notes.txt", repr(page))
        self.assertNotIn(".private-garden", repr(page))
        self.assertEqual(len(browse_directories("~", home=self.root, show_hidden=True)["entries"]), 4)
        self.assertFalse((self.root / "should-not-exist").exists())

    def test_symlink_targets_are_disclosed_and_navigation_is_canonical(self):
        target = self.root / "Garden"
        target.mkdir()
        alias = self.root / "Alias"
        alias.symlink_to(target, target_is_directory=True)
        (self.root / "Broken").symlink_to(self.root / "Missing")
        entries = browse_directories(str(self.root))["entries"]
        entry = next(item for item in entries if item["name"] == "Alias")
        self.assertTrue(entry["is_symlink"])
        self.assertTrue(entry["can_open"])
        self.assertEqual(entry["resolved_path"], str(target))
        self.assertEqual(entry["path"], str(alias))
        self.assertEqual(browse_directories(str(alias))["path"], str(target))
        self.assertEqual(len(entries), 2)

    def test_large_directory_pages_are_stable_nonduplicating_and_bounded(self):
        for index in range(237):
            (self.root / f"garden-{index:03}").mkdir()
        paths, cursor, lengths = [], None, []
        while True:
            result = browse_directories(str(self.root), cursor=cursor)
            lengths.append(len(result["entries"]))
            paths.extend(entry["path"] for entry in result["entries"])
            cursor = result["next_cursor"]
            if cursor is None:
                break
        self.assertEqual(lengths, [100, 100, 37])
        self.assertEqual(len(set(paths)), 237)
        self.assertEqual(paths, sorted(paths))
        with patch("herdr_harness.directory_browser.MAX_SCAN_ENTRIES", 200):
            self.assert_error("directory_too_large", lambda: browse_directories(str(self.root)))

    def test_cursor_cannot_cross_paths_filters_or_directory_changes(self):
        for index in range(101):
            (self.root / f"garden-{index:03}").mkdir()
        cursor = browse_directories(str(self.root))["next_cursor"]
        self.assert_error("directory_stale", lambda: browse_directories(str(self.root), cursor=cursor, show_hidden=True))
        self.assert_error("directory_stale", lambda: browse_directories(str(self.root / "garden-000"), cursor=cursor))
        (self.root / "A new garden").mkdir()
        self.assert_error("directory_stale", lambda: browse_directories(str(self.root), cursor=cursor))
        for invalid in ("garbage!", "", "e30=", "x" * 513):
            self.assert_error("directory_cursor_invalid", lambda invalid=invalid: browse_directories(str(self.root), cursor=invalid))

    def test_missing_invalid_loop_and_denied_paths_have_typed_errors(self):
        for value in ("relative/path", "", "\x00", "/tmp/garden\ud800", 4, "x" * 4097):
            self.assert_error("directory_invalid", lambda value=value: canonical_directory(value))
        self.assert_error("directory_missing", lambda: canonical_directory(str(self.root / "missing")))
        file = self.root / "file"
        file.write_text("Synthetic")
        self.assert_error("directory_invalid", lambda: canonical_directory(str(file)))
        loop = self.root / "loop"
        loop.symlink_to(loop)
        self.assert_error("directory_invalid", lambda: canonical_directory(str(loop)))
        with patch("herdr_harness.directory_browser.os.access", return_value=False):
            self.assert_error("directory_denied", lambda: browse_directories(str(self.root)))
        with patch("herdr_harness.directory_browser.os.scandir", side_effect=PermissionError(errno.EACCES, "synthetic")):
            self.assert_error("directory_denied", lambda: browse_directories(str(self.root)))

    def test_cursor_detects_external_symlink_target_removal(self):
        folder = self.root / "Browse"
        folder.mkdir()
        target = self.root / "Target"
        target.mkdir()
        for index in range(100):
            (folder / f"garden-{index:03}").mkdir()
        (folder / "A link").symlink_to(target, target_is_directory=True)
        cursor = browse_directories(str(folder))["next_cursor"]
        target.rmdir()
        self.assert_error("directory_stale", lambda: browse_directories(str(folder), cursor=cursor))

    def test_scan_timeout_and_root_parent(self):
        (self.root / "Garden").mkdir()
        with patch("herdr_harness.directory_browser.time.monotonic", side_effect=[0.0, 4.0]):
            self.assert_error("directory_too_large", lambda: browse_directories(str(self.root)))
        with patch("herdr_harness.directory_browser.os.scandir") as scan:
            scan.return_value.__enter__.return_value = iter([])
            self.assertIsNone(browse_directories("/")["parent_path"])


if __name__ == "__main__":
    unittest.main()
