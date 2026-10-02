#!/usr/bin/env python3
"""JSON command line controls for PR Review."""
from __future__ import annotations

import base64
import json
import mimetypes
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid

MAX_DOCUMENT_BYTES = 2 * 1024 * 1024 * 1024

try:
    from .herdr_notes_cli import CLIError, NotesClient, Parser as BaseParser, _read_file
except ImportError:
    from herdr_notes_cli import CLIError, NotesClient, Parser as BaseParser, _read_file
from herdr_harness.secret_file import SecretFileError, load_private_bearer_token_file, validate_bearer_token


class Parser(BaseParser):
    def error(self, _message):
        raise CLIError("Invalid arguments; use herdr-pr-review --help", "invalid_arguments")


class PRReviewClient(NotesClient):
    api_path = "/api/v1/pr-reviews"


class UIControlClient(NotesClient):
    api_path = "/api/v1/ui"


def _review_id(subparser, environ):
    subparser.add_argument("id", nargs="?", default=environ.get("HERDR_PR_REVIEW_ID"))


def _comment_input(subparser):
    source = subparser.add_mutually_exclusive_group(required=True)
    source.add_argument("--body", help="Exact Markdown comment text")
    source.add_argument("--body-file", help="Read Markdown from a file, or - for stdin")


def _comparison_input(subparser):
    subparser.add_argument("--mode", choices=("all", "commit", "range"))
    subparser.add_argument("--start-commit")
    subparser.add_argument("--end-commit")
    subparser.add_argument("--base-sha")
    subparser.add_argument("--head-sha")


