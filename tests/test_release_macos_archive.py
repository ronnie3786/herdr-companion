"""Portable security regressions for release archive and artifact validation."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("herdr_release_archive_checks", ROOT / "scripts/release-macos.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def write_archive(path, entries):
    """Entries are (member name, contents, whether it is a symbolic link)."""
    with zipfile.ZipFile(path, "w") as archive:
        for name, contents, symlink in entries:
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = ((stat.S_IFLNK | 0o777) if symlink else (stat.S_IFREG | 0o644)) << 16
            archive.writestr(info, contents)


def valid_feed():
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, release.SPARKLE_NS + "version").text = "12"
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{release.REPOSITORY}/releases/download/macos-v1.2.3/Herdr-1.2.3.zip",
        release.SPARKLE_NS + "edSignature": "synthetic-signature",
    })
    return root


class ArchiveTopologyTests(unittest.TestCase):
    def assert_rejected_before_extraction(self, entries):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "release.zip"
            write_archive(archive, entries)
            with patch.object(release, "run") as command:
                with self.assertRaises(release.ReleaseError):
                    release.safe_zip(archive, root / "extracted")
                command.assert_not_called()
            self.assertFalse((root / "extracted").exists())

    def test_symlink_chain_cannot_escape_in_either_archive_order(self):
        # Each target looks contained when normalized without resolving the
        # other archive member. Together they resolve above the extraction root.
        links = [("Herdr Companion.app/a", ".", True),
                 ("Herdr Companion.app/sub/link", "../a/../..", True)]
        for entries in (links, list(reversed(links))):
            with self.subTest(order=[item[0] for item in entries]):
                self.assert_rejected_before_extraction(entries)

    def test_symlink_cycle_is_rejected_before_extraction(self):
        self.assert_rejected_before_extraction([
            ("Herdr Companion.app/first", "second", True),
            ("Herdr Companion.app/second", "first", True),
        ])

    def test_archive_cannot_write_through_another_member_symlink(self):
        self.assert_rejected_before_extraction([
            ("Herdr Companion.app/link", "real", True),
            ("Herdr Companion.app/real/file", "first payload", False),
            ("Herdr Companion.app/link/file", "replacement payload", False),
        ])

    def test_normalized_member_aliases_cannot_overwrite_a_checked_file(self):
        self.assert_rejected_before_extraction([
            ("Herdr Companion.app/file", "first payload", False),
            ("Herdr Companion.app/./file", "replacement payload", False),
        ])

    def test_absolute_paths_and_unaudited_top_level_payloads_are_rejected(self):
        for name in ("/outside", "unreviewed-command", "Other.app/Contents/Info.plist"):
            with self.subTest(name=name):
                self.assert_rejected_before_extraction([
                    ("Herdr Companion.app/Contents/Info.plist", "synthetic plist", False),
                    (name, "unexpected payload", False),
                ])

    def test_legitimate_sparkle_framework_links_and_resource_forks_are_allowed(self):
        framework = "Herdr Companion.app/Contents/Frameworks/Sparkle.framework/"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "release.zip"
            write_archive(archive, [
                (framework + "Versions/B/Sparkle", "synthetic executable", False),
                (framework + "Versions/B/Resources/Info.plist", "synthetic plist", False),
                (framework + "Versions/Current", "B", True),
                (framework + "Sparkle", "Versions/Current/Sparkle", True),
                (framework + "Resources", "Versions/Current/Resources", True),
                ("__MACOSX/Herdr Companion.app/._Contents", "synthetic resource fork", False),
            ])
            with patch.object(release, "run") as command:
                release.safe_zip(archive, root / "extracted")
            command.assert_called_once_with(["ditto", "-x", "-k", archive, root / "extracted"])


class ArtifactPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        patterns = self.root / "patterns.json"
        patterns.write_text(json.dumps(["synthetic-operator-identifier"]))
        patterns.chmod(0o600)
        self.settings = {"private_patterns_file": str(patterns)}

    def assert_private(self, path, **kwargs):
        with self.assertRaises(release.ReleaseError) as caught:
            release.privacy_check(path, self.settings, **kwargs)
        self.assertNotIn("synthetic-operator-identifier", str(caught.exception).lower())

    def test_configured_private_patterns_scan_real_notes_and_nested_resources(self):
        notes = self.root / "notes.md"
        notes.write_text("Public update notes.")
        release.privacy_check(notes, self.settings)
        notes.write_text("A SYNTHETIC-OPERATOR-IDENTIFIER must stay private.")
        self.assert_private(notes)
        app = self.root / "Herdr.app"
        resource = app / "Contents/Resources/example.txt"
        resource.parent.mkdir(parents=True)
        resource.write_bytes(notes.read_bytes())
        self.assert_private(app)

    def test_symlinked_artifact_directory_is_not_treated_as_empty(self):
        app = self.root / "Herdr.app"
        app.mkdir()
        (app / "resource.txt").write_text("synthetic-operator-identifier")
        link = self.root / "linked.app"
        link.symlink_to(app, target_is_directory=True)
        self.assert_private(link)

    def test_resource_symlink_cannot_escape_the_app_privacy_boundary(self):
        app = self.root / "Herdr.app"
        app.mkdir()
        outside = self.root / "private.txt"
        outside.write_text("synthetic-operator-identifier")
        (app / "resource.txt").symlink_to(outside)
        self.assert_private(app)

    def test_only_exact_certificate_bytes_inside_macho_are_exempt(self):
        certificate = b"synthetic certificate: synthetic-operator-identifier"
        executable = self.root / "executable"
        executable.write_bytes(b"\xcf\xfa\xed\xfe" + b"synthetic code" + certificate)
        release.privacy_check(executable, self.settings, certificate=certificate)
        # The same identifier anywhere outside the exact certificate remains private.
        executable.write_bytes(executable.read_bytes() + b"synthetic-operator-identifier")
        self.assert_private(executable, certificate=certificate)

    def test_certificate_exception_does_not_exempt_notes_or_resource_contents(self):
        certificate = b"synthetic certificate: synthetic-operator-identifier"
        notes = self.root / "notes.md"
        notes.write_bytes(certificate)
        self.assert_private(notes, certificate=certificate)


class AppcastInputTests(unittest.TestCase):
    def test_malformed_xml_and_entity_declarations_are_rejected(self):
        for data in (b"<rss><channel>", b"not XML", b'<!ENTITY sample "content"><rss/>'):
            with self.subTest(data=data), self.assertRaises(release.ReleaseError):
                release.feed_items(data)

    def test_oversized_feed_is_rejected_before_xml_parsing(self):
        with patch.object(release.ET, "fromstring") as parse:
            with self.assertRaises(release.ReleaseError):
                release.feed_items(b" " * (2 * 1024 * 1024 + 1))
            parse.assert_not_called()

    def test_archive_urls_cannot_add_traversal_queries_or_sibling_assets(self):
        valid = valid_feed()
        url = valid.find("./channel/item/enclosure").get("url")
        for altered in (url + "?redirect=other", url.replace("/Herdr-", "/../Herdr-"),
                        url.replace("/Herdr-", "/Different-")):
            with self.subTest(url=altered):
                root = valid_feed()
                root.find("./channel/item/enclosure").set("url", altered)
                with self.assertRaises(release.ReleaseError):
                    release.feed_items(ET.tostring(root))
        self.assertEqual(len(release.feed_items(ET.tostring(valid))), 1)

    def test_missing_signature_enclosure_or_numeric_build_is_rejected(self):
        for missing in ("signature", "enclosure", "build"):
            root = valid_feed()
            item = root.find("./channel/item")
            if missing == "signature":
                del item.find("enclosure").attrib[release.SPARKLE_NS + "edSignature"]
            elif missing == "enclosure":
                item.remove(item.find("enclosure"))
            else:
                item.find(release.SPARKLE_NS + "version").text = "twelve"
            with self.subTest(missing=missing), self.assertRaises(release.ReleaseError):
                release.feed_items(ET.tostring(root))


if __name__ == "__main__":
    unittest.main()
