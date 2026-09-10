import io
import json
import unittest
from unittest.mock import Mock

from scripts.herdr_hud_chats_cli import main


class HudChatsCLITests(unittest.TestCase):
    def test_read_only_search_and_show_use_private_auth_and_pagination(self):
        for arguments, suffix in [(["search", "herb garden"], "?offset=0&q=herb+garden"),
                                  (["--offset", "50", "show", "agr_0123456789ab"], "/agr_0123456789ab?offset=50")]:
            response = Mock()
            response.__enter__ = Mock(return_value=response)
            response.__exit__ = Mock(return_value=False)
            response.read.return_value = b'{"ok":true,"chats":[]}'
            expected_url = "http://localhost:9092/api/v1/hud-chats" + suffix
            response.geturl.return_value = expected_url
            opener = Mock(return_value=response)
            output = io.StringIO()
            self.assertEqual(main(arguments, environ={"HERDR_HARNESS_URL": "http://localhost:9092",
                                                      "HERDR_HARNESS_API_TOKEN": "fixture-secret"},
                                  opener=opener, stdout=output), 0)
            request = opener.call_args.args[0]
            self.assertEqual(request.full_url, expected_url)
            self.assertEqual(request.method, "GET")
            self.assertEqual(request.get_header("Authorization"), "Bearer fixture-secret")
            self.assertNotIn("fixture-secret", output.getvalue())

    def test_missing_credentials_and_unsafe_origin_never_send(self):
        for env in ({}, {"HERDR_HARNESS_URL": "http://example.invalid", "HERDR_HARNESS_API_TOKEN": "fixture-secret"}):
            opener, error = Mock(), io.StringIO()
            self.assertEqual(main(["list"], environ=env, opener=opener, stderr=error), 2)
            opener.assert_not_called()
            self.assertFalse(json.loads(error.getvalue())["ok"])
            self.assertNotIn("fixture-secret", error.getvalue())
