import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from herdr_harness import agent_docs


class AgentDocsTests(unittest.TestCase):
    def test_topics_are_closed_allowlist_and_resolve_independent_of_cwd(self):
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            os.chdir(directory)
            try:
                root = agent_docs.docs_root()
                self.assertTrue(root.is_absolute())
                for topic in agent_docs.TOPICS:
                    path = agent_docs.topic_path(topic)
                    self.assertEqual(path.parent, root)
                    self.assertTrue(path.read_text(encoding="utf-8").startswith("# "))
            finally:
                os.chdir(previous)

        for topic in ("../overview", "/tmp/overview", "overview.md", "unknown"):
            with self.subTest(topic=topic), self.assertRaises(ValueError):
                agent_docs.topic_path(topic)

    def test_cli_list_read_path_help_and_errors_need_no_configuration(self):
        output = io.StringIO()
        self.assertEqual(agent_docs.main(["list"], stdout=output), 0)
        payload = json.loads(output.getvalue())
        self.assertEqual([item["topic"] for item in payload["topics"]], list(agent_docs.TOPICS))
        self.assertTrue(all(Path(item["path"]).is_absolute() for item in payload["topics"]))

        output = io.StringIO()
        self.assertEqual(agent_docs.main(["read", "overview"], stdout=output), 0)
        self.assertIn("Herdr Companion agent overview", output.getvalue())

        output = io.StringIO()
        self.assertEqual(agent_docs.main(["path", "control"], stdout=output), 0)
        self.assertTrue(Path(output.getvalue().strip()).is_file())

        error = io.StringIO()
        self.assertEqual(agent_docs.main(["read", "../overview"], stderr=error), 2)
        self.assertIn("unknown topic", error.getvalue())
        self.assertNotIn("Traceback", error.getvalue())

        with self.assertRaises(SystemExit) as help_exit, patch("sys.stdout", new=io.StringIO()):
            agent_docs.main(["--help"])
        self.assertEqual(help_exit.exception.code, 0)

    def test_absent_resources_fail_helpfully_and_suppress_server_bootstrap(self):
        error = io.StringIO()
        environment = {"HERDR_AGENT_RUN_ID": "agr_000000000001", "HERDR_AGENT_RUN_MODE": "ask"}
        with patch("herdr_harness.agent_docs.docs_root", side_effect=FileNotFoundError("synthetic guides unavailable")):
            self.assertEqual(agent_docs.main(["list"], stderr=error), 2)
            self.assertIsNone(agent_docs.agent_run_bootstrap(environment, None))
        self.assertIn("synthetic guides unavailable", error.getvalue())

    def test_server_bootstrap_is_bounded_idempotent_and_suppresses_restricted_profiles(self):
        self.assertIsNone(agent_docs.agent_run_bootstrap({}, None))
        self.assertIsNone(agent_docs.agent_run_bootstrap({"HERDR_AGENT_RUN_ID": " \t "}, None))
        environment = {
            "HERDR_AGENT_RUN_ID": "agr_000000000001",
            "HERDR_AGENT_RUN_MODE": "ask",
            "PRIVATE_SYNTHETIC_TOKEN": "must-not-leak",
        }
        bootstrap = agent_docs.agent_run_bootstrap(environment, None)
        self.assertIsNotNone(bootstrap)
        self.assertIn("This is a Companion agent run", bootstrap)
        self.assertNotIn("must-not-leak", bootstrap)
        self.assertNotIn("# Herdr Companion agent overview", bootstrap)
        self.assertGreaterEqual(len(bootstrap.split()), 150)
        self.assertLessEqual(len(bootstrap.split()), 220)
        combined = agent_docs.append_agent_run_bootstrap("existing charter", bootstrap)
        self.assertTrue(combined.startswith("existing charter\n\n"))
        self.assertEqual(combined.count(agent_docs.AWARENESS_MARKER), 1)
        self.assertEqual(agent_docs.append_agent_run_bootstrap(combined, bootstrap), combined)

        for profile in agent_docs.RESTRICTED_AGENT_PROFILES:
            with self.subTest(profile=profile):
                self.assertIsNone(agent_docs.agent_run_bootstrap(environment, profile))

        hud = agent_docs.agent_run_bootstrap(environment, "hud-chat-v1")
        self.assertIn("independent saved HUD chat", hud)
        self.assertNotIn("managed workspace chat", hud)

    def test_installed_topic_links_are_relative_and_resolve_within_guide_set(self):
        root = agent_docs.docs_root()
        for topic, (_, filename) in agent_docs.TOPICS.items():
            text = (root / filename).read_text(encoding="utf-8")
            links = [name for _, name in agent_docs.TOPICS.values() if name != filename and f"]({name})" in text]
            with self.subTest(topic=topic):
                self.assertTrue(links)
                self.assertTrue(all((root / name).is_file() for name in links))


if __name__ == "__main__":
    unittest.main()
