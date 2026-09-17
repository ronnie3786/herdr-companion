import io
import json
import tempfile
import unittest
import urllib.error
from email.message import Message
from pathlib import Path

from herdr_harness.connection_info import publish_connection
from scripts.herdr_session_context_cli import main


TOKEN = "synthetic-main-bearer"
CONTEXT = {
    "ok": True,
    "context": {
        "workspaceId": "workspace-1",
        "sessionId": "pi-session-1",
        "text": "User: Please inspect the sample.\n\nAssistant: I inspected it.",
        "turnCount": 2,
        "truncated": False,
        "generatedAt": "2030-01-02T03:04:05Z",
    },
}


class FakeResponse:
    def __init__(self, payload, *, final_url=None):
        self.body = json.dumps(payload).encode("utf-8")
        self.final_url = final_url
        self.request_url = None

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def geturl(self):
        return self.final_url or self.request_url

    def read(self, limit):
        return self.body[:limit]


class RecordingOpener:
    def __init__(self, response):
        self.response = response
        self.requests = []

    def __call__(self, request, timeout):
        self.requests.append((request, timeout))
        if isinstance(self.response, BaseException):
            raise self.response
        self.response.request_url = request.full_url
        return self.response


class SessionContextCLITests(unittest.TestCase):
    def run_cli(self, arguments, response=CONTEXT, *, environ=None):
        output, error = io.StringIO(), io.StringIO()
        opener = RecordingOpener(
            response if isinstance(response, BaseException) else FakeResponse(response)
        )
        environment = {
            "HERDR_HARNESS_URL": "https://companion.example.test",
            "HERDR_HARNESS_API_TOKEN": TOKEN,
        }
        if environ is not None:
            environment = environ
        status = main(
            arguments,
            environ=environment,
            stdout=output,
            stderr=error,
            opener=opener,
        )
        return status, output.getvalue(), error.getvalue(), opener

    def test_get_prints_human_context_and_uses_main_bearer_auth(self):
        status, output, error, opener = self.run_cli(
            [
                "get",
                "--workspace-id",
                "workspace-1",
                "--session-id",
                "pi-session-1",
            ]
        )
        self.assertEqual(status, 0)
        self.assertEqual(output, CONTEXT["context"]["text"] + "\n")
        self.assertEqual(error, "")
        self.assertEqual(len(opener.requests), 1)
        request, timeout = opener.requests[0]
        self.assertEqual(timeout, 20)
        self.assertEqual(
            request.full_url,
            "https://companion.example.test/api/v1/workspaces/workspace-1/pi/sessions/pi-session-1/context",
        )
        self.assertEqual(request.get_header("Authorization"), "Bearer " + TOKEN)
        self.assertEqual(request.get_header("Accept"), "application/json")
        self.assertNotIn(TOKEN, output + error)

    def test_json_includes_context_metadata(self):
        status, output, error, _ = self.run_cli(
            [
                "get",
                "--workspace-id",
                "workspace-1",
                "--session-id",
                "pi-session-1",
                "--json",
            ]
        )
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output), CONTEXT)
        self.assertEqual(error, "")

    def test_private_socket_connection_is_discovered_without_token_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            socket = str(Path(directory) / "terminal.sock")
            registration = publish_connection(
                socket_path=socket,
                host="127.0.0.1",
                port=9192,
                environ={"HOME": directory, "HERDR_HARNESS_API_TOKEN": TOKEN},
            )
            self.assertIsNotNone(registration)
            assert registration is not None
            self.addCleanup(registration.close)
            status, output, error, opener = self.run_cli(
                [
                    "get",
                    "--workspace-id",
                    "workspace-1",
                    "--session-id",
                    "pi-session-1",
                ],
                environ={"HOME": directory, "HERDR_SOCKET_PATH": socket},
            )
            self.assertEqual(status, 0)
            self.assertEqual(error, "")
            self.assertEqual(output, CONTEXT["context"]["text"] + "\n")
            request, _ = opener.requests[0]
            self.assertTrue(request.full_url.startswith("http://127.0.0.1:9192/"))
            self.assertEqual(request.get_header("Authorization"), "Bearer " + TOKEN)

    def test_missing_auth_and_unsafe_origins_fail_before_network(self):
        cases = [
            ({}, "invalid_configuration"),
            (
                {
                    "HERDR_HARNESS_URL": "http://remote.example.test",
                    "HERDR_HARNESS_API_TOKEN": TOKEN,
                },
                "invalid_configuration",
            ),
            (
                {
                    "HERDR_HARNESS_URL": "https://user:password@example.test",
                    "HERDR_HARNESS_API_TOKEN": TOKEN,
                },
                "invalid_configuration",
            ),
            (
                {
                    "HERDR_HARNESS_URL": "https://example.test/untrusted-path",
                    "HERDR_HARNESS_API_TOKEN": TOKEN,
                },
                "invalid_configuration",
            ),
        ]
        for environment, expected_code in cases:
            with self.subTest(environment=environment):
                status, output, error, opener = self.run_cli(
                    [
                        "get",
                        "--workspace-id",
                        "workspace-1",
                        "--session-id",
                        "pi-session-1",
                    ],
                    environ=environment,
                )
                self.assertEqual(status, 2)
                self.assertEqual(output, "")
                self.assertEqual(json.loads(error)["error"]["code"], expected_code)
                self.assertEqual(opener.requests, [])
                self.assertNotIn(TOKEN, error)

    def test_caller_cannot_override_configured_origin_when_main_token_is_loaded(self):
        status, output, error, opener = self.run_cli(
            [
                "--base-url",
                "https://attacker.example.test",
                "get",
                "--workspace-id",
                "workspace-1",
                "--session-id",
                "pi-session-1",
            ]
        )

        self.assertEqual(status, 2)
        self.assertEqual(output, "")
        self.assertEqual(json.loads(error)["error"]["code"], "invalid_arguments")
        self.assertEqual(opener.requests, [])
        self.assertNotIn(TOKEN, error)

    def test_redirect_is_rejected_without_following_or_leaking_auth(self):
        url = "https://companion.example.test/api/v1/workspaces/workspace-1/pi/sessions/pi-session-1/context"
        redirect = urllib.error.HTTPError(
            url,
            302,
            "Found",
            Message(),
            io.BytesIO(b""),
        )
        status, output, error, opener = self.run_cli(
            [
                "get",
                "--workspace-id",
                "workspace-1",
                "--session-id",
                "pi-session-1",
            ],
            redirect,
        )
        self.assertEqual(status, 3)
        self.assertEqual(output, "")
        self.assertEqual(json.loads(error)["error"]["code"], "redirect_not_allowed")
        self.assertEqual(len(opener.requests), 1)
        self.assertNotIn(TOKEN, error)

    def test_token_is_redacted_from_success_and_backend_errors(self):
        reflected = json.loads(json.dumps(CONTEXT))
        reflected["context"]["text"] = "User pasted " + TOKEN
        status, output, error, _ = self.run_cli(
            [
                "get",
                "--workspace-id",
                "workspace-1",
                "--session-id",
                "pi-session-1",
                "--json",
            ],
            reflected,
        )
        self.assertEqual(status, 0)
        self.assertEqual(error, "")
        self.assertNotIn(TOKEN, output)
        self.assertIn("[redacted]", output)

        url = "https://companion.example.test/context"
        body = json.dumps(
            {
                "ok": False,
                "error": {
                    "code": TOKEN,
                    "message": "rejected credential " + TOKEN,
                },
            }
        ).encode("utf-8")
        failure = urllib.error.HTTPError(
            url, 500, "Error", Message(), io.BytesIO(body)
        )
        status, output, error, _ = self.run_cli(
            [
                "get",
                "--workspace-id",
                "workspace-1",
                "--session-id",
                "pi-session-1",
            ],
            failure,
        )
        self.assertEqual(status, 3)
        self.assertEqual(output, "")
        payload = json.loads(error)
        self.assertEqual(payload["error"]["code"], "herdr_http_error")
        self.assertNotIn(TOKEN, error)
        self.assertIn("[redacted]", payload["error"]["message"])

    def test_invalid_identifiers_and_responses_are_rejected(self):
        status, output, error, opener = self.run_cli(
            [
                "get",
                "--workspace-id",
                "../workspace",
                "--session-id",
                "pi-session-1",
            ]
        )
        self.assertEqual(status, 2)
        self.assertEqual(output, "")
        self.assertEqual(json.loads(error)["error"]["code"], "invalid_arguments")
        self.assertEqual(opener.requests, [])

        status, output, error, opener = self.run_cli(
            [
                "get",
                "--workspace-id",
                "workspace-1",
                "--session-id",
                "pi-session-1",
            ],
            {"ok": True, "context": {"turnCount": 2}},
        )
        self.assertEqual(status, 3)
        self.assertEqual(output, "")
        self.assertEqual(json.loads(error)["error"]["code"], "invalid_response")
        self.assertEqual(len(opener.requests), 1)


if __name__ == "__main__":
    unittest.main()
