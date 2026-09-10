#!/usr/bin/env python3
"""Read-only discovery of saved HUD chats, using the shared private configuration."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.parse
from pathlib import Path

from .herdr_notes_cli import CLIError, NotesClient
from herdr_harness.secret_file import SecretFileError, load_private_bearer_token_file, validate_bearer_token


class HudChatsClient(NotesClient):
    api_path = "/api/v1/hud-chats"


def main(argv=None, *, environ=None, stdout=None, stderr=None, opener=None):
    environ = dict(os.environ if environ is None else environ)
    stdout, stderr = stdout or sys.stdout, stderr or sys.stderr
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--base-url", default=environ.get("HERDR_HARNESS_BASE_URL") or environ.get("HERDR_HARNESS_URL") or "http://127.0.0.1:9092")
    parser.add_argument("--token-file")
    parser.add_argument("--offset", type=int, default=0, help="Page offset; follow nextOffset in the JSON response")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    commands.add_parser("search").add_argument("query")
    commands.add_parser("show").add_argument("id", help="HUD chat root or run ID (agr_…)")
    token = ""
    try:
        args = parser.parse_args(argv)
        if not 0 <= args.offset <= 100000:
            raise CLIError("Offset must be between 0 and 100000", "invalid_arguments")
        token_file = args.token_file or environ.get("HERDR_HARNESS_API_TOKEN_FILE")
        token = (load_private_bearer_token_file(str(Path(token_file).expanduser().absolute()), field="Herdr API token")
                 if token_file else validate_bearer_token(environ.get("HERDR_HARNESS_API_TOKEN", ""), field="Herdr API token", required=True))
        query = {"offset": args.offset}
        path = ""
        if args.command == "show":
            if not re.fullmatch(r"agr_[0-9a-f]{12}", args.id):
                raise CLIError("Invalid HUD chat ID", "invalid_arguments")
            path = "/" + args.id
        if args.command == "search":
            query["q"] = args.query
        result = HudChatsClient(args.base_url, token, opener=opener).request("GET", path + "?" + urllib.parse.urlencode(query))
        print(json.dumps(result, ensure_ascii=False).replace(token, "[redacted]"), file=stdout)
        return 0
    except (CLIError, SecretFileError, OSError, ValueError) as exc:
        message = str(exc) if isinstance(exc, (CLIError, SecretFileError)) else "Invalid input or unavailable configuration"
        payload = json.dumps({"ok": False, "error": {"code": getattr(exc, "code", "hud_chats_cli_error"), "message": message}})
        print(payload.replace(token, "[redacted]") if token else payload, file=stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