def parser(environ):
    command_parser = Parser(description=__doc__)
    command_parser.add_argument("--base-url", default=environ.get("HERDR_HARNESS_URL") or "http://127.0.0.1:9092")
    command_parser.add_argument("--token-file")
    commands = command_parser.add_subparsers(dest="command", required=True)

    commands.add_parser("capabilities", help="Show PR Review capabilities")
    commands.add_parser("skills", help="List configured skills")
    listing = commands.add_parser("list", help="List reviews")
    listing.add_argument("--archived", action="store_true")
    listing.add_argument("--all", action="store_true")

    add_skill = commands.add_parser("add-skill", help="Add a custom skill")
    add_skill.add_argument("--id", required=True)
    add_skill.add_argument("--title", required=True)
    add_skill.add_argument("--kind")
    add_skill.add_argument("--prompt")
    add_skill.add_argument("--command")
    add_skill.add_argument("--outputs", nargs="*")
    add_skill.add_argument("--description")
    add_skill.add_argument("--request-id")

    remove_skill = commands.add_parser("remove-skill", help="Disable a custom skill")
    remove_skill.add_argument("id")
    remove_skill.add_argument("--request-id")

    create = commands.add_parser("create", help="Create a PR review")
    create.add_argument("--url", required=True)
    create.add_argument("--skill", action="append", default=[])
    create.add_argument("--request-id")

    for name in ("get", "files", "runs", "documents", "archive", "unarchive", "refresh", "rank", "sync-viewed"):
        subparser = commands.add_parser(name, help=f"{name.replace('-', ' ').title()} a review")
        _review_id(subparser, environ)
        if name in ("archive", "unarchive", "refresh", "rank", "sync-viewed"):
            subparser.add_argument("--request-id")

    diff = commands.add_parser("diff", help="Show a review diff")
    _review_id(diff, environ)
    diff.add_argument("--path")
    _comparison_input(diff)

    commits = commands.add_parser("commits", help="Read the pinned review commit history")
    _review_id(commits, environ)
    commits.add_argument("--base-sha")
    commits.add_argument("--head-sha")

    file_command = commands.add_parser("file", help="Read a reviewed file")
    _review_id(file_command, environ)
    file_command.add_argument("--path", required=True)
    file_command.add_argument("--side", required=True, choices=("before", "after"))
    file_command.add_argument("--start", type=int)
    file_command.add_argument("--end", type=int)
    _comparison_input(file_command)

    comments = commands.add_parser("comments", help="Read persistent comments on the review host")
    _review_id(comments, environ)
    comments.add_argument("--state", choices=("all", "open", "resolved"), default="all")
    comments.add_argument("--path")
    comments.add_argument("--thread", help="Read one thread including its revision history")

    for name, help_text in (("comment", "Add a private PR or inline comment"),
                            ("reply", "Reply to a private review thread"),
                            ("resolve", "Mark a private thread resolved"),
                            ("reopen", "Reopen a private thread"),
                            ("edit-comment", "Edit a message while retaining its history")):
        subparser = commands.add_parser(name, help=help_text)
        _review_id(subparser, environ)
        subparser.add_argument("--author", choices=("human", "agent"), default="agent")
        subparser.add_argument("--request-id")
        if name in ("comment", "reply", "edit-comment"):
            _comment_input(subparser)
        if name != "comment":
            subparser.add_argument("--thread", required=True)
        if name in ("resolve", "reopen", "edit-comment"):
            subparser.add_argument("--expected-version", type=int, required=True)
        if name == "edit-comment":
            subparser.add_argument("--message", required=True)
        if name == "comment":
            subparser.add_argument("--path")
            subparser.add_argument("--side", choices=("before", "after"))
            subparser.add_argument("--start", type=int)
            subparser.add_argument("--end", type=int)
            _comparison_input(subparser)

    findings = commands.add_parser("findings", help="Read findings for one file")
    _review_id(findings, environ)
    findings.add_argument("--path", required=True)

    run = commands.add_parser("run", help="Start a skill run")
    _review_id(run, environ)
    run.add_argument("--skill", required=True)
    run.add_argument("--request-id")

    finish = commands.add_parser("finish-run", help="Finish a skill run")
    _review_id(finish, environ)
    finish.add_argument("run_id", nargs="?", default=environ.get("HERDR_PR_REVIEW_RUN_ID"))
    finish.add_argument("--state", default="finished", choices=("finished", "failed"))
    finish.add_argument("--note")
    finish.add_argument("--request-id")

    output = commands.add_parser("run-output", help="Read skill-run output")
    _review_id(output, environ)
    output.add_argument("run_id", nargs="?", default=environ.get("HERDR_PR_REVIEW_RUN_ID"))
    output.add_argument("--lines", type=int, default=200)

    mark = commands.add_parser("mark", help="Mark a skill as run or not run")
    _review_id(mark, environ)
    mark.add_argument("--skill", required=True)
    mark.add_argument("--state", required=True, choices=("ran", "not-run"))
    mark.add_argument("--note")
    mark.add_argument("--request-id")

    rankings = commands.add_parser("set-rankings", help="Set file rankings from JSON")
    _review_id(rankings, environ)
    rankings.add_argument("--file", required=True)
    rankings.add_argument("--request-id")

    viewed = commands.add_parser("viewed", help="Set viewed state for files")
    _review_id(viewed, environ)
    viewed.add_argument("--path", action="append", required=True)
    viewed.add_argument("--unviewed", action="store_true")
    viewed.add_argument("--no-github", action="store_true")
    viewed.add_argument("--request-id")

    add_document = commands.add_parser("add-document", help="Attach a document")
    _review_id(add_document, environ)
    source = add_document.add_mutually_exclusive_group(required=True)
    source.add_argument("--file")
    source.add_argument("--upload")
    source.add_argument("--link")
    add_document.add_argument("--title")
    add_document.add_argument("--request-id")

    document = commands.add_parser("document", help="Download one document")
    _review_id(document, environ)
    document.add_argument("doc_id")
    document.add_argument("--out", required=True)

    events = commands.add_parser("events", help="List review events")
    _review_id(events, environ)
    events.add_argument("--after", type=int, default=0)

    open_command = commands.add_parser("open", help="Open a review in the native app")
    _review_id(open_command, environ)
    open_command.add_argument("--file")
    open_command.add_argument("--line", type=int)
    open_command.add_argument("--side", choices=("before", "after"))
    open_command.add_argument("--tab", choices=("files", "context", "agents", "skills"))
    open_command.add_argument("--app-server-url")
    open_command.add_argument("--print-url", action="store_true", help="Return the native app link without launching it")

    state = commands.add_parser("state", help="Read state from a native PR Review receiver")
    state.add_argument("--client")
    state.add_argument("--wait", type=float, default=30)
    state.add_argument("--request-id")
    return command_parser


def _quote(value):
    return urllib.parse.quote(str(value), safe="")


def _request_id(args):
    return getattr(args, "request_id", None) or str(uuid.uuid4())


def _review_path(args):
    if not args.id:
        raise CLIError("Specify a review ID or set HERDR_PR_REVIEW_ID", "missing_review_id")
    return "/" + _quote(args.id)


