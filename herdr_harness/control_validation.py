"""Strict validation helpers for the agent-control wire contract."""
from __future__ import annotations

import json
import re
import urllib.parse
from typing import Any, Mapping, Optional


MAX_JSON_BYTES = 64 * 1024
MAX_JSON_DEPTH = 8
_REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_ACTION_ID_RE = re.compile(r"^[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*)+$")
_CLIENT_ID_RE = re.compile(
    r"^ui_[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)
_UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)
_RECEIVER_TOKEN_RE = re.compile(r"^[0-9a-f]{64}$")
_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._-]{0,255}$")
_TARGET_FIELDS = frozenset(
    {
        "kind",
        "serverId",
        "serverURL",
        "machineId",
        "workspaceId",
        "tabId",
        "paneId",
        "terminalId",
        "sessionId",
        "hudChatId",
        "featureId",
    }
)
_SCHEMA_FIELDS = frozenset({"type", "enum", "required", "properties", "additionalProperties"})
_SCHEMA_TYPES = frozenset({"object", "array", "string", "integer", "number", "boolean", "null"})


class ControlError(ValueError):
    """Safe API error for control, discovery, and resource operations."""

    def __init__(self, message: str, *, code: str = "invalid_request", status: int = 400):
        super().__init__(message)
        self.code = code
        self.status = status


def require_fields(value: Mapping[str, Any], *, allowed: set[str], required: set[str], label: str) -> None:
    extra = set(value) - allowed
    missing = required - set(value)
    if extra:
        raise ControlError(f"{label} contains an unsupported field")
    if missing:
        raise ControlError(f"{label} is missing a required field")


def short_string(value: Any, label: str, *, maximum: int, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or "\x00" in value:
        raise ControlError(f"{label} must be a string")
    if not allow_empty and not value:
        raise ControlError(f"{label} is required")
    if len(value) > maximum:
        raise ControlError(f"{label} exceeds {maximum} characters")
    return value


def request_id(value: Any) -> str:
    text = short_string(value, "requestId", maximum=128)
    if not _REQUEST_ID_RE.fullmatch(text):
        raise ControlError("requestId contains unsupported characters")
    return text


def action_id(value: Any) -> str:
    text = short_string(value, "action", maximum=128)
    if not _ACTION_ID_RE.fullmatch(text):
        raise ControlError("action is invalid")
    return text


def client_id(value: Any) -> str:
    text = short_string(value, "clientId", maximum=64)
    if not _CLIENT_ID_RE.fullmatch(text):
        raise ControlError("clientId must be ui_ followed by a UUID")
    return "ui_" + text[3:].lower()


def instance_id(value: Any) -> str:
    text = short_string(value, "instanceId", maximum=36)
    if not _UUID_RE.fullmatch(text):
        raise ControlError("instanceId must be a UUID")
    return text.lower()


def receiver_token(value: Any) -> str:
    text = short_string(value, "receiverToken", maximum=64)
    if not _RECEIVER_TOKEN_RE.fullmatch(text):
        raise ControlError("receiverToken must be 64 lowercase hexadecimal characters")
    return text


def publisher_token(value: Any) -> str:
    """Validate a chat-tab-color publisher secret bound on first publication."""

    text = short_string(value, "publisherToken", maximum=64)
    if not _RECEIVER_TOKEN_RE.fullmatch(text):
        raise ControlError("publisherToken must be 64 lowercase hexadecimal characters")
    return text


def _json_depth(value: Any, depth: int = 0) -> int:
    if depth > MAX_JSON_DEPTH:
        return depth
    if isinstance(value, dict):
        return max([depth] + [_json_depth(item, depth + 1) for item in value.values()])
    if isinstance(value, list):
        return max([depth] + [_json_depth(item, depth + 1) for item in value])
    return depth


def validate_json(value: Any, label: str, *, maximum_bytes: int = MAX_JSON_BYTES) -> None:
    try:
        encoded = json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError, RecursionError) as exc:
        raise ControlError(f"{label} must contain finite, bounded JSON values") from exc
    if len(encoded) > maximum_bytes:
        raise ControlError(f"{label} is too large", code="body_too_large", status=413)
    if _json_depth(value) > MAX_JSON_DEPTH:
        raise ControlError(f"{label} is nested too deeply")


