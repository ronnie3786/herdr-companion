"""Dependency-free watcher definition and smart-chip validation.

Definitions preserve the person's summary markup. Additive summary_tokens and
summary_text expose safe rendering: unknown or untruthful tokens become text,
with precise warnings, rather than claiming actions absent from the steps.
"""
from __future__ import annotations

from copy import deepcopy
from pathlib import PurePosixPath
import re

from .assets import CHARACTERS, INSTRUMENTS, CHIP_KINDS, STEP_ICONS, asset_catalog, pick_avatar
from .errors import WatchersError
from .schedule import default_missed_runs, machine_timezone, validate_schedule, timezone_info

MAX_SCRIPT_BYTES = 256 * 1024
MAX_STEPS = 32
TOKEN = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)(?::([^{}]*))?\}")
IDENTIFIER = re.compile(r"[A-Za-z][A-Za-z0-9_-]{0,127}")
DEFINITION_KEYS = {
    "id", "revision", "state", "name", "avatar", "machine", "timezone", "schedule",
    "missed_runs", "overlap", "summary", "steps", "created_by", "source_prompt",
    "source", "created_at", "updated_at", "activated_by", "activated_via",
    "builder_session_id", "edit_target_id", "edit_target_revision", "kind", "warnings", "summary_tokens", "summary_text",
}
COMMON_STEP_KEYS = {"id", "kind", "title", "note", "icon"}
STEP_KEYS = {
    "script": {"file", "interpreter", "timeout_seconds", "cwd"},
    "gate": {"rule"},
    "agent": {"model", "instructions", "skill", "display_name", "timeout_seconds", "mode"},
    "deliver": {"to"},
}
INTERPRETERS = {"bash": "/bin/bash", "zsh": "/bin/zsh", "sh": "/bin/sh", "python": "/usr/bin/python3", "python3": "/usr/bin/python3"}


def _invalid(message: str):
    raise WatchersError("invalid_definition", message)


def _text(value, name: str, maximum: int = 4000, *, optional=False) -> str:
    if not isinstance(value, str) or "\x00" in value or len(value) > maximum or (not optional and not value.strip()):
        _invalid(f"{name} must be {'a' if not optional else 'an optional'} string of at most {maximum} characters")
    return value


def _keys(value: dict, allowed: set[str], name: str):
    unknown = set(value) - allowed
    if unknown:
        _invalid(f"Unknown {name} fields: {', '.join(sorted(str(key) for key in unknown))}")


def _identifier(value, name: str) -> str:
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        _invalid(f"{name} must start with a letter and contain only letters, numbers, underscores, and hyphens")
    return value


def _timeout(value, name: str) -> int:
    if type(value) is not int or not 1 <= value <= 21600:
        _invalid(f"{name} must be an integer from 1 through 21600 seconds")
    return value


def model_display_name(model: str) -> str:
    name = model.rsplit("/", 1)[-1]
    for suffix in ("astra", "sol", "luna", "terra", "fable", "opus", "sonnet", "haiku"):
        if re.search(rf"(?:^|-){suffix}(?:-|$)", name, flags=re.IGNORECASE):
            return suffix.title()
    return name


