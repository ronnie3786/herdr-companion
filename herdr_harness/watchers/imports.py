"""Non-executing, atomic import preparation for portable bundles and Cronboard."""
from __future__ import annotations

import copy
import hashlib
import os
import shlex
import shutil
from datetime import datetime, timezone

from .errors import WatchersError
from .schedule import preview, machine_timezone
from .validation import validate_definition, validate_script_body
from .assets import INSTRUMENTS


def cronboard_entries(payload, *, confirmed=False, now=None, environ=None):
    if isinstance(payload, dict):
        if "ok" in payload and payload["ok"] is not True:
            raise WatchersError("invalid_import", "Cronboard export did not report success.")
        if "data" in payload:
            if payload.get("ok") is not True or not isinstance(payload["data"], dict):
                raise WatchersError("invalid_import", "Cronboard export requires a successful data object.")
            payload = payload["data"]
        if payload.get("externalJobs"):
            raise WatchersError("invalid_import", "External crontab entries need separate review and cannot be imported automatically.")
        jobs = payload.get("jobs")
    else:
        jobs = payload
    if not isinstance(jobs, list) or not jobs or len(jobs) > 200:
        raise WatchersError("invalid_import", "Cronboard import requires 1 to 200 jobs.")
    entries, previews, seen = [], [], set()
    for job in jobs:
        if not isinstance(job, dict):
            raise WatchersError("invalid_import", "Every Cronboard job must be an object.")
        job_id = job.get("id")
        if not isinstance(job_id, str) or not job_id or job_id in seen:
            raise WatchersError("invalid_import", "Cronboard job IDs must be present and unique.")
        seen.add(job_id)
        interpreter_name = job.get("interpreter")
        if not isinstance(interpreter_name, str):
            raise WatchersError("invalid_import", "Cronboard interpreter must be a name.")
        interpreter = {"bash": "/bin/bash", "python": "/usr/bin/python3", "python3": "/usr/bin/python3", "zsh": "/bin/zsh"}.get(interpreter_name)
        if interpreter is None:
            raise WatchersError("invalid_import", "Cronboard interpreter is unsupported.")
        command = job.get("command")
        validate_script_body(command)
        if not isinstance(job.get("enabled"), bool):
            raise WatchersError("invalid_import", "Each Cronboard job requires an enabled boolean.")
        timezone_name = job.get("scheduleTimeZone") or job.get("timezone") or machine_timezone(environ)
        filename = "cronboard-" + hashlib.sha256(job_id.encode()).hexdigest()[:12] + (".py" if "python" in interpreter else ".sh")
        definition = validate_definition({
            "name": job.get("name"), "timezone": timezone_name,
            "avatar": INSTRUMENTS[int(hashlib.sha256(job_id.encode()).hexdigest()[:8], 16) % len(INSTRUMENTS)],
            "schedule": {"kind": "cron", "expression": job.get("schedule")},
            "summary": "{time}, I run {script:" + filename + "}.",
            "steps": [{"id": "script", "kind": "script", "title": "Run the imported script", "file": filename,
                       "interpreter": interpreter, "timeout_seconds": 3600, "icon": "terminal"}],
            "source": {"kind": "cronboard", "job_id": job_id}, "created_by": "user:cronboard-import",
        })
        entry = {"definition": definition, "scripts": {"script": command},
                 "state": "paused" if confirmed and job["enabled"] else "draft"}
        if entry["state"] == "paused":
            definition.update(activated_by="user", activated_via="cronboard-import")
        entries.append(entry)
        dates = preview(definition["schedule"], timezone_name, count=3, after=now)
        cronboard_next = job.get("nextRun") or job.get("nextRunAt") or job.get("next_run")
        parity = None
        if cronboard_next and dates["next"]:
            try:
                parity = datetime.fromisoformat(cronboard_next.replace("Z", "+00:00")) == datetime.fromisoformat(dates["next"][0].replace("Z", "+00:00"))
            except (ValueError, TypeError, AttributeError):
                pass
        previews.append({"job_id": job_id, "name": definition["name"], "state": entry["state"],
                         "schedule": definition["schedule"], "timezone": timezone_name,
                         "interpreter": interpreter, "interpreter_present": bool(shutil.which(interpreter)),
                         "next": dates["next"], "cronboard_next": cronboard_next, "parity": parity})
    commands = {
        "disable": ["cronboard disable " + shlex.quote(job["id"]) for job in jobs if job["enabled"]],
        "rollback_enable": ["cronboard enable " + shlex.quote(job["id"]) for job in jobs if job["enabled"]],
        "resume": "herdr-watchers resume --source cronboard",
        "rollback_pause": "herdr-watchers pause --source cronboard",
    }
    return entries, previews, commands


def bundle_entry(bundle, *, creator_timezone=None):
    if not isinstance(bundle, dict) or not isinstance(bundle.get("definition"), dict) or not isinstance(bundle.get("scripts", {}), dict):
        raise WatchersError("invalid_import", "A bundle requires definition and scripts objects.")
    definition = copy.deepcopy(bundle["definition"])
    for key in ("id", "revision", "state", "machine", "created_at", "updated_at", "activated_by", "activated_via",
                "next_fire_at", "last_run", "live", "attention", "runs_count", "unread_inbox", "warnings", "kind",
                "edit_target_id", "edit_target_revision"):
        definition.pop(key, None)
    definition.setdefault("timezone", creator_timezone or machine_timezone())
    definition = validate_definition(definition)
    return {"definition": definition, "scripts": bundle.get("scripts", {}), "state": "paused"}
