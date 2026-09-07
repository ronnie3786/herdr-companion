import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from herdr_harness.config import ConfigurationError, load_configuration
from herdr_harness.fleet import FleetError, FleetManager, _canonical_repository
from herdr_harness.quick_voice import QuickVoiceError, QuickVoiceManager
from herdr_harness.response_audio import ResponseAudioService


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / 'config.toml'

    def write(self, text):
        self.path.write_text(text)
        self.path.chmod(0o600)
        return self.path

    def load(self, text, **kwargs):
        return load_configuration(self.write(text), environ={'HOME': str(self.root)}, **kwargs)

    def test_shared_machine_and_process_precedence(self):
        path = self.write('''version = 1
[server]
port = 9000
host = "127.0.0.1"
[environment]
HERDR_CUSTOM = "shared"
[machines.worker]
name = "Worker"
role = "development"
url = "https://worker.example.invalid"
[machines.worker.server]
port = 9099
[machines.worker.environment]
HERDR_CUSTOM = "worker"
''')
        config = load_configuration(path, 'worker', environ={})
        self.assertEqual(config.environ['HERDR_HARNESS_PORT'], '9099')
        self.assertEqual(config.environ['HERDR_CUSTOM'], 'worker')
        override = load_configuration(path, 'worker', environ={'HERDR_HARNESS_PORT': '9191'})
        self.assertEqual(override.environ['HERDR_HARNESS_PORT'], '9191')
        self.assertEqual(override.environ['HERDR_HARNESS_HOST'], '127.0.0.1')

    def test_unknown_machine_and_malformed_toml_fail_closed_without_values(self):
        for text in ('[broken\npassword="SECRET"', 'version=99'):
            with self.assertRaises(ConfigurationError) as raised:
                self.load(text)
            self.assertNotIn('SECRET', str(raised.exception))
        with self.assertRaises(ConfigurationError):
            self.load('[server]\nport=9092', machine='unknown')

    def test_missing_explicit_file_fails(self):
        with self.assertRaises(ConfigurationError):
            load_configuration(self.root / 'missing.toml', environ={})

    def test_terminal_configuration_is_not_treated_as_cluster_configuration(self):
        directory = self.root / '.config/herdr'
        directory.mkdir(parents=True)
        (directory / 'config.toml').write_text('[onboarding]\ncompleted=true')
        with mock.patch('herdr_harness.config.Path.cwd', return_value=self.root):
            config = load_configuration(environ={'HOME': str(self.root)})
        self.assertIsNone(config.path)
        with self.assertRaises(ConfigurationError):
            load_configuration(directory / 'config.toml', environ={})

    def test_default_discovery_uses_only_private_local_or_user_file(self):
        user_config = self.root / '.config/herdr-companion/config.toml'
        user_config.parent.mkdir(parents=True)
        user_config.write_text('[server]\nport=9010')
        with mock.patch('herdr_harness.config.Path.cwd', return_value=self.root):
            config = load_configuration(environ={'HOME': str(self.root)})
            self.assertEqual(config.environ['HERDR_HARNESS_PORT'], '9010')
            (self.root / 'config.local.toml').write_text('[server]\nport=9020')
            config = load_configuration(environ={'HOME': str(self.root)})
            self.assertEqual(config.environ['HERDR_HARNESS_PORT'], '9020')

    def test_private_file_and_environment_secret_references(self):
        secret = self.root / 'token'
        secret.write_text('unit-test-secret\n')
        secret.chmod(0o600)
        config = self.load('[server]\napi_token_file="token"')
        self.assertEqual(config.environ['HERDR_HARNESS_API_TOKEN'], 'unit-test-secret')
        self.assertNotIn('unit-test-secret', repr(config))
        config = load_configuration(self.write('[server]\napi_token={env="TEST_TOKEN"}'), environ={'TEST_TOKEN': 'test-value'})
        self.assertEqual(config.environ['HERDR_HARNESS_API_TOKEN'], 'test-value')
        with self.assertRaises(ConfigurationError):
            load_configuration(self.path, environ={})
        secret.chmod(0o644)
        with self.assertRaises(ConfigurationError):
            self.load('[server]\napi_token_file="token"')

    def test_process_override_does_not_require_unused_secret_file(self):
        config = load_configuration(self.write('[server]\napi_token_file="missing"'), environ={'HERDR_HARNESS_API_TOKEN': 'process-value'})
        self.assertEqual(config.environ['HERDR_HARNESS_API_TOKEN'], 'process-value')

    def test_metadata_only_build_does_not_resolve_server_secrets(self):
        config = load_configuration(self.write('''[server]
api_token_file="missing"
[apple]
team_id="EXAMPLETEAM"
[machines.desktop]
name="Desktop"
url="https://desktop.example.invalid"
'''), environ={}, resolve_secrets=False)
        self.assertEqual(config.section('apple')['team_id'], 'EXAMPLETEAM')
        self.assertNotIn('HERDR_HARNESS_API_TOKEN', config.environ)
        self.assertEqual(config.public_machines()[0]['id'], 'desktop')

    def test_roster_never_exports_private_machine_settings(self):
        config = self.load('''[machines.worker]
name="Worker"
url="https://worker.example.invalid"
ssh_user="private-user"
[machines.worker.server]
api_token="private-token"
''')
        self.assertEqual(config.public_machines(), [{'id':'worker', 'name':'Worker', 'url':'https://worker.example.invalid', 'role':'node'}])
        for url in ('https://user:secret@example.invalid', 'https://example.invalid?token=secret', 'file:///tmp/a', 'https://example.invalid/path'):
            with self.subTest(url=url), self.assertRaises(ConfigurationError):
                self.load(f'[machines.worker]\nurl="{url}"')

    def test_state_directory_owns_all_durable_server_stores(self):
        config = self.load('[server]\nstate_dir="state"')
        root = str(self.root.resolve() / 'state')
        stores = [value for name, value in config.environ.items() if name.startswith(('HERDR_HARNESS_', 'HERDR_QUICK_VOICE_', 'HERDR_FLEET_')) and name.endswith(('_PATH','_ROOT','_DIR'))]
        self.assertGreaterEqual(len(stores), 15)
        self.assertTrue(all(value.startswith(root + '/') for value in stores))
        self.assertTrue(config.environ['HERDR_HARNESS_NOTES_STORE_PATH'].endswith('notes.sqlite3'))
        self.assertEqual(config.environ['HERDR_HARNESS_WORKFLOWS_DIR'], root + '/workflows')

    def test_workflow_definitions_only_load_from_configured_directory(self):
        from herdr_harness.active_work_store import ActiveWorkRepository

        legacy = self.root / '.config/herdr-harness/workflows'
        legacy.mkdir(parents=True)
        payload = {
            'workflow': 'garden-demo', 'version': 1, 'title': 'Garden Demo',
            'phases': [{'key': 'plan', 'title': 'Plan'}, {'key': 'finish', 'title': 'Finish'}],
            'stages': [
                {'key': 'plan', 'title': 'Plan', 'phase': 'plan', 'skill': 'plan'},
                {'key': 'finish', 'title': 'Finish', 'phase': 'finish', 'skill': 'finish'},
            ],
        }
        (legacy / 'garden.json').write_text(json.dumps(payload))
        repository = ActiveWorkRepository(':memory:', environ={'HOME': str(self.root)})
        self.addCleanup(repository.close)
        self.assertNotIn('garden-demo', {item['slug'] for item in repository.list_workflows()})

        config = self.load('[active_work]\nworkflows_dir=".config/herdr-harness/workflows"')
        configured = ActiveWorkRepository(':memory:', environ=config.environ)
        self.addCleanup(configured.close)
        self.assertIn('garden-demo', {item['slug'] for item in configured.list_workflows()})

    def test_manage_token_and_apns_names_match_actual_consumers(self):
        config = self.load('''[active_work]
manage_token="test-manage"
ingest_token="test-ingest"
[push]
environment="sandbox"
[apple]
team_id="EXAMPLETEAM"
ios_bundle_id="org.example.herdr.ios"
''')
        self.assertEqual(config.environ['HERDR_ACTIVE_WORK_MANAGE_TOKEN'], 'test-manage')
        self.assertEqual(config.environ['HERDR_ACTIVE_WORK_TOKEN'], 'test-ingest')
        self.assertEqual(config.environ['HERDR_APNS_ENV'], 'sandbox')
        self.assertEqual(config.environ['HERDR_HARNESS_APP_IDS'], 'EXAMPLETEAM.org.example.herdr.ios')

    def test_process_manage_token_override_is_shared_with_cli(self):
        config = load_configuration(self.write('[active_work]\nmanage_token="from-file"'), environ={"HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": "from-process"})
        self.assertEqual(config.environ["HERDR_ACTIVE_WORK_MANAGE_TOKEN"], "from-process")

    def test_invalid_port_error_never_echoes_the_supplied_value(self):
        with self.assertRaises(ConfigurationError) as raised:
            self.load('[server]\nport="accidentally-pasted-secret"')
        self.assertNotIn("accidentally-pasted-secret", str(raised.exception))

    def test_client_urls_follow_configured_server_port_and_bind_address(self):
        config = self.load('[server]\nhost="0.0.0.0"\nport=9191')
        self.assertEqual(config.environ['HERDR_HARNESS_URL'], 'http://127.0.0.1:9191')
        self.assertEqual(config.environ['HERDR_ACTIVE_WORK_BASE_URL'], 'http://127.0.0.1:9191')
        self.assertIn('HERDR_HARNESS_URL', config.derived_urls)
        config = self.load('[server]\nhost="::"\nport=9292')
        self.assertEqual(config.environ['HERDR_HARNESS_URL'], 'http://[::1]:9292')
        config = self.load('[server]\nurl="https://custom.example.invalid"\nport=9191')
        self.assertEqual(config.environ['HERDR_HARNESS_URL'], 'https://custom.example.invalid')
        self.assertFalse(config.derived_urls)

    def test_sample_has_no_configured_provider_networks_or_secrets(self):
        config = load_configuration(Path(__file__).resolve().parents[1] / 'config.example.toml', environ={})
        for name in ('HERDR_HARNESS_API_TOKEN', 'HERDR_FLEET_CATALOG_REPOSITORY', 'HERDR_HARNESS_ACTIVITY_MODEL_URL', 'HERDR_RESPONSE_AUDIO_SUMMARY_URL', 'HERDR_RESPONSE_AUDIO_TTS_URL'):
            self.assertNotIn(name, config.environ)
        service = ResponseAudioService(config.environ, opener=lambda *a, **kw: self.fail('unconfigured network request'))
        self.assertFalse(service.capabilities()['available'])

    def test_group_writable_configuration_rejected(self):
        path = self.write('[server]\nport=9092')
        path.chmod(0o660)
        with self.assertRaises(ConfigurationError):
            load_configuration(path, environ={})

    def test_fleet_uses_only_explicit_trusted_origin(self):
        config = self.load('[fleet]\nrepository="https://github.com/example/catalog.git"')
        manager = FleetManager(environ=config.environ)
        self.assertEqual(manager.repository, 'https://github.com/example/catalog.git')
        self.assertEqual(_canonical_repository(manager.repository), _canonical_repository('git@github.com:example/catalog.git'))
        self.assertNotEqual(_canonical_repository(manager.repository), _canonical_repository('https://github.com/other/catalog.git'))
        self.assertEqual(manager._checkout_candidates(), [manager.managed_checkout])
        for value in ('http://github.com/example/catalog', 'https://token@github.com/example/catalog', 'git@-host:repo.git', 'file://remote/path'):
            with self.subTest(value=value), self.assertRaises(FleetError):
                _canonical_repository(value)

    def test_unconfigured_fleet_never_clones(self):
        manager = FleetManager(environ={'HOME': str(self.root)})
        with mock.patch('herdr_harness.fleet._run_command', side_effect=AssertionError('command executed')):
            with self.assertRaises(FleetError) as raised:
                manager.sync()
        self.assertEqual(raised.exception.code, 'catalog_unconfigured')

    def test_quick_voice_requires_explicit_agent_model(self):
        from types import SimpleNamespace
        manager = QuickVoiceManager(SimpleNamespace(environ={}), store_path=self.root)
        self.addCleanup(manager.stop)
        with self.assertRaises(QuickVoiceError) as raised:
            manager.start(request_id='test', text='Read my notes')
        self.assertEqual(raised.exception.code, 'quick_voice_unconfigured')


class ConfiguredFleetDestinationTests(unittest.TestCase):
    setUp = ConfigurationTests.setUp
    write = ConfigurationTests.write
    load = ConfigurationTests.load
    def test_custom_roots_are_operator_configuration_not_catalog_authority(self):
        config = self.load('[fleet.skill_destinations]\nassistant="custom-skills"')
        manager = FleetManager(environ=config.environ)
        self.assertEqual(manager._skill_destination('assistant'), 'assistant')
        with self.assertRaises(FleetError):
            manager._skill_destination('/arbitrary/catalog/chosen/path')
        with self.assertRaises(FleetError):
            manager._skill_destination('unconfigured')

    def test_overlapping_or_symlink_custom_roots_are_rejected(self):
        for path in ('~/.agents/skills', '~/.agents/skills/nested', '~/.agents'):
            with self.subTest(path=path), self.assertRaises(FleetError):
                FleetManager(environ=self.load(f'[fleet.skill_destinations]\nassistant="{path}"').environ)
        target = self.root / 'real'
        target.mkdir()
        link = self.root / 'linked'
        link.symlink_to(target)
        with self.assertRaises(FleetError):
            FleetManager(environ=self.load('[fleet.skill_destinations]\nassistant="linked"').environ)