def canonical_json(value: Any, *, maximum_bytes: int = MAX_JSON_BYTES) -> str:
    """Canonical serialization with an explicit call-site size budget.

    Callers with a documented larger contract (for example the 512 KiB chat
    tab color publication) must pass their own ``maximum_bytes``; the generic
    control default stays 64 KiB.
    """

    validate_json(value, "payload", maximum_bytes=maximum_bytes)
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    )


def target(value: Any, *, required: bool = False) -> Optional[dict[str, str]]:
    if value is None:
        if required:
            raise ControlError("target is required")
        return None
    if not isinstance(value, dict):
        raise ControlError("target must be an object")
    if set(value) - _TARGET_FIELDS:
        raise ControlError("target contains an unsupported field")
    result: dict[str, str] = {}
    for key, raw in value.items():
        text = short_string(raw, f"target.{key}", maximum=2048 if key == "serverURL" else 256)
        if key == "serverURL":
            try:
                parsed = urllib.parse.urlsplit(text)
                port = parsed.port
            except ValueError as exc:
                raise ControlError("target.serverURL is invalid") from exc
            if (
                parsed.scheme.lower() not in {"http", "https"}
                or not parsed.hostname
                or any(character.isspace() or ord(character) < 32 for character in parsed.netloc)
                or parsed.username
                or parsed.password
                or parsed.path not in {"", "/"}
                or parsed.query
                or parsed.fragment
            ):
                raise ControlError("target.serverURL must be an HTTP(S) origin")
            host = parsed.hostname.lower()
            if ":" in host:
                host = f"[{host}]"
            netloc = host if port is None else f"{host}:{port}"
            text = urllib.parse.urlunsplit((parsed.scheme.lower(), netloc, "", "", ""))
        elif key != "kind" and not _IDENTIFIER_RE.fullmatch(text):
            raise ControlError(f"target.{key} is invalid")
        result[key] = text
    return result


def ui_state(value: Any) -> dict:
    if not isinstance(value, dict):
        raise ControlError("state must be an object")
    require_fields(
        value,
        allowed={"revision", "window", "segment", "selection", "modal", "enabled"},
        required={"revision", "window", "segment", "enabled"},
        label="state",
    )
    revision = value.get("revision")
    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
        raise ControlError("state.revision must be a nonnegative integer")
    window = value.get("window")
    if window not in {"main", "settings", "hud", "active-work"}:
        raise ControlError("state.window is invalid")
    segment = short_string(value.get("segment"), "state.segment", maximum=64)
    enabled = value.get("enabled")
    if not isinstance(enabled, bool):
        raise ControlError("state.enabled must be a boolean")
    result: dict[str, Any] = {
        "revision": revision,
        "window": window,
        "segment": segment,
        "enabled": enabled,
    }
    if "selection" in value:
        result["selection"] = target(value.get("selection"), required=True)
    if "modal" in value:
        modal = value.get("modal")
        if modal is not None:
            result["modal"] = short_string(modal, "state.modal", maximum=128)
    validate_json(result, "state", maximum_bytes=16 * 1024)
    return result


