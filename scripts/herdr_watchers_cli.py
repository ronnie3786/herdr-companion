#!/usr/bin/env python3
"""Create reviewable Watcher drafts, inspect schedules and control scheduled work."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import time
import urllib.parse
import uuid
from datetime import datetime, timezone

try:
    from .herdr_notes_cli import CLIError, NotesClient, Parser as NotesParser, _read_file
except ImportError:
    from herdr_notes_cli import CLIError, NotesClient, Parser as NotesParser, _read_file
from herdr_harness.config import load_configuration
from herdr_harness.connection_info import connection_environment
from herdr_harness.control_cli import machine_client
from herdr_harness.secret_file import load_private_bearer_token_file
from herdr_harness.watchers.errors import WatchersError
from herdr_harness.watchers.schedule import machine_timezone
from herdr_harness.watchers.validation import schema, example, validate_definition


class Parser(NotesParser):
    def error(self, _message):
        raise CLIError("Invalid arguments; use herdr-watchers --help", "invalid_arguments")


class WatchersClient(NotesClient):
    api_path = "/api/v1/watchers"


def parser():
    p = Parser(prog="herdr-watchers", description=__doc__)
    commands = p.add_subparsers(dest="command", required=True)
    for name in ("capabilities", "machines", "schema", "example", "doctor"):
        commands.add_parser(name)
    validate = commands.add_parser("validate")
    validate.add_argument("--definition-file", required=True)
    listing = commands.add_parser("list")
    listing.add_argument("--state", choices=("draft", "active", "paused", "done"))
    listing.add_argument("--source", choices=("cronboard",))
    for name in ("get", "export", "run"):
        commands.add_parser(name).add_argument("id")
    draft = commands.add_parser("draft").add_subparsers(dest="draft_command", required=True)
    for name in ("create", "update"):
        sub = draft.add_parser(name)
        sub.add_argument("--definition-file", required=True)
        sub.add_argument("--scripts-file")
        if name == "update":
            sub.add_argument("id")
            sub.add_argument("--expected-revision", required=True, type=int)
    script = commands.add_parser("script").add_subparsers(dest="script_command", required=True)
    for name in ("put", "get"):
        sub = script.add_parser(name)
        sub.add_argument("id")
        sub.add_argument("--step", required=True)
        if name == "put":
            sub.add_argument("--file", default="-", help="Script body path, or - for stdin")
            sub.add_argument("--expected-revision", required=True, type=int)
    schedule = commands.add_parser("schedule").add_subparsers(dest="schedule_command", required=True).add_parser("preview")
    schedule.add_argument("schedule", help="Schedule JSON")
    schedule.add_argument("--timezone", default=None)
    schedule.add_argument("--count", type=int, default=5)
    for name in ("pause", "resume", "run-now", "dry-run", "activate", "duplicate", "delete", "stop"):
        sub = commands.add_parser(name, help="Person-only activation with --i-confirm" if name == "activate" else None)
        sub.add_argument("id", nargs="?" if name in {"pause", "resume"} else None)
        if name in {"pause", "resume"}:
            sub.add_argument("--source", choices=("cronboard",))
        if name in {"run-now", "dry-run"}:
            sub.add_argument("--wait", action="store_true")
            sub.add_argument("--wait-seconds", type=int, default=3600)
        if name == "activate":
            sub.add_argument("--i-confirm", action="store_true")
        if name == "delete":
            sub.add_argument("--force", action="store_true")
    runs = commands.add_parser("runs")
    runs.add_argument("id", nargs="?")
    runs.add_argument("--source", choices=("cronboard",))
    runs.add_argument("--status")
    runs.add_argument("--limit", type=int, default=100)
    logs = commands.add_parser("logs")
    logs.add_argument("id")
    logs.add_argument("--step")
    logs.add_argument("--stream", choices=("stdout", "stderr"), default="stdout")
    inbox = commands.add_parser("inbox")
    inbox.add_argument("--source", choices=("cronboard",))
    inbox.add_argument("--unread", action="store_true")
    commands.add_parser("read").add_argument("id")
    commands.add_parser("read-all")
    importing = commands.add_parser("import")
    sources = importing.add_mutually_exclusive_group(required=True)
    sources.add_argument("--bundle")
    sources.add_argument("--cronboard-json")
    importing.add_argument("--dry-run", action="store_true", help="Preview only; executes nothing")
    importing.add_argument("--i-confirm", action="store_true", help="Import previously enabled jobs resting, with an activation audit record")
    return p


def query(**values):
    result = urllib.parse.urlencode({k: v for k, v in values.items() if v is not None})
    return "?" + result if result else ""


def quote(value):
    return urllib.parse.quote(value, safe="")


def execute(args, client, *, stdin, request_id, creator_timezone):
    command = args.command
    caps = client.request("GET", "/capabilities")
    if command == "capabilities":
        return caps
    if command == "doctor":
        issues = []
        if not caps.get("enabled"):
            issues.append("Enable HERDR_WATCHERS_ENABLED=1 on the selected companion.")
        if not caps.get("supervised"):
            issues.append("Install the companion as a KeepAlive launchd or restart-enabled systemd service; verify it, then set HERDR_WATCHERS_SUPERVISED=1 if supervision is not auto-detected.")
        scheduler = caps.get("scheduler", {})
        try:
            age = (datetime.now(timezone.utc) - datetime.fromisoformat(scheduler["last_tick_at"].replace("Z", "+00:00"))).total_seconds()
        except (KeyError, ValueError, TypeError):
            age = float("inf")
        if not scheduler.get("running") or age > 90 or age < -5:
            issues.append("The scheduler tick is stale or stopped. Restart the supervised companion and check its logs.")
        if issues:
            raise CLIError(" ".join(issues), "watchers_unhealthy")
        return {"ok": True, "summary": "On watch. The scheduler is healthy and supervised.", **caps}
    if not caps.get("enabled") or "watchers-v1" not in caps.get("capabilities", []):
        raise CLIError("Enable HERDR_WATCHERS_ENABLED=1 on an updated companion.", "watchers_disabled", 503)
    if command == "list":
        return client.request("GET", query(state=args.state, source=args.source))
    if command in {"get", "export"}:
        return client.request("GET", "/" + quote(args.id) + ("/export" if command == "export" else ""))
    if command == "draft":
        definition = json.loads(_read_file(args.definition_file, stdin))
        if not isinstance(definition, dict):
            raise CLIError("The definition file must contain a JSON object.", "invalid_definition")
        body = {"request_id": request_id, "definition": definition}
        if args.scripts_file:
            body["scripts"] = json.loads(_read_file(args.scripts_file, stdin))
        if args.draft_command == "create":
            definition.setdefault("timezone", creator_timezone)
            return client.request("POST", "", body)
        body["expected_revision"] = args.expected_revision
        return client.request("PATCH", "/" + quote(args.id), body)
    if command == "script":
        path = "/" + quote(args.id) + "/scripts/" + quote(args.step)
        if args.script_command == "get":
            return client.request("GET", path)
        return client.request("PUT", path, {"request_id": request_id, "expected_revision": args.expected_revision, "content": _read_file(args.file, stdin)})
    if command == "schedule":
        return client.request("POST", "/schedule/preview", {"schedule": json.loads(args.schedule), "timezone": args.timezone or creator_timezone, "count": args.count})
    if command == "import":
        source = "bundle" if args.bundle else "cronboard"
        payload = json.loads(_read_file(args.bundle or args.cronboard_json, stdin))
        if source == "bundle" and isinstance(payload, dict) and "bundle" in payload:
            payload = payload["bundle"]
        body = {"request_id": request_id, "source": source, "bundle" if source == "bundle" else "jobs": payload, "dry_run": args.dry_run, "timezone": creator_timezone}
        if args.i_confirm:
            body["confirmed_by"] = "user"
        return client.request("POST", "/import", body)
    if command in {"pause", "resume"} and args.source:
        if args.id:
            raise CLIError("Choose an ID or --source, not both.", "invalid_arguments")
        return client.request("POST", "/actions", {"request_id": request_id, "action": command, "source": args.source})
    if command in {"pause", "resume", "activate", "run-now", "dry-run", "duplicate"}:
        if not args.id:
            raise CLIError("Specify an ID or --source cronboard.", "invalid_arguments")
        body = {"request_id": request_id, "action": command.replace("-", "_")}
        if command == "activate":
            if not args.i_confirm:
                raise CLIError("A person must review the watcher and pass --i-confirm.", "confirmation_required")
            body.update(confirmed_by="user", activated_via="cli")
        result = client.request("POST", "/" + quote(args.id) + "/actions", body)
        if getattr(args, "wait", False):
            deadline = time.monotonic() + max(1, min(21660, args.wait_seconds))
            while result["run"]["status"] in {"queued", "running"} and time.monotonic() < deadline:
                time.sleep(1)
                result = client.request("GET", "/runs/" + quote(result["run"]["id"]))
            if result["run"]["status"] in {"queued", "running"}:
                raise CLIError("The run is still working. Use run RUN_ID to inspect it.", "wait_timeout")
        return result
    if command == "delete":
        return client.request("DELETE", "/" + quote(args.id) + ("?force=1" if args.force else ""), {"request_id": request_id})
    if command == "stop":
        return client.request("POST", "/runs/" + quote(args.id) + "/stop", {"request_id": request_id})
    if command == "runs":
        return client.request("GET", ("/" + quote(args.id) if args.id else "") + "/runs" + query(source=args.source, status=args.status, limit=args.limit))
    if command == "run":
        return client.request("GET", "/runs/" + quote(args.id))
    if command == "logs":
        return client.request("GET", "/runs/" + quote(args.id) + "/logs" + query(step=args.step, stream=args.stream))
    if command == "inbox":
        return client.request("GET", "/inbox" + query(source=args.source, unread="1" if args.unread else None))
    if command in {"read", "read-all"}:
        return client.request("POST", "/inbox/" + (quote(args.id) + "/read" if command == "read" else "read-all"), {"request_id": request_id})
    raise CLIError("Unknown command", "invalid_arguments")


def main(argv=None, *, environ=None, stdin=None, stdout=None, stderr=None, opener=None):
    environment = dict(os.environ if environ is None else environ)
    stdin, stdout, stderr = stdin or sys.stdin, stdout or sys.stdout, stderr or sys.stderr
    secrets = []
    try:
        common = Parser(add_help=False)
        common.add_argument("--config")
        common.add_argument("--machine")
        common.add_argument("--base-url")
        common.add_argument("--token-file")
        common.add_argument("--request-id", default=str(uuid.uuid4()))
        selected, remaining = common.parse_known_args(argv)
        args = parser().parse_args(remaining)
        creator_timezone = machine_timezone(environment)
        if args.command == "schema":
            result = {"ok": True, "schema": schema()}
        elif args.command == "example":
            result = {"ok": True, **example(timezone=creator_timezone)}
        elif args.command == "validate":
            result = {"ok": True, "definition": validate_definition(json.loads(_read_file(args.definition_file, stdin)), timezone=creator_timezone)}
        else:
            baseline = environment if selected.config or selected.machine else connection_environment(environment)
            configuration = load_configuration(selected.config, environ=baseline)
            roster = {item["id"]: item for item in configuration.public_machines()}
            def client_for(machine=None):
                if machine:
                    if machine not in roster:
                        raise CLIError("Selected machine is not in the configured roster.", "unknown_machine")
                    remote = machine_client(selected.config, machine, environment, roster=roster, opener=opener)
                    client = WatchersClient(remote.base_url, remote.token, opener=opener)
                else:
                    resolved = configuration.environ
                    token_file = selected.token_file or resolved.get("HERDR_HARNESS_API_TOKEN_FILE")
                    token = load_private_bearer_token_file(str(Path(token_file).expanduser().absolute()), field="Herdr API token") if token_file else resolved.get("HERDR_HARNESS_API_TOKEN", "")
                    client = WatchersClient(selected.base_url or resolved.get("HERDR_HARNESS_URL") or "http://127.0.0.1:9092", token, opener=opener)
                secrets.append(client.token)
                return client
            if args.command == "machines":
                rows = []
                for machine_id, machine in roster.items():
                    if selected.machine and machine_id != selected.machine:
                        continue
                    try:
                        caps = client_for(machine_id).request("GET", "/capabilities")
                        rows.append({"id": machine_id, "name": machine.get("name", machine_id), "reachable": True, **{k: caps.get(k) for k in ("enabled", "capabilities", "timezone", "supervised", "steps")}})
                    except ValueError as exc:
                        rows.append({"id": machine_id, "name": machine.get("name", machine_id), "reachable": False, "error": getattr(exc, "code", "machine_unreachable")})
                result = {"ok": True, "machines": rows}
            else:
                result = execute(args, client_for(selected.machine), stdin=stdin, request_id=selected.request_id, creator_timezone=creator_timezone)
        print(json.dumps(result, ensure_ascii=False), file=stdout)
        return 0
    except (ValueError, OSError, WatchersError) as exc:
        message = str(exc)
        for secret in secrets:
            if secret:
                message = message.replace(secret, "[redacted]")
        code = getattr(exc, "code", "invalid_request")
        if code == "herdr_unavailable":
            code = "machine_unreachable"
        print(json.dumps({"ok": False, "error": {"code": code, "message": message}}), file=stderr)
        return 4 if getattr(exc, "status", None) == 409 else 2


if __name__ == "__main__":
    raise SystemExit(main())
