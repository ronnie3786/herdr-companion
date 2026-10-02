"""Watchers HTTP contract. Disabled discovery never constructs a store."""
from __future__ import annotations

import copy
import os
import re
from datetime import datetime, timezone
from pathlib import Path

from .errors import WatchersError
from .schedule import machine_timezone, preview
from .imports import bundle_entry, cronboard_entries
from .assets import asset_catalog
from .settings import CHANGED_VIA_LIMIT

EVENTS = ["watchers.updated", "watchers.run", "watchers.inbox", "watchers.builder"]


def capabilities(service):
    settings = service.watchers_settings()
    enabled = settings["enabled"]
    scheduler = service.watchers_scheduler_status()
    environment = service.environ
    supervised = environment.get("HERDR_WATCHERS_SUPERVISED") == "1" or bool(environment.get("INVOCATION_ID")) or environment.get("XPC_SERVICE_NAME", "0") not in {"", "0"}
    return {"ok": True, "enabled": enabled, "capabilities": ["watchers-v1"] if enabled else [],
            "settings": settings,
            "machine": service.watchers_machine, "timezone": machine_timezone(environment),
            "steps": ["script", "gate", "deliver"], "delivery": {"inbox": True, "slack": False, "notify": False},
            "limits": {"script_bytes": 262144, "timeout_seconds": 21600},
            "scheduler": scheduler, "supervised": supervised,
            "assets": asset_catalog(),
            "summary_tokens": ["time", "gh", "script", "agent", "skill", "slack", "inbox", "repo", "pc"]}


def change_settings(service, body):
    """POST /settings: the person's on/off choice for this companion.

    Like activation, confirmed_by:"user" is a convention and audit trail; agents
    hold the same main token.
    """
    keys(body, {"request_id", "enabled", "confirmed_by", "changed_via"}, {"request_id", "enabled", "confirmed_by"})
    if not isinstance(body["enabled"], bool):
        raise WatchersError("invalid_request", "enabled must be a boolean.")
    if body["confirmed_by"] != "user":
        raise WatchersError("invalid_request", "confirmed_by must be user: turning Watchers on or off is the person's step.")
    changed_via = body.get("changed_via", "api")
    if not isinstance(changed_via, str) or not 1 <= len(changed_via) <= CHANGED_VIA_LIMIT or not changed_via.isprintable():
        raise WatchersError("invalid_request", f"changed_via must be a nonempty string of at most {CHANGED_VIA_LIMIT} characters.")
    service.set_watchers_enabled(body["enabled"], changed_via=changed_via)
    return capabilities(service)


def keys(body, allowed, required=()):
    if not isinstance(body, dict) or set(body) - set(allowed) or set(required) - set(body):
        raise WatchersError("invalid_request", "Request contains unsupported or missing fields.")
    if "request_id" in required:
        value = body.get("request_id")
        if not isinstance(value, str) or not 1 <= len(value) <= 200:
            raise WatchersError("invalid_request", "request_id must be a nonempty string of at most 200 characters.")


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", value):
        raise WatchersError("invalid_identifier", "Invalid Watchers identifier.")
    return value


def definition_body(body, *, revision=False):
    if not isinstance(body.get("definition"), dict):
        raise WatchersError("invalid_request", "definition must be an object.")
    if "scripts" in body and not isinstance(body["scripts"], dict):
        raise WatchersError("invalid_request", "scripts must be an object keyed by script step ID.")
    if revision:
        expected_revision(body)


def expected_revision(body):
    value = body.get("expected_revision")
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise WatchersError("invalid_request", "expected_revision must be a positive integer.")


def integer(value, default=100, maximum=200):
    if isinstance(value, bool) or isinstance(value, float):
        raise WatchersError("invalid_request", "Expected a bounded integer.")
    try:
        result = int(value) if value is not None else default
    except (ValueError, TypeError):
        raise WatchersError("invalid_request", "Expected a bounded integer.")
    if not 1 <= result <= maximum:
        raise WatchersError("invalid_request", "Integer is outside the supported range.")
    return result


