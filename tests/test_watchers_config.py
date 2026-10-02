"""Rollout flags and private paths remain optional and machine-scoped."""
import json
from pathlib import Path
import stat
import tempfile
import threading
import unittest

from herdr_harness.config import load_configuration
from herdr_harness.service import HerdrService
from herdr_harness.watchers import settings


class WatchersConfigurationTests(unittest.TestCase):
    def test_omitted_section_is_disabled_and_state_paths_are_derived(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            path.write_text('[server]\nstate_dir="state"\n')
            path.chmod(0o600)
            config = load_configuration(path, environ={"HOME": directory})
            self.assertNotIn("HERDR_WATCHERS_ENABLED", config.environ)
            self.assertEqual(config.environ["HERDR_HARNESS_WATCHERS_STORE_PATH"], str(Path(directory).resolve() / "state/watchers.sqlite3"))
            self.assertEqual(config.environ["HERDR_HARNESS_WATCHERS_ROOT"], str(Path(directory).resolve() / "state/watchers"))
            self.assertEqual(config.environ["HERDR_HARNESS_WATCHERS_SETTINGS_PATH"], str(Path(directory).resolve() / "state/watchers-settings.json"))

    def test_optional_table_and_per_machine_escape_hatch(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            path.write_text('[watchers]\nmax_runs=3\nenabled="0"\n[machines.example]\nname="Example"\n[machines.example.environment]\nHERDR_WATCHERS_ENABLED="1"\n')
            path.chmod(0o600)
            config = load_configuration(path, "example", environ={"HOME": directory})
            self.assertEqual(config.environ["HERDR_WATCHERS_ENABLED"], "1")
            self.assertEqual(config.environ["HERDR_WATCHERS_MAX_RUNS"], "3")
            service = HerdrService.__new__(HerdrService)
            service._lock = threading.RLock()
            for value, expected, source in (("1", True, "config"), ("0", False, "config"), ("true", False, "default"), ("", False, "default")):
                service.environ = {"HERDR_WATCHERS_ENABLED": value}
                self.assertEqual(service.watchers_enabled, expected)
                self.assertEqual(service.watchers_settings()["source"], source)

    def test_explicit_root_is_resolved_like_other_private_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            config_dir = root / "config"
            config_dir.mkdir()
            path = config_dir / "config.toml"
            for raw, expected in (("watcher-state", config_dir / "watcher-state"), ("~/watcher-state", root / "watcher-state")):
                with self.subTest(root=raw):
                    path.write_text(f'[watchers]\nroot="{raw}"\n')
                    path.chmod(0o600)
                    config = load_configuration(path, environ={"HOME": str(root)})
                    self.assertEqual(config.environ["HERDR_HARNESS_WATCHERS_ROOT"], str(expected))


class WatchersSettingsFileTests(unittest.TestCase):
    def test_configuration_pins_the_value_and_otherwise_the_saved_choice_applies(self):
        self.assertEqual(settings.describe({"HERDR_WATCHERS_ENABLED": "1"}, {"enabled": False}), {"enabled": True, "source": "config", "changeable": False})
        self.assertEqual(settings.describe({"HERDR_WATCHERS_ENABLED": "0"}, {"enabled": True}), {"enabled": False, "source": "config", "changeable": False})
        self.assertEqual(settings.describe({"HERDR_WATCHERS_ENABLED": "true"}, {"enabled": True}), {"enabled": True, "source": "app", "changeable": True})
        self.assertEqual(settings.describe({}, None), {"enabled": False, "source": "default", "changeable": True})

    def test_path_follows_the_state_directory_and_explicit_override(self):
        self.assertEqual(settings.settings_path({"HERDR_STATE_DIR": "/example/state"}, home_default=False), Path("/example/state/watchers-settings.json"))
        self.assertEqual(settings.settings_path({"HERDR_STATE_DIR": "/example/state", settings.PATH_KEY: "/example/other.json"}, home_default=False), Path("/example/other.json"))
        self.assertEqual(settings.settings_path({"HOME": "/Users/example"}, home_default=True), Path("/Users/example/.local/share/herdr-companion/watchers-settings.json"))
        # A partially configured test service never reads the home state root.
        self.assertIsNone(settings.settings_path({"HOME": "/Users/example"}, home_default=False))

    def test_saved_file_is_private_atomic_and_tolerates_damage(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "new-state" / "watchers-settings.json"
            record = {"enabled": True, "changed_at": "2026-10-02T00:00:00.000Z", "changed_by": "user", "changed_via": "api"}
            settings.save(path, record)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            self.assertEqual(json.loads(path.read_text()), record)
            self.assertEqual(settings.load(path), record)
            self.assertEqual([entry.name for entry in path.parent.iterdir()], [path.name])
            for damaged in ("not json", "[]", '{"enabled": "yes"}', '{"enabled": 1}', "{" + " " * settings.MAXIMUM_BYTES + "}"):
                with self.subTest(damaged=damaged[:20]):
                    path.write_text(damaged)
                    self.assertIsNone(settings.load(path))
            settings.remove(path)
            self.assertFalse(path.exists())
            self.assertIsNone(settings.load(path))
            settings.remove(path)
