"""Defaults, overrides and validation of the Code Factory settings."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from herdr_harness.code_factory.errors import CodeFactoryError
from herdr_harness.code_factory.settings import CodeFactorySettings

HOME = "/home/your-username"
STATE = HOME + "/state"
PREFIX = "HERDR_CODE_FACTORY_"


def environ(**extra: str) -> dict[str, str]:
    base = {"HOME": HOME, "HERDR_STATE_DIR": STATE, PREFIX + "REPOSITORY": "owner/repo"}
    base.update({(PREFIX + key.upper() if not key.startswith("HERDR_") else key): value for key, value in extra.items()})
    return base


class DefaultsTests(unittest.TestCase):
    def test_defaults_derive_from_state_dir(self):
        settings = CodeFactorySettings.from_environ(environ())
        self.assertEqual(settings.repository, "owner/repo")
        self.assertEqual(settings.state_path, Path(STATE) / "code-factory" / "code-factory.sqlite3")
        self.assertEqual(settings.worktree_root, Path(STATE) / "code-factory" / "worktrees")
        self.assertEqual(settings.runs_root, Path(STATE) / "code-factory" / "runs")
        self.assertEqual(settings.release_output_root, Path(STATE) / "releases")
        self.assertEqual(settings.poll_seconds, 60)
        self.assertEqual(settings.trigger_label, "herdr-autofix")
        self.assertEqual(settings.allowed_authors, ())
        self.assertEqual(settings.planner_model, "openai-codex/gpt-6-astra")
        self.assertEqual(settings.planner_thinking, "xhigh")
        self.assertEqual(settings.implementer_model, "ollama-cloud/deepseek-v4.1-flash:cloud")
        self.assertEqual(settings.implementer_thinking, "max")
        self.assertEqual(settings.max_parallel_issues, 2)
        self.assertEqual(settings.max_review_rounds, 3)
        self.assertEqual(settings.max_ci_failures, 3)
        self.assertEqual(settings.session_timeout_seconds, 3600)
        self.assertEqual(settings.reviser_session_timeout_seconds, 7200)
        self.assertEqual(settings.max_rebase_attempts, 2)
        self.assertEqual(settings.max_transient_retries, 2)
        self.assertEqual(settings.verify_wait_seconds, 3600)
        self.assertEqual(settings.dashboard_host, "tailscale")
        self.assertEqual(settings.dashboard_port, 9097)
        self.assertEqual(settings.dashboard_token, "")
        self.assertEqual(settings.dashboard_link, "")
        self.assertTrue(settings.release_enabled)
        self.assertEqual(settings.release_channel, "preview")
        self.assertTrue(settings.comment_on_issues)
        self.assertEqual(settings.base_branch, "main")
        self.assertEqual(settings.pi_binary, "pi")
        self.assertEqual(settings.python, sys.executable)
        self.assertIsNone(settings.config_path)
        self.assertIsNone(settings.machine)
        self.assertFalse(settings.checkout_configured)

    def test_state_dir_falls_back_to_home(self):
        env = environ()
        del env["HERDR_STATE_DIR"]
        settings = CodeFactorySettings.from_environ(env)
        self.assertEqual(settings.state_path, Path(HOME) / ".local/share/herdr-companion/code-factory/code-factory.sqlite3")
        self.assertEqual(settings.release_output_root, Path(HOME) / ".local/share/herdr-companion/releases")

    def test_review_repository_is_never_used_as_a_fallback(self):
        env = environ()
        del env[PREFIX + "REPOSITORY"]
        env["HERDR_REVIEW_REPOSITORY"] = "other/project"
        with self.assertRaises(CodeFactoryError) as caught:
            CodeFactorySettings.from_environ(env)
        self.assertEqual(caught.exception.code, "invalid_settings")
        self.assertIn("code_factory.repository", str(caught.exception))

    def test_config_and_machine_are_passed_through(self):
        env = environ(HERDR_CONFIG="/etc/herdr/config.toml", HERDR_MACHINE="studio")
        settings = CodeFactorySettings.from_environ(env)
        self.assertEqual(settings.config_path, "/etc/herdr/config.toml")
        self.assertEqual(settings.machine, "studio")


class OverrideTests(unittest.TestCase):
    def test_every_field_can_be_overridden(self):
        env = environ(
            checkout="~/projects/checkout",
            worktree_root="~/wt",
            state_path="/var/lib/herdr/cf.sqlite3",
            runs_root="/var/lib/herdr/runs",
            release_output_root="/var/lib/herdr/releases",
            poll_seconds="120",
            trigger_label="autofix me",
            allowed_authors="alice, bob,alice ,Carol",
            planner_model="openai/gpt-x",
            planner_thinking="high",
            implementer_model="ollama-cloud/model:cloud",
            implementer_thinking="low",
            max_parallel_issues="4",
            max_review_rounds="0",
            max_ci_failures="5",
            session_timeout_seconds="600",
            reviser_session_timeout_seconds="1800",
            max_rebase_attempts="3",
            max_transient_retries="1",
            verify_wait_seconds="900",
            dashboard_host="127.0.0.1",
            dashboard_port="8080",
            dashboard_token="secret-token",
            dashboard_link="https://factory.example.invalid:9097",
            release_enabled="no",
            release_channel="stable",
            comment_on_issues="0",
            base_branch="develop",
            pi_bin="/opt/pi/bin/pi",
            python="/opt/python/bin/python3",
        )
        settings = CodeFactorySettings.from_environ(env)
        self.assertEqual(settings.checkout, Path(HOME) / "projects/checkout")
        self.assertTrue(settings.checkout_configured)
        self.assertEqual(settings.worktree_root, Path(HOME) / "wt")
        self.assertEqual(settings.state_path, Path("/var/lib/herdr/cf.sqlite3"))
        self.assertEqual(settings.runs_root, Path("/var/lib/herdr/runs"))
        self.assertEqual(settings.release_output_root, Path("/var/lib/herdr/releases"))
        self.assertEqual(settings.poll_seconds, 120)
        self.assertEqual(settings.trigger_label, "autofix me")
        self.assertEqual(settings.allowed_authors, ("alice", "bob", "Carol"))
        self.assertEqual(settings.planner_model, "openai/gpt-x")
        self.assertEqual(settings.planner_thinking, "high")
        self.assertEqual(settings.implementer_model, "ollama-cloud/model:cloud")
        self.assertEqual(settings.implementer_thinking, "low")
        self.assertEqual(settings.max_parallel_issues, 4)
        self.assertEqual(settings.max_review_rounds, 0)
        self.assertEqual(settings.max_ci_failures, 5)
        self.assertEqual(settings.session_timeout_seconds, 600)
        self.assertEqual(settings.reviser_session_timeout_seconds, 1800)
        self.assertEqual(settings.max_rebase_attempts, 3)
        self.assertEqual(settings.max_transient_retries, 1)
        self.assertEqual(settings.verify_wait_seconds, 900)
        self.assertEqual(settings.dashboard_host, "127.0.0.1")
        self.assertEqual(settings.dashboard_port, 8080)
        self.assertEqual(settings.dashboard_token, "secret-token")
        self.assertEqual(settings.dashboard_link, "https://factory.example.invalid:9097/")
        self.assertFalse(settings.release_enabled)
        self.assertEqual(settings.release_channel, "stable")
        self.assertFalse(settings.comment_on_issues)
        self.assertEqual(settings.base_branch, "develop")
        self.assertEqual(settings.pi_binary, "/opt/pi/bin/pi")
        self.assertEqual(settings.python, "/opt/python/bin/python3")

    def test_boolean_words(self):
        for word, expected in (("true", True), ("1", True), ("YES", True), ("false", False), ("0", False), ("No", False)):
            with self.subTest(word=word):
                self.assertEqual(CodeFactorySettings.from_environ(environ(release_enabled=word)).release_enabled, expected)

    def test_blank_values_use_defaults(self):
        settings = CodeFactorySettings.from_environ(environ(poll_seconds="  ", planner_model="", release_enabled=""))
        self.assertEqual(settings.poll_seconds, 60)
        self.assertEqual(settings.planner_model, "openai-codex/gpt-6-astra")
        self.assertTrue(settings.release_enabled)

    def test_summaries_never_expose_the_token(self):
        settings = CodeFactorySettings.from_environ(environ(dashboard_token="secret-token"))
        self.assertNotIn("secret-token", str(settings.public_summary()))
        self.assertEqual(settings.as_dict()["dashboard_token"], "***")
        self.assertEqual(settings.as_dict()["allowed_authors"], [])
        self.assertIsInstance(settings.as_dict()["state_path"], str)
        self.assertEqual(settings.public_summary()["repository"], "owner/repo")
        self.assertEqual(settings.public_summary()["max_ci_failures"], 3)
        self.assertEqual(settings.public_summary()["reviser_session_timeout_seconds"], 7200)
        self.assertEqual(settings.public_summary()["max_rebase_attempts"], 2)
        self.assertEqual(settings.session_timeout_for("reviser"), 7200)
        self.assertEqual(settings.session_timeout_for("rebase"), 7200)
        self.assertEqual(settings.session_timeout_for("planner"), 3600)
        self.assertEqual(settings.session_timeout_for("reviewer"), 3600)


class ValidationTests(unittest.TestCase):
    def assert_invalid(self, env: dict[str, str], fragment: str):
        with self.assertRaises(CodeFactoryError) as caught:
            CodeFactorySettings.from_environ(env)
        self.assertEqual(caught.exception.code, "invalid_settings")
        self.assertIn(fragment, str(caught.exception))

    def test_repository_required_and_shaped(self):
        env = environ()
        del env[PREFIX + "REPOSITORY"]
        self.assert_invalid(env, "repository is not configured")
        self.assert_invalid(environ(repository="just-a-name"), "OWNER/NAME")
        self.assert_invalid(environ(repository="owner/repo/extra"), "OWNER/NAME")
        self.assert_invalid(environ(repository="own er/repo"), "OWNER/NAME")

    def test_integer_ranges(self):
        cases = {
            "poll_seconds": ("9", "3601"),
            "max_parallel_issues": ("0", "9"),
            "max_review_rounds": ("-1", "11"),
            "max_ci_failures": ("-1", "11"),
            "session_timeout_seconds": ("59", "86401"),
            "reviser_session_timeout_seconds": ("59", "86401"),
            "max_rebase_attempts": ("-1", "11"),
            "max_transient_retries": ("-1", "6"),
            "verify_wait_seconds": ("10", "100000"),
            "dashboard_port": ("0", "65536"),
        }
        for key, (low, high) in cases.items():
            with self.subTest(key=key):
                self.assert_invalid(environ(**{key: low}), key)
                self.assert_invalid(environ(**{key: high}), key)
                self.assert_invalid(environ(**{key: "twelve"}), "integer")

    def test_choices(self):
        self.assert_invalid(environ(planner_thinking="ultra"), "planner_thinking")
        self.assert_invalid(environ(implementer_thinking="none"), "implementer_thinking")
        self.assert_invalid(environ(release_channel="nightly"), "release_channel")
        self.assert_invalid(environ(release_enabled="maybe"), "release_enabled")
        self.assert_invalid(environ(comment_on_issues="2"), "comment_on_issues")

    def test_dashboard_link_must_be_a_safe_http_url(self):
        for value in ("factory.example", "ftp://factory.example/", "https://user:secret@factory.example/", "https://factory.example/?token=x"):
            with self.subTest(value=value):
                self.assert_invalid(environ(dashboard_link=value), "dashboard_link")

    def test_model_pattern(self):
        self.assert_invalid(environ(planner_model="bad model"), "planner_model")
        self.assert_invalid(environ(implementer_model="x" * 201), "implementer_model")
        self.assert_invalid(environ(implementer_model="model;rm"), "implementer_model")

    def test_labels_authors_and_branches(self):
        self.assert_invalid(environ(trigger_label="a,b"), "trigger_label")
        self.assert_invalid(environ(trigger_label="x" * 51), "trigger_label")
        self.assert_invalid(environ(allowed_authors="ok, bad login"), "allowed_authors")
        self.assert_invalid(environ(base_branch="feature..main"), "base_branch")
        self.assert_invalid(environ(base_branch="-x"), "base_branch")

    def test_control_characters_rejected(self):
        self.assert_invalid(environ(dashboard_host="host\nname"), "dashboard_host")
        self.assert_invalid(environ(pi_bin="pi\x00"), "pi_binary")


class CheckoutTests(unittest.TestCase):
    def test_missing_checkout_is_reported_by_validate_only(self):
        settings = CodeFactorySettings.from_environ(environ())
        with self.assertRaises(CodeFactoryError) as caught:
            settings.validate_checkout()
        self.assertEqual(caught.exception.code, "invalid_settings")
        self.assertIn("checkout is not configured", str(caught.exception))

    def test_checkout_must_be_a_git_repository(self):
        with tempfile.TemporaryDirectory() as temp:
            missing = Path(temp) / "missing"
            settings = CodeFactorySettings.from_environ(environ(checkout=str(missing)))
            with self.assertRaises(CodeFactoryError) as caught:
                settings.validate_checkout()
            self.assertIn("does not exist", str(caught.exception))
            plain = Path(temp) / "plain"
            plain.mkdir()
            settings = CodeFactorySettings.from_environ(environ(checkout=str(plain)))
            with self.assertRaises(CodeFactoryError) as caught:
                settings.validate_checkout()
            self.assertIn("not a git repository", str(caught.exception))
            repo = Path(temp) / "repo"
            repo.mkdir()
            isolated = {"PATH": os.environ.get("PATH", ""), "HOME": temp,
                        "GIT_CONFIG_GLOBAL": str(Path(temp) / "gitconfig"), "GIT_CONFIG_NOSYSTEM": "1"}
            subprocess.run(["git", "init", "--quiet", str(repo)], check=True, capture_output=True, env=isolated)
            settings = CodeFactorySettings.from_environ(environ(checkout=str(repo)))
            self.assertEqual(settings.validate_checkout(), repo)


if __name__ == "__main__":
    unittest.main()
