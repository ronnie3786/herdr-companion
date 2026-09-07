import contextlib
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts import setup_herdr_demo


class DemoConfigurationTests(unittest.TestCase):
    def test_demo_honors_shared_machine_config_and_portable_temporary_root(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            path.write_text('[machines.example]\nurl="https://example.invalid"\n[machines.example.server]\nsession="sample-session"\nsocket_path="terminal.sock"\n')
            path.chmod(0o600)
            with patch.dict(os.environ, {}, clear=True), patch("scripts.setup_herdr_demo.tempfile.gettempdir", return_value=directory), patch("scripts.setup_herdr_demo.create_demo", return_value={"ok": True}) as create, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(setup_herdr_demo.main(["--config", str(path), "--machine", "example", "--json"]), 0)
            args = create.call_args.args[0]
            self.assertEqual(args.session, "sample-session")
            self.assertEqual(args.socket_path, str(path.resolve().parent / "terminal.sock"))
            self.assertEqual(args.root, Path(directory) / "herdr-harness-demo")

    def test_bad_config_fails_before_creating_demo_workspaces(self):
        with patch("scripts.setup_herdr_demo.create_demo") as create, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(setup_herdr_demo.main(["--config", "/missing/companion-config.toml"]), 2)
        create.assert_not_called()


if __name__ == "__main__":
    unittest.main()