def _schema(value: Any, *, depth: int = 0) -> dict:
    if not isinstance(value, dict) or depth > 5:
        raise ControlError("action parameters schema is invalid")
    if set(value) - _SCHEMA_FIELDS:
        raise ControlError("action parameters schema contains an unsupported keyword")
    schema_type = value.get("type")
    if schema_type not in _SCHEMA_TYPES:
        raise ControlError("action parameters schema type is invalid")
    result: dict[str, Any] = {"type": schema_type}
    if "enum" in value:
        enum = value["enum"]
        if not isinstance(enum, list) or not enum or len(enum) > 100:
            raise ControlError("action parameters schema enum is invalid")
        validate_json(enum, "action parameters enum", maximum_bytes=8 * 1024)
        result["enum"] = enum
    properties = value.get("properties", {})
    if not isinstance(properties, dict) or len(properties) > 64:
        raise ControlError("action parameters schema properties are invalid")
    normalized_properties = {}
    for key, child in properties.items():
        if not isinstance(key, str) or not key or len(key) > 64:
            raise ControlError("action parameters schema property name is invalid")
        normalized_properties[key] = _schema(child, depth=depth + 1)
    if normalized_properties:
        if schema_type != "object":
            raise ControlError("only object schemas may define properties")
        result["properties"] = normalized_properties
    required = value.get("required", [])
    if not isinstance(required, list) or any(not isinstance(item, str) for item in required):
        raise ControlError("action parameters schema required is invalid")
    if len(set(required)) != len(required) or any(item not in properties for item in required):
        raise ControlError("action parameters schema required references an unknown property")
    if required:
        result["required"] = required
    additional = value.get("additionalProperties", False)
    if not isinstance(additional, bool):
        raise ControlError("action parameters schema additionalProperties must be a boolean")
    if schema_type == "object":
        result["additionalProperties"] = additional
    return result


def action_descriptor(value: Any) -> dict:
    if not isinstance(value, dict):
        raise ControlError("action descriptor must be an object")
    require_fields(
        value,
        allowed={"id", "title", "parameters", "targetKinds", "effect", "enabled", "disabledReason"},
        required={"id", "title", "parameters", "targetKinds", "effect", "enabled"},
        label="action descriptor",
    )
    identifier = action_id(value.get("id"))
    title = short_string(value.get("title"), "action title", maximum=120)
    parameters = _schema(value.get("parameters"))
    if parameters.get("type") != "object":
        raise ControlError("action parameters schema must have object type")
    kinds = value.get("targetKinds")
    if not isinstance(kinds, list) or len(kinds) > 32 or any(
        not isinstance(item, str) or not item or len(item) > 64 for item in kinds
    ):
        raise ControlError("action targetKinds is invalid")
    effect = value.get("effect")
    if effect not in {"navigation", "read", "mutation"}:
        raise ControlError("action effect is invalid")
    enabled = value.get("enabled")
    if not isinstance(enabled, bool):
        raise ControlError("action enabled must be a boolean")
    result = {
        "id": identifier,
        "title": title,
        "parameters": parameters,
        "targetKinds": list(dict.fromkeys(kinds)),
        "effect": effect,
        "enabled": enabled,
    }
    reason = value.get("disabledReason")
    if reason is not None:
        result["disabledReason"] = short_string(reason, "action disabledReason", maximum=240)
    if not enabled and "disabledReason" not in result:
        raise ControlError("a disabled action requires disabledReason")
    validate_json(result, "action descriptor", maximum_bytes=16 * 1024)
    return result


def action_descriptors(value: Any) -> list[dict]:
    if not isinstance(value, list) or len(value) > 128:
        raise ControlError("actions must be an array with at most 128 entries")
    result = [action_descriptor(item) for item in value]
    identifiers = [item["id"] for item in result]
    if len(set(identifiers)) != len(identifiers):
        raise ControlError("actions contains a duplicate id")
    validate_json(result, "actions")
    return result


def validate_parameters(value: Any, schema: dict, *, label: str = "parameters") -> dict:
    if not isinstance(value, dict):
        raise ControlError(f"{label} must be an object")
    validate_json(value, label)
    _validate_schema_value(value, schema, label)
    return value


def _validate_schema_value(value: Any, schema: dict, label: str) -> None:
    schema_type = schema.get("type")
    valid = {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }.get(schema_type, False)
    if not valid:
        raise ControlError(f"{label} has the wrong type")
    if "enum" in schema and value not in schema["enum"]:
        raise ControlError(f"{label} is not an allowed value")
    if schema_type == "object":
        properties = schema.get("properties", {})
        missing = set(schema.get("required", [])) - set(value)
        if missing:
            raise ControlError(f"{label} is missing a required field")
        if schema.get("additionalProperties") is False and set(value) - set(properties):
            raise ControlError(f"{label} contains an unsupported field")
        for key, child in value.items():
            if key in properties:
                _validate_schema_value(child, properties[key], f"{label}.{key}")
