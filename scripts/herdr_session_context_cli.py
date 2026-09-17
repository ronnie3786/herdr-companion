#!/usr/bin/env python3
"""Read projected visible context for one Herdr workspace and Pi session."""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from herdr_harness.connection_info import connection_environment
from herdr_harness.secret_file import (
    SecretFileError,
    load_private_bearer_token_file,
    validate_bearer_token,
)

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
IDENTIFIER = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9._-]{0,254}[A-Za-z0-9])?")


class CLIError(ValueError):
    def __init__(self, message, code="session_context_cli_error", status=None):
        super().__init__(message)
        self.code = code
        self.status = status


class Parser(argparse.ArgumentParser):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, allow_abbrev=False, **kwargs)

    def error(self, message):
        raise CLIError(
            "Invalid arguments; use herdr-session-context --help",
            "invalid_arguments",
        )


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class SessionContextClient:
    def __init__(self, base_url, token, *, opener=None):
        try:
            parsed = urllib.parse.urlsplit(base_url)
            hostname = parsed.hostname
            parsed.port
            loopback = hostname == "localhost"
            if hostname and not loopback:
                try:
                    loopback = ipaddress.ip_address(hostname).is_loopback
                except ValueError:
                    pass
        except (TypeError, ValueError) as exc:
            raise CLIError("Invalid Herdr base URL", "invalid_configuration") from exc
        if (
            parsed.scheme not in {"http", "https"}
            or not hostname
            or parsed.username
            or parsed.password
            or parsed.path not in {"", "/"}
            or parsed.query
            or parsed.fragment
            or (parsed.scheme == "http" and not loopback)
        ):
            raise CLIError(
                "Use a Herdr HTTPS origin, or HTTP on loopback, without embedded credentials",
                "invalid_configuration",
            )
        self.base_url = base_url.rstrip("/")
        self.token = validate_bearer_token(
            token, field="Herdr API token", required=True
        )
        self.opener = opener or urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect()
        ).open

    def get(self, workspace_id, session_id):
        path = "/api/v1/workspaces/{}/pi/sessions/{}/context".format(
            urllib.parse.quote(workspace_id, safe=""),
            urllib.parse.quote(session_id, safe=""),
        )
        request = urllib.request.Request(
            self.base_url + path,
            method="GET",
            headers={
                "Authorization": "Bearer " + self.token,
                "Accept": "application/json",
                "User-Agent": "herdr-session-context/1",
            },
        )
        try:
            with self.opener(request, timeout=20) as response:
                if response.geturl() != request.full_url:
                    raise CLIError(
                        "Herdr redirects are not allowed", "redirect_not_allowed"
                    )
                raw = response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as exc:
            with exc:
                raw = exc.read(64 * 1024)
            if 300 <= exc.code < 400:
                raise CLIError(
                    "Herdr redirects are not allowed", "redirect_not_allowed", exc.code
                ) from exc
            message = f"Herdr returned HTTP {exc.code}"
            code = "herdr_http_error"
            try:
                error = json.loads(raw).get("error", {})
                if isinstance(error, dict):
                    message = str(error.get("message") or message)
                    candidate = error.get("code")
                    if isinstance(candidate, str) and re.fullmatch(
                        r"[a-z][a-z0-9_]{0,63}", candidate
                    ):
                        code = candidate
            except (ValueError, UnicodeError, AttributeError):
                pass
            raise CLIError(
                _redact(message, self.token), code, exc.code
            ) from exc
        except CLIError:
            raise
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            raise CLIError(
                "Could not reach the selected Herdr backend", "herdr_unavailable"
            ) from exc
        if len(raw) > MAX_RESPONSE_BYTES:
            raise CLIError("Herdr response is too large", "response_too_large")
        try:
            result = json.loads(raw)
        except (ValueError, UnicodeError) as exc:
            raise CLIError("Herdr returned invalid JSON", "invalid_response") from exc
        if not isinstance(result, dict) or result.get("ok") is not True:
            raise CLIError(
                "Herdr returned an invalid session context", "invalid_response"
            )
        _context_text(result)
        return result


