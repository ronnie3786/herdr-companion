"""Rollout flags and private paths remain optional and machine-scoped."""
from pathlib import Path
import tempfile
import unittest

from herdr_harness.config import load_configuration
from herdr_harness.service import HerdrService


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

    def test_optional_table_and_per_machine_escape_hatch(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            path.write_text('[watchers]\nmax_runs=3\nenabled="0"\n[machines.example]\nname="Example"\n[machines.example.environment]\nHERDR_WATCHERS_ENABLED="1"\n')
            path.chmod(0o600)
            config = load_configuration(path, "example", environ={"HOME": directory})
            self.assertEqual(config.environ["HERDR_WATCHERS_ENABLED"], "1")
            self.assertEqual(config.environ["HERDR_WATCHERS_MAX_RUNS"], "3")
            service = HerdrService.__new__(HerdrService)
            for value, expected in (("1", True), ("0", False), ("true", False), ("", False)):
                service.environ = {"HERDR_WATCHERS_ENABLED": value}
                self.assertEqual(service.watchers_enabled, expected)

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