def route(service, method, tail, query, body):
    q = lambda name, default=None: (query.get(name) or [default])[0]
    if method == "GET" and tail == ["capabilities"]:
        return capabilities(service)
    if tail == ["settings"]:
        # Reachable while Watchers is off, so a person can turn it on.
        if method != "POST":
            raise WatchersError("method_not_allowed", "Use POST to change the Watchers setting.", 405)
        return change_settings(service, body)
    runtime = service.watchers
    store = runtime.store
    if tail == ["schedule", "preview"] and method == "POST":
        keys(body, {"schedule", "timezone", "count"}, {"schedule", "timezone"})
        return {"ok": True, **preview(body["schedule"], body["timezone"], count=integer(body.get("count"), 5, 20))}
    if tail[:2] == ["builder", "sessions"]:
        return service.watchers_builder.route(method, tail[2:], body)
    if tail == ["import"] and method == "POST":
        keys(body, {"request_id", "source", "jobs", "bundle", "dry_run", "confirmed_by", "timezone"}, {"request_id", "source"})
        if "dry_run" in body and not isinstance(body["dry_run"], bool):
            raise WatchersError("invalid_request", "dry_run must be a boolean.")
        if "confirmed_by" in body and body["confirmed_by"] != "user":
            raise WatchersError("invalid_request", "confirmed_by must be user when provided.")
        if body["source"] == "cronboard":
            entries, previews, commands = cronboard_entries(body.get("jobs"), confirmed=body.get("confirmed_by") == "user", environ=service.environ)
        elif body["source"] == "bundle":
            entries, previews, commands = [bundle_entry(body.get("bundle"), creator_timezone=body.get("timezone"))], [], {}
        else:
            raise WatchersError("invalid_import", "Supported import sources are cronboard and bundle.")
        if body.get("dry_run"):
            return {"ok": True, "dry_run": True, "previews": previews, "commands": commands, "executed": False}
        if any(not row["interpreter_present"] for row in previews):
            raise WatchersError("interpreter_missing", "An imported interpreter is not installed on this machine.")
        watchers = store.batch_create(entries, request_id=body["request_id"])
        runtime.wake()
        return {"ok": True, "watchers": watchers, "previews": previews, "commands": commands}, 201
    if tail == ["actions"] and method == "POST":
        keys(body, {"request_id", "action", "source"}, {"request_id", "action", "source"})
        if body["action"] not in ("pause", "resume") or body["source"] != "cronboard":
            raise WatchersError("invalid_action", "Batch actions support pause or resume of Cronboard watchers.")
        result = store.transition_source("cronboard", "paused" if body["action"] == "pause" else "active", request_id=body["request_id"])
        runtime.wake()
        return {"ok": True, "watchers": result}
    if tail == ["runs"] and method == "GET":
        return {"ok": True, "runs": store.runs(source=q("source"), status=q("status"), limit=integer(q("limit")), before=q("before"))}
    if tail[:1] == ["runs"] and len(tail) >= 2:
        run_id = identifier(tail[1])
        if len(tail) == 2 and method == "GET":
            return {"ok": True, "run": store.get_run(run_id)}
        if tail[2:] == ["stop"] and method == "POST":
            keys(body, {"request_id"}, {"request_id"})
            return {"ok": True, "run": runtime.stop_run(run_id, request_id=body["request_id"])}
        if tail[2:] == ["logs"] and method == "GET":
            return {"ok": True, **store.logs(run_id, step_id=q("step"), stream=q("stream", "stdout"))}
    if tail == ["inbox"] and method == "GET":
        rows = store.inbox(source=q("source"), limit=integer(q("limit")), before=q("before"), unread=q("unread") == "1")
        return {"ok": True, "items": rows, "unread_count": store.unread_count(source=q("source"))}
    if tail == ["inbox", "read-all"] and method == "POST":
        keys(body, {"request_id"}, {"request_id"})
        store.mark_all_inbox_read(request_id=body["request_id"])
        runtime.wake()
        return {"ok": True}
    if len(tail) == 3 and tail[0] == "inbox" and tail[2] == "read" and method == "POST":
        keys(body, {"request_id"}, {"request_id"})
        result = store.mark_inbox_read(identifier(tail[1]), request_id=body["request_id"])
        runtime.wake()
        return {"ok": True, "item": result}
    if not tail:
        if method == "GET":
            return {"ok": True, "watchers": store.list(state=q("state"), source=q("source"))}
        if method == "POST":
            keys(body, {"request_id", "definition", "scripts"}, {"request_id", "definition"})
            definition_body(body)
            watcher = store.create(body["definition"], scripts=body.get("scripts"), request_id=body["request_id"])
            runtime.wake()
            return {"ok": True, "watcher": watcher}, 201
    if not tail:
        raise WatchersError("not_found", "Watchers endpoint not found.", 404)
    watcher_id, rest = identifier(tail[0]), tail[1:]
    if not rest:
        if method == "GET":
            return {"ok": True, "watcher": store.get(watcher_id)}
        if method == "PATCH":
            keys(body, {"request_id", "definition", "expected_revision", "scripts"}, {"request_id", "definition", "expected_revision"})
            definition_body(body, revision=True)
            result = store.patch(watcher_id, body["definition"], body["expected_revision"], request_id=body["request_id"], scripts=body.get("scripts"))
            runtime.wake()
            return {"ok": True, "watcher": result}
        if method == "DELETE":
            keys(body, {"request_id"}, {"request_id"})
            force = q("force") == "1"
            runtime.delete(watcher_id, force=force, request_id=body["request_id"])
            runtime.wake()
            return {"ok": True}
    if rest == ["export"] and method == "GET":
        return {"ok": True, "bundle": store.export(watcher_id)}
    if rest == ["runs"] and method == "GET":
        runs = store.runs(watcher_id=watcher_id, status=q("status"), limit=integer(q("limit")), before=q("before"))
        return {"ok": True, "runs": runs}
    if len(rest) == 2 and rest[0] == "scripts":
        step_id = identifier(rest[1])
        if method == "GET":
            script = store.get_script(watcher_id, step_id)
            return {"ok": True, "script": script, "content": script["content"]}
        if method == "PUT":
            keys(body, {"request_id", "expected_revision", "content"}, {"request_id", "expected_revision", "content"})
            expected_revision(body)
            if not isinstance(body["content"], str):
                raise WatchersError("invalid_request", "Script content must be a string.")
            watcher = store.set_script(watcher_id, step_id, body["content"], body["expected_revision"], request_id=body["request_id"])
            runtime.wake()
            return {"ok": True, "watcher": watcher}
    if rest == ["actions"] and method == "POST":
        keys(body, {"request_id", "action", "confirmed_by", "activated_via"}, {"request_id", "action"})
        action = body["action"]
        if action in ("activate", "pause", "resume"):
            if action == "activate" and body.get("confirmed_by") != "user":
                raise WatchersError("confirmation_required", "Create watcher requires the person's confirmation.", 409)
            if action in ("activate", "resume"):
                from .runtime import validate_executable
                validate_executable(store.get(watcher_id))
            if action == "activate" and store.get(watcher_id).get("edit_target_id"):
                watcher = store.apply_edit_draft(watcher_id, request_id=body["request_id"], confirmed_by=body.get("confirmed_by"), activated_via=body.get("activated_via") or "api")
            else:
                watcher = store.transition(watcher_id, "paused" if action == "pause" else "active", request_id=body["request_id"],
                                           confirmed_by=body.get("confirmed_by"), activated_via=body.get("activated_via") or "api")
            result = {"ok": True, "watcher": watcher}
        elif action in ("run_now", "dry_run"):
            result = {"ok": True, "run": runtime.run_now(watcher_id, dry_run=action == "dry_run", request_id=body["request_id"])}
        elif action == "duplicate":
            result = {"ok": True, "watcher": store.duplicate(watcher_id, request_id=body["request_id"])}
        else:
            raise WatchersError("invalid_action", "Unknown Watchers action.")
        runtime.wake()
        return result
    raise WatchersError("not_found", "Watchers endpoint not found.", 404)
