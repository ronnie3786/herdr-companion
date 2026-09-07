import contextlib
import io
import os
from pathlib import Path
import tempfile
import tomllib
import unittest

from herdr_harness.configuration_cli import main
from herdr_harness.config import load_configuration


class ConfigurationInitializationTests(unittest.TestCase):
    def test_initialization_generates_private_token_without_disclosing_it(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(main(["init", "--config", str(path)]), 0)
            data = tomllib.loads(path.read_text())
            token = data["server"]["api_token"]
            self.assertEqual(len(token), 64)
            self.assertNotIn(token, output.getvalue())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            configuration = load_configuration(path, "desktop", environ={})
            self.assertEqual(configuration.environ["HERDR_HARNESS_API_TOKEN"], token)
            with contextlib.redirect_stdout(output):
                self.assertEqual(main(["check", "--config", str(path), "--machine", "desktop"]), 0)
            self.assertNotIn(token, output.getvalue())

    def test_existing_file_and_symlink_are_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "existing.toml"
            target.write_text("preserve me")
            linked = Path(directory) / "link.toml"
            linked.symlink_to(target)
            for path in (target, linked):
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(main(["init", "--config", str(path)]), 2)
            self.assertEqual(target.read_text(), "preserve me")


if __name__ == "__main__":
    unittest.main()
