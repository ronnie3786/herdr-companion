"""Opt-in native contract check, never attached to the operator's session.

HERDR_NATIVE_TEST_BIN=/path/to/herdr python -m unittest tests.test_pane_lifecycle_native
Uses an isolated HOME, named server, shell, and a synthetic stdin program named
pi. No real Pi session, provider, credentials, or network service is used.
"""
import os
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from herdr_harness.client import HerdrClient, HerdrClientError
from herdr_harness.service import HerdrService
from tests.test_pane_lifecycle import LifecycleSemantic


@unittest.skipUnless(os.environ.get("HERDR_NATIVE_TEST_BIN") and shutil.which("node"), "opt-in isolated native Herdr check")
class NativePaneRetirementTests(unittest.TestCase):
    def test_real_process_exit_replaces_last_pane_without_recreating_containers(self):
        binary = str(Path(os.environ["HERDR_NATIVE_TEST_BIN"]).resolve())
        node = shutil.which("node")
        # Short paths fit Unix domain socket length limits on macOS.
        with tempfile.TemporaryDirectory(prefix="hret-", dir="/tmp") as root:
            config = Path(root) / ".config/herdr/config.toml"
            config.parent.mkdir(parents=True)
            config.write_text('[terminal]\ndefault_shell="/bin/sh"\nshell_mode="non_login"\n[update]\nversion_check=false\nmanifest_check=false\n[experimental]\nallow_nested=true\n')
            session = "retirement"
            env = {"HOME": root, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh", "TERM": "xterm-256color", "HERDR_CONFIG_PATH": str(config)}
            socket_path = config.parent / "sessions" / session / "herdr.sock"
            fake_pi = Path(root) / "pi"
            fake_pi.write_text('process.stdin.setRawMode(true); process.stdin.resume(); let input=""; process.stdin.on("data", chunk => { input += chunk.toString(); if (input.includes("/quit\\r") || input.includes("/quit\\n")) process.exit(0); }); console.log("Synthetic Pi ready");')
            with (Path(root) / "server.log").open("w") as log:
                process = subprocess.Popen([binary, "--session", session, "server"], env=env, cwd=root, stdout=log, stderr=log)
                try:
                    client = HerdrClient(socket_path=str(socket_path), session=session)
                    deadline = time.monotonic() + 12
                    while True:
                        try:
                            snapshot = client.snapshot()
                            break
                        except HerdrClientError:
                            if process.poll() is not None or time.monotonic() >= deadline:
                                self.fail("The isolated native server did not start")
                            time.sleep(0.1)
                    if not snapshot.get("panes"):
                        client.request("workspace.create", {"label": "Synthetic retirement", "cwd": root, "focus": False})
                        snapshot = client.snapshot()
                    pane = snapshot["panes"][0]
                    service = HerdrService(client=client, environ={}, pi_semantic=LifecycleSemantic())
                    lifecycle = service.pane_lifecycle
                    try:
                        self.wait_for(lambda: lifecycle._is_shell(lifecycle._process_info(pane["pane_id"])))
                        client.request("pane.send_input", {"pane_id": pane["pane_id"], "text": f"{shlex.quote(node)} {shlex.quote(str(fake_pi))}", "keys": ["enter"]})
                        self.wait_for(lambda: lifecycle._is_pi(lifecycle._process_info(pane["pane_id"])))
                        result = lifecycle.retire(pane["pane_id"], request_id="synthetic-native-request", terminal_id=pane["terminal_id"], session_id="synthetic-session-1")
                        self.assertEqual(result["workspaceId"], pane["workspace_id"])
                        self.assertEqual(result["tabId"], pane["tab_id"])
                        self.assertNotEqual(result["nextPaneId"], pane["pane_id"])
                        self.assertTrue(result["reservedShell"])
                        after = client.snapshot()
                        self.assertFalse(any(item["pane_id"] == pane["pane_id"] for item in after["panes"]))
                        replacement = next(item for item in after["panes"] if item["pane_id"] == result["nextPaneId"])
                        lifecycle.open_reserved_shell(replacement["pane_id"], terminal_id=replacement["terminal_id"])
                        self.assertFalse(lifecycle.reservation(replacement))
                    finally:
                        lifecycle.close()
                finally:
                    try:
                        subprocess.run([binary, "--session", session, "server", "stop"], env=env, cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
                    finally:
                        try:
                            process.wait(timeout=8)
                        except subprocess.TimeoutExpired:
                            process.terminate()  # Only the child created above.
                            process.wait(timeout=5)

    def wait_for(self, predicate):
        deadline = time.monotonic() + 6
        while not predicate():
            if time.monotonic() >= deadline:
                self.fail("The isolated foreground process did not become ready")
            time.sleep(0.1)