def _download_document(client, path, output):
    destination = Path(output).expanduser()
    if destination.exists():
        raise CLIError("Output file already exists", "output_exists")
    request = urllib.request.Request(
        client.base_url + client.api_path + path,
        method="GET",
        headers={
            "Authorization": "Bearer " + client.token,
            "Accept": "application/octet-stream",
            "User-Agent": "herdr-pr-review/1",
        },
    )
    try:
        with client.opener(request, timeout=20) as response:
            if response.geturl() != request.full_url:
                raise CLIError("Herdr redirects are not allowed", "redirect_not_allowed")
            content_length = response.headers.get("Content-Length") if hasattr(response, "headers") else None
            if content_length is not None:
                try:
                    if not 0 <= int(content_length) <= MAX_DOCUMENT_BYTES:
                        raise CLIError("Herdr response is too large", "response_too_large")
                except ValueError as exc:
                    raise CLIError("Herdr response has an invalid length", "invalid_response") from exc
            destination.parent.mkdir(parents=True, exist_ok=True)
            total = 0
            with destination.open("xb") as stream:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > MAX_DOCUMENT_BYTES:
                        raise CLIError("Herdr response is too large", "response_too_large")
                    stream.write(chunk)
    except CLIError:
        if destination.exists():
            destination.unlink()
        raise
    except OSError as exc:
        raise CLIError("Could not download the selected document", "herdr_unavailable") from exc
    return {"ok": True, "path": str(output), "bytes": total}


def _select_ui_client(client, explicit, environ):
    response = client.request("GET", "/clients")
    clients = response.get("clients")
    if not isinstance(clients, list) or any(not isinstance(item, dict) for item in clients):
        raise CLIError("UI client response is invalid", "invalid_response")
    live = [item for item in clients if item.get("online") is True and isinstance(item.get("clientId"), str)]
    selected_id = explicit or environ.get("HERDR_UI_CLIENT_ID")
    if selected_id:
        matches = [item for item in live if item.get("clientId") == selected_id]
        if len(matches) != 1:
            raise CLIError("Select a UI client explicitly with --client", "ambiguous_ui_client")
        return selected_id, matches[0]
    if len(live) == 1:
        return live[0]["clientId"], live[0]
    raise CLIError("Select a UI client explicitly with --client", "ambiguous_ui_client")


def _state(args, client, environ):
    ui_client = UIControlClient(client.base_url, client.token, opener=client.opener)
    client_id, selected = _select_ui_client(ui_client, args.client, environ)
    actions = selected.get("actions")
    if not isinstance(actions, list):
        raise CLIError("UI client action registry is invalid", "invalid_response")
    descriptors = [item for item in actions if isinstance(item, dict) and item.get("id") == "pr-review.state"]
    descriptor = descriptors[0] if len(descriptors) == 1 else None
    if not descriptor or descriptor.get("enabled") is not True:
        reason = descriptor.get("disabledReason") if descriptor else None
        raise CLIError(reason or "Action unavailable", "action_disabled")
    request_id = args.request_id or str(uuid.uuid4())
    created = ui_client.request("POST", f"/clients/{_quote(client_id)}/commands", {
        "requestId": request_id,
        "action": "pr-review.state",
        "parameters": {},
        "ttlSeconds": 30,
    })
    command = created.get("command")
    command_id = command.get("id") if isinstance(command, dict) else None
    command_id = command_id or request_id
    deadline = time.monotonic() + max(0, args.wait)
    while True:
        response = ui_client.request("GET", "/commands/" + _quote(command_id))
        command = response.get("command")
        if not isinstance(command, dict):
            raise CLIError("UI command response is invalid", "invalid_response")
        status = command.get("status")
        if status in {"completed", "failed", "expired", "outcome_unknown"}:
            if status == "failed":
                error = command.get("error") if isinstance(command.get("error"), dict) else {}
                raise CLIError(error.get("message") or "UI action failed", error.get("code") or "ui_action_failed")
            return {"ok": True, "requestId": request_id, "status": status, "state": command.get("result"), "error": command.get("error")}
        if time.monotonic() >= deadline:
            return {"ok": True, "requestId": request_id, "status": status or "pending", "state": command.get("result"), "error": command.get("error")}
        time.sleep(0.25)


