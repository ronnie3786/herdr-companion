import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest

from herdr_harness.connection_info import connection_environment, connection_path, publish_connection


class ConnectionInfoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.socket = str(self.root / "terminal.sock")
        self.env = {"HOME": self.temp.name, "HERDR_HARNESS_API_TOKEN": "example-api-token", "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": "never-project-admin", "HERDR_HARNESS_REMOTE_ACTIVITY_TOKEN": "never-project-peer"}

    def publish(self, **kwargs):
        registration = publish_connection(socket_path=self.socket, host="127.0.0.1", port=9192, environ={**self.env, **kwargs})
        self.addCleanup(registration.close)
        return registration

    def test_projection_is_private_bounded_and_contains_only_one_socket_connection(self):
        registration = self.publish()
        self.assertEqual(registration.path, connection_path(self.socket, self.env))
        self.assertEqual(registration.path.name, hashlib.sha256(self.socket.encode()).hexdigest() + ".json")
        self.assertEqual(registration.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(registration.path.parent.stat().st_mode & 0o777, 0o700)
        data = json.loads(registration.path.read_text())
        self.assertEqual(set(data), {"version", "instance_id", "socket_path", "url", "token"})
        self.assertEqual(data["url"], "http://127.0.0.1:9192")
        self.assertNotIn("never-project", registration.path.read_text())
        self.assertNotIn("example-api-token", repr(registration))
        resolved = connection_environment({"HOME": self.temp.name, "HERDR_SOCKET_PATH": self.socket})
        self.assertEqual(resolved["HERDR_HARNESS_URL"], data["url"])
        self.assertEqual(resolved["HERDR_HARNESS_API_TOKEN"], "example-api-token")

    def test_old_server_cleanup_cannot_remove_a_new_connection(self):
        first = self.publish()
        second = self.publish(HERDR_HARNESS_API_TOKEN="replacement-api-token")
        first.close()
        self.assertTrue(second.path.is_file())
        self.assertEqual(json.loads(second.path.read_text())["token"], "replacement-api-token")
        second.close()
        self.assertFalse(second.path.exists())

    def test_unconfigured_server_does_not_write_credentials(self):
        result = publish_connection(socket_path=self.socket, host="127.0.0.1", port=9192, environ={"HOME": self.temp.name})
        self.assertIsNone(result)
        self.assertFalse(connection_path(self.socket, self.env).exists())

    def test_reader_rejects_world_readable_symlink_wrong_socket_and_foreign_origin(self):
        registration = self.publish()
        original = registration.path.read_text()
        registration.path.chmod(0o644)
        with self.assertRaises(ValueError):
            connection_environment({"HOME": self.temp.name, "HERDR_SOCKET_PATH": self.socket})
        registration.path.chmod(0o600)
        for override in ({"socket_path": "/another/terminal.sock"}, {"url": "https://attacker.example.test"}, {"token": "bad\nheader"}):
            registration.path.write_text(json.dumps({**json.loads(original), **override}))
            with self.subTest(override=override), self.assertRaises(ValueError):
                connection_environment({"HOME": self.temp.name, "HERDR_SOCKET_PATH": self.socket})
        registration.path.unlink()
        target = self.root / "elsewhere.json"
        target.write_text(original)
        target.chmod(0o600)
        registration.path.symlink_to(target)
        with self.assertRaises(ValueError):
            connection_environment({"HOME": self.temp.name, "HERDR_SOCKET_PATH": self.socket})

    def test_publish_refuses_symlink_directory_and_does_not_touch_target(self):
        path = connection_path(self.socket, self.env)
        path.parent.parent.mkdir(parents=True)
        target = self.root / "other"
        target.mkdir()
        path.parent.symlink_to(target, target_is_directory=True)
        with self.assertRaises(OSError):
            self.publish()
        self.assertEqual(list(target.iterdir()), [])

    def test_explicit_process_credentials_override_native_discovery(self):
        environment = {"HERDR_SOCKET_PATH": "/not/a/live/socket", "HERDR_HARNESS_API_TOKEN": "explicit"}
        self.assertEqual(connection_environment(environment), environment)


if __name__ == "__main__":
    unittest.main()
