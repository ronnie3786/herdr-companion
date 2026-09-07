import contextlib
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from herdr_harness.child_environment import agent_environment
from herdr_harness.configuration_cli import main


class ChildEnvironmentTests(unittest.TestCase):
    def test_agents_keep_needed_capabilities_without_cluster_administration_secrets(self):
        environment = {
            "PATH": "/usr/bin", "OPENAI_API_KEY": "model-key",
            "HERDR_CONFIG": "/private/operator/config.toml",
            "HERDR_CONFIG_PATH": "/upstream/terminal/config.toml",
            "HERDR_HARNESS_PORT": "9192", "HERDR_HARNESS_API_TOKEN": "local-api-token",
            "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": "admin-secret",
            "HERDR_HARNESS_REMOTE_ACTIVITY_TOKEN": "peer-secret",
            "HERDR_APNS_KEY_PATH": "/private/push.p8",
            "HERDR_HARNESS_TRANSCRIPTION_TOKEN": "speech-secret",
            "HERDR_FLEET_CATALOG_REPOSITORY": "https://example.invalid/private.git",
        }
        result = agent_environment(environment)
        self.assertEqual(result["OPENAI_API_KEY"], "model-key")
        self.assertEqual(result["HERDR_HARNESS_API_TOKEN"], "local-api-token")
        self.assertEqual(result["HERDR_HARNESS_URL"], "http://127.0.0.1:9192")
        self.assertEqual(result["HERDR_CONFIG_PATH"], "/upstream/terminal/config.toml")
        for name in ("HERDR_CONFIG", "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN", "HERDR_HARNESS_REMOTE_ACTIVITY_TOKEN", "HERDR_APNS_KEY_PATH", "HERDR_HARNESS_TRANSCRIPTION_TOKEN", "HERDR_FLEET_CATALOG_REPOSITORY"):
            self.assertNotIn(name, result)
        discovered = agent_environment(environment, integration=False)
        self.assertEqual(discovered, {"PATH": "/usr/bin", "OPENAI_API_KEY": "model-key"})
        self.assertIn("HERDR_CONFIG", environment)

    def test_exec_loads_single_config_without_shell_or_credential_output(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings.toml"
            path.write_text('[server]\napi_token="example-api-token"\nport=9292\n[active_work]\nmanage_token="admin-secret"\n[environment]\nOPENAI_API_KEY="model-key"\n')
            path.chmod(0o600)
            stdout = io.StringIO()
            stderr = io.StringIO()
            with patch.dict(os.environ, {}, clear=True), patch("herdr_harness.configuration_cli.os.execvpe") as execute, contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(main(["exec", "--config", str(path), "--", "pi", "argument with spaces", "$(literal)"]), 0)
            executable, argv, environment = execute.call_args.args
            self.assertEqual(executable, "pi")
            self.assertEqual(argv, ["pi", "argument with spaces", "$(literal)"])
            self.assertEqual(environment["HERDR_HARNESS_API_TOKEN"], "example-api-token")
            self.assertEqual(environment["HERDR_HARNESS_URL"], "http://127.0.0.1:9292")
            self.assertEqual(environment["OPENAI_API_KEY"], "model-key")
            self.assertNotIn("HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN", environment)
            self.assertNotIn("example-api-token", stdout.getvalue() + stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