def execute(args, client, *, stdin, launch, environ):
    if args.command in ("capabilities", "skills"):
        return client.request("GET", "/" + args.command)
    if args.command == "list":
        scope = "all" if args.all else "archived" if args.archived else "active"
        return client.request("GET", "?" + urllib.parse.urlencode({"scope": scope}))
    if args.command == "add-skill":
        return client.request("POST", "/skills", {
            "id": args.id,
            "title": args.title,
            "kind": args.kind or "custom",
            "prompt_template": args.prompt,
            "command_template": args.command,
            "outputs": args.outputs or [],
            "description": args.description or "",
            "request_id": _request_id(args),
        })
    if args.command == "remove-skill":
        return client.request("DELETE", "/skills/" + _quote(args.id), {"request_id": _request_id(args)})
    if args.command == "create":
        return client.request("POST", "", {"url": args.url, "skill_ids": args.skill, "request_id": _request_id(args)})

    path = _review_path(args) if hasattr(args, "id") else ""
    if args.command in ("get", "files", "runs", "documents"):
        return client.request("GET", path)
    if args.command in ("archive", "unarchive", "refresh", "rank"):
        return client.request("POST", path + "/" + args.command, {"request_id": _request_id(args)})
    if args.command == "sync-viewed":
        return client.request("POST", path + "/viewed/sync", {"request_id": _request_id(args)})
    if args.command in ("diff", "commits"):
        query = {name: getattr(args, name, None) for name in ("path", "mode", "start_commit", "end_commit", "base_sha", "head_sha") if getattr(args, name, None) is not None}
        suffix = "?" + urllib.parse.urlencode(query) if query else ""
        return client.request("GET", path + "/" + args.command + suffix)
    if args.command == "file":
        query = {name: getattr(args, name) for name in ("path", "side", "start", "end", "mode", "start_commit", "end_commit", "base_sha", "head_sha") if getattr(args, name) is not None}
        return client.request("GET", path + "/file?" + urllib.parse.urlencode(query))
    if args.command == "comments":
        if args.thread:
            if args.path or args.state != "all":
                raise CLIError("Thread lookup cannot use list filters", "invalid_arguments")
            return client.request("GET", path + "/comments/" + _quote(args.thread))
        query = {"state": args.state, **({"path": args.path} if args.path else {})}
        return client.request("GET", path + "/comments?" + urllib.parse.urlencode(query))
    if args.command in ("comment", "reply", "resolve", "reopen", "edit-comment"):
        body = {"author": args.author, "request_id": _request_id(args)}
        if args.command in ("comment", "reply", "edit-comment"):
            body["body"] = _read_file(args.body_file, stdin) if args.body_file else args.body
            if not body["body"].strip() or len(body["body"]) > 20_000 or "\x00" in body["body"]:
                raise CLIError("Comment body must contain 1 to 20000 characters", "invalid_arguments")
        if args.command == "comment":
            anchor_fields = ("path", "side", "start", "end", "base_sha", "head_sha", "mode", "start_commit", "end_commit")
            if any(getattr(args, name) is not None for name in anchor_fields):
                if any(getattr(args, name) is None for name in ("path", "side", "start", "base_sha", "head_sha")):
                    raise CLIError("Inline comments require --path, --side, --start, --base-sha and --head-sha from the reviewed diff", "invalid_arguments")
                body["anchor"] = {"path": args.path, "side": args.side, "start_line": args.start,
                    "end_line": args.end if args.end is not None else args.start, "base_sha": args.base_sha, "head_sha": args.head_sha}
                selection = {name: getattr(args, name) for name in ("mode", "start_commit", "end_commit") if getattr(args, name) is not None}
                if selection:
                    body["anchor"]["comparison"] = selection
            return client.request("POST", path + "/comments", body)
        thread_path = path + "/comments/" + _quote(args.thread)
        if args.command == "reply":
            return client.request("POST", thread_path + "/replies", body)
        if args.expected_version < 1:
            raise CLIError("--expected-version must be a positive integer from the thread", "invalid_arguments")
        body["expected_version"] = args.expected_version
        if args.command == "edit-comment":
            return client.request("PUT", thread_path + "/messages/" + _quote(args.message), body)
        body["state"] = "resolved" if args.command == "resolve" else "open"
        return client.request("POST", thread_path + "/state", body)
    if args.command == "findings":
        return client.request("GET", path + "/findings?" + urllib.parse.urlencode({"path": args.path}))
    if args.command == "run":
        return client.request("POST", path + "/runs", {"skill_id": args.skill, "request_id": _request_id(args)})
    if args.command == "finish-run":
        if not args.run_id:
            raise CLIError("Specify a run ID or set HERDR_PR_REVIEW_RUN_ID", "missing_run_id")
        return client.request("POST", path + "/runs/" + _quote(args.run_id) + "/finish", {"state": args.state, "note": args.note or "", "request_id": _request_id(args)})
    if args.command == "run-output":
        if not args.run_id:
            raise CLIError("Specify a run ID or set HERDR_PR_REVIEW_RUN_ID", "missing_run_id")
        return client.request("GET", path + "/runs/" + _quote(args.run_id) + "/output?" + urllib.parse.urlencode({"lines": args.lines}))
    if args.command == "mark":
        state = "not_run" if args.state == "not-run" else args.state
        body = {"state": state, "note": args.note or "", "request_id": _request_id(args)}
        return client.request("POST", path + "/skills/" + _quote(args.skill) + "/mark", body)
    if args.command == "set-rankings":
        return client.request("PUT", path + "/rankings", {"files": json.loads(_read_file(args.file, stdin)), "request_id": _request_id(args)})
    if args.command == "viewed":
        return client.request("POST", path + "/viewed", {"paths": args.path, "viewed": not args.unviewed, "sync_github": not args.no_github, "request_id": _request_id(args)})
    if args.command == "add-document":
        body = {"title": args.title or "", "request_id": _request_id(args)}
        if args.link:
            body["url"] = args.link
            body["title"] = args.title or args.link
        elif args.file:
            body["path"] = str(Path(args.file).expanduser().absolute())
        else:
            raw = Path(args.upload).read_bytes()
            if len(raw) > 20 * 1024 * 1024:
                raise CLIError("File exceeds 20 MB limit", "input_too_large")
            media_type = mimetypes.guess_type(args.upload)[0] or "application/octet-stream"
            body.update({"filename": Path(args.upload).name, "content_type": media_type, "data_base64": base64.b64encode(raw).decode()})
        return client.request("POST", path + "/documents", body)
    if args.command == "document":
        return _download_document(client, path + "/documents/" + _quote(args.doc_id) + "/content", args.out)
    if args.command == "events":
        return client.request("GET", path + "/events?" + urllib.parse.urlencode({"after": args.after}))
    if args.command == "open":
        client.request("GET", path)
        query = {"review_id": args.id, "server_url": PRReviewClient(args.app_server_url, "route-validation").base_url if args.app_server_url else client.base_url}
        for name in ("file", "line", "side", "tab"):
            value = getattr(args, name)
            if value is not None:
                query[name] = str(value)
        url = "herdr://pr-review?" + urllib.parse.urlencode(query)
        if not args.print_url:
            launch(["/usr/bin/open", url], check=True)
        return {"ok": True, "url": url, "launch_requested": not args.print_url}
    if args.command == "state":
        return _state(args, client, environ)
    raise CLIError("Unsupported command", "invalid_arguments")


