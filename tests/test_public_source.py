import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / "scripts/check-public-source.py"
spec = importlib.util.spec_from_file_location("public_source_check", path)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class PublicationBoundaryTests(unittest.TestCase):
    def test_forced_private_config_and_binary_secret_are_rejected(self):
        self.assertTrue(checker.inspect("config.local.toml", b"version = 1"))
        self.assertTrue(checker.inspect("config.toml", b"version = 1"))
        self.assertTrue(checker.inspect(".env.production", b"SECRET=value"))
        self.assertFalse(checker.inspect(".env.example", b"EXAMPLE=placeholder"))
        credential = b"ghp_" + b"A" * 36
        self.assertTrue(checker.inspect("image.png", b"\x00\xff" + credential))

    def test_example_hosts_are_allowed_but_tailnet_literals_are_not(self):
        self.assertFalse(checker.inspect("sample.txt", b"https://desktop.example.invalid"))
        private_host = b"desktop." + b"ts" + b".net"
        self.assertTrue(checker.inspect("sample.txt", private_host))

    def test_findings_never_return_matching_values(self):
        private_path = b"/Users/" + b"fictional-sensitive-user/project"
        findings = checker.inspect("fixture.json", private_path)
        self.assertTrue(findings)
        self.assertNotIn("fictional-sensitive-user", str(findings))


if __name__ == "__main__":
    unittest.main()
