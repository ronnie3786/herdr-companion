from __future__ import annotations

import contextlib
import io
import json
import os
import plistlib
import tempfile
import unittest
from pathlib import Path

from scripts import prune_companion_runtimes as prune


def revision(letter: str, digit: str) -> str:
    return letter * 39 + digit


class PruneCompanionRuntimesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "runtimes"
        self.home = self.base / "home"
        self.root.mkdir()
        self.home.mkdir()

    def runtime(self, name: str, *, content: bytes = b"runtime", mtime: float | None = None) -> Path:
        path = self.root / name
        path.mkdir()
        (path / "payload").write_bytes(content)
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return path

    def test_detects_references_from_every_supported_source(self):
        arguments = revision("a", "1")
        working = revision("b", "2")
        packages = revision("c", "3")
        wrapper = revision("d", "4")
        launcher = revision("e", "5")
        for name in (arguments, working, packages, wrapper, launcher):
            self.runtime(name)

        agents = self.home / "Library" / "LaunchAgents"
        agents.mkdir(parents=True)
        with (agents / "arguments.plist").open("wb") as handle:
            plistlib.dump({"ProgramArguments": ["runtime", arguments]}, handle)
        with (agents / "working.plist").open("wb") as handle:
            plistlib.dump({"WorkingDirectory": f"/runtime/{working}"}, handle)
        settings = self.home / ".pi" / "agent"
        settings.mkdir(parents=True)
        (settings / "settings.json").write_text(json.dumps({"packages": {"nested": [packages]}}))
        bin_dir = self.home / ".local" / "bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "herdr-example").write_text(f"runtime={wrapper}\n")
        config = self.home / ".config" / "herdr-harness"
        config.mkdir(parents=True)
        (config / "run-herdr-harness.sh").write_text(f"runtime={launcher}\n")

        result = prune.prune(self.root, self.home, 0, apply=False)

        self.assertEqual(result["inUse"], sorted((arguments, working, packages, wrapper, launcher)))
        self.assertEqual(result["kept"], result["inUse"])
        self.assertEqual(result["removed"], [])

    def test_recovers_references_from_malformed_launch_agent_plist(self):
        referenced = revision("a", "1")
        self.runtime(referenced)
        agents = self.home / "Library" / "LaunchAgents"
        agents.mkdir(parents=True)
        malformed = agents / "malformed.plist"
        malformed.write_bytes(
            plistlib.dumps({"ProgramArguments": ["runtime", referenced]}) + b"\nnot xml garbage"
        )

        result = prune.prune(self.root, self.home, 0, apply=False)

        self.assertIn(referenced, result["inUse"])
        warnings = [warning for warning in result["warnings"] if warning["file"] == str(malformed)]
        self.assertEqual(len(warnings), 1)
        self.assertTrue(warnings[0]["problem"])

    def test_warns_for_undecodable_pi_settings(self):
        settings = self.home / ".pi" / "agent" / "settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_bytes(b"\xff\xfe not json")

        result = prune.prune(self.root, self.home, 0, apply=False)

        self.assertTrue(any(warning["file"] == str(settings) for warning in result["warnings"]))

    def test_retains_newest_unused_and_all_in_use_runtimes(self):
        oldest = revision("a", "1")
        in_use = revision("b", "2")
        newer = revision("c", "3")
        newest = revision("d", "4")
        for offset, name in enumerate((oldest, in_use, newer, newest), start=1):
            self.runtime(name, mtime=float(offset))
        bin_dir = self.home / ".local" / "bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "herdr-example").write_text(in_use)

        result = prune.prune(self.root, self.home, 2, apply=False)

        self.assertEqual(result["inUse"], [in_use])
        self.assertEqual(result["kept"], sorted((in_use, newer, newest)))
        self.assertEqual(result["removed"], [oldest])

    def test_dry_run_reports_size_and_apply_deletes_exactly_that_set(self):
        old = revision("a", "1")
        middle = revision("b", "2")
        newest = revision("c", "3")
        self.runtime(old, content=b"one", mtime=1)
        self.runtime(middle, content=b"four", mtime=2)
        self.runtime(newest, content=b"newest", mtime=3)

        dry_run = prune.prune(self.root, self.home, 1, apply=False)

        self.assertEqual(dry_run["removed"], [old, middle])
        self.assertEqual(dry_run["freedBytes"], 7)
        self.assertTrue((self.root / old).is_dir())
        self.assertTrue((self.root / middle).is_dir())
        applied = prune.prune(self.root, self.home, 1, apply=True)
        self.assertEqual(applied, dry_run)
        self.assertFalse((self.root / old).exists())
        self.assertFalse((self.root / middle).exists())
        self.assertTrue((self.root / newest).is_dir())

    def test_ignores_non_revision_directories(self):
        invalid = ("short", "A" * 40, "g" * 40, "unrelated")
        for name in invalid:
            (self.root / name).mkdir()

        result = prune.prune(self.root, self.home, 0, apply=True)

        self.assertEqual(result["inUse"], [])
        self.assertEqual(result["kept"], [])
        self.assertEqual(result["removed"], [])
        for name in invalid:
            self.assertTrue((self.root / name).is_dir())

    def test_ignores_matching_symlink_and_preserves_its_target(self):
        target = self.base / "outside-runtime"
        target.mkdir()
        marker = target / "marker"
        marker.write_text("keep")
        link = self.root / revision("f", "6")
        link.symlink_to(target, target_is_directory=True)

        result = prune.prune(self.root, self.home, 0, apply=True)

        self.assertEqual(result["removed"], [])
        self.assertTrue(link.is_symlink())
        self.assertTrue(marker.is_file())

    def test_main_reports_the_unresolved_root_string(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = prune.main(["--root", str(self.root), "--home", str(self.home)])

        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output.getvalue())["root"], str(self.root))


if __name__ == "__main__":
    unittest.main()