def validate_step(step: dict, previous_ids: set[str]) -> dict:
    if not isinstance(step, dict):
        _invalid("Each step must be an object")
    kind = step.get("kind")
    if not isinstance(kind, str) or kind not in STEP_KEYS:
        _invalid("step.kind must be script, gate, agent, or deliver")
    _keys(step, COMMON_STEP_KEYS | STEP_KEYS[kind], f"{kind} step")
    result = deepcopy(step)
    _identifier(result.get("id"), "step.id")
    if result["id"].casefold() in {value.casefold() for value in previous_ids}:
        _invalid(f"Duplicate step id: {result['id']}")
    default_title = {"script": "Run script", "gate": "Check for changes", "agent": "Agent step", "deliver": "Deliver results"}[kind]
    result["title"] = _text(result.get("title", default_title), "step.title", 200)
    if "note" in result:
        _text(result["note"], "step.note", 2000, optional=True)
    result.setdefault("icon", {"script": "terminal", "gate": "check", "agent": "sparkles", "deliver": "inbox"}[kind])
    if result["icon"] not in STEP_ICONS:
        _invalid("step.icon must be from the schema asset catalog")
    if kind == "script":
        file = _text(result.get("file"), "script.file", 128)
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", file) or file.casefold() in (".", "..", "definition.json"):
            _invalid("script.file must be a single safe filename, without directories or the reserved definition.json name")
        interpreter = _text(result.get("interpreter", "bash"), "script.interpreter", 1024)
        interpreter = INTERPRETERS.get(interpreter, interpreter)
        if not interpreter.startswith("/") or "\n" in interpreter or "\r" in interpreter or ".." in PurePosixPath(interpreter).parts:
            _invalid("script.interpreter must be bash, zsh, sh, python3, or an absolute executable path")
        result["interpreter"] = interpreter
        result["timeout_seconds"] = _timeout(result.get("timeout_seconds", 3600), "script.timeout_seconds")
        if "cwd" in result:
            cwd = _text(result["cwd"], "script.cwd", 2048)
            if not cwd.startswith("/"):
                _invalid("script.cwd must be an absolute directory")
    elif kind == "gate":
        rule = result.get("rule")
        if not isinstance(rule, dict) or rule.get("kind") not in ("new_items", "changed"):
            _invalid("gate.rule.kind must be new_items or changed")
        _keys(rule, {"kind", "from", "key", "version"} if rule["kind"] == "new_items" else {"kind", "from"}, "gate rule")
        source = _text(rule.get("from"), "gate.rule.from", 128)
        if source not in previous_ids:
            _invalid("gate.rule.from must refer to an earlier step")
        if rule["kind"] == "new_items":
            _text(rule.get("key"), "gate.rule.key", 200)
            if "version" in rule:
                _text(rule["version"], "gate.rule.version", 200)
    elif kind == "agent":
        result["model"] = _text(result.get("model"), "agent.model", 200)
        _text(result.get("instructions"), "agent.instructions", 32000)
        result["display_name"] = _text(result.get("display_name", model_display_name(result["model"])), "agent.display_name", 100)
        result["timeout_seconds"] = _timeout(result.get("timeout_seconds", 1800), "agent.timeout_seconds")
        result.setdefault("mode", "ask")
        if result["mode"] not in ("ask", "act"):
            _invalid("agent.mode must be ask or act")
        if "skill" in result:
            _text(result["skill"], "agent.skill", 200)
    else:
        targets = result.get("to")
        if not isinstance(targets, list) or not 1 <= len(targets) <= 16:
            _invalid("deliver.to must contain 1 through 16 destinations")
        seen = set()
        for target in targets:
            if not isinstance(target, dict) or target.get("kind") not in ("inbox", "slack", "notify"):
                _invalid("Delivery kind must be inbox, slack, or notify")
            _keys(target, {"kind", "target"} if target["kind"] == "slack" else {"kind"}, "delivery")
            destination = _text(target.get("target"), "slack.target", 200) if target["kind"] == "slack" else ""
            identity = (target["kind"], destination)
            if identity in seen:
                _invalid("Duplicate delivery destination")
            seen.add(identity)
    return result


def _chip_values(steps: list[dict]) -> dict[str, set[str]]:
    values = {key: set() for key in ("script", "agent", "skill", "slack")}
    for step in steps:
        kind = step.get("kind")
        if kind == "script" and step.get("file"):
            values["script"].add(step["file"])
        if kind == "agent":
            if step.get("model"):
                values["agent"].add(step.get("display_name") or model_display_name(step["model"]))
            if step.get("skill"):
                values["skill"].add(step["skill"])
        if kind == "deliver":
            for target in step.get("to", []):
                if target.get("kind") == "slack" and target.get("target"):
                    values["slack"].add(target["target"])
    return values


