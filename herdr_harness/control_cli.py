"""Authenticated, JSON-only agent control client for a configured Herdr fleet.

The CLI deliberately exposes typed control operations, not shell dispatch or an
arbitrary HTTP passthrough.  Machine credentials are resolved independently from
the original private cluster configuration so a local process token is never
silently reused for another machine. UI receivers are selected by explicit ID,
then the origin hint, then a sole live receiver; with multiple live receivers,
only one whose current selection exactly matches PI_SESSION_ID may be inferred.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import contextlib
import hashlib
import ipaddress
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Mapping, TextIO

from .chat_tab_color_cli import (
    CHAT_TAB_COLOR_CHOICES,
    GROUPING_SCOPE,
    GROUP_BY_CHOICES,
    chat_tab_colors_unsupported_message,
    color_query_parameters,
    group_results,
    is_color_requested,
    normalized_color_client,
    supports_chat_tab_colors,
)
from .config import ConfigurationError, load_configuration
from .secret_file import (
    SecretFileError,
    load_private_bearer_token_file,
    validate_bearer_token,
)

MAX_REQUEST_BYTES = 1024 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_ERROR_BYTES = 64 * 1024
MAX_INPUT_BYTES = 1024 * 1024
MAX_CURSOR_BYTES = 16 * 1024
MAX_SCHEMA_DEPTH = 12
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
CURSOR_RE = re.compile(r"^[A-Za-z0-9_-]+$")
ERROR_CODE_RE = re.compile(r"^[a-z][a-z0-9_.-]{0,127}$")
TERMINAL_COMMAND_STATUSES = {"completed", "failed", "expired", "outcome_unknown"}
FAILED_COMMAND_STATUSES = {"failed", "expired", "outcome_unknown"}

# These process values describe one already-selected server.  They must not win
# while resolving another roster member.  A value is retained when the selected
# TOML configuration explicitly names it through {env = "..."}.
_MACHINE_ENVIRONMENT_KEYS = {
    "HERDR_MACHINE",
    "HERDR_HARNESS_API_TOKEN",
    "HERDR_HARNESS_API_TOKEN_FILE",
    "HERDR_HARNESS_URL",
    "HERDR_HARNESS_BASE_URL",
    "HERDR_HARNESS_HOST",
    "HERDR_HARNESS_PORT",
    "HERDR_SOCKET_PATH",
    "HERDR_SESSION",
}
_TARGET_ID_FIELDS = (
    "kind",
    "serverId",
    "workspaceId",
    "tabId",
    "paneId",
    "terminalId",
    "sessionId",
    "hudChatId",
    "featureId",
)
_SESSION_SELECTION_KINDS = {"pane", "hud-chat", "first-mate"}
_UI_CLIENT_HELP = (
    "Explicit receiver ID; otherwise HERDR_UI_CLIENT_ID, a sole live receiver, "
    "or one exact current PI_SESSION_ID selection is used"
)


@dataclass
class CLIError(RuntimeError):
    """A safe, machine-readable failure."""

    message: str
    code: str = "control_cli_error"
    exit_code: int = 2
    http_status: int | None = None
    details: dict[str, Any] | None = None

    def __str__(self) -> str:
        return self.message

    def payload(self) -> dict[str, Any]:
        error: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.http_status is not None:
            error["httpStatus"] = self.http_status
        if self.details:
            error["details"] = self.details
        return {"ok": False, "error": error}


@dataclass
class Outcome:
    payload: dict[str, Any]
    exit_code: int = 0


class JSONArgumentParser(argparse.ArgumentParser):
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        kwargs.setdefault("allow_abbrev", False)
        super().__init__(*args, **kwargs)

    def error(self, _message: str) -> None:
        raise CLIError(
            "Invalid arguments; use herdr-control --help for supported syntax",
            code="invalid_arguments",
        )


class RejectRedirects(urllib.request.HTTPRedirectHandler):
    """Do not forward a bearer credential to a redirected origin."""

    def redirect_request(
        self,
        request: Any,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> None:
        raise urllib.error.HTTPError(
            request.full_url,
            code,
            "Herdr redirects are not allowed",
            headers,
            file_pointer,
        )


def _is_loopback(hostname: str) -> bool:
    if hostname.casefold() == "localhost":
        return True
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False


def _validate_origin(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise CLIError("Selected machine has no server origin", "invalid_configuration")
    try:
        parsed = urllib.parse.urlsplit(value.strip())
        hostname = parsed.hostname
        parsed.port
    except ValueError as exc:
        raise CLIError("Selected machine server origin is invalid", "invalid_configuration") from exc
    if (
        parsed.scheme not in {"http", "https"}
        or not hostname
        or parsed.username
        or parsed.password
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
        or (parsed.scheme == "http" and not _is_loopback(hostname))
    ):
        raise CLIError(
            "Use HTTPS for remote machines, or HTTP on loopback, without embedded credentials",
            "invalid_configuration",
        )
    return value.strip().rstrip("/")


def _safe_text(value: Any, *, fallback: str, maximum: int = 512) -> str:
    if not isinstance(value, str):
        return fallback
    cleaned = " ".join(value.replace("\x00", "").split())
    return cleaned[:maximum] or fallback


def _redact(value: Any, secrets: list[str]) -> Any:
    if isinstance(value, str):
        for secret in secrets:
            if secret:
                value = value.replace(secret, "[redacted]")
        return value
    if isinstance(value, list):
        return [_redact(item, secrets) for item in value]
    if isinstance(value, dict):
        return {
            _redact(key, secrets) if isinstance(key, str) else key: _redact(child, secrets)
            for key, child in value.items()
        }
    return value


class ControlClient:
    """Small no-redirect JSON transport for the locked control API."""

    def __init__(
        self,
        base_url: str,
        token: str,
        *,
        opener: Callable[..., Any] | Any | None = None,
        timeout: float = 20,
    ) -> None:
        self.base_url = _validate_origin(base_url)
        try:
            self.token = validate_bearer_token(token, field="Herdr API token", required=True)
        except SecretFileError as exc:
            raise CLIError("Selected machine API credential is unavailable or unsafe", "invalid_configuration") from exc
        self.timeout = timeout
        if opener is None:
            self._open = urllib.request.build_opener(
                urllib.request.ProxyHandler({}), RejectRedirects()
            ).open
        elif callable(opener):
            self._open = opener
        else:
            self._open = opener.open

    def request(
        self,
        method: str,
        path: str,
        payload: Any = None,
        *,
        query: Mapping[str, Any] | None = None,
        has_payload: bool = False,
    ) -> dict[str, Any]:
        if not path.startswith("/api/v1/") or "?" in path or "#" in path:
            raise CLIError("Internal control API path is invalid", "invalid_request")
        url = self.base_url + path
        if query:
            url += "?" + urllib.parse.urlencode(
                [(key, str(value)) for key, value in query.items() if value is not None]
            )
        body: bytes | None = None
        if has_payload:
            try:
                body = json.dumps(
                    payload, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True
                ).encode("utf-8")
            except (TypeError, ValueError) as exc:
                raise CLIError("Request payload is not valid JSON", "invalid_payload") from exc
            if len(body) > MAX_REQUEST_BYTES:
                raise CLIError("Request payload is too large", "request_too_large")
        headers = {
            "Accept": "application/json",
            "Authorization": "Bearer " + self.token,
            "User-Agent": "herdr-control/1",
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self._open(request, timeout=self.timeout) as response:
                final_url = response.geturl() if callable(getattr(response, "geturl", None)) else url
                if final_url != url:
                    raise CLIError("Herdr redirects are not allowed", "redirect_not_allowed", 3)
                status = getattr(response, "status", None)
                if status is None and callable(getattr(response, "getcode", None)):
                    status = response.getcode()
                if isinstance(status, int) and not 200 <= status < 300:
                    raise CLIError("Herdr returned an unsuccessful HTTP status", "herdr_http_error", 5, status)
                raw = response.read(MAX_RESPONSE_BYTES + 1)
        except CLIError:
            raise
        except urllib.error.HTTPError as exc:
            with contextlib.closing(exc):
                raw = exc.read(MAX_ERROR_BYTES)
            if 300 <= exc.code < 400:
                raise CLIError("Herdr redirects are not allowed", "redirect_not_allowed", 3, exc.code) from exc
            fallback = f"Herdr returned HTTP {exc.code}"
            code = "herdr_http_error"
            message = fallback
            try:
                decoded = _redact(json.loads(raw), [self.token])
                error = decoded.get("error", {}) if isinstance(decoded, dict) else {}
                candidate = str(error.get("code") or "")
                code = candidate if ERROR_CODE_RE.fullmatch(candidate) else code
                message = _safe_text(error.get("message"), fallback=fallback)
            except (ValueError, UnicodeError, AttributeError):
                pass
            exit_code = 4 if exc.code == 409 else 5
            raise CLIError(message, code, exit_code, exc.code) from exc
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            raise CLIError("Could not reach the selected Herdr backend", "herdr_unavailable", 3) from exc
        if len(raw) > MAX_RESPONSE_BYTES:
            raise CLIError("Herdr response is too large", "response_too_large", 3)
        try:
            result = _redact(json.loads(raw), [self.token])
        except (ValueError, UnicodeError) as exc:
            raise CLIError("Herdr returned invalid JSON", "invalid_response", 3) from exc
        if not isinstance(result, dict):
            raise CLIError("Herdr returned an invalid response object", "invalid_response", 3)
        if result.get("ok") is not True:
            error = result.get("error") if isinstance(result.get("error"), dict) else {}
            candidate = str(error.get("code") or "")
            code = candidate if ERROR_CODE_RE.fullmatch(candidate) else "unsuccessful_response"
            message = _safe_text(error.get("message"), fallback="Herdr returned an unsuccessful response")
            raise CLIError(message, code, 4 if code.endswith("conflict") else 5)
        return result


def _collect_environment_references(value: Any) -> set[str]:
    references: set[str] = set()
    if isinstance(value, dict):
        if set(value) == {"env"} and isinstance(value.get("env"), str):
            references.add(value["env"])
        else:
            for child in value.values():
                references.update(_collect_environment_references(child))
    elif isinstance(value, list):
        for child in value:
            references.update(_collect_environment_references(child))
    return references


def _configuration_environment(
    original: Mapping[str, str], *, references: set[str] = frozenset()
) -> dict[str, str]:
    environment = dict(original)
    for name in _MACHINE_ENVIRONMENT_KEYS:
        if name not in references:
            environment.pop(name, None)
    return environment


def _read_json_file(path: str, stdin: TextIO) -> Any:
    try:
        if path == "-":
            text = stdin.read(MAX_INPUT_BYTES + 1)
        else:
            with Path(path).expanduser().open(encoding="utf-8") as stream:
                text = stream.read(MAX_INPUT_BYTES + 1)
    except OSError as exc:
        raise CLIError("Input JSON file is unavailable", "input_unavailable") from exc
    if len(text.encode("utf-8")) > MAX_INPUT_BYTES:
        raise CLIError("Input JSON file is too large", "input_too_large")
    try:
        return json.loads(text)
    except (ValueError, UnicodeError) as exc:
        raise CLIError("Input file does not contain valid JSON", "invalid_input") from exc


def _request_id(value: str | None) -> str:
    candidate = value or "ctl_" + uuid.uuid4().hex
    if not REQUEST_ID_RE.fullmatch(candidate):
        raise CLIError("request ID must be 1 to 128 safe characters", "invalid_request_id")
    return candidate


def _attach_request_id(error: CLIError, request_id: str) -> CLIError:
    details = dict(error.details or {})
    details.setdefault("requestId", request_id)
    error.details = details
    return error


def _quote(value: str) -> str:
    return urllib.parse.quote(value, safe="")


def _range_type(minimum: int, maximum: int) -> Callable[[str], int]:
    def parse(value: str) -> int:
        try:
            number = int(value)
        except ValueError as exc:
            raise argparse.ArgumentTypeError("must be an integer") from exc
        if not minimum <= number <= maximum:
            raise argparse.ArgumentTypeError(f"must be between {minimum} and {maximum}")
        return number

    return parse


def _target_from_document(value: Any) -> dict[str, Any]:
    candidate = value
    if isinstance(candidate, dict) and isinstance(candidate.get("result"), dict):
        candidate = candidate["result"]
    if isinstance(candidate, dict) and isinstance(candidate.get("target"), dict):
        candidate = candidate["target"]
    if not isinstance(candidate, dict) or not any(key in candidate for key in _TARGET_ID_FIELDS):
        raise CLIError(
            "Reference file must contain a target or a discovery result containing target",
            "invalid_target",
        )
    return dict(candidate)


def _has_target_arguments(args: argparse.Namespace) -> bool:
    return any(
        getattr(args, name, None) is not None
        for name in ("ref_file", "pane", "workspace", "tab")
    )


def _operation_exit(operation: Any) -> int:
    if not isinstance(operation, dict):
        raise CLIError("Herdr omitted the operation receipt", "invalid_response", 3)
    status = operation.get("status")
    if status == "completed":
        return 0
    if status in {"failed", "outcome_unknown"}:
        return 5
    raise CLIError("Herdr returned an invalid operation status", "invalid_response", 3)


def _updated_timestamp(value: Any) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, OverflowError, OSError):
        return None


def _encode_cursor(settings: Mapping[str, Any], offsets: Mapping[str, int]) -> str:
    raw = json.dumps(
        {"version": 1, "query": settings, "offsets": offsets},
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    if len(raw) > MAX_CURSOR_BYTES:
        raise CLIError("Discovery cursor is too large", "invalid_cursor")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _decode_cursor(
    value: str, *, settings: Mapping[str, Any], machines: list[str]
) -> dict[str, int]:
    if not value or len(value) > MAX_CURSOR_BYTES * 2 or not CURSOR_RE.fullmatch(value):
        raise CLIError("Discovery cursor is invalid", "invalid_cursor")
    try:
        padded = value + "=" * (-len(value) % 4)
        raw = base64.b64decode(padded, altchars=b"-_", validate=True)
        document = json.loads(raw)
    except (ValueError, UnicodeError, binascii.Error) as exc:
        raise CLIError("Discovery cursor is invalid", "invalid_cursor") from exc
    if len(raw) > MAX_CURSOR_BYTES or not isinstance(document, dict) or set(document) != {
        "version", "query", "offsets"
    }:
        raise CLIError("Discovery cursor is invalid", "invalid_cursor")
    offsets = document.get("offsets")
    if (
        document.get("version") != 1
        or document.get("query") != dict(settings)
        or not isinstance(offsets, dict)
        or set(offsets) != set(machines)
    ):
        raise CLIError("Discovery cursor does not match this query and roster", "cursor_mismatch")
    parsed: dict[str, int] = {}
    for machine, offset in offsets.items():
        if (
            not isinstance(machine, str)
            or machine not in machines
            or not isinstance(offset, int)
            or isinstance(offset, bool)
            or not 0 <= offset <= 100000
        ):
            raise CLIError("Discovery cursor is invalid", "invalid_cursor")
        parsed[machine] = offset
    return parsed


def _json_values_equal(left: Any, right: Any) -> bool:
    return type(left) is type(right) and left == right


def _validate_schema(schema: Any, *, depth: int = 0) -> None:
    if depth > MAX_SCHEMA_DEPTH or not isinstance(schema, dict):
        raise CLIError("Advertised action parameter schema is invalid", "invalid_action_descriptor", 3)
    allowed = {"type", "enum", "required", "properties", "additionalProperties"}
    if not set(schema).issubset(allowed):
        raise CLIError("Advertised action parameter schema is unsupported", "invalid_action_descriptor", 3)
    schema_type = schema.get("type")
    if schema_type is not None and schema_type not in {
        "object", "array", "string", "integer", "number", "boolean", "null"
    }:
        raise CLIError("Advertised action parameter schema is invalid", "invalid_action_descriptor", 3)
    enum = schema.get("enum")
    if enum is not None and (not isinstance(enum, list) or not enum):
        raise CLIError("Advertised action parameter schema is invalid", "invalid_action_descriptor", 3)
    required = schema.get("required")
    if required is not None and (
        not isinstance(required, list)
        or any(not isinstance(item, str) for item in required)
        or len(set(required)) != len(required)
    ):
        raise CLIError("Advertised action parameter schema is invalid", "invalid_action_descriptor", 3)
    properties = schema.get("properties")
    if properties is not None:
        if not isinstance(properties, dict) or any(not isinstance(key, str) for key in properties):
            raise CLIError("Advertised action parameter schema is invalid", "invalid_action_descriptor", 3)
        for child in properties.values():
            _validate_schema(child, depth=depth + 1)
    additional = schema.get("additionalProperties")
    if additional is not None and not isinstance(additional, bool):
        raise CLIError("Advertised action parameter schema is invalid", "invalid_action_descriptor", 3)


def _validate_schema_value(value: Any, schema: Mapping[str, Any], *, depth: int = 0) -> None:
    if depth > MAX_SCHEMA_DEPTH:
        raise CLIError("UI action parameters are too deeply nested", "invalid_parameters")
    schema_type = schema.get("type")
    valid_type = {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float))
        and not isinstance(value, bool)
        and (not isinstance(value, float) or math.isfinite(value)),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }
    if schema_type is not None and not valid_type[schema_type]:
        raise CLIError("UI action parameters do not match the advertised schema", "invalid_parameters")
    enum = schema.get("enum")
    if enum is not None and not any(_json_values_equal(value, candidate) for candidate in enum):
        raise CLIError("UI action parameters do not match the advertised schema", "invalid_parameters")
    if isinstance(value, dict):
        required = schema.get("required", [])
        missing = [name for name in required if name not in value]
        if missing:
            raise CLIError("UI action parameters omit an advertised required field", "invalid_parameters")
        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for name, child in value.items():
            if name in properties:
                _validate_schema_value(child, properties[name], depth=depth + 1)
            elif additional is False:
                raise CLIError("UI action parameters contain an unsupported field", "invalid_parameters")


def _derived_open_request_id(creation_request_id: str) -> str:
    digest = hashlib.sha256(creation_request_id.encode("utf-8")).hexdigest()[:32]
    return "open_" + digest


def _normalized_uuid(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        normalized = str(uuid.UUID(value))
    except (ValueError, AttributeError):
        return None
    return normalized if value.casefold() == normalized else None


class ControlCLI:
    def __init__(
        self,
        args: argparse.Namespace,
        *,
        environ: Mapping[str, str],
        stdin: TextIO,
        opener: Callable[..., Any] | Any | None,
        clock: Callable[[], float],
        sleep: Callable[[float], None],
    ) -> None:
        self.args = args
        self.environ = dict(environ)
        self.stdin = stdin
        self.opener = opener
        self.clock = clock
        self.sleep = sleep
        self.secrets: list[str] = []
        self._roster: dict[str, dict[str, str]] | None = None
        self._clients: dict[str, ControlClient] = {}

    def roster(self) -> dict[str, dict[str, str]]:
        if self._roster is None:
            try:
                configuration = load_configuration(
                    self.args.config,
                    environ=_configuration_environment(self.environ),
                    resolve_secrets=False,
                )
            except (ConfigurationError, OSError, ValueError) as exc:
                raise CLIError(str(exc), "invalid_configuration") from exc
            self._roster = {
                item["id"]: item for item in sorted(configuration.public_machines(), key=lambda row: row["id"])
            }
        return self._roster

    def client(self, machine: str | None) -> ControlClient:
        if not machine:
            raise CLIError("Select a machine explicitly with --machine", "machine_required")
        if machine in self._clients:
            return self._clients[machine]
        roster = self.roster()
        if machine not in roster:
            raise CLIError("Selected machine is not in the configured roster", "unknown_machine")
        baseline = _configuration_environment(self.environ)
        try:
            raw = load_configuration(
                self.args.config,
                machine,
                environ=baseline,
                resolve_secrets=False,
            )
            effective_raw = {key: value for key, value in raw.data.items() if key != "machines"}
            references = _collect_environment_references(effective_raw)
            selected_environment = _configuration_environment(self.environ, references=references)
            configuration = load_configuration(
                self.args.config,
                machine,
                environ=selected_environment,
            )
        except (ConfigurationError, SecretFileError, OSError, ValueError) as exc:
            raise CLIError(str(exc), "invalid_configuration") from exc

        machine_settings = raw.data.get("machines", {}).get(machine, {})
        machine_server = machine_settings.get("server", {}) if isinstance(machine_settings, dict) else {}
        machine_environment = machine_settings.get("environment", {}) if isinstance(machine_settings, dict) else {}
        explicit_machine_token = (
            isinstance(machine_server, dict)
            and any(key in machine_server for key in ("api_token", "api_token_file"))
        ) or (
            isinstance(machine_environment, dict)
            and any(key in machine_environment for key in ("HERDR_HARNESS_API_TOKEN", "HERDR_HARNESS_API_TOKEN_FILE"))
        )
        if len(roster) > 1 and not explicit_machine_token:
            raise CLIError(
                "Each machine in a multi-machine roster needs its own configured API credential",
                "machine_credential_required",
            )
        token = configuration.environ.get("HERDR_HARNESS_API_TOKEN", "")
        token_file = configuration.environ.get("HERDR_HARNESS_API_TOKEN_FILE", "")
        try:
            if token and token_file:
                raise SecretFileError("Herdr API credential is configured twice")
            if token_file:
                token = load_private_bearer_token_file(
                    str(Path(token_file).expanduser().absolute()), field="Herdr API token"
                )
            token = validate_bearer_token(token, field="Herdr API token", required=True)
        except SecretFileError as exc:
            raise CLIError("Selected machine API credential is unavailable or unsafe", "invalid_configuration") from exc
        origin = roster[machine].get("url") or configuration.environ.get("HERDR_HARNESS_URL")
        client = ControlClient(str(origin or ""), token, opener=self.opener)
        self.secrets.append(token)
        self._clients[machine] = client
        return client

    def require_data_machine(self) -> str:
        machine = self.args.machine
        if not machine:
            raise CLIError("Select a target machine explicitly with --machine", "machine_required")
        return machine

    def require_control_machine(self) -> str:
        machine = self.args.control_machine
        if not machine:
            raise CLIError(
                "Select the receiver host explicitly with --control-machine",
                "control_machine_required",
            )
        return machine

    def _augment_result(
        self, result: dict[str, Any], *, machine: str, server_id: Any
    ) -> dict[str, Any]:
        updated = dict(result)
        target = dict(updated.get("target") or {})
        existing_server = target.get("serverId")
        if existing_server is not None and server_id is not None and existing_server != server_id:
            raise CLIError("Discovery returned inconsistent server identity", "invalid_response", 3)
        if server_id is not None:
            target["serverId"] = server_id
        target["machineId"] = machine
        target["serverURL"] = self.client(machine).base_url
        updated["target"] = target
        updated["sourceMachine"] = machine
        return updated

    def _discover(self, machine: str, **query: Any) -> dict[str, Any]:
        result = self.client(machine).request("GET", "/api/v1/discovery", query=query)
        if not isinstance(result.get("results"), list):
            raise CLIError("Discovery response omitted results", "invalid_response", 3)
        server_id = result.get("serverId")
        results = []
        for item in result["results"]:
            if not isinstance(item, dict):
                raise CLIError("Discovery response contains an invalid result", "invalid_response", 3)
            results.append(self._augment_result(item, machine=machine, server_id=server_id))
        return {**result, "results": results}

    def require_color_capability(self, machine: str) -> None:
        """Fail closed when a companion cannot report tab colors.

        Color discovery is additive. A companion without ``chat-tab-colors-v1``
        would ignore or reject the new query parameters, so the CLI reports an
        explicit unsupported result instead of a false empty match.
        """

        unsupported = CLIError(
            chat_tab_colors_unsupported_message(),
            code="chat_tab_colors_unsupported",
            exit_code=5,
            details={"machineId": machine},
        )
        try:
            response = self.client(machine).request(
                "GET", "/api/v1/control/capabilities"
            )
        except CLIError as exc:
            if exc.code == "not_found" or exc.http_status in {404, 405, 501}:
                raise unsupported from exc
            raise
        if not supports_chat_tab_colors(response.get("capabilities")):
            raise unsupported

    def _check_target_machine(self, target: Mapping[str, Any], machine: str) -> None:
        target_machine = target.get("machineId")
        if target_machine is not None and target_machine != machine:
            raise CLIError("Target belongs to a different configured machine", "wrong_machine")
        target_url = target.get("serverURL")
        if target_url is not None:
            try:
                expected = self.client(machine).base_url
                actual = _validate_origin(target_url)
            except CLIError:
                raise CLIError("Target server URL is invalid", "invalid_target") from None
            if actual != expected:
                raise CLIError("Target belongs to a different server origin", "wrong_machine")

    def _inspect_target(self, machine: str, target: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
        self._check_target_machine(target, machine)
        response = self.client(machine).request(
            "POST", "/api/v1/control/inspect", {"target": target}, has_payload=True
        )
        result = response.get("result")
        if not isinstance(result, dict) or not isinstance(result.get("target"), dict):
            raise CLIError("Inspect response omitted an exact target", "invalid_response", 3)
        response_server_id = response.get("serverId") or target.get("serverId")
        inspected = self._augment_result(
            result, machine=machine, server_id=response_server_id
        )
        resolved = inspected["target"]
        for field in _TARGET_ID_FIELDS:
            if field in target and field in resolved and target[field] != resolved[field]:
                raise CLIError("Target identity changed during inspection", "stale_target", 5)
            if field in target and field not in resolved:
                raise CLIError("Target identity is no longer complete", "stale_target", 5)
        return resolved, {**response, "result": inspected}

    def _resolve_exact(self, machine: str, kind: str, identifier: str) -> dict[str, Any]:
        id_field = {"pane": "paneId", "workspace": "workspaceId", "tab": "tabId"}[kind]
        target, response = self._inspect_target(
            machine, {"kind": kind, id_field: identifier}
        )
        result = response.get("result")
        if (
            not isinstance(result, dict)
            or result.get("kind") != kind
            or target.get("kind") != kind
            or target.get(id_field) != identifier
        ):
            raise CLIError("Inspect returned a different resource identity", "stale_target", 5)
        return target

    def _target_from_args(self, args: argparse.Namespace, *, required: bool = False) -> dict[str, Any] | None:
        choices = [
            name
            for name in ("ref_file", "pane", "workspace", "tab")
            if getattr(args, name, None) is not None
        ]
        if len(choices) > 1:
            raise CLIError("Specify only one target reference", "invalid_arguments")
        if not choices:
            if required:
                raise CLIError("Specify an exact target", "target_required")
            return None
        machine = self.require_data_machine()
        choice = choices[0]
        if choice == "ref_file":
            target = _target_from_document(_read_json_file(args.ref_file, self.stdin))
            inspected, _ = self._inspect_target(machine, target)
            return inspected
        return self._resolve_exact(machine, choice, getattr(args, choice))

    def _load_parameters(self, path: str | None) -> dict[str, Any]:
        if path is None:
            return {}
        value = _read_json_file(path, self.stdin)
        if not isinstance(value, dict):
            raise CLIError("Parameters file must contain a JSON object", "invalid_parameters")
        return value

    def _merge_parameter(self, parameters: dict[str, Any], name: str, value: Any) -> None:
        if value is None:
            return
        if name in parameters and parameters[name] != value:
            raise CLIError(f"Typed {name} conflicts with the parameters file", "invalid_parameters")
        parameters[name] = value

    def _select_ui_client(self, machine: str, explicit: str | None) -> tuple[str, dict[str, Any]]:
        """Select explicit/hinted/sole-live, or one exact current PI session receiver.

        PI fallback is considered only when multiple receivers are live. It uses
        state.selection.sessionId on a known session-bearing kind; pane IDs,
        activity timestamps, host recency, and arbitrary ordering never qualify.
        """
        response = self.client(machine).request("GET", "/api/v1/ui/clients")
        clients = response.get("clients")
        if not isinstance(clients, list) or any(not isinstance(item, dict) for item in clients):
            raise CLIError("UI client response is invalid", "invalid_response", 3)
        live = [item for item in clients if item.get("online") is True and isinstance(item.get("clientId"), str)]
        selected_id = (
            explicit
            if explicit is not None
            else self.environ.get("HERDR_UI_CLIENT_ID") or None
        )
        if selected_id is not None:
            matches = [item for item in live if item.get("clientId") == selected_id]
            if len(matches) != 1:
                raise CLIError(
                    "Requested UI client is not uniquely available and online",
                    "ui_client_unavailable",
                    5,
                    details={"candidates": [item["clientId"] for item in live]},
                )
            return selected_id, matches[0]
        if len(live) == 1:
            return live[0]["clientId"], live[0]
        if len(live) > 1:
            session_id = _normalized_uuid(self.environ.get("PI_SESSION_ID"))
            if session_id is not None:
                session_matches = []
                for item in live:
                    state = item.get("state")
                    selection = state.get("selection") if isinstance(state, dict) else None
                    if (
                        isinstance(selection, dict)
                        and selection.get("kind") in _SESSION_SELECTION_KINDS
                        and _normalized_uuid(selection.get("sessionId")) == session_id
                    ):
                        session_matches.append(item)
                if len(session_matches) == 1:
                    selected = session_matches[0]
                    return selected["clientId"], selected
        raise CLIError(
            "Select a UI client explicitly; live receiver selection is ambiguous",
            "ambiguous_ui_client" if live else "ui_client_unavailable",
            5,
            details={"candidates": [item["clientId"] for item in live]},
        )

    def _ui_state(self, machine: str, client_id: str) -> dict[str, Any]:
        response = self.client(machine).request(
            "GET", f"/api/v1/ui/clients/{_quote(client_id)}/state"
        )
        client = response.get("client")
        state = client.get("state") if isinstance(client, dict) else None
        if not isinstance(state, dict):
            raise CLIError("UI client state is invalid", "invalid_response", 3)
        return response

    def _advertised_ui_action(
        self, client: Mapping[str, Any], action: str
    ) -> dict[str, Any]:
        actions = client.get("actions")
        if not isinstance(actions, list) or any(not isinstance(item, dict) for item in actions):
            raise CLIError("UI client action registry is invalid", "invalid_response", 3)
        matches = [item for item in actions if item.get("id") == action]
        if len(matches) != 1:
            raise CLIError("Requested UI action is not advertised", "action_not_found", 5)
        descriptor = matches[0]
        if not isinstance(descriptor.get("enabled"), bool):
            raise CLIError("Advertised UI action enabled state is invalid", "invalid_action_descriptor", 3)
        if descriptor["enabled"] is not True:
            raise CLIError(
                _safe_text(
                    descriptor.get("disabledReason"),
                    fallback="Requested UI action is currently disabled",
                ),
                "action_disabled",
                5,
            )
        target_kinds = descriptor.get("targetKinds")
        schema = descriptor.get("parameters")
        if (
            not isinstance(target_kinds, list)
            or any(not isinstance(item, str) or not item for item in target_kinds)
            or len(set(target_kinds)) != len(target_kinds)
        ):
            raise CLIError("Advertised UI action target kinds are invalid", "invalid_action_descriptor", 3)
        _validate_schema(schema)
        return descriptor

    def _validate_ui_action(
        self,
        descriptor: Mapping[str, Any],
        target: Mapping[str, Any] | None,
        parameters: Mapping[str, Any],
    ) -> None:
        target_kinds = descriptor["targetKinds"]
        if target is not None:
            if not target_kinds:
                raise CLIError(
                    "This UI action does not accept a target; use ui open for exact navigation",
                    "unsupported_target",
                )
            if target.get("kind") not in target_kinds:
                raise CLIError("Target kind is not supported by this UI action", "unsupported_target")
        elif target_kinds:
            raise CLIError("This UI action requires an exact target", "target_required")
        _validate_schema_value(parameters, descriptor["parameters"])

    def _wait_for_command(
        self,
        machine: str,
        request_id: str,
        initial: dict[str, Any],
        wait_seconds: int,
    ) -> Outcome:
        command = initial.get("command")
        if not isinstance(command, dict) or command.get("requestId") != request_id:
            raise CLIError("Herdr returned an invalid command receipt", "invalid_response", 3)
        status = command.get("status")
        if status in TERMINAL_COMMAND_STATUSES:
            return Outcome({**initial, "requestId": request_id}, 5 if status in FAILED_COMMAND_STATUSES else 0)
        if status not in {"accepted", "running"}:
            raise CLIError("Herdr returned an invalid command status", "invalid_response", 3)
        if wait_seconds == 0:
            return Outcome({**initial, "requestId": request_id}, 6)
        deadline = self.clock() + wait_seconds
        latest = initial
        while self.clock() < deadline:
            self.sleep(min(0.25, max(0.0, deadline - self.clock())))
            latest = self.client(machine).request(
                "GET", f"/api/v1/ui/commands/{_quote(request_id)}"
            )
            command = latest.get("command")
            if not isinstance(command, dict) or command.get("requestId") != request_id:
                raise CLIError("Herdr returned an invalid command receipt", "invalid_response", 3)
            polled_status = command.get("status")
            if polled_status in TERMINAL_COMMAND_STATUSES:
                return Outcome(
                    {**latest, "requestId": request_id},
                    5 if polled_status in FAILED_COMMAND_STATUSES else 0,
                )
            if polled_status not in {"accepted", "running"}:
                raise CLIError("Herdr returned an invalid command status", "invalid_response", 3)
        return Outcome({**latest, "requestId": request_id, "timedOut": True}, 6)

    def _ui_command(
        self,
        *,
        action: str,
        target: dict[str, Any] | None,
        parameters: dict[str, Any],
        args: argparse.Namespace,
    ) -> Outcome:
        request_id = _request_id(getattr(args, "request_id", None))
        try:
            machine = self.require_control_machine()
            client_id, public_client = self._select_ui_client(
                machine, getattr(args, "client", None)
            )
            descriptor = self._advertised_ui_action(public_client, action)
            expected_revision = getattr(args, "expected_revision", None)
            if getattr(args, "current", False):
                if target is not None:
                    raise CLIError("--current cannot be combined with an explicit target", "invalid_arguments")
                state_response = self._ui_state(machine, client_id)
                state = state_response["client"]["state"]
                revision = state.get("revision")
                if not isinstance(revision, int) or isinstance(revision, bool):
                    raise CLIError("Current UI state has no exact revision", "current_target_unavailable", 5)
                if expected_revision is not None and expected_revision != revision:
                    raise CLIError("Expected UI revision does not match current state", "revision_conflict", 4)
                if descriptor["targetKinds"]:
                    selection = state.get("selection")
                    if not isinstance(selection, dict):
                        raise CLIError("Current UI state has no exact selection", "current_target_unavailable", 5)
                    target = dict(selection)
                else:
                    target = None
                expected_revision = revision
            self._validate_ui_action(descriptor, target, parameters)
            payload: dict[str, Any] = {
                "requestId": request_id,
                "action": action,
                "parameters": parameters,
                "ttlSeconds": getattr(args, "ttl_seconds", 30),
            }
            if target is not None:
                payload["target"] = target
            if expected_revision is not None:
                payload["expectedRevision"] = expected_revision
            if getattr(args, "dry_run", False):
                return Outcome({"ok": True, "dryRun": True, "requestId": request_id, "command": payload})
            response = self.client(machine).request(
                "POST",
                f"/api/v1/ui/clients/{_quote(client_id)}/commands",
                payload,
                has_payload=True,
            )
            return self._wait_for_command(
                machine, request_id, response, getattr(args, "wait", 0)
            )
        except CLIError as exc:
            raise _attach_request_id(exc, request_id)

    def _resource_action(
        self,
        action: str,
        target: dict[str, Any] | None,
        parameters: dict[str, Any],
        args: argparse.Namespace,
    ) -> Outcome:
        machine = self.require_data_machine()
        request_id = _request_id(getattr(args, "request_id", None))
        payload: dict[str, Any] = {
            "requestId": request_id,
            "action": action,
            "parameters": parameters,
        }
        if target is not None:
            payload["target"] = target
        if getattr(args, "dry_run", False):
            payload["dryRun"] = True
        try:
            response = self.client(machine).request(
                "POST", "/api/v1/control/actions", payload, has_payload=True
            )
            operation = response.get("operation")
            if not isinstance(operation, dict) or operation.get("requestId") != request_id:
                raise CLIError("Herdr returned an invalid operation receipt", "invalid_response", 3)
            return Outcome({**response, "requestId": request_id}, _operation_exit(operation))
        except CLIError as exc:
            raise _attach_request_id(exc, request_id)

    def _created_target(self, outcome: Outcome) -> dict[str, Any] | None:
        operation = outcome.payload.get("operation")
        result = operation.get("result") if isinstance(operation, dict) else None
        target = result.get("target") if isinstance(result, dict) else None
        return dict(target) if isinstance(target, dict) else None

    def _create_and_optionally_open(
        self,
        action: str,
        target: dict[str, Any] | None,
        parameters: dict[str, Any],
        args: argparse.Namespace,
    ) -> Outcome:
        args.request_id = _request_id(getattr(args, "request_id", None))
        if getattr(args, "open", False):
            args.open_request_id = _request_id(
                getattr(args, "open_request_id", None)
                or _derived_open_request_id(args.request_id)
            )
        elif (
            getattr(args, "open_request_id", None) is not None
            or getattr(args, "client", None) is not None
            or getattr(args, "view", None) is not None
            or getattr(args, "wait", 0) != 0
            or getattr(args, "ttl_seconds", 30) != 30
        ):
            raise CLIError("UI open options require --open", "invalid_arguments")
        creation = self._resource_action(action, target, parameters, args)
        if not getattr(args, "open", False) or creation.exit_code != 0 or getattr(args, "dry_run", False):
            return creation
        created_target = self._created_target(creation)
        if created_target is not None:
            data_machine = self.require_data_machine()
            created_target.setdefault("machineId", data_machine)
            created_target.setdefault("serverURL", self.client(data_machine).base_url)
        if created_target is None:
            navigation = CLIError(
                "Creation completed without a navigable exact target",
                "created_target_unavailable",
                5,
            )
            return Outcome(
                {
                    "ok": False,
                    "requestId": creation.payload["requestId"],
                    "creation": creation.payload,
                    "navigation": navigation.payload(),
                },
                navigation.exit_code,
            )
        navigation_args = argparse.Namespace(
            control_machine=self.args.control_machine,
            client=getattr(args, "client", None),
            current=False,
            expected_revision=None,
            request_id=args.open_request_id,
            ttl_seconds=getattr(args, "ttl_seconds", 30),
            dry_run=False,
            wait=getattr(args, "wait", 0),
        )
        view = getattr(args, "view", None)
        open_parameters = {"view": view} if view else {}
        try:
            navigation = self._ui_command(
                action="ui.open",
                target=created_target,
                parameters=open_parameters,
                args=navigation_args,
            )
            return Outcome(
                {
                    "ok": navigation.exit_code == 0,
                    "requestId": creation.payload["requestId"],
                    "creation": creation.payload,
                    "navigation": navigation.payload,
                },
                navigation.exit_code,
            )
        except CLIError as exc:
            return Outcome(
                {
                    "ok": False,
                    "requestId": creation.payload["requestId"],
                    "creation": creation.payload,
                    "navigation": exc.payload(),
                },
                exc.exit_code,
            )

    def execute(self) -> Outcome:
        args = self.args
        if args.command == "machines":
            return Outcome({"ok": True, "machines": list(self.roster().values())})

        if args.command == "find":
            all_machines = args.all_machines or getattr(args, "find_all_machines", False)
            if all_machines and args.machine:
                raise CLIError("Use either --machine or --all-machines for discovery", "invalid_arguments")
            machines = sorted(self.roster()) if all_machines else [self.require_data_machine()]
            if not machines:
                raise CLIError("The configured machine roster is empty", "no_machines")
            color = getattr(args, "color", None)
            color_label = getattr(args, "color_label", None)
            color_client = normalized_color_client(getattr(args, "color_client", None))
            group_by = getattr(args, "group_by", None)
            color_requested = is_color_requested(
                color=color,
                color_label=color_label,
                color_client=color_client,
                group_by=group_by,
            )
            if color_requested and args.find_kind == "workspaces":
                raise CLIError(
                    "Tab color filters and grouping apply to chats, tabs, or all; "
                    "workspaces have no tab color metadata",
                    "invalid_arguments",
                )
            # Color behavior is tab-scoped, so a color request over chats or all
            # reads terminal discovery and never implies saved HUD ownership.
            chat_scope = (
                "terminal" if color_requested and args.find_kind in {"chats", "all"} else None
            )
            settings = {
                "kind": args.find_kind,
                "query": args.query,
                "ticket": args.ticket,
                "sort": args.sort,
                "limit": args.limit,
                "color": color,
                "colorLabel": color_label,
                "colorClientId": color_client,
                "groupBy": group_by,
                "machines": machines,
            }
            if args.cursor is not None and args.offset is not None:
                raise CLIError("Use --offset only for an initial discovery request", "invalid_arguments")
            if args.cursor is not None:
                offsets = _decode_cursor(args.cursor, settings=settings, machines=machines)
            else:
                initial_offset = args.offset or 0
                offsets = {machine: initial_offset for machine in machines}

            successes: dict[str, dict[str, Any]] = {}
            error_by_machine: dict[str, CLIError] = {}
            ready: list[str] = []
            # Resolve each credential serially before fan-out so client cache and
            # secret redaction state are not mutated concurrently.
            for machine in machines:
                try:
                    self.client(machine)
                    if color_requested:
                        self.require_color_capability(machine)
                    ready.append(machine)
                except CLIError as exc:
                    error_by_machine[machine] = exc
            if ready:
                color_query = color_query_parameters(
                    color=color, color_label=color_label, color_client=color_client
                )
                with ThreadPoolExecutor(max_workers=min(4, len(ready))) as executor:
                    futures = {
                        executor.submit(
                            self._discover,
                            machine,
                            kind=args.find_kind,
                            q=args.query,
                            ticket=args.ticket,
                            sort=args.sort,
                            limit=args.limit,
                            offset=offsets[machine],
                            chatScope=chat_scope,
                            **color_query,
                        ): machine
                        for machine in ready
                    }
                    for future in as_completed(futures):
                        machine = futures[future]
                        try:
                            successes[machine] = future.result()
                        except CLIError as exc:
                            error_by_machine[machine] = exc
            errors = [
                {
                    "machineId": machine,
                    "error": {
                        "code": error_by_machine[machine].code,
                        "message": error_by_machine[machine].message,
                    },
                }
                for machine in machines
                if machine in error_by_machine
            ]
            if not successes:
                if color_requested and all(
                    error_by_machine.get(machine) is not None
                    and error_by_machine[machine].code == "chat_tab_colors_unsupported"
                    for machine in machines
                ):
                    raise CLIError(
                        chat_tab_colors_unsupported_message(),
                        "chat_tab_colors_unsupported",
                        5,
                        details={"sources": errors},
                    )
                raise CLIError(
                    "Discovery failed on every selected machine",
                    "all_sources_failed",
                    3,
                    details={"sources": errors},
                )

            ranked: list[tuple[str, int, dict[str, Any]]] = []
            for machine in machines:
                response = successes.get(machine)
                if response is not None:
                    ranked.extend(
                        (machine, index, item)
                        for index, item in enumerate(response["results"])
                    )
            if args.sort == "updated":
                ranked.sort(
                    key=lambda row: (
                        _updated_timestamp(row[2].get("updatedAt")) is None,
                        -(_updated_timestamp(row[2].get("updatedAt")) or 0),
                        row[0],
                        row[1],
                        str(row[2].get("kind") or ""),
                        str(row[2].get("id") or ""),
                    )
                )
            else:
                ranked.sort(
                    key=lambda row: (
                        offsets[row[0]] + row[1],
                        row[0],
                        str(row[2].get("id") or ""),
                    )
                )
            emitted_rows = ranked[: args.limit]
            emitted_by_machine = Counter(row[0] for row in emitted_rows)
            merged = [row[2] for row in emitted_rows]
            next_offsets = dict(offsets)
            source_has_more: dict[str, bool] = {}
            sources: list[dict[str, Any]] = []
            for machine in machines:
                response = successes.get(machine)
                if response is None:
                    source_has_more[machine] = True
                    continue
                emitted = emitted_by_machine[machine]
                next_offsets[machine] = offsets[machine] + emitted
                source_has_more[machine] = (
                    emitted < len(response["results"])
                    or response.get("nextOffset") is not None
                )
                sources.append(
                    {
                        "machineId": machine,
                        "serverId": response.get("serverId"),
                        "consumed": emitted,
                        "nextOffset": next_offsets[machine]
                        if source_has_more[machine]
                        else None,
                        "coverage": response.get("coverage", {}),
                        "generatedAt": response.get("generatedAt"),
                    }
                )
            can_continue = any(source_has_more.values()) and all(
                offset <= 100000 for offset in next_offsets.values()
            )
            payload: dict[str, Any] = {
                "ok": True,
                "partial": bool(errors),
                "results": merged,
                "sources": sources,
                "sourceErrors": errors,
                "nextCursor": _encode_cursor(settings, next_offsets)
                if can_continue
                else None,
            }
            if group_by is not None:
                payload["groups"] = group_results(
                    merged,
                    group_by=group_by,
                    color=color,
                    color_label=color_label,
                    color_client=color_client,
                )
                payload["groupingScope"] = GROUPING_SCOPE
            return Outcome(payload)

        if args.command == "inspect":
            machine = self.require_data_machine()
            target = _target_from_document(_read_json_file(args.ref_file, self.stdin))
            _, response = self._inspect_target(machine, target)
            return Outcome(response)

        if args.command == "ui":
            machine = self.require_control_machine()
            if args.ui_command == "clients":
                return Outcome(self.client(machine).request("GET", "/api/v1/ui/clients"))
            if args.ui_command in {"state", "actions"}:
                client_id, _ = self._select_ui_client(machine, args.client)
                suffix = "state" if args.ui_command == "state" else "actions"
                return Outcome(
                    self.client(machine).request(
                        "GET", f"/api/v1/ui/clients/{_quote(client_id)}/{suffix}"
                    )
                )
            if args.ui_command == "receipt":
                request_id = _request_id(args.request_id)
                try:
                    response = self.client(machine).request(
                        "GET", f"/api/v1/ui/commands/{_quote(request_id)}"
                    )
                    return self._wait_for_command(
                        machine, request_id, response, args.wait
                    )
                except CLIError as exc:
                    raise _attach_request_id(exc, request_id)
            if args.ui_command == "open":
                if args.current and _has_target_arguments(args):
                    raise CLIError("--current cannot be combined with an explicit target", "invalid_arguments")
                target = None if args.current else self._target_from_args(args, required=True)
                parameters = self._load_parameters(args.parameters_file)
                self._merge_parameter(parameters, "view", args.view)
                return self._ui_command(action="ui.open", target=target, parameters=parameters, args=args)
            if args.ui_command == "segment":
                segment = args.segment_option or args.segment
                if not segment:
                    raise CLIError("Specify a segment", "invalid_arguments")
                if args.segment_option and args.segment:
                    raise CLIError("Specify the segment once", "invalid_arguments")
                if _has_target_arguments(args):
                    raise CLIError(
                        "ui segment does not accept an explicit target; use ui open",
                        "unsupported_target",
                    )
                parameters = self._load_parameters(args.parameters_file)
                self._merge_parameter(parameters, "segment", segment)
                return self._ui_command(action="ui.segment", target=None, parameters=parameters, args=args)
            if args.ui_command in {"back", "forward"}:
                parameters = self._load_parameters(args.parameters_file)
                return self._ui_command(
                    action="ui." + args.ui_command, target=None, parameters=parameters, args=args
                )
            if args.ui_command == "invoke":
                if args.current and _has_target_arguments(args):
                    raise CLIError("--current cannot be combined with an explicit target", "invalid_arguments")
                parameters = self._load_parameters(args.parameters_file)
                target = None if args.current else self._target_from_args(args)
                return self._ui_command(action=args.action, target=target, parameters=parameters, args=args)
            raise CLIError("Unknown UI command", "invalid_arguments")

        if args.command == "actions":
            ui_domain = getattr(args, "ui", False) or getattr(args, "client", None) is not None
            if args.actions_command in {"list", "describe"}:
                if ui_domain:
                    machine = self.require_control_machine()
                    client_id, _ = self._select_ui_client(machine, args.client)
                    response = self.client(machine).request(
                        "GET", f"/api/v1/ui/clients/{_quote(client_id)}/actions"
                    )
                    domain_name = "UI"
                else:
                    machine = self.require_data_machine()
                    response = self.client(machine).request("GET", "/api/v1/control/actions")
                    domain_name = "resource"
                if args.actions_command == "list":
                    return Outcome(response)
                actions = response.get("actions")
                matches = [
                    item
                    for item in actions or []
                    if isinstance(item, dict) and item.get("id") == args.action
                ]
                if len(matches) != 1:
                    raise CLIError(
                        f"Requested {domain_name} action is not advertised",
                        "action_not_found",
                        5,
                    )
                return Outcome({"ok": True, "action": matches[0]})
            if args.actions_command == "receipt":
                machine = self.require_data_machine()
                request_id = _request_id(args.request_id)
                response = self.client(machine).request(
                    "GET", f"/api/v1/control/operations/{_quote(request_id)}"
                )
                return Outcome({**response, "requestId": request_id}, _operation_exit(response.get("operation")))
            if args.actions_command == "invoke":
                if getattr(args, "current", False) and _has_target_arguments(args):
                    raise CLIError("--current cannot be combined with an explicit target", "invalid_arguments")
                target = None if getattr(args, "current", False) else self._target_from_args(args)
                parameters = self._load_parameters(args.parameters_file)
                if ui_domain:
                    return self._ui_command(
                        action=args.action,
                        target=target,
                        parameters=parameters,
                        args=args,
                    )
                if (
                    getattr(args, "current", False)
                    or getattr(args, "wait", 0) != 0
                    or getattr(args, "expected_revision", None) is not None
                ):
                    raise CLIError(
                        "--current, --wait, and --expected-revision require --ui or --client",
                        "invalid_arguments",
                    )
                return self._resource_action(args.action, target, parameters, args)

        if args.command == "workspace" and args.workspace_command == "create":
            parameters = {"name": args.name, "cwd": args.cwd}
            return self._create_and_optionally_open("workspace.create", None, parameters, args)

        if args.command == "tab" and args.tab_command == "create":
            target = self._resolve_exact(self.require_data_machine(), "workspace", args.workspace)
            parameters: dict[str, Any] = {}
            self._merge_parameter(parameters, "name", args.name)
            self._merge_parameter(parameters, "cwd", args.cwd)
            return self._create_and_optionally_open("tab.create", target, parameters, args)

        if args.command == "chat" and args.chat_command == "create":
            if bool(args.workspace) == bool(args.tab):
                raise CLIError("Specify exactly one of --workspace or --tab", "invalid_arguments")
            kind, identifier = ("workspace", args.workspace) if args.workspace else ("tab", args.tab)
            target = self._resolve_exact(self.require_data_machine(), kind, identifier)
            parameters: dict[str, Any] = {}
            self._merge_parameter(parameters, "name", args.name)
            self._merge_parameter(parameters, "cwd", args.cwd)
            parent_session_id = args.parent_session_id or self.environ.get("PI_SESSION_ID") or self.environ.get("HERDR_PI_PARENT_SESSION_ID")
            self._merge_parameter(parameters, "parentSessionId", parent_session_id)
            return self._create_and_optionally_open("chat.create", target, parameters, args)

        raise CLIError("Unknown command", "invalid_arguments")


def _add_target_arguments(parser: argparse.ArgumentParser) -> None:
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--ref-file", help="JSON target or discovery result; use - for stdin")
    target.add_argument("--pane")
    target.add_argument("--workspace")
    target.add_argument("--tab")


def _add_ui_mutation_arguments(parser: argparse.ArgumentParser, *, target: bool = False) -> None:
    if target:
        _add_target_arguments(parser)
    parser.add_argument("--current", action="store_true", help="Use the selected target and revision from fresh UI state")
    parser.add_argument("--client", help=_UI_CLIENT_HELP)
    parser.add_argument("--request-id")
    parser.add_argument("--expected-revision", type=_range_type(0, 2**63 - 1))
    parser.add_argument("--ttl-seconds", type=_range_type(1, 60), default=30)
    parser.add_argument("--wait", type=_range_type(0, 300), default=0)
    parser.add_argument("--dry-run", action="store_true", help="Print the command without enqueueing it")
    parser.add_argument("--parameters-file", help="JSON object; use - for stdin")


def _add_resource_mutation_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--request-id")
    parser.add_argument("--dry-run", action="store_true")


def _add_create_open_arguments(parser: argparse.ArgumentParser) -> None:
    _add_resource_mutation_arguments(parser)
    parser.add_argument(
        "--open",
        action="store_true",
        help="After creation, separately try UI open; creation remains completed if navigation fails",
    )
    parser.add_argument("--open-request-id")
    parser.add_argument("--client", help=_UI_CLIENT_HELP)
    parser.add_argument("--wait", type=_range_type(0, 300), default=0)
    parser.add_argument("--ttl-seconds", type=_range_type(1, 60), default=30)
    parser.add_argument("--view", choices=("chat", "terminal", "git", "skills"))


def _add_find_color_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--color",
        choices=CHAT_TAB_COLOR_CHOICES,
        help="Match one palette color, or none for explicitly unassigned tabs",
    )
    parser.add_argument(
        "--color-label",
        help="Match a published tab color label exactly (trimmed, case-insensitive)",
    )
    parser.add_argument(
        "--color-client",
        help="Restrict tab color matching to one publisher installation ID",
    )
    parser.add_argument(
        "--group-by",
        choices=GROUP_BY_CHOICES,
        help="Add a page-scoped color or label group projection of the returned rows",
    )


def _parser() -> JSONArgumentParser:
    parser = JSONArgumentParser(
        prog="herdr-control",
        description="Search and control an authenticated Herdr fleet. All output is JSON.",
    )
    parser.add_argument("--config", help="Private Herdr cluster TOML")
    parser.add_argument("--machine", help="Explicit data/resource machine")
    parser.add_argument("--all-machines", action="store_true", help="Federate a find command across the roster")
    parser.add_argument("--control-machine", help="Explicit host of the Mac UI receiver")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("machines", help="List configured public machine metadata")

    find = commands.add_parser("find", help="Search discoverable resources")
    find_kinds = find.add_subparsers(dest="find_kind", required=True)
    for kind in ("chats", "workspaces", "tabs", "all"):
        search = find_kinds.add_parser(kind)
        search.add_argument("--query", default="")
        search.add_argument("--ticket")
        search.add_argument("--sort", choices=("updated", "relevance"), default="updated")
        search.add_argument("--limit", type=_range_type(1, 100), default=20)
        search.add_argument(
            "--offset",
            type=_range_type(0, 100000),
            help="Initial per-source offset; for continuation use --cursor",
        )
        search.add_argument(
            "--cursor",
            help="Opaque continuation cursor returned by a previous matching query",
        )
        search.add_argument("--all-machines", dest="find_all_machines", action="store_true")
        _add_find_color_arguments(search)

    inspect = commands.add_parser("inspect", help="Revalidate one exact target")
    inspect.add_argument("--ref-file", required=True)

    ui = commands.add_parser(
        "ui",
        help="Inspect or command an enabled Mac receiver",
        description=(
            "Inspect or command a Mac receiver. Selection precedence is --client, "
            "HERDR_UI_CLIENT_ID, one live receiver, then one live receiver whose "
            "current selection exactly matches a valid PI_SESSION_ID."
        ),
    )
    ui_commands = ui.add_subparsers(dest="ui_command", required=True)
    ui_commands.add_parser("clients")
    for name in ("state", "actions"):
        command = ui_commands.add_parser(name)
        command.add_argument("--client", help=_UI_CLIENT_HELP)
    ui_receipt = ui_commands.add_parser(
        "receipt", help="Fetch a UI command receipt without selecting an online receiver"
    )
    ui_receipt.add_argument("request_id")
    ui_receipt.add_argument("--wait", type=_range_type(0, 300), default=0)
    open_command = ui_commands.add_parser("open")
    _add_ui_mutation_arguments(open_command, target=True)
    open_command.add_argument("--view", choices=("chat", "terminal", "git", "skills"))
    segment = ui_commands.add_parser("segment")
    _add_ui_mutation_arguments(segment, target=True)
    segment.add_argument(
        "segment",
        nargs="?",
        choices=("chat", "terminal", "git", "skills", "workspace", "active-work", "pr-review", "first-mate", "fleet", "attention", "activity"),
    )
    segment.add_argument(
        "--segment",
        dest="segment_option",
        choices=("chat", "terminal", "git", "skills", "workspace", "active-work", "pr-review", "first-mate", "fleet", "attention", "activity"),
    )
    for name in ("back", "forward"):
        command = ui_commands.add_parser(name)
        _add_ui_mutation_arguments(command)
    invoke = ui_commands.add_parser("invoke", help="Invoke one advertised typed UI action")
    invoke.add_argument("action")
    _add_ui_mutation_arguments(invoke, target=True)

    actions = commands.add_parser(
        "actions", help="Inspect or invoke resource actions (or UI actions with --ui/--client)"
    )
    action_commands = actions.add_subparsers(dest="actions_command", required=True)
    list_actions = action_commands.add_parser("list")
    list_actions.add_argument("--ui", action="store_true", help="Use the Mac UI action domain")
    list_actions.add_argument("--client", help=_UI_CLIENT_HELP + "; selects the UI action domain")
    describe = action_commands.add_parser("describe")
    describe.add_argument("action")
    describe.add_argument("--ui", action="store_true", help="Use the Mac UI action domain")
    describe.add_argument("--client", help=_UI_CLIENT_HELP + "; selects the UI action domain")
    receipt = action_commands.add_parser("receipt")
    receipt.add_argument("request_id")
    invoke_action = action_commands.add_parser("invoke")
    invoke_action.add_argument("action")
    _add_target_arguments(invoke_action)
    invoke_action.add_argument("--parameters-file")
    _add_resource_mutation_arguments(invoke_action)
    invoke_action.add_argument("--ui", action="store_true", help="Use the Mac UI action domain")
    invoke_action.add_argument("--client", help=_UI_CLIENT_HELP + "; selects the UI action domain")
    invoke_action.add_argument("--current", action="store_true")
    invoke_action.add_argument("--expected-revision", type=_range_type(0, 2**63 - 1))
    invoke_action.add_argument("--ttl-seconds", type=_range_type(1, 60), default=30)
    invoke_action.add_argument("--wait", type=_range_type(0, 300), default=0)

    workspace = commands.add_parser("workspace")
    workspace_commands = workspace.add_subparsers(dest="workspace_command", required=True)
    workspace_create = workspace_commands.add_parser("create")
    workspace_create.add_argument("--name", required=True)
    workspace_create.add_argument("--cwd", required=True)
    _add_create_open_arguments(workspace_create)

    tab = commands.add_parser("tab")
    tab_commands = tab.add_subparsers(dest="tab_command", required=True)
    tab_create = tab_commands.add_parser("create")
    tab_create.add_argument("--workspace", required=True)
    tab_create.add_argument("--name")
    tab_create.add_argument("--cwd")
    _add_create_open_arguments(tab_create)

    chat = commands.add_parser("chat")
    chat_commands = chat.add_subparsers(dest="chat_command", required=True)
    chat_create = chat_commands.add_parser("create")
    chat_target = chat_create.add_mutually_exclusive_group(required=True)
    chat_target.add_argument("--workspace")
    chat_target.add_argument("--tab")
    chat_create.add_argument("--name")
    chat_create.add_argument("--cwd")
    chat_create.add_argument("--parent-session-id")
    _add_create_open_arguments(chat_create)
    return parser


def main(
    argv: list[str] | None = None,
    *,
    environ: Mapping[str, str] | None = None,
    stdin: TextIO | None = None,
    stdout: TextIO | None = None,
    stderr: TextIO | None = None,
    opener: Callable[..., Any] | Any | None = None,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> int:
    environment = dict(os.environ if environ is None else environ)
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    stderr = stderr or sys.stderr
    runner: ControlCLI | None = None
    try:
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                args = _parser().parse_args(argv)
            except SystemExit as exc:
                return int(exc.code or 0)
        runner = ControlCLI(
            args,
            environ=environment,
            stdin=stdin,
            opener=opener,
            clock=clock,
            sleep=sleep,
        )
        outcome = runner.execute()
        payload = _redact(outcome.payload, runner.secrets)
        print(json.dumps(payload, ensure_ascii=False, allow_nan=False, sort_keys=True), file=stdout)
        return outcome.exit_code
    except CLIError as exc:
        secrets = runner.secrets if runner else []
        print(json.dumps(_redact(exc.payload(), secrets), ensure_ascii=False, sort_keys=True), file=stderr)
        return exc.exit_code
    except (ConfigurationError, SecretFileError):
        error = CLIError("Herdr configuration is unavailable or unsafe", "invalid_configuration")
        print(json.dumps(error.payload(), sort_keys=True), file=stderr)
        return error.exit_code
    except (OSError, ValueError, TypeError, KeyError):
        error = CLIError("Invalid input or unavailable input file", "invalid_input")
        print(json.dumps(error.payload(), sort_keys=True), file=stderr)
        return error.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
