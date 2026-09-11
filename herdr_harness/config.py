"""One private TOML configuration for a Herdr cluster.

File values are defaults: explicit process environment wins. Machine selection is
explicit, never inferred from hostnames. No network operations occur here.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import stat
import tomllib
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

from .secret_file import SecretFileError, load_private_file_bytes


class ConfigurationError(ValueError):
    """Invalid local configuration, with sensitive values excluded from messages."""


# Typed, discoverable conveniences. [environment] supports the remaining
# implementation knobs without adding a second deployment configuration file.
ENVIRONMENT_FIELDS = {
    "server": {
        "host": "HERDR_HARNESS_HOST", "port": "HERDR_HARNESS_PORT",
        "url": "HERDR_HARNESS_URL", "api_token": "HERDR_HARNESS_API_TOKEN",
        "socket_path": "HERDR_SOCKET_PATH", "session": "HERDR_SESSION",
        "state_dir": "HERDR_STATE_DIR", "attachments_dir": "HERDR_HARNESS_ATTACHMENTS_DIR",
        "terminal_command": "HERDR_BIN_PATH",
        "no_browser": "HERDR_HARNESS_NO_BROWSER",
    },
    "fleet": {
        "repository": "HERDR_FLEET_CATALOG_REPOSITORY",
        "checkout": "HERDR_FLEET_CATALOG_PATH", "state_path": "HERDR_FLEET_STATE_PATH",
        "allow_local_repository": "HERDR_FLEET_ALLOW_LOCAL_REPOSITORY",
        "command_timeout_seconds": "HERDR_FLEET_COMMAND_TIMEOUT_SECONDS",
    },
    "providers.cleanup": {
        "model": "HERDR_HARNESS_CLEANUP_MODEL", "thinking_level": "HERDR_HARNESS_CLEANUP_THINKING",
        "pi_binary": "HERDR_HARNESS_CLEANUP_PI_BIN",
    },
    "providers.activity": {
        "url": "HERDR_HARNESS_ACTIVITY_MODEL_URL", "model": "HERDR_HARNESS_ACTIVITY_MODEL_NAME",
        "debounce_seconds": "HERDR_HARNESS_ACTIVITY_DEBOUNCE_SECONDS",
    },
    "providers.summary": {
        "url": "HERDR_RESPONSE_AUDIO_SUMMARY_URL", "model": "HERDR_RESPONSE_AUDIO_SUMMARY_MODEL",
        "provider": "HERDR_RESPONSE_AUDIO_SUMMARY_PROVIDER", "api_key": "HERDR_RESPONSE_AUDIO_SUMMARY_API_KEY",
    },
    "providers.tts": {
        "url": "HERDR_RESPONSE_AUDIO_TTS_URL", "enabled": "HERDR_RESPONSE_AUDIO_ENABLED",
        "voice": "HERDR_RESPONSE_AUDIO_VOICE", "speed": "HERDR_RESPONSE_AUDIO_SPEED",
    },
    "providers.voice": {
        "provider": "HERDR_QUICK_VOICE_PROVIDER", "model": "HERDR_QUICK_VOICE_MODEL",
        "thinking_level": "HERDR_QUICK_VOICE_THINKING_LEVEL",
    },
    "providers.transcription": {
        "url": "HERDR_HARNESS_TRANSCRIPTION_URL", "token": "HERDR_HARNESS_TRANSCRIPTION_TOKEN",
        "backend": "HERDR_HARNESS_TRANSCRIPTION_BACKEND", "model": "HERDR_HARNESS_TRANSCRIPTION_MODEL",
    },
    "active_work": {
        "url": "HERDR_ACTIVE_WORK_BASE_URL", "token": "HERDR_ACTIVE_WORK_TOKEN",
        "manage_token": "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN",
        "ingest_token": "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN",
        "workflow_root": "BUZZ_WORKFLOW_ROOT", "store_path": "HERDR_HARNESS_ACTIVE_WORK_STORE_PATH",
        "workflows_dir": "HERDR_HARNESS_WORKFLOWS_DIR",
    },
    "remote_activity": {
        "url": "HERDR_HARNESS_REMOTE_ACTIVITY_URL", "prefix": "HERDR_HARNESS_REMOTE_ACTIVITY_PREFIX",
        "token": "HERDR_HARNESS_REMOTE_ACTIVITY_TOKEN", "poll_seconds": "HERDR_HARNESS_REMOTE_ACTIVITY_POLL_SECONDS",
    },
    "integrations": {
        "github_repository": "HERDR_REVIEW_REPOSITORY", "jira_url": "HERDR_JIRA_URL",
        "review_model": "HERDR_REVIEW_MODEL", "review_assessor": "HERDR_REVIEW_ASSESSOR",
        "review_state_dir": "HERDR_REVIEW_STATE_DIR", "review_exclude_globs": "HERDR_REVIEW_EXCLUDE_GLOBS",
    },
    "apple": {"app_ids": "HERDR_HARNESS_APP_IDS"},
    "push": {
        "key_id": "HERDR_APNS_KEY_ID", "team_id": "HERDR_APNS_TEAM_ID", "key_path": "HERDR_APNS_KEY_PATH",
        "topic": "HERDR_APNS_TOPIC", "environment": "HERDR_APNS_ENV",
    },
}
_MACHINE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
_ENV_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_ALLOWED_ROLES = {"local", "work", "development", "node"}


def _merge(base: Mapping[str, Any], override: Mapping[str, Any]) -> dict[str, Any]:
    result = copy.deepcopy(dict(base))
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = _merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def _section(data: Mapping[str, Any], name: str) -> dict[str, Any]:
    value: Any = data
    for part in name.split("."):
        value = value.get(part, {}) if isinstance(value, dict) else None
    if not isinstance(value, dict):
        raise ConfigurationError(f"{name} must be a TOML table")
    return value


def _scalar(value: Any, field: str, root: Path, environ: Mapping[str, str]) -> str:
    if isinstance(value, dict):
        if set(value) == {"env"} and isinstance(value["env"], str):
            if not _ENV_KEY.fullmatch(value["env"]) or value["env"] not in environ:
                raise ConfigurationError(f"{field} references an unset environment variable")
            return environ[value["env"]]
        if set(value) == {"file"} and isinstance(value["file"], str):
            path = Path(value["file"]).expanduser()
            if not path.is_absolute():
                path = root / path
            try:
                raw = load_private_file_bytes(str(path), field="configuration secret", maximum_bytes=65536)
                result = raw.decode("utf-8").strip()
            except (SecretFileError, OSError, ValueError, UnicodeError):
                raise ConfigurationError(f"{field} secret file is unreadable or not private") from None
            if not result or "\x00" in result or "\n" in result or "\r" in result:
                raise ConfigurationError(f"{field} secret must be one nonempty line")
            return result
        raise ConfigurationError(f"{field} must use exactly {{env = 'NAME'}} or {{file = 'path'}}")
    if isinstance(value, bool):
        return "true" if value else "false"
    if not isinstance(value, (str, int, float)) or "\x00" in str(value):
        raise ConfigurationError(f"{field} must be a string, number, boolean, or secret reference")
    return str(value)


def _machine_records(data: Mapping[str, Any]) -> list[dict[str, str]]:
    result = []
    for key, settings in _section(data, "machines").items():
        if not _MACHINE_ID.fullmatch(key) or not isinstance(settings, dict):
            raise ConfigurationError("machines must contain named TOML tables with simple machine IDs")
        role = settings.get("role", "node")
        if not isinstance(role, str) or role not in _ALLOWED_ROLES:
            raise ConfigurationError(f"machines.{key}.role must be local, work, development, or node")
        name = settings.get("name", settings.get("label", key))
        url = settings.get("url", "")
        if not isinstance(name, str) or not name.strip() or len(name) > 128:
            raise ConfigurationError(f"machines.{key}.name must be a nonempty short string")
        if not isinstance(url, str):
            raise ConfigurationError(f"machines.{key}.url must be a URL string")
        if url:
            try:
                parsed = urllib.parse.urlsplit(url)
                valid = parsed.scheme in {"http", "https"} and bool(parsed.hostname) and not (
                    parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in {"", "/"}
                ) and (parsed.port is None or 1 <= parsed.port <= 65535)
            except ValueError:
                valid = False
            if not valid:
                raise ConfigurationError(f"machines.{key}.url must be an HTTP(S) origin without credentials")
        result.append({"id": key, "name": name, "url": url.rstrip("/"), "role": role})
    return result


@dataclass(repr=False)
class Configuration:
    path: Path | None
    machine: str | None
    data: dict[str, Any]
    environ: dict[str, str]
    derived_urls: frozenset[str] = field(default_factory=frozenset)

    def section(self, name: str) -> dict[str, Any]:
        return copy.deepcopy(_section(self.data, name))

    def public_machines(self) -> list[dict[str, str]]:
        """Only allowlisted connection metadata; never tokens or per-machine settings."""
        return _machine_records(self.data)


def server_origin(host: str, port: str | int) -> str:
    """A local client origin for a server binding, including wildcard bindings."""
    host = str(host or "127.0.0.1").strip()
    if any(char.isspace() for char in host) or any(char in host for char in "/?#@"):
        raise ConfigurationError("server.host must be a host name or IP address without a URL scheme")
    if host == "0.0.0.0":
        host = "127.0.0.1"
    elif host in {"::", "[::]"}:
        host = "::1"
    if ":" in host and not host.startswith("["):
        host = "[" + host + "]"
    return f"http://{host}:{port}"


def load_configuration(
    path: str | Path | None = None,
    machine: str | None = None,
    environ: Mapping[str, str] | None = None,
    *,
    resolve_secrets: bool = True,
) -> Configuration:
    environment = dict(os.environ if environ is None else environ)
    explicit = path or environment.get("HERDR_CONFIG")
    if explicit:
        selected_path = Path(explicit).expanduser().resolve()
        if not selected_path.is_file():
            raise ConfigurationError("The explicitly selected Herdr configuration file does not exist")
    else:
        home = Path(environment.get("HOME") or Path.home())
        candidates = [Path.cwd() / "config.local.toml", home / ".config/herdr-companion/config.toml"]
        selected_path = next((candidate.resolve() for candidate in candidates if candidate.is_file()), None)
    data: dict[str, Any] = {}
    if selected_path is not None:
        try:
            if selected_path.stat().st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                raise ConfigurationError("Herdr configuration must not be writable by other users (use chmod 600)")
            if selected_path.stat().st_size > 1024 * 1024:
                raise ConfigurationError("Herdr configuration exceeds the 1 MiB size limit")
            with selected_path.open("rb") as handle:
                data = tomllib.load(handle)
        except (OSError, tomllib.TOMLDecodeError):
            raise ConfigurationError("Herdr configuration could not be read as valid TOML") from None
        allowed_sections = {"version", "machine", "server", "fleet", "providers", "active_work", "remote_activity", "integrations", "push", "apple", "deployment", "environment", "machines"}
        if set(data) - allowed_sections:
            raise ConfigurationError("Unrecognized top-level configuration section; use the Herdr cluster configuration sample")
        if data.get("version", 1) != 1:
            raise ConfigurationError("Unsupported Herdr configuration version")
    # Validate the entire roster, even when another machine is selected.
    _machine_records(data)
    selected = machine or environment.get("HERDR_MACHINE") or data.get("machine")
    if selected is not None:
        if not isinstance(selected, str) or selected not in _section(data, "machines"):
            raise ConfigurationError("Selected machine is not defined in [machines]")
        data = _merge(data, data["machines"][selected])
    if not resolve_secrets:
        return Configuration(selected_path, selected, data, environment)
    root = selected_path.parent if selected_path else Path.cwd()
    resolved: dict[str, str] = {}
    for section, fields in ENVIRONMENT_FIELDS.items():
        values = _section(data, section)
        for key, name in fields.items():
            if name in environment or name + "_FILE" in environment:
                continue
            if key in values and key + "_file" in values:
                raise ConfigurationError(f"{section}.{key} and {key}_file cannot both be set")
            value = values.get(key)
            if key + "_file" in values:
                value = {"file": values[key + "_file"]}
            if value is not None:
                resolved[name] = _scalar(value, f"{section}.{key}", root, environment)
                if key.endswith(("_path", "_dir", "_root")) or key in {"checkout", "socket_path", "review_assessor"}:
                    raw_path = resolved[name]
                    if raw_path:
                        if raw_path == "~" or raw_path.startswith("~/"):
                            raw_path = str(Path(environment.get("HOME") or Path.home())) + raw_path[1:]
                        expanded = Path(raw_path).expanduser()
                        resolved[name] = str(expanded if expanded.is_absolute() else root / expanded)
    for name, value in _section(data, "environment").items():
        if not _ENV_KEY.fullmatch(name):
            raise ConfigurationError("environment contains an invalid variable name")
        if name not in environment:
            resolved[name] = _scalar(value, f"environment.{name}", root, environment)
    destinations = _section(data, "fleet.skill_destinations")
    if destinations and "HERDR_FLEET_SKILL_DESTINATIONS" not in environment:
        normalized_destinations = {}
        for destination, value in destinations.items():
            if not isinstance(value, str) or not value.strip() or "\x00" in value:
                raise ConfigurationError("fleet.skill_destinations values must be nonempty path strings")
            if value.startswith("~/"):
                value = str(Path(environment.get("HOME") or Path.home()) / value[2:])
            path_value = Path(value)
            normalized_destinations[destination] = str(path_value if path_value.is_absolute() else root / path_value)
        resolved["HERDR_FLEET_SKILL_DESTINATIONS"] = json.dumps(normalized_destinations)
    apple = _section(data, "apple")
    if apple.get("team_id") and "HERDR_HARNESS_APP_IDS" not in resolved:
        bundle_prefix = apple.get("bundle_prefix", "org.herdr.companion")
        bundle_id = apple.get("ios_bundle_id") or f"{bundle_prefix}.ios"
        resolved["HERDR_HARNESS_APP_IDS"] = f"{apple['team_id']}.{bundle_id}"
    resolved.update(environment)
    # Both clients consume the resolved server credential unless an explicit
    # client-specific credential was selected by the operator.
    for suffix in ("", "_FILE"):
        manage = "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN" + suffix
        ingest = "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN" + suffix
        if manage in resolved:
            resolved.setdefault("HERDR_ACTIVE_WORK_MANAGE_TOKEN" + suffix, resolved[manage])
        if ingest in resolved and "HERDR_ACTIVE_WORK_TOKEN" not in resolved and "HERDR_ACTIVE_WORK_TOKEN_FILE" not in resolved:
            resolved["HERDR_ACTIVE_WORK_TOKEN" + suffix] = resolved[ingest]
    if "HERDR_HARNESS_PORT" in resolved:
        try:
            valid_port = 1 <= int(resolved["HERDR_HARNESS_PORT"]) <= 65535
        except (TypeError, ValueError):
            valid_port = False
        if not valid_port:
            raise ConfigurationError("server.port must be an integer between 1 and 65535")
    derived_urls = set()
    if not resolved.get("HERDR_HARNESS_URL"):
        resolved["HERDR_HARNESS_URL"] = server_origin(resolved.get("HERDR_HARNESS_HOST", "127.0.0.1"), resolved.get("HERDR_HARNESS_PORT", "9092"))
        derived_urls.add("HERDR_HARNESS_URL")
    if not resolved.get("HERDR_ACTIVE_WORK_BASE_URL"):
        resolved["HERDR_ACTIVE_WORK_BASE_URL"] = resolved["HERDR_HARNESS_URL"]
        if "HERDR_HARNESS_URL" in derived_urls:
            derived_urls.add("HERDR_ACTIVE_WORK_BASE_URL")
    if selected_path is not None:
        resolved["HERDR_CONFIG"] = str(selected_path)
    if selected:
        resolved["HERDR_MACHINE"] = selected
    state_dir = resolved.setdefault("HERDR_STATE_DIR", str(Path(environment.get("HOME") or Path.home()) / ".local/share/herdr-companion"))
    if state_dir:
        state = Path(state_dir).expanduser()
        if not state.is_absolute():
            state = root / state
        paths = {
            "ALERT_STORE_PATH": "alerts.json", "STAR_STORE_PATH": "stars.json",
            "PI_STORE_PATH": "pi-semantic.sqlite3", "ACTIVE_WORK_STORE_PATH": "active-work.sqlite3",
            "CLEANUP_RUNS_ROOT": "cleanup/runs", "AGENT_RUNS_ROOT": "agent-runs",
            "ATTACHMENTS_DIR": "uploads", "NOTES_STORE_PATH": "notes.sqlite3",
            "PANE_SEEN_STORE_PATH": "pane-first-seen.json", "SESSION_LABEL_STORE_PATH": "session-labels.json",
            "PANE_LIFECYCLE_STORE_PATH": "pane-lifecycle.sqlite3",
            "RESULT_ARTIFACTS_ROOT": "result-artifacts", "PUSH_STORE_PATH": "push-devices.json",
            "WORKFLOWS_DIR": "workflows",
        }
        for variable, suffix in paths.items():
            resolved.setdefault("HERDR_HARNESS_" + variable, str(state / suffix))
        resolved.setdefault("HERDR_QUICK_VOICE_STORE_PATH", str(state / "quick-voice"))
        resolved.setdefault("HERDR_FLEET_STATE_PATH", str(state / "fleet/state.json"))
        resolved.setdefault("HERDR_FLEET_QUARANTINE_PATH", str(state / "fleet/quarantine"))
    return Configuration(selected_path, selected, data, resolved, frozenset(derived_urls))


def configure_environment(argv: list[str] | None = None) -> Configuration:
    """Load shared flags before an entry point parses environment-based defaults."""
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--config")
    parser.add_argument("--machine")
    args, _ = parser.parse_known_args(argv)
    configuration = load_configuration(args.config, args.machine)
    os.environ.update(configuration.environ)
    return configuration