def validate_summary(summary: str, steps: list[dict]) -> list[dict]:
    _text(summary, "summary", 8000)
    values = _chip_values(steps)
    warnings = []
    time_found = False
    last = 0
    for match in TOKEN.finditer(summary):
        if "{" in summary[last:match.start()] or "}" in summary[last:match.start()]:
            raise WatchersError("invalid_summary", "Summary chips cannot nest or contain braces in their values")
        kind, value = match.groups()
        token = match.group()
        reason = None
        if kind == "time" and value is None:
            time_found = True
        elif kind not in CHIP_KINDS:
            reason = "unknown_chip"
        elif kind == "time" or value is None or not value.strip():
            reason = "invalid_chip_value"
        elif kind in values and value not in values[kind]:
            reason = "chip_step_mismatch"
        if reason:
            warnings.append({"code": reason, "token": token, "start": match.start(), "end": match.end(), "message": f"{token} is shown as plain text because it does not match an available chip and step"})
        last = match.end()
    if "{" in summary[last:] or "}" in summary[last:]:
        raise WatchersError("invalid_summary", "Summary chips must have matching braces and cannot nest")
    if not time_found:
        raise WatchersError("invalid_summary", "summary must contain the live schedule chip {time}")
    return warnings


def summary_tokens(summary: str, steps: list[dict], schedule_summary: str = "") -> list[dict]:
    invalid = {warning["start"] for warning in validate_summary(summary, steps)}
    results = []
    last = 0
    for match in TOKEN.finditer(summary):
        if match.start() > last:
            results.append({"kind": "text", "text": summary[last:match.start()]})
        kind, value = match.groups()
        if match.start() in invalid:
            results.append({"kind": "text", "text": value if value else kind})
        else:
            if kind == "time":
                value = schedule_summary
                if match.start() == 0 or re.search(r"[.!?]\s*$", summary[:match.start()]):
                    value = value[:1].upper() + value[1:]
            results.append({"kind": "chip", "chip": kind, "value": value, "start": match.start(), "end": match.end()})
        last = match.end()
    if last < len(summary):
        results.append({"kind": "text", "text": summary[last:]})
    return results


def summary_text(summary: str, steps: list[dict], schedule_summary: str = "") -> str:
    return "".join(token.get("text", token.get("value", "")) for token in summary_tokens(summary, steps, schedule_summary))


