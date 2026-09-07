"""Release safety checks run without a certificate, Keychain, network, or app build."""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("herdr_release_macos", ROOT / "scripts/release-macos.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
STABLE = {"version": "1.2.3", "build": 12, "channel": "stable", "preview": 0}
PREVIEW = {"version": "1.3.0", "build": 13, "channel": "preview", "preview": 1}
SOURCE = "a" * 40


def feed(versions):
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    for version in versions:
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, release.SPARKLE_NS + "version").text = str(version["build"])
        ET.SubElement(item, release.SPARKLE_NS + "shortVersionString").text = version["version"]
        if version["channel"] == "preview":
            ET.SubElement(item, release.SPARKLE_NS + "channel").text = "preview"
        tag = release.release_tag(version)
        ET.SubElement(item, "enclosure", {"url": f"https://github.com/{release.REPOSITORY}/releases/download/{tag}/Herdr-{tag.removeprefix('macos-v')}.zip",
                                        release.SPARKLE_NS + "edSignature": "synthetic-signature"})
    return ET.tostring(root)


class ReleaseSafetyTests(unittest.TestCase):
    def test_minor_bump_resets_patch_and_keeps_global_build_increasing(self):
        self.assertEqual(release.next_version(STABLE), {"version": "1.3.0", "build": 13, "channel": "stable", "preview": 0})

    def test_preview_iteration_and_promotion_have_distinct_tags_and_builds(self):
        second = release.next_version(PREVIEW, "build", "preview")
        stable = release.next_version(second, "build", "stable")
        self.assertEqual((second["preview"], second["build"], stable["build"]), (2, 14, 15))
        self.assertEqual(len({release.release_tag(value) for value in (PREVIEW, second, stable)}), 3)

    def test_stable_build_only_cannot_reuse_immutable_tag(self):
        with self.assertRaisesRegex(release.ReleaseError, "immutable"):
            release.next_version(STABLE, "build", "stable")

    def test_version_rejects_boolean_build_and_noncanonical_versions(self):
        for change in ({"build": True}, {"version": "01.2.3"}, {"preview": 1}, {"extra": "value"}):
            with self.subTest(change=change), self.assertRaises(release.ReleaseError):
                release.validate_version({**STABLE, **change})

    def test_tools_are_exact_pinned_binaries(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in release.TOOL_HASHES:
                (Path(directory) / name).write_text("unexpected executable")
            with self.assertRaisesRegex(release.ReleaseError, "pinned"):
                release.tools_path(SimpleNamespace(sparkle_tools=directory), {})

    def test_only_github_cli_receives_its_own_auth_environment(self):
        environment = {"HOME": "/home/developer", "PATH": "/usr/bin", "GH_TOKEN": "synthetic", "HERDR_HARNESS_API_TOKEN": "synthetic", "OPENAI_API_KEY": "synthetic", "DYLD_INSERT_LIBRARIES": "synthetic"}
        with patch.dict(os.environ, environment, clear=True):
            self.assertEqual(set(release.command_environment("xcodebuild")), {"HOME", "PATH"})
            self.assertEqual(set(release.command_environment("gh")), {"HOME", "PATH", "GH_TOKEN"})

    def test_failure_output_stays_in_owner_only_diagnostics(self):
        result = subprocess.CompletedProcess(["synthetic"], 1, b"private-output-marker", b"private-error-marker")
        with patch.object(release.subprocess, "run", return_value=result), self.assertRaises(release.ReleaseError) as caught:
            release.run(["synthetic", "private-argument-marker"])
        message = str(caught.exception)
        self.assertNotIn("marker", message)
        path = Path(message.split("private diagnostics: ", 1)[1])
        try:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            self.assertIn(b"private-output-marker", path.read_bytes())
            self.assertNotIn(b"private-argument-marker", path.read_bytes())
        finally:
            shutil.rmtree(path.parent)

    def test_prepare_rejects_development_signing_before_external_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "settings.toml"
            config.write_text('[deployment.macos_release]\nsigning_identity = "Apple Development: Example (ABCDEFGHIJ)"\nnotary_profile = "example"\n')
            with patch.dict(os.environ, {}, clear=True), patch.object(release, "run") as command, redirect_stderr(io.StringIO()) as errors:
                result = release.main(["prepare", "--config", str(config), "--notes", str(Path(directory) / "notes.md"), "--output", str(Path(directory) / "out")])
            self.assertEqual(result, 1)
            self.assertIn("Developer ID", errors.getvalue())
            command.assert_not_called()

    def test_release_config_resolves_relative_paths_without_loading_provider_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "settings.toml"
            config.write_text('[providers.summary]\ntoken_file = "absent-secret"\n[deployment.macos_release]\nsparkle_tools = "tools/bin"\nprivate_patterns_file = "patterns.json"\n')
            with patch.dict(os.environ, {}, clear=True):
                settings = release.release_settings(SimpleNamespace(config=config, machine=None))
            self.assertEqual(settings["sparkle_tools"], str(Path(directory).resolve() / "tools/bin"))
            self.assertEqual(settings["private_patterns_file"], str(Path(directory).resolve() / "patterns.json"))

    def test_symlink_notes_are_rejected_and_regular_notes_are_scanned(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "notes.md"
            path.write_text("synthetic private marker")
            link = Path(directory) / "link.md"
            link.symlink_to(path)
            with self.assertRaisesRegex(release.ReleaseError, "symlink"):
                release.privacy_check(link)
            with patch.object(release, "private_patterns", return_value=[("private identifier", __import__("re").compile(b"synthetic private marker"))]), self.assertRaisesRegex(release.ReleaseError, "privacy"):
                release.privacy_check(path)

    def test_private_pattern_file_permissions_are_enforced(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "patterns.json"
            path.write_text('["synthetic marker"]')
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                release.private_patterns({"private_patterns_file": str(path)})
            path.chmod(0o600)
            self.assertEqual(len(release.private_patterns({"private_patterns_file": str(path)})), 1)

    def test_feed_rejects_external_archives_unknown_channels_and_dtd(self):
        valid = feed([STABLE])
        invalid = [valid.replace(b"github.com", b"example.invalid"), valid.replace(b"<enclosure", b"<sparkle:channel xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle'>other</sparkle:channel><enclosure"), b"<!DOCTYPE rss>" + valid]
        for data in invalid:
            with self.subTest(data=data[:30]), self.assertRaises(release.ReleaseError):
                release.feed_items(data)

    def test_feed_keeps_stable_and_preview_and_resigns_friendly_preview_label(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            def execute(argv, **kwargs):
                if Path(argv[0]).name == "generate_appcast":
                    (path / "appcast.xml").write_bytes(feed([STABLE, PREVIEW]))
                return subprocess.CompletedProcess(argv, 0, b"", b"")
            with patch.object(release, "run", side_effect=execute) as commands:
                result = release.assemble_feed(path, PREVIEW, Path("/tools"), {}, feed([STABLE]))
            items = release.feed_items(result.read_bytes())
            self.assertEqual(len(items), 2)
            self.assertEqual(items[1].findtext(release.SPARKLE_NS + "shortVersionString"), "1.3.0 Preview 1")
            invocations = [list(call.args[0]) for call in commands.call_args_list]
            generate = next(args for args in invocations if Path(args[0]).name == "generate_appcast")
            self.assertIn("--channel", generate)
            self.assertEqual(generate[generate.index("--maximum-versions") + 1], "0")
            self.assertEqual(Path(invocations[-2][0]).name, "sign_update")
            self.assertNotIn("--verify", invocations[-2])
            self.assertIn("--verify", invocations[-1])

    def test_feed_refuses_lower_build_before_generation(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release, "run") as commands:
            with self.assertRaisesRegex(release.ReleaseError, "exceed"):
                release.assemble_feed(Path(directory), STABLE, Path("/tools"), {}, feed([PREVIEW]))
            self.assertEqual(commands.call_count, 1)  # Verify existing feed before trusting its build.

    def test_feed_refuses_tool_output_that_drops_previous_release(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            def execute(argv, **kwargs):
                if Path(argv[0]).name == "generate_appcast": (path / "appcast.xml").write_bytes(feed([PREVIEW]))
            with patch.object(release, "run", side_effect=execute), self.assertRaisesRegex(release.ReleaseError, "dropped"):
                release.assemble_feed(path, PREVIEW, Path("/tools"), {}, feed([STABLE]))

    def test_zip_traversal_and_escaping_symlinks_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            for symlink in (False, True):
                archive = path / "test.zip"
                with zipfile.ZipFile(archive, "w") as zipped:
                    if symlink:
                        info = zipfile.ZipInfo("Herdr.app/link")
                        info.external_attr = (stat.S_IFLNK | 0o777) << 16
                        zipped.writestr(info, "../../outside")
                    else: zipped.writestr("../outside", "unsafe")
                with patch.object(release, "run") as command, self.assertRaises(release.ReleaseError):
                    release.safe_zip(archive, path / "extracted")
                command.assert_not_called()

    def test_existing_assets_can_resume_only_without_replacing_bytes(self):
        manifest = {"assets": {"one.zip": "abc", "release.json": "def"}, "release": PREVIEW}
        existing = {"assets": [{"name": "one.zip", "digest": "sha256:abc"}], "prerelease": True}
        self.assertEqual(release.verify_remote_assets(existing, manifest, complete=False), {"release.json"})
        with self.assertRaises(release.ReleaseError): release.verify_remote_assets(existing, manifest, complete=True)
        existing["assets"][0]["digest"] = "sha256:changed"
        with self.assertRaisesRegex(release.ReleaseError, "not be overwritten"):
            release.verify_remote_assets(existing, manifest, complete=False)

    def test_tag_absence_is_only_a_404_and_annotated_tags_are_resolved(self):
        for result, expected in [(subprocess.CompletedProcess([], 1, b"", b"HTTP 404"), None), (subprocess.CompletedProcess([], 0, json.dumps({"object": {"type": "commit", "sha": SOURCE}}).encode(), b""), SOURCE)]:
            with patch.object(release, "run", return_value=result): self.assertEqual(release.tag_commit("synthetic"), expected)
        with patch.object(release, "run", return_value=subprocess.CompletedProcess([], 1, b"", b"HTTP 403")), self.assertRaises(release.ReleaseError):
            release.tag_commit("synthetic")
        obj = {"object": {"type": "tag", "sha": "b" * 40}}
        with patch.object(release, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(obj).encode(), b"")), patch.object(release, "api", return_value={"object": {"type": "commit", "sha": SOURCE}}):
            self.assertEqual(release.tag_commit("synthetic"), SOURCE)


class PreparationBoundaryTests(unittest.TestCase):
    def test_privacy_failure_stops_before_notary_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notes = root / "notes.md"; notes.write_text("Synthetic release notes")
            events = []
            def execute(argv, **kwargs):
                events.append([str(arg) for arg in argv])
                if "-exportArchive" in argv:
                    path = Path(argv[argv.index("-exportPath") + 1]) / "Exported.app"
                    path.mkdir(parents=True)
                return subprocess.CompletedProcess(argv, 0, b"", b"")
            settings = {"signing_identity": "Developer ID Application: Example (ABCDEFGHIJ)", "notary_profile": "synthetic-profile"}
            args = SimpleNamespace(output=root / "out", notes=notes)
            with patch.object(release, "release_settings", return_value=settings), patch.object(release, "tools_path", return_value=Path("/tools")), patch.object(release, "signing_preflight"), patch.object(release, "source_revision", return_value=SOURCE), patch.object(release, "require_green_ci"), patch.object(release, "privacy_check"), patch.object(release, "read_feed", return_value=None), patch.object(release, "export_source"), patch.object(release, "run", side_effect=execute), patch.object(release, "audit_app", side_effect=release.ReleaseError("privacy rejected")) as audit:
                with self.assertRaisesRegex(release.ReleaseError, "privacy rejected"):
                    release.prepare(args)
            self.assertEqual(audit.call_args.kwargs, {"notarized": False})
            self.assertEqual(audit.call_args.args[0].name, "Herdr.app")
            self.assertTrue(any("archive" in argv for argv in events))
            self.assertTrue(any("-exportArchive" in argv for argv in events))
            self.assertFalse(any("submit" in argv for argv in events))
            self.assertFalse((args.output / "prepared.json").exists())

    def test_changed_prepared_metadata_is_rejected_before_verification_or_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            names = ["archive.zip", "notes.md", "appcast.xml", "release.json", "release.json.ed25519", "SHA256SUMS"]
            metadata = {"schema": 1, "source": SOURCE, "tag": release.release_tag(PREVIEW), "release": PREVIEW,
                        "bundle_id": release.BUNDLE_ID, "public_key": release.PUBLIC_KEY,
                        "feed_url": release.FEED_URL, "archive": "archive.zip", "notes": "notes.md"}
            for name in names: (root / name).write_text("synthetic")
            (root / "release.json").write_text(json.dumps(metadata))
            manifest = {**metadata, "source": "b" * 40,
                        "assets": {name: release.digest(root / name) for name in names}}
            path = root / "prepared.json"; path.write_text(json.dumps(manifest))
            with patch.object(release, "run") as command, self.assertRaisesRegex(release.ReleaseError, "signed release metadata"):
                release.verify_prepared(path, Path("/tools"), {})
            command.assert_not_called()


class PublishTransactionTests(unittest.TestCase):
    def exercise(self, *, resume=False, competing_tag=False, restore_missing=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "prepared.json"
            (path.parent / "appcast.xml").write_bytes(feed([PREVIEW]))
            manifest = {"source": SOURCE, "tag": release.release_tag(PREVIEW), "release": PREVIEW,
                        "assets": {"archive.zip": "abc"}, "notes": "notes.md", "previous_feed_sha256": "previous-feed-hash" if restore_missing else None}
            published = {"draft": False, "prerelease": True, "assets": [{"name": "archive.zip", "digest": "sha256:abc"}]}
            remote = {"draft": not resume, "prerelease": True, "assets": published["assets"] if resume else []}
            events = []
            def call_api(endpoint, **kwargs):
                events.append(("api", endpoint, kwargs))
                if endpoint == "releases/tags/" + release.FEED_TAG:
                    return {"prerelease": True, "draft": False, "immutable": False}
                if endpoint == "releases/tags/" + manifest["tag"]:
                    return remote
            def call_gh(*args, **kwargs):
                events.append(("gh", args, kwargs))
                if args[:2] == ("release", "list"):
                    return json.dumps([{"tagName": release.FEED_TAG}] + ([{"tagName": manifest["tag"]}] if resume else [])).encode()
                if args[:2] == ("release", "upload") and args[2] == manifest["tag"]:
                    remote["assets"] = published["assets"]
                return b""
            targets = [SOURCE if resume else None, "b" * 40 if competing_tag else SOURCE]
            with patch.object(release, "release_settings", return_value={}), patch.object(release, "validate_signing_settings"), patch.object(release, "tools_path", return_value=Path("/tools")), patch.object(release, "signing_preflight"), patch.object(release, "verify_prepared", return_value=manifest), patch.object(release, "require_green_ci"), patch.object(release, "read_feed", side_effect=[None, (path.parent / "appcast.xml").read_bytes()]), patch.object(release, "api", side_effect=call_api), patch.object(release, "gh", side_effect=call_gh), patch.object(release, "tag_commit", side_effect=targets), redirect_stdout(io.StringIO()):
                if competing_tag:
                    with self.assertRaisesRegex(release.ReleaseError, "tag changed"):
                        release.publish(SimpleNamespace(manifest=path, restore_missing_feed=restore_missing))
                else: release.publish(SimpleNamespace(manifest=path, restore_missing_feed=restore_missing))
            return events

    def test_new_tag_is_atomically_bound_before_draft_and_feed_is_last(self):
        events = self.exercise()
        creates = [event for event in events if event[0] == "api" and event[1] == "git/refs"]
        self.assertEqual(creates[1][2]["payload"], {"ref": "refs/tags/" + release.release_tag(PREVIEW), "sha": SOURCE})
        commands = [event[1] for event in events if event[0] == "gh"]
        draft = next(command for command in commands if command[:2] == ("release", "create"))
        self.assertIn("--verify-tag", draft)
        self.assertEqual(commands[-1][2], release.FEED_TAG)
        self.assertEqual(events[-1][2]["method"], "DELETE")

    def test_published_version_retry_only_replaces_rolling_feed(self):
        commands = [event[1] for event in self.exercise(resume=True) if event[0] == "gh"]
        self.assertFalse(any(command[:2] in (("release", "create"), ("release", "edit")) for command in commands))
        uploads = [command for command in commands if command[:2] == ("release", "upload")]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0][2], release.FEED_TAG)

    def test_explicit_missing_feed_restore_only_uploads_feed_for_matching_published_version(self):
        commands = [event[1] for event in self.exercise(resume=True, restore_missing=True) if event[0] == "gh"]
        self.assertFalse(any(command[:2] in (("release", "create"), ("release", "edit")) for command in commands))
        self.assertEqual([command[2] for command in commands if command[:2] == ("release", "upload")], [release.FEED_TAG])
        with self.assertRaisesRegex(release.ReleaseError, "published already"):
            self.exercise(restore_missing=True)

    def test_changed_final_tag_blocks_publication_and_releases_lock(self):
        events = self.exercise(competing_tag=True)
        self.assertFalse(any(event[0] == "gh" and event[1][:2] == ("release", "edit") for event in events))
        self.assertFalse(any(event[0] == "gh" and event[1][:3] == ("release", "upload", release.FEED_TAG) for event in events))
        self.assertEqual(events[-1][2]["method"], "DELETE")


if __name__ == "__main__":
    unittest.main()
