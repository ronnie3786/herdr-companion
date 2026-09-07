"""Atomic Fleet promotion must preserve a concurrently created destination."""

import errno
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from herdr_harness import fleet


class ExclusiveMoveTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.source = self.root / "source"
        self.destination = self.root / "destination"

    def test_native_directory_promotion_keeps_complete_tree(self):
        self.source.mkdir()
        (self.source / "value").write_text("complete tree")
        fleet._exclusive_move(self.source, self.destination)
        self.assertFalse(self.source.exists())
        self.assertEqual((self.destination / "value").read_text(), "complete tree")

    def test_native_promotion_never_replaces_existing_destination(self):
        self.source.mkdir()
        (self.source / "value").write_text("source data")
        for kind in ("file", "empty-directory", "directory", "symlink"):
            with self.subTest(kind=kind):
                if kind == "file":
                    self.destination.write_text("keep existing")
                elif kind == "symlink":
                    self.destination.symlink_to(self.root / "missing")
                else:
                    self.destination.mkdir()
                    if kind == "directory":
                        (self.destination / "value").write_text("keep existing")
                identity = self.destination.lstat().st_ino
                with self.assertRaises(OSError) as raised:
                    fleet._exclusive_move(self.source, self.destination)
                self.assertEqual(raised.exception.errno, errno.EEXIST)
                self.assertEqual(self.destination.lstat().st_ino, identity)
                self.assertEqual((self.source / "value").read_text(), "source data")
                if kind == "directory":
                    self.assertEqual((self.destination / "value").read_text(), "keep existing")
                    (self.destination / "value").unlink()
                if kind.endswith("directory"):
                    self.destination.rmdir()
                else:
                    if kind == "file":
                        self.assertEqual(self.destination.read_text(), "keep existing")
                    self.destination.unlink()

    def test_linux_uses_no_replace_flag_and_current_directory_descriptors(self):
        renameat2 = mock.Mock(return_value=0)
        with mock.patch.object(fleet.platform, "system", return_value="Linux"), mock.patch.object(
            fleet.ctypes, "CDLL", return_value=SimpleNamespace(renameat2=renameat2)
        ), mock.patch.object(fleet.os, "link") as link:
            fleet._exclusive_move(self.source, self.destination)
        renameat2.assert_called_once_with(-100, os.fsencode(self.source), -100, os.fsencode(self.destination), 1)
        link.assert_not_called()

    def test_linux_native_errors_cannot_trigger_an_overwrite_fallback(self):
        self.source.write_text("source data")
        for error in (errno.EEXIST, errno.EXDEV, errno.EACCES, errno.EIO):
            with self.subTest(error=error), mock.patch.object(fleet.platform, "system", return_value="Linux"), mock.patch.object(
                fleet.ctypes, "CDLL", return_value=SimpleNamespace(renameat2=mock.Mock(return_value=-1))
            ), mock.patch.object(fleet.ctypes, "get_errno", return_value=error), mock.patch.object(fleet.os, "link") as link:
                with self.assertRaises(OSError) as raised:
                    fleet._exclusive_move(self.source, self.destination)
                self.assertEqual(raised.exception.errno, error)
                link.assert_not_called()
                self.assertEqual(self.source.read_text(), "source data")

    def test_linux_without_native_support_rejects_directory_promotion(self):
        self.source.mkdir()
        cases = [(SimpleNamespace(), None)] + [
            (SimpleNamespace(renameat2=mock.Mock(return_value=-1)), error)
            for error in (errno.ENOSYS, errno.EINVAL, errno.ENOTSUP)
        ]
        for libc, error in cases:
            with self.subTest(error=error), mock.patch.object(fleet.platform, "system", return_value="Linux"), mock.patch.object(
                fleet.ctypes, "CDLL", return_value=libc
            ), mock.patch.object(fleet.ctypes, "get_errno", return_value=error):
                with self.assertRaises(OSError) as raised:
                    fleet._exclusive_move(self.source, self.destination)
                self.assertEqual(raised.exception.errno, errno.ENOTSUP)
                self.assertTrue(self.source.is_dir())
                self.assertFalse(self.destination.exists())

    def test_linux_without_native_support_preserves_regular_file_fallback(self):
        self.source.write_text("source data")
        with mock.patch.object(fleet.platform, "system", return_value="Linux"), mock.patch.object(
            fleet.ctypes, "CDLL", return_value=SimpleNamespace()
        ):
            self.destination.write_text("existing data")
            with self.assertRaises(FileExistsError):
                fleet._exclusive_move(self.source, self.destination)
            self.assertEqual(self.destination.read_text(), "existing data")
            self.assertEqual(self.source.read_text(), "source data")
            self.destination.unlink()
            fleet._exclusive_move(self.source, self.destination)
            self.assertFalse(self.source.exists())
            self.assertEqual(self.destination.read_text(), "source data")