def _redact(value, token):
    return str(value).replace(token, "[redacted]") if token else str(value)


def _redact_data(value, token):
    if isinstance(value, str):
        return _redact(value, token)
    if isinstance(value, list):
        return [_redact_data(item, token) for item in value]
    if isinstance(value, dict):
        return {
            _redact(key, token): _redact_data(item, token)
            for key, item in value.items()
        }
    return value


def _context_text(result):
    context = result.get("context")
    if isinstance(context, dict) and isinstance(context.get("text"), str):
        return context["text"]
    if isinstance(context, str):
        return context
    for key in ("contextText", "text"):
        if isinstance(result.get(key), str):
            return result[key]
    raise CLIError("Herdr returned an invalid session context", "invalid_response")


def _identifier(value, name):
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise CLIError(
            f"{name} must be 1 to 256 letters, numbers, dots, underscores, or hyphens",
            "invalid_arguments",
        )
    return value


def _parser(environ):
    parser = Parser(description=__doc__)
    parser.add_argument(
        "--token-file",
        help="Explicit private API token file; otherwise use the configured main API token",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    get = commands.add_parser("get", help="Fetch projected visible conversation context")
    get.add_argument("--workspace-id", required=True)
    get.add_argument("--session-id", required=True)
    get.add_argument(
        "--json",
        action="store_true",
        help="Print the authenticated JSON response, including context metadata",
    )
    return parser


def main(argv=None, *, environ=None, stdout=None, stderr=None, opener=None):
    environment = dict(os.environ if environ is None else environ)
    stdout, stderr = stdout or sys.stdout, stderr or sys.stderr
    token = ""
    try:
        if (
            environment.get("HERDR_SOCKET_PATH")
            and not environment.get("HERDR_HARNESS_API_TOKEN")
            and not environment.get("HERDR_HARNESS_API_TOKEN_FILE")
        ):
            environment = connection_environment(environment)
        args = _parser(environment).parse_args(argv)
        workspace_id = _identifier(args.workspace_id, "Workspace ID")
        session_id = _identifier(args.session_id, "Pi session ID")
        token_file = args.token_file or environment.get(
            "HERDR_HARNESS_API_TOKEN_FILE"
        )
        if token_file:
            token = load_private_bearer_token_file(
                str(Path(token_file).expanduser().absolute()),
                field="Herdr API token",
            )
        else:
            token = validate_bearer_token(
                environment.get("HERDR_HARNESS_API_TOKEN", ""),
                field="Herdr API token",
                required=True,
            )
        result = SessionContextClient(
            environment.get("HERDR_HARNESS_BASE_URL")
            or environment.get("HERDR_HARNESS_URL")
            or "http://127.0.0.1:9092",
            token,
            opener=opener,
        ).get(workspace_id, session_id)
        if args.json:
            print(
                json.dumps(_redact_data(result, token), ensure_ascii=False),
                file=stdout,
            )
        else:
            text = _redact(_context_text(result), token)
            stdout.write(text)
            if not text.endswith("\n"):
                stdout.write("\n")
        return 0
    except (CLIError, SecretFileError, OSError, ValueError) as exc:
        if isinstance(exc, (CLIError, SecretFileError)):
            message = _redact(exc, token)
        else:
            message = "Invalid input or unavailable private Herdr connection"
        payload = {
            "ok": False,
            "error": {
                "code": getattr(exc, "code", "invalid_configuration"),
                "message": message,
            },
        }
        status = getattr(exc, "status", None)
        if status is not None:
            payload["error"]["httpStatus"] = status
        print(json.dumps(_redact_data(payload, token)), file=stderr)
        return 3 if status or getattr(exc, "code", "") in {
            "herdr_unavailable",
            "redirect_not_allowed",
            "invalid_response",
            "response_too_large",
        } else 2


if __name__ == "__main__":
    raise SystemExit(main())