def validate_definition(definition: dict, *, machine_id: str | None = None, timezone: str | None = None) -> dict:
    if not isinstance(definition, dict):
        _invalid("definition must be an object")
    _keys(definition, DEFINITION_KEYS, "definition")
    result = deepcopy(definition)
    result["name"] = _text(result.get("name"), "name", 200)
    if machine_id is not None:
        if "machine" in result and result["machine"] != machine_id:
            raise WatchersError("machine_mismatch", "The watcher must live on this companion's machine")
        result["machine"] = machine_id
    elif "machine" in result:
        _text(result["machine"], "machine", 200)
    result["timezone"] = result.get("timezone", timezone or machine_timezone())
    timezone_info(result["timezone"])
    result["schedule"] = validate_schedule(result.get("schedule"), result["timezone"])
    result.setdefault("state", "draft")
    if result["state"] not in ("draft", "active", "paused", "done"):
        _invalid("state must be draft, active, paused, or done")
    result.setdefault("missed_runs", default_missed_runs(result["schedule"]))
    if result["missed_runs"] not in ("skip", "run_once"):
        _invalid("missed_runs must be skip or run_once")
    result.setdefault("overlap", "skip")
    if result["overlap"] != "skip":
        _invalid("Only overlap=skip is supported")
    steps = result.get("steps")
    if not isinstance(steps, list) or not 1 <= len(steps) <= MAX_STEPS:
        _invalid(f"steps must contain 1 through {MAX_STEPS} steps")
    normalized, ids, files = [], set(), set()
    for step in steps:
        step = validate_step(step, ids)
        ids.add(step["id"])
        if step["kind"] == "script":
            if step["file"].casefold() in files:
                _invalid("Each script step must have its own filename")
            files.add(step["file"].casefold())
        normalized.append(step)
    result["steps"] = normalized
    has_agent = any(step["kind"] == "agent" for step in normalized)
    has_script = any(step["kind"] == "script" for step in normalized)
    result["kind"] = "hybrid" if has_agent and has_script else "agent" if has_agent else "script"
    family = CHARACTERS if has_agent else INSTRUMENTS
    if "avatar" not in result:
        result["avatar"] = pick_avatar(has_agent)
    elif result["avatar"] not in CHARACTERS + INSTRUMENTS:
        _invalid("avatar must be an ID from the schema asset catalog")
    elif result["avatar"] not in family:
        result["avatar"] = pick_avatar(has_agent)
    result["warnings"] = validate_summary(result.get("summary"), normalized)
    result["summary_tokens"] = summary_tokens(result["summary"], normalized, result["schedule"]["summary"])
    result["summary_text"] = summary_text(result["summary"], normalized, result["schedule"]["summary"])
    if "id" in result:
        _identifier(result["id"], "id")
    if "revision" in result and (type(result["revision"]) is not int or result["revision"] < 1):
        _invalid("revision must be a positive integer")
    if ("edit_target_id" in result) != ("edit_target_revision" in result):
        _invalid("edit_target_id and edit_target_revision must be supplied together")
    if "edit_target_id" in result:
        _identifier(result["edit_target_id"], "edit_target_id")
        if type(result["edit_target_revision"]) is not int or result["edit_target_revision"] < 1:
            _invalid("edit_target_revision must be a positive integer")
    for name in ("created_by", "activated_by", "activated_via", "builder_session_id", "created_at", "updated_at"):
        if name in result:
            _text(result[name], name, 300)
    if "source_prompt" in result:
        _text(result["source_prompt"], "source_prompt", 32000, optional=True)
    if "source" in result:
        source = result["source"]
        if not isinstance(source, dict):
            _invalid("source must be an object")
        _keys(source, {"kind", "job_id"}, "source")
        if source.get("kind") != "cronboard":
            _invalid("source.kind must be cronboard")
        _text(source.get("job_id"), "source.job_id", 200)
    return result


def validate_script_body(body: str) -> str:
    if not isinstance(body, str) or "\x00" in body or len(body.encode("utf-8")) > MAX_SCRIPT_BYTES:
        raise WatchersError("invalid_script", "Script bodies must be text no larger than 256 KiB, without NUL bytes")
    return body


def example(timezone: str = "UTC", machine_id: str | None = None) -> dict:
    """A synthetic create/draft request with separately reviewable script text."""
    definition = {
        "name": "Example file check", "timezone": timezone,
        "schedule": {"kind": "interval", "every_minutes": 15},
        "summary": "{time}, I run {script:check.sh} and keep the results in the {inbox:Watcher inbox}.",
        "steps": [
            {"id": "check", "kind": "script", "title": "Check synthetic items", "file": "check.sh", "interpreter": "bash", "icon": "terminal"},
            {"id": "post", "kind": "deliver", "title": "Save the result", "to": [{"kind": "inbox"}]},
        ],
    }
    if machine_id is not None:
        definition["machine"] = machine_id
    return {"definition": definition, "scripts": {"check": "printf '%s\\n' 'Example check finished.'\n"}}


