"""Agent-facing profile reads and proposed (never silently applied) edits."""
from __future__ import annotations

import argparse
import io
import json
import os
import sys
import time
from pathlib import Path

from .agent_profiles import identifier, text
from .config import load_configuration
from .connection_info import connection_environment
from .control_cli import CLIError, ControlCLI, ControlClient
from .secret_file import load_private_bearer_token_file


def main(argv=None, *, environ=None, stdout=None, stderr=None):
    env = dict(os.environ if environ is None else environ)
    stdout, stderr = stdout or sys.stdout, stderr or sys.stderr
    parser = argparse.ArgumentParser(description="Read Herdr profiles or propose a scoped edit for Settings/Fleet approval. Never grants mutation authority. No automatic retries.")
    parser.add_argument("--config")
    parser.add_argument("--machine", help="Exact data machine; defaults to this terminal's companion")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    commands.add_parser("effective")
    commands.add_parser("get").add_argument("id")
    propose = commands.add_parser("propose")
    propose.add_argument("id")
    propose.add_argument("--expected-revision", required=True, type=int)
    propose.add_argument("--soul-file", required=True)
    propose.add_argument("--user-file", required=True)
    propose.add_argument("--reason", required=True)
    propose.add_argument("--request-id", required=True, help="Stable UUID; retry only the same payload and ID after an uncertain result")
    token = ""
    try:
        args = parser.parse_args(argv)
        if args.machine:
            cli = ControlCLI(args, environ=env, stdin=io.StringIO(), opener=None, clock=time.time, sleep=time.sleep)
            client = cli.client(args.machine)
        else:
            configured = load_configuration(args.config, environ=connection_environment(env)).environ
            token = configured.get("HERDR_HARNESS_API_TOKEN", "")
            if configured.get("HERDR_HARNESS_API_TOKEN_FILE"):
                token = load_private_bearer_token_file(str(Path(configured["HERDR_HARNESS_API_TOKEN_FILE"]).expanduser().absolute()), field="Herdr API token")
            client = ControlClient(configured.get("HERDR_HARNESS_URL") or configured.get("HERDR_HARNESS_BASE_URL") or "http://127.0.0.1:9092", token)
        token = client.token
        path = "/api/v1/agent-profiles"
        if args.command == "get":
            result = client.request("GET", path + "/profiles/" + identifier(args.id))
        elif args.command == "propose":
            if env.get("HERDR_AGENT_RUN_MODE", "").lower() == "ask" or env.get("HERDR_FIRST_MATE_MANAGED_ROLE"):
                raise CLIError("This restricted or managed process cannot mutate profile state; ask the operator to submit the proposal", "profile_read_only")
            def document(filename):
                with Path(filename).expanduser().open(encoding="utf-8") as stream:
                    return text(stream.read(16385), "document")
            body = {"action": "propose", "requestId": identifier(args.request_id), "profileId": identifier(args.id),
                    "expectedRevision": args.expected_revision, "soul": document(args.soul_file),
                    "user": document(args.user_file), "reason": args.reason}
            result = client.request("POST", path, body, has_payload=True)
        else:
            result = client.request("GET", path)
            if args.command == "effective":
                result = {"ok": True, "machineId": result["machineId"], "effective": result["effective"]}
            else:
                result = {"ok": True, "machineId": result["machineId"], "binding": result["binding"],
                          "profiles": [{key: p[key] for key in ("id", "name", "revision")} for p in result["profiles"]]}
        print(json.dumps(result, ensure_ascii=False).replace(token, "[redacted]") if token else json.dumps(result), file=stdout)
        return 0
    except (ValueError, OSError, KeyError, CLIError) as exc:
        error = {"ok": False, "error": {"code": getattr(exc, "code", "profile_cli_error"),
                 "message": "Profile command failed; check the selected machine, input files, and expected revision"}}
        print(json.dumps(error), file=stderr)
        return 4 if getattr(exc, "status", None) == 409 else 2


if __name__ == "__main__":
    raise SystemExit(main())