def main(argv=None, *, environ=None, stdin=None, stdout=None, stderr=None, opener=None, launch=subprocess.run):
    environ = dict(os.environ if environ is None else environ)
    stdin, stdout, stderr = stdin or sys.stdin, stdout or sys.stdout, stderr or sys.stderr
    token = ""
    try:
        args = parser(environ).parse_args(argv)
        token_file = args.token_file or environ.get("HERDR_HARNESS_API_TOKEN_FILE")
        token = load_private_bearer_token_file(str(Path(token_file).expanduser().absolute()), field="Herdr API token") if token_file else validate_bearer_token(environ.get("HERDR_HARNESS_API_TOKEN", ""), field="Herdr API token", required=True)
        result = execute(args, PRReviewClient(args.base_url, token, opener=opener), stdin=stdin, launch=launch, environ=environ)
        print(json.dumps(result, ensure_ascii=False).replace(token, "[redacted]"), file=stdout)
        return 0
    except (CLIError, SecretFileError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        message = str(exc) if isinstance(exc, (CLIError, SecretFileError)) else "Invalid input or unavailable resource"
        payload = {"ok": False, "error": {"code": getattr(exc, "code", "invalid_input"), "message": message}}
        if getattr(exc, "status", None):
            payload["error"]["httpStatus"] = exc.status
        encoded = json.dumps(payload)
        print(encoded.replace(token, "[redacted]") if token else encoded, file=stderr)
        return 4 if getattr(exc, "status", None) == 409 else 2


if __name__ == "__main__":
    raise SystemExit(main())
