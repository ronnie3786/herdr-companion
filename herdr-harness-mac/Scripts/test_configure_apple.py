"""Security and portability checks for generated native build inputs."""
import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("configure_apple", Path(__file__).with_name("configure-apple.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AppleConfigurationTests(unittest.TestCase):
    def generate(self, directory: Path, extra: str = "", tail: str = "") -> None:
        for platform in ("mac", "ios"):
            app = directory / f"herdr-harness-{platform}" / f"herdr-harness-{platform}"
            app.mkdir(parents=True)
            source = MODULE.ROOT / f"herdr-harness-{platform}" / f"herdr-harness-{platform}" / f"herdr_harness_{platform}.entitlements"
            (app / source.name).write_bytes(source.read_bytes())
        config = directory / "private.toml"
        config.write_text('''version = 1
[server]
api_token = "test-secret-must-never-be-in-app"
[apple]
bundle_prefix = "org.example.test"
associated_domains = ["applinks:app.example.test"]
''' + extra + '''
[machines.desktop]
label = "Desktop"
url = "https://desktop.example.test"
role = "local"
ssh_host = "private-ssh.example.test"
ssh_user = "private-user"
''' + tail)
        with patch.object(MODULE, "ROOT", directory), patch("sys.argv", ["configure-apple.py", "--config", str(config)]), contextlib.redirect_stdout(io.StringIO()):
            MODULE.main()

    def test_only_nonsecret_machine_metadata_is_embedded(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.generate(root)
            for platform in ("mac", "ios"):
                project = root / f"herdr-harness-{platform}"
                roster = project / f"herdr-harness-{platform}" / "HerdrBootstrap.plist"
                self.assertEqual(plistlib.loads(roster.read_bytes()), [{"id": "desktop", "name": "Desktop", "urlString": "https://desktop.example.test", "role": "local"}])
                for output in (roster, project / "Local.xcconfig", project / "Local.entitlements"):
                    text = output.read_text()
                    self.assertNotIn("test-secret", text)
                    self.assertNotIn("private-user", text)
                    self.assertNotIn("private-ssh", text)
                    self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                entitlements = plistlib.loads((project / "Local.entitlements").read_bytes())
                self.assertEqual(entitlements["com.apple.developer.associated-domains"], ["applinks:app.example.test"])
                if platform == "mac":
                    self.assertTrue(entitlements["com.apple.security.app-sandbox"])
                    self.assertNotIn("keychain-access-groups", entitlements)
                    self.assertIn("HERDR_MAC_KEYCHAIN_BACKEND = login", (project / "Local.xcconfig").read_text())

    def test_mac_keychain_group_preserves_signing_build_variables(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.generate(root, 'mac_keychain_backend = "data-protection"\n')
            generated = root / "herdr-harness-mac" / "Local.entitlements"
            entitlements = plistlib.loads(generated.read_bytes())
            self.assertEqual(
                entitlements["keychain-access-groups"],
                ["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"],
            )

    def test_predictable_temporary_symlink_cannot_overwrite_another_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            victim = root / "keep.txt"
            victim.write_text("untouched")
            project = root / "herdr-harness-mac"
            project.mkdir()
            planted = project / "Local.xcconfig.tmp"
            planted.symlink_to(victim)
            self.generate(root)
            self.assertEqual(victim.read_text(), "untouched")
            self.assertTrue(planted.is_symlink())
            self.assertTrue((project / "Local.xcconfig").is_file())

    def test_build_only_machine_is_not_embedded_in_roster(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.generate(root, tail='\n[machines.builder]\nlabel = "Build only"\nrole = "node"\n')
            roster = root / "herdr-harness-ios/herdr-harness-ios/HerdrBootstrap.plist"
            self.assertEqual([item["id"] for item in plistlib.loads(roster.read_bytes())], ["desktop"])

    def test_build_setting_injection_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, "team_id"):
                self.generate(Path(temp), 'team_id = "TEAM\\nOTHER_SETTING=unsafe"\n')

    def test_unknown_mac_keychain_backend_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, "mac_keychain_backend"):
                self.generate(Path(temp), 'mac_keychain_backend = "plaintext"\n')

    def test_widget_identity_must_belong_to_parent_app(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, "widget_bundle_id"):
                self.generate(Path(temp), 'widget_bundle_id = "org.unrelated.widget"\n')


if __name__ == "__main__":
    unittest.main()
