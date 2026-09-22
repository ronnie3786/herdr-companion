#!/usr/bin/env python3
"""Read-only discovery of saved HUD chats and terminal tab-color groups.

``list`` and ``search`` default to the existing saved-history catalog. The
explicit ``--scope terminal`` reads the companion's terminal chat discovery,
which carries inherited tab color metadata, and stays read-only: every request
is a GET, redirects are refused, and the bearer is redacted from output.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.parse
from pathlib import Path
from typing import Any, Optional

from .herdr_notes_cli import CLIError, NotesClient
from herdr_harness.chat_tab_color_cli import (
    CHAT_TAB_COLOR_CHOICES,
    GROUPING_SCOPE,
    GROUP_BY_CHOICES,
    chat_tab_colors_unsupported_message,
    color_query_parameters,
    group_results,
    is_color_requested,
    supports_chat_tab_colors,
)
from herdr_harness.secret_file import SecretFileError, load_private_bearer_token_file, validate_bearer_token


# Accepted both before the subcommand (saved-list compatibility) and after one
# of the list/search subcommands, mirroring ``herdr-control find`` options.
_PAGE_OFFSET_HELP = "Page offset; follow nextOffset in the JSON response"


class HudChatsClient(NotesClient):
    api_path = "/api/v1/hud-chats"


class ControlDiscoveryClient(NotesClient):
    api_path = "/api/v1"


def _terminal_only_options(args: argparse.Namespace) -> dict[str, Optional[str]]:
    return {
        "color": getattr(args, "color", None),
        "color_label": getattr(args, "color_label", None),
        "color_client": getattr(args, "color_client", None),
        "group_by": getattr(args, "group_by", None),
    }


def _saved_history(args: argparse.Namespace, token: str, *, opener: Any) -> dict:
    """Run the unchanged saved-HUD request path."""

    query = {"offset": args.offset}
    path = ""
    if args.command == "show":
        if not re.fullmatch(r"agr_[0-9a-f]{12}", args.id):
            raise CLIError("Invalid HUD chat ID", "invalid_arguments")
        path = "/" + args.id
    if args.command == "search":
        query["q"] = args.query
    return HudChatsClient(args.base_url, token, opener=opener).request(
        "GET", path + "?" + urllib.parse.urlencode(query)
    )


def _terminal_discovery(args: argparse.Namespace, token: str, *, opener: Any) -> dict:
    """Read terminal chats with inherited tab color metadata."""

    client = ControlDiscoveryClient(args.base_url, token, opener=opener)
    try:
        capabilities = client.request("GET", "/control/capabilities")
    except CLIError as exc:
        if exc.code == "not_found" or exc.status in {404, 405, 501}:
            raise CLIError(
                chat_tab_colors_unsupported_message(), "chat_tab_colors_unsupported"
            ) from exc
        raise
    if not supports_chat_tab_colors(capabilities.get("capabilities")):
        raise CLIError(
            chat_tab_colors_unsupported_message(), "chat_tab_colors_unsupported"
        )
    query: dict[str, Any] = {
        "kind": "chats",
        "chatScope": "terminal",
        "offset": args.offset,
    }
    if args.command == "search":
        query["q"] = args.query
    query.update(
        color_query_parameters(
            color=getattr(args, "color", None),
            color_label=getattr(args, "color_label", None),
            color_client=getattr(args, "color_client", None),
        )
    )
    result = client.request("GET", "/discovery?" + urllib.parse.urlencode(query))
    result["scope"] = "terminal"
    group_by = getattr(args, "group_by", None)
    if group_by is not None:
        results = result.get("results")
        result["groups"] = group_results(
            results if isinstance(results, list) else [],
            group_by=group_by,
            color=getattr(args, "color", None),
            color_label=getattr(args, "color_label", None),
            color_client=getattr(args, "color_client", None),
        )
        result["groupingScope"] = GROUPING_SCOPE
    return result


def main(argv=None, *, environ=None, stdout=None, stderr=None, opener=None):
    environ = dict(os.environ if environ is None else environ)
    stdout, stderr = stdout or sys.stdout, stderr or sys.stderr
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--base-url", default=environ.get("HERDR_HARNESS_BASE_URL") or environ.get("HERDR_HARNESS_URL") or "http://127.0.0.1:9092")
    parser.add_argument("--token-file")
    parser.add_argument("--offset", type=int, default=0, help=_PAGE_OFFSET_HELP)
    commands = parser.add_subparsers(dest="command", required=True)
    list_command = commands.add_parser("list")
    search_command = commands.add_parser("search")
    search_command.add_argument("query")
    commands.add_parser("show").add_argument("id", help="HUD chat root or run ID (agr_…)")
    for command in (list_command, search_command):
        command.add_argument(
            "--offset",
            type=int,
            default=argparse.SUPPRESS,
            help=_PAGE_OFFSET_HELP,
        )
        command.add_argument(
            "--scope",
            choices=("saved", "terminal"),
            default="saved",
            help="Saved HUD history (default) or terminal chats with tab color metadata",
        )
        command.add_argument(
            "--color",
            choices=CHAT_TAB_COLOR_CHOICES,
            help="Match one palette color, or none for explicitly unassigned tabs",
        )
        command.add_argument(
            "--color-label",
            help="Match a published tab color label exactly (trimmed, case-insensitive)",
        )
        command.add_argument(
            "--color-client",
            help="Restrict tab color matching to one publisher installation ID",
        )
        command.add_argument(
            "--group-by",
            choices=GROUP_BY_CHOICES,
            help="Add a page-scoped color or label group projection of the returned rows",
        )
    token = ""
    try:
        args = parser.parse_args(argv)
        if not 0 <= args.offset <= 100000:
            raise CLIError("Offset must be between 0 and 100000", "invalid_arguments")
        color_options = _terminal_only_options(args)
        if getattr(args, "scope", "saved") != "terminal" and is_color_requested(
            **color_options
        ):
            raise CLIError(
                "Tab color discovery is terminal-only; re-run with --scope terminal, "
                "or drop the color options for saved HUD history",
                "invalid_arguments",
            )
        token_file = args.token_file or environ.get("HERDR_HARNESS_API_TOKEN_FILE")
        token = (load_private_bearer_token_file(str(Path(token_file).expanduser().absolute()), field="Herdr API token")
                 if token_file else validate_bearer_token(environ.get("HERDR_HARNESS_API_TOKEN", ""), field="Herdr API token", required=True))
        result = (
            _terminal_discovery(args, token, opener=opener)
            if getattr(args, "scope", "saved") == "terminal"
            else _saved_history(args, token, opener=opener)
        )
        print(json.dumps(result, ensure_ascii=False).replace(token, "[redacted]"), file=stdout)
        return 0
    except (CLIError, SecretFileError, OSError, ValueError) as exc:
        message = str(exc) if isinstance(exc, (CLIError, SecretFileError)) else "Invalid input or unavailable configuration"
        payload = json.dumps({"ok": False, "error": {"code": getattr(exc, "code", "hud_chats_cli_error"), "message": message}})
        print(payload.replace(token, "[redacted]") if token else payload, file=stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
