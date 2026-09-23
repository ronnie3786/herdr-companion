#!/usr/bin/env python3
"""JSON controls for First Mate. Mutations use the same authenticated API as the apps."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.parse
import uuid
try:
    from .herdr_notes_cli import CLIError, NotesClient, Parser as BaseParser, _read_file
except ImportError:
    from herdr_notes_cli import CLIError, NotesClient, Parser as BaseParser, _read_file
from herdr_harness.secret_file import SecretFileError, load_private_bearer_token_file, validate_bearer_token

class Parser(BaseParser):
    def error(self, _message):
        raise CLIError("Invalid arguments; use herdr-first-mate --help", "invalid_arguments")

class FirstMateClient(NotesClient):
    api_path = "/api/v1/first-mate"


LINKS_CAPABILITY = "first-mate-links-v1"
LINKS_UNSUPPORTED = ("This companion does not advertise first-mate-links-v1. "
                     "Update the companion server to list, save, hide, or restore First Mate links.")


def _require_links_capability(client, request):
    """Fail with upgrade guidance before any link route is attempted."""
    try:
        result = request("GET", "/capabilities")
    except CLIError as exc:
        if exc.code == "not_found" or exc.status in {404, 405, 501}:
            raise CLIError(LINKS_UNSUPPORTED, "first_mate_links_unsupported") from exc
        raise
    capabilities = result.get("capabilities")
    if not isinstance(capabilities, list) or LINKS_CAPABILITY not in capabilities:
        raise CLIError(LINKS_UNSUPPORTED, "first_mate_links_unsupported")

def parser(environ):
    p = Parser(description=__doc__)
    p.add_argument("--base-url", default=environ.get("HERDR_HARNESS_URL") or "http://127.0.0.1:9092")
    p.add_argument("--token-file")
    commands = p.add_subparsers(dest="command", required=True)
    feature_list = commands.add_parser("list")
    list_scope = feature_list.add_mutually_exclusive_group()
    list_scope.add_argument("--archived", action="store_true", help="List archived features only")
    list_scope.add_argument("--all", action="store_true", help="List active and archived features")
    for name in ("capabilities", "models"):
        commands.add_parser(name)
    create = commands.add_parser("create")
    for field in ("title", "goal", "cwd"):
        create.add_argument("--" + field, required=True)
    create.add_argument("--work-item-id")
    create.add_argument("--request-id", default=None)
    for name in ("get", "agents", "documents", "messages", "events", "send", "pause", "resume", "cancel", "archive", "unarchive", "open", "links"):
        sub = commands.add_parser(name)
        sub.add_argument("feature_id")
        if name == "events":
            sub.add_argument("--after", type=int, default=0)
        if name == "send":
            body = sub.add_mutually_exclusive_group(required=True)
            body.add_argument("--text")
            body.add_argument("--text-file", help="UTF-8 file, or - for stdin")
        if name in ("send", "pause", "resume", "cancel", "archive", "unarchive"):
            sub.add_argument("--request-id", default=None)
        if name in ("pause", "resume", "cancel"):
            sub.add_argument("--expected-revision", type=int)
        if name == "archive":
            sub.add_argument("--reason", choices=("test/synthetic", "duplicate", "no longer relevant", "superseded", "other"))
        if name == "open":
            sub.add_argument("--tab", choices=("overview", "agents", "documents", "workflow"), default="overview")
            sub.add_argument("--graph", action="store_true")
            sub.add_argument("--app-server-url", help="Existing saved Mac app origin when the API uses a different loopback origin")
            sub.add_argument("--print-url", action="store_true", help="Return the native app link without launching it")
    add_link = commands.add_parser("add-link")
    add_link.add_argument("feature_id")
    add_link.add_argument("--url", required=True, help="Exact absolute http(s) URL to retain")
    add_link.add_argument("--title", help="Short human-readable label")
    add_link.add_argument("--kind", choices=("pull_request", "link"), help="Explicit classification for a non-github.com PR")
    add_link.add_argument("--request-id", default=None)
    for name in ("hide-link", "restore-link"):
        sub = commands.add_parser(name)
        sub.add_argument("feature_id")
        sub.add_argument("link_id")
        sub.add_argument("--request-id", default=None)
    settings = commands.add_parser("set-model")
    settings.add_argument("feature_id")
    settings.add_argument("--model", required=True, help="provider/model, or an empty string for host default")
    settings.add_argument("--thinking", default="", choices=("", "off", "minimal", "low", "medium", "high", "xhigh", "max"))
    settings.add_argument("--expected-settings-revision", type=int, required=True)
    settings.add_argument(
        "--expected-session-id",
        help="Exact current coordinator session ID required for an established-session change",
    )
    settings.add_argument(
        "--confirm-session-model-change", action="store_true", default=None,
        help="Explicitly accept reprocessing and prompt-cache cost risk at a safe idle turn boundary",
    )
    settings.add_argument("--request-id")
    commands.add_parser("document").add_argument("id")
    session = commands.add_parser("session")
    session.add_argument("id")
    session.add_argument("--before", type=int)
    session.add_argument("--limit", type=int, default=100)
    return p

def execute(args, client, *, stdin, launch):
    quote = lambda value: urllib.parse.quote(value, safe="")
    if args.command in ("capabilities", "models"): return client.request("GET", "/" + args.command)
    if args.command == "links":
        _require_links_capability(client, client.request)
        result = client.request("GET", "/features/" + quote(args.feature_id))
        links = result.get("links")
        return {"ok": True, "links": links if isinstance(links, list) else []}
    if args.command in ("add-link", "hide-link", "restore-link"):
        _require_links_capability(client, client.request)
        path = "/features/" + quote(args.feature_id) + "/links"
        if args.command == "add-link":
            body = {"url": args.url, "request_id": args.request_id or str(uuid.uuid4())}
            if args.title is not None: body["title"] = args.title
            if args.kind is not None: body["kind"] = args.kind
        else:
            body = {"hidden": args.command == "hide-link",
                    "request_id": args.request_id or str(uuid.uuid4())}
            path += "/" + quote(args.link_id) + "/visibility"
        result = client.request("POST", path, body)
        return {"ok": True, "link": result.get("link")}
    if args.command == "list":
        view = "all" if args.all else "archived" if args.archived else "active"
        query = "" if view == "active" else "?" + urllib.parse.urlencode({"view": view})
        return client.request("GET", "/features" + query)
    if args.command == "create":
        body = {k: getattr(args, k) for k in ("title", "goal", "cwd")}
        body["request_id"] = args.request_id or str(uuid.uuid4())
        if args.work_item_id: body["work_item_id"] = args.work_item_id
        return client.request("POST", "/features", body)
    if args.command in ("document", "session"):
        path = "/documents/" if args.command == "document" else "/sessions/"
        query = {"limit": args.limit} if args.command == "session" else {}
        if args.command == "session" and args.before is not None: query["before"] = args.before
        return client.request("GET", path + quote(args.id) + ("?" + urllib.parse.urlencode(query) if query else ""))
    path = "/features/" + quote(args.feature_id)
    if args.command == "set-model":
        body = {
            "model": args.model, "thinking": args.thinking,
            "expected_settings_revision": args.expected_settings_revision,
            "request_id": args.request_id or str(uuid.uuid4()),
        }
        if args.expected_session_id is not None:
            body["expected_session_id"] = args.expected_session_id
        if args.confirm_session_model_change is not None:
            body["confirm_session_model_change"] = args.confirm_session_model_change
        return client.request("POST", path + "/model-settings", body)
    if args.command == "events": return client.request("GET", path + "/events?" + urllib.parse.urlencode({"after": args.after}))
    if args.command == "send":
        text = _read_file(args.text_file, stdin) if args.text_file else args.text
        if not text.strip(): raise CLIError("Message cannot be empty", "invalid_input")
        return client.request("POST", path + "/messages", {"text": text, "request_id": args.request_id or str(uuid.uuid4())})
    if args.command in ("pause", "resume", "cancel"):
        body = {"action": args.command, "request_id": args.request_id or str(uuid.uuid4())}
        if args.expected_revision is not None: body["expected_revision"] = args.expected_revision
        return client.request("POST", path + "/actions", body)
    if args.command in ("archive", "unarchive"):
        body = {"action": args.command, "request_id": args.request_id or str(uuid.uuid4())}
        if args.command == "archive" and args.reason is not None: body["reason"] = args.reason
        return client.request("POST", path + "/actions", body)
    result = client.request("GET", path)
    if args.command == "open":
        query = {"feature_id": args.feature_id, "server_url": FirstMateClient(args.app_server_url, "route-validation").base_url if args.app_server_url else client.base_url, "tab": "workflow" if args.graph else args.tab}
        if args.graph: query["view"] = "graph"
        url = "herdr://first-mate?" + urllib.parse.urlencode(query)
        if not args.print_url: launch(["/usr/bin/open", url], check=True)
        return {"ok": True, "url": url, "launch_requested": not args.print_url}
    key = "assignments" if args.command == "agents" else args.command
    return {"ok": True, key: result[key]} if key in ("assignments", "documents", "messages") else result

def main(argv=None, *, environ=None, stdin=None, stdout=None, stderr=None, opener=None, launch=subprocess.run):
    environ = dict(os.environ if environ is None else environ)
    stdin, stdout, stderr = stdin or sys.stdin, stdout or sys.stdout, stderr or sys.stderr
    token = ""
    try:
        args = parser(environ).parse_args(argv)
        token_file = args.token_file or environ.get("HERDR_HARNESS_API_TOKEN_FILE")
        token = load_private_bearer_token_file(str(Path(token_file).expanduser().absolute()), field="Herdr API token") if token_file else validate_bearer_token(environ.get("HERDR_HARNESS_API_TOKEN", ""), field="Herdr API token", required=True)
        result = execute(args, FirstMateClient(args.base_url, token, opener=opener), stdin=stdin, launch=launch)
        print(json.dumps(result, ensure_ascii=False).replace(token, "[redacted]"), file=stdout)
        return 0
    except (CLIError, SecretFileError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        message = str(exc) if isinstance(exc, (CLIError, SecretFileError)) else "Invalid input or unavailable resource"
        payload = {"ok": False, "error": {"code": getattr(exc, "code", "invalid_input"), "message": message}}
        if getattr(exc, "status", None): payload["error"]["httpStatus"] = exc.status
        encoded = json.dumps(payload)
        print(encoded.replace(token, "[redacted]") if token else encoded, file=stderr)
        return 4 if getattr(exc, "status", None) == 409 else 2

if __name__ == "__main__":
    raise SystemExit(main())