def schema() -> dict:
    """Agent-facing contract and JSON Schema with no third-party dependency."""
    string = {"type": "string", "minLength": 1}
    days = {"oneOf": [{"enum": ["all", "weekdays"]}, {"type": "array", "minItems": 1, "maxItems": 7, "uniqueItems": True, "items": {"type": "integer", "minimum": 1, "maximum": 7}}]}
    schedules = []
    variants = {
        "interval": ({"every_minutes": {"type": "integer", "minimum": 1, "maximum": 1440}, "days": days, "window": {"type": "array", "minItems": 2, "maxItems": 2, "items": {"type": "string", "pattern": r"^\d{2}:\d{2}$"}}}, ["every_minutes"]),
        "daily": ({"at": {"type": "string", "pattern": r"^\d{2}:\d{2}$"}, "days": days}, ["at"]),
        "cron": ({"expression": string}, ["expression"]),
        "once": ({"at": {"type": "string", "format": "date-time"}}, ["at"]),
    }
    for kind, (properties, required) in variants.items():
        schedules.append({"type": "object", "additionalProperties": False, "required": ["kind"] + required, "properties": {"kind": {"const": kind}, **properties}})
    step_variants = []
    common = {"id": {"type": "string", "pattern": IDENTIFIER.pattern}, "title": string, "note": {"type": "string"}, "icon": {"enum": list(STEP_ICONS)}}
    timeout = {"type": "integer", "minimum": 1, "maximum": 21600}
    specific = {
        "script": ({"file": string, "interpreter": string, "timeout_seconds": {**timeout, "default": 3600}, "cwd": string}, ["file"]),
        "gate": ({"rule": {"oneOf": [
            {"type": "object", "additionalProperties": False, "required": ["kind", "from", "key"], "properties": {"kind": {"const": "new_items"}, "from": string, "key": string, "version": string}},
            {"type": "object", "additionalProperties": False, "required": ["kind", "from"], "properties": {"kind": {"const": "changed"}, "from": string}},
        ]}}, ["rule"]),
        "agent": ({"model": string, "instructions": string, "skill": string, "display_name": string, "timeout_seconds": {**timeout, "default": 1800}, "mode": {"enum": ["ask", "act"], "default": "ask"}}, ["model", "instructions"]),
        "deliver": ({"to": {"type": "array", "minItems": 1, "maxItems": 16, "items": {"oneOf": [
            {"type": "object", "additionalProperties": False, "required": ["kind"], "properties": {"kind": {"enum": ["inbox", "notify"]}}},
            {"type": "object", "additionalProperties": False, "required": ["kind", "target"], "properties": {"kind": {"const": "slack"}, "target": string}},
        ]}}}, ["to"]),
    }
    for kind, (properties, required) in specific.items():
        step_variants.append({"type": "object", "additionalProperties": False, "required": ["id", "kind"] + required, "properties": {**common, "kind": {"const": kind}, **properties}})
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema", "title": "Watcher definition", "type": "object", "additionalProperties": False,
        "required": ["name", "schedule", "summary", "steps"],
        "properties": {
            "name": {**string, "maxLength": 200}, "timezone": {**string, "description": "IANA timezone; defaults to the creator's timezone"}, "machine": string,
            "avatar": {"enum": list(CHARACTERS + INSTRUMENTS)}, "schedule": {"oneOf": schedules}, "summary": {**string, "maxLength": 8000},
            "steps": {"type": "array", "minItems": 1, "maxItems": MAX_STEPS, "items": {"oneOf": step_variants}},
            "missed_runs": {"enum": ["skip", "run_once"]}, "overlap": {"const": "skip"},
            "created_by": string, "source_prompt": {"type": "string", "maxLength": 32000}, "builder_session_id": string,
            "source": {"type": "object", "additionalProperties": False, "required": ["kind", "job_id"], "properties": {"kind": {"const": "cronboard"}, "job_id": string}},
            "edit_target_id": {"type": "string", "pattern": IDENTIFIER.pattern},
            "edit_target_revision": {"type": "integer", "minimum": 1},
        },
        "dependentRequired": {"edit_target_id": ["edit_target_revision"], "edit_target_revision": ["edit_target_id"]},
        "assets": asset_catalog(),
        "chip_markup": {"grammar": "{kind} or {kind:value}; no nesting or braces inside values", "required": "{time}", "step_matched": ["script", "agent", "skill", "slack"], "mismatch": "plain text with a warning; raw summary is preserved"},
        "scripts": {"transport": "Outer scripts object keyed by step id, separate from definition", "maximum_bytes": MAX_SCRIPT_BYTES},
        "executable_steps": ["script", "gate", "deliver"], "executable_delivery": ["inbox"],
        "workflow": ["Create a draft with definition and scripts", "Review chips and every script", "Preview next fires", "Dry-run only with permission to execute scripts", "Ask the person to activate"],
    }
