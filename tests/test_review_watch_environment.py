import json
import os
import subprocess
import unittest
from unittest.mock import patch

from scripts import herdr_pr_review_watch as watch


class ReviewWatchEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.environment = {
            "PATH": "/usr/bin", "HOME": "/example/home",
            "OPENAI_API_KEY": "example-model-key", "GH_TOKEN": "example-github-key",
            "HERDR_CONFIG": "/example/private/config.toml",
            "HERDR_HARNESS_API_TOKEN": "example-api-key",
            "HERDR_HARNESS_REMOTE_ACTIVITY_TOKEN": "example-peer-key",
            "HERDR_HARNESS_TRANSCRIPTION_TOKEN": "example-speech-key",
            "HERDR_ACTIVE_WORK_MANAGE_TOKEN": "example-board-key",
            "HERDR_ACTIVE_WORK_BASE_URL": "http://127.0.0.1:9392",
        }

    def test_discovery_and_assessment_preserve_provider_auth_without_cluster_secrets(self):
        for command in (["gh", "api", "user"], ["pi", "--no-session", "-p"]):
            with patch.dict(os.environ, self.environment, clear=True), patch.object(watch.subprocess, "run", return_value=subprocess.CompletedProcess(command, 0, "{}", "")) as run:
                watch.run_cmd(command, timeout=10)
            environment = run.call_args.kwargs["env"]
            self.assertEqual(environment["OPENAI_API_KEY"], self.environment["OPENAI_API_KEY"])
            self.assertEqual(environment["GH_TOKEN"], self.environment["GH_TOKEN"])
            self.assertFalse(any(name.startswith("HERDR_") for name in environment))

    def test_board_child_receives_only_board_settings_and_no_secrets_in_argv(self):
        response = {"ok": True, "data": {"items": []}}
        with patch.dict(os.environ, self.environment, clear=True), patch.object(watch.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(response), "")) as run:
            self.assertEqual(watch.active_work("list"), response)
        environment = run.call_args.kwargs["env"]
        self.assertEqual({name: value for name, value in environment.items() if name.startswith("HERDR_")}, {
            "HERDR_ACTIVE_WORK_MANAGE_TOKEN": self.environment["HERDR_ACTIVE_WORK_MANAGE_TOKEN"],
            "HERDR_ACTIVE_WORK_BASE_URL": self.environment["HERDR_ACTIVE_WORK_BASE_URL"],
        })
        self.assertNotIn(self.environment["HERDR_ACTIVE_WORK_MANAGE_TOKEN"], run.call_args.args[0])
