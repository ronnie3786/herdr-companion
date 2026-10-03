"""Upgrading away from the retired board preserves data and API authentication."""

from pathlib import Path
import tempfile
import unittest

from herdr_harness.config import load_configuration
from herdr_harness.server import AuthConfigurationError, make_handler
from herdr_harness.service import HerdrService
from tests.test_agent_activity import FakeHerdrClient


class RetiredActiveWorkTests(unittest.TestCase):
    def test_old_configuration_loads_without_resolving_retired_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_path = root / "config.toml"
            config_path.write_text('''[server]
api_token = "synthetic-api-token"
state_dir = "state"
[active_work]
manage_token_file = "missing-retired-token"
ingest_token_file = "missing-retired-ingest-token"
store_path = "state/active-work.sqlite3"
[remote_activity]
token_file = "missing-retired-remote-token"
[providers.activity]
url = "https://unused.example.invalid"
''')
            config_path.chmod(0o600)
            config = load_configuration(config_path, environ={})
            self.assertEqual(config.environ["HERDR_HARNESS_API_TOKEN"], "synthetic-api-token")
            self.assertFalse(any("ACTIVE_WORK" in key or "REMOTE_ACTIVITY" in key
                                 or "ACTIVITY_MODEL" in key for key in config.environ))
            self.assertFalse((root / "state" / "active-work.sqlite3").exists())

    def test_service_leaves_legacy_board_data_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            old_store = Path(directory) / "active-work.sqlite3"
            original = b"synthetic retained operator data"
            old_store.write_bytes(original)
            service = HerdrService(FakeHerdrClient(), environ={
                "HERDR_HARNESS_ACTIVE_WORK_STORE_PATH": str(old_store),
            })
            service.stop()
            self.assertEqual(old_store.read_bytes(), original)
            self.assertEqual(sorted(path.name for path in Path(directory).iterdir()), [old_store.name])

    def test_main_token_validation_remains_strict_and_private(self):
        service = type("Service", (), {"environ": {}})()
        for token in ("synthetic token", "synthetic\ntoken", "synthétique"):
            with self.subTest(token=repr(token)), self.assertRaises(AuthConfigurationError) as error:
                make_handler(service, api_token=token)
            self.assertNotIn(token, str(error.exception))
