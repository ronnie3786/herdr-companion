#!/usr/bin/env python3
"""JSON command line access to the notes on one Herdr backend."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from herdr_harness.secret_file import SecretFileError, load_private_bearer_token_file, validate_bearer_token

MAX_BYTES = 32 * 1024 * 1024


class CLIError(ValueError):
    def __init__(self, message, code="notes_cli_error", status=None):
        super().__init__(message)
        self.code, self.status = code, status


class Parser(argparse.ArgumentParser):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, allow_abbrev=False, **kwargs)

    def error(self, _message):
        raise CLIError("Invalid arguments; use herdr-notes --help", "invalid_arguments")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


class NotesClient:
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
        except ValueError as exc:
            raise CLIError("Invalid Herdr base URL", "invalid_configuration") from exc
        if (parsed.scheme not in {"http", "https"} or not hostname or parsed.username or parsed.password
                or parsed.path not in {"", "/"} or parsed.query or parsed.fragment
                or (parsed.scheme == "http" and not loopback)):
            raise CLIError("Use a Herdr HTTPS origin, or HTTP on loopback, without embedded credentials", "invalid_configuration")
        self.base_url = base_url.rstrip("/")
        self.token = validate_bearer_token(token, field="Herdr API token", required=True)
        self.opener = opener or urllib.request.build_opener(NoRedirect()).open

    def request(self, method, path, payload=None):
        encoded = json.dumps(payload, allow_nan=False).encode() if payload is not None else None
        if encoded is not None and len(encoded) > MAX_BYTES:
            raise CLIError("Request is too large", "request_too_large")
        request = urllib.request.Request(self.base_url + "/api/v1/notes" + path, data=encoded, method=method,
            headers={"Authorization": "Bearer " + self.token, "Accept": "application/json",
                     "Content-Type": "application/json", "User-Agent": "herdr-notes/1"})
        try:
            with self.opener(request, timeout=20) as response:
                if response.geturl() != request.full_url:
                    raise CLIError("Herdr redirects are not allowed", "redirect_not_allowed")
                raw = response.read(MAX_BYTES + 1)
        except urllib.error.HTTPError as exc:
            with exc:
                raw = exc.read(64 * 1024)
            message, code = f"Herdr returned HTTP {exc.code}", "herdr_http_error"
            try:
                error = json.loads(raw).get("error", {})
                message, code = str(error.get("message") or message), str(error.get("code") or code)
            except (ValueError, AttributeError):
                pass
            raise CLIError(message.replace(self.token, "[redacted]"), code.replace(self.token, "[redacted]"), exc.code) from exc
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            raise CLIError("Could not reach the selected Herdr backend", "herdr_unavailable") from exc
        if len(raw) > MAX_BYTES:
            raise CLIError("Herdr response is too large", "response_too_large")
        try:
            result = json.loads(raw)
        except (ValueError, UnicodeError) as exc:
            raise CLIError("Herdr returned invalid JSON", "invalid_response") from exc
        if not isinstance(result, dict) or result.get("ok") is not True:
            raise CLIError("Herdr returned an unsuccessful response", "invalid_response")
        return result


def _parser(environ):
    parser = Parser(description="Read and manage notes synced to one Herdr machine. Outputs JSON. Never retries conflicting edits.")
    parser.add_argument("--base-url", default=environ.get("HERDR_NOTES_BASE_URL") or environ.get("HERDR_HARNESS_BASE_URL") or environ.get("HERDR_HARNESS_URL") or "http://127.0.0.1:9092")
    parser.add_argument("--token-file", default=None, help="Explicit private API token file; otherwise use the configured API token")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    commands.add_parser("search").add_argument("query")
    get = commands.add_parser("get")
    get.add_argument("id")
    get.add_argument("--raw", action="store_true", help="Include opaque native rich-text payloads")
    for command in ("create", "update"):
        sub = commands.add_parser(command)
        if command == "update":
            sub.add_argument("id")
            sub.add_argument("--expected-revision", type=int)
        else:
            sub.add_argument("--id", default=None, help="Stable UUID makes retried creates idempotent")
        sub.add_argument("--title")
        body = sub.add_mutually_exclusive_group()
        body.add_argument("--body")
        body.add_argument("--body-file", help="UTF-8 text file, or - for stdin")
        sub.add_argument("--color", choices=("yellow", "peach", "pink", "green", "blue", "lavender"))
    delete = commands.add_parser("delete")
    delete.add_argument("id")
    delete.add_argument("--expected-revision", type=int)
    commands.add_parser("import").add_argument("file", help="JSON note array or hud-notes.json; - reads stdin")
    return parser


def _read_file(path, stdin):
    if path == "-":
        text = stdin.read(MAX_BYTES + 1)
    else:
        with Path(path).expanduser().open(encoding="utf-8") as stream:
            text = stream.read(MAX_BYTES + 1)
    if len(text.encode("utf-8")) > MAX_BYTES:
        raise CLIError("Input file is too large", "input_too_large")
    return text


def execute(args, client, *, stdin):
    if args.command in {"list", "search"}:
        result = client.request("GET", "?" + urllib.parse.urlencode({"q": args.query}) if args.command == "search" else "")
        entries = []
        for note in result["notes"]:
            preview = " ".join(note["body"].split())[:160]
            title = note["title"].strip() or next((line.strip()[:60] for line in note["body"].splitlines() if line.strip()), "Untitled note")
            entries.append({key: note[key] for key in ("id", "title", "color", "revision", "updatedAt")}
                           | {"displayTitle": title, "preview": preview})
        return {"ok": True, "revision": result["revision"], "count": len(entries), "notes": entries}
    if args.command == "import":
        payload = json.loads(_read_file(args.file, stdin))
        notes = payload.get("notes") if isinstance(payload, dict) else payload
        return client.request("POST", "/import", {"notes": notes})
    identifier = str(uuid.UUID(args.id)) if args.id else str(uuid.uuid4())
    if args.command == "get":
        result = client.request("GET", "/" + identifier)
        if not args.raw:
            result["note"].pop("richBody", None)
            previous = result["note"].get("previousVersion")
            if isinstance(previous, dict):
                previous.pop("richBody", None)
        return result
    if args.command in {"create", "update"}:
        changes = {key: getattr(args, key) for key in ("title", "body", "color") if getattr(args, key) is not None}
        if args.body_file is not None:
            changes["body"] = _read_file(args.body_file, stdin)
        if args.command == "create":
            return client.request("POST", "", {"note": {"id": identifier, **changes}})
        if not changes:
            raise CLIError("Specify at least one field to update", "invalid_arguments")
    expected = args.expected_revision
    if expected is None:
        expected = client.request("GET", "/" + identifier)["note"]["revision"]
    payload = {"expectedRevision": expected}
    if args.command == "update":
        payload["changes"] = changes
    return client.request("PATCH" if args.command == "update" else "DELETE", "/" + identifier, payload)


def main(argv=None, *, environ=None, stdin=None, stdout=None, stderr=None, opener=None):
    environ = dict(os.environ if environ is None else environ)
    stdin, stdout, stderr = stdin or sys.stdin, stdout or sys.stdout, stderr or sys.stderr
    token = ""
    try:
        args = _parser(environ).parse_args(argv)
        token_file = args.token_file or environ.get("HERDR_HARNESS_API_TOKEN_FILE")
        if token_file:
            token = load_private_bearer_token_file(str(Path(token_file).expanduser().absolute()), field="Herdr API token")
        elif environ.get("HERDR_HARNESS_API_TOKEN"):
            token = validate_bearer_token(environ["HERDR_HARNESS_API_TOKEN"], field="Herdr API token", required=True)
        else:
            raise CLIError("Configure an API token with herdr-config, or supply --token-file", "invalid_configuration")
        result = execute(args, NotesClient(args.base_url, token, opener=opener), stdin=stdin)
        print(json.dumps(result, ensure_ascii=False).replace(token, "[redacted]"), file=stdout)
        return 0
    except (CLIError, SecretFileError, OSError, ValueError, KeyError) as exc:
        message = str(exc) if isinstance(exc, (CLIError, SecretFileError)) else "Invalid input or unavailable input file"
        payload = {"ok": False, "error": {"code": getattr(exc, "code", "invalid_input"), "message": message}}
        if getattr(exc, "status", None):
            payload["error"]["httpStatus"] = exc.status
        encoded = json.dumps(payload)
        print(encoded.replace(token, "[redacted]") if token else encoded, file=stderr)
        return 4 if getattr(exc, "status", None) == 409 else 2


if __name__ == "__main__":
    raise SystemExit(main())
