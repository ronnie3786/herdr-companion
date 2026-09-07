import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from scripts.herdr_notes_cli import main


class NotesCLIConfigurationTests(unittest.TestCase):
    def test_missing_configuration_does_not_discover_legacy_token_file(self):
        with tempfile.TemporaryDirectory() as directory:
            legacy = Path(directory) / ".config/herdr-harness/api-token"
            legacy.parent.mkdir(parents=True)
            legacy.write_text("legacy-example-secret")
            legacy.chmod(0o600)
            output, error = io.StringIO(), io.StringIO()
            opener = Mock(side_effect=AssertionError("must not send a request"))
            status = main(["list"], environ={"HOME": directory}, stdout=output,
                          stderr=error, opener=opener)
            self.assertEqual(status, 2)
            self.assertEqual(output.getvalue(), "")
            self.assertEqual(json.loads(error.getvalue())["error"]["code"], "invalid_configuration")
            self.assertIn("herdr-config", error.getvalue())
            self.assertNotIn("legacy-example-secret", error.getvalue())
            opener.assert_not_called()
