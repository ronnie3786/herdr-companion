"""Owner-private connection discovery for Pi sessions inside the terminal runtime.

This is generated runtime state, projected from the companion's one configuration
file. It contains only the authenticated API connection for one terminal socket.
"""
from __future__ import annotations

import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import secrets
import stat
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Mapping

from .secret_file import load_private_file_bytes, validate_bearer_token

MAX_CONNECTION_BYTES = 16 * 1024


def normalized_socket_path(value: str, *, home: str | None = None) -> str:
    if not isinstance(value, str) or not value or len(value) > 4096 or "\x00" in value:
        raise ValueError("Herdr socket path is invalid")
    if value.startswith("~/"):
        value = str(Path(home or Path.home()) / value[2:])
    return os.path.abspath(value)


def connection_path(socket_path: str, environ: Mapping[str, str]) -> Path:
    home = str(environ.get("HOME") or Path.home())
    socket = normalized_socket_path(socket_path, home=home)
    digest = hashlib.sha256(socket.encode("utf-8")).hexdigest()
    return Path(home) / ".local/share/herdr-companion/connections" / (digest + ".json")


def bound_origin(host: str, port: int) -> str:
    """Describe the address actually bound, using loopback for wildcard binds."""
    value = "127.0.0.1" if host in {"", "0.0.0.0"} else ("::1" if host == "::" else host)
    try:
        address = ipaddress.ip_address(value)
        value = f"[{address}]" if address.version == 6 else str(address)
    except ValueError:
        if value != "localhost":
            raise ValueError("Bound Herdr address must be an IP address or localhost") from None
    if not 1 <= port <= 65535:
        raise ValueError("Bound Herdr port is invalid")
    return f"http://{value}:{port}"


@contextmanager
def _locked_directory(path: Path):
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    lock = -1
    try:
        metadata = os.fstat(directory)
        if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o077:
            raise ValueError("Herdr connection directory must belong to the current user and be private")
        lock = os.open(path.stem + ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        metadata = os.fstat(lock)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o077:
            raise ValueError("Herdr connection lock must be an owner-private regular file")
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield directory
    finally:
        if lock >= 0:
            os.close(lock)
        os.close(directory)


@dataclass(repr=False)
class ConnectionRegistration:
    path: Path
    instance_id: str

    def close(self) -> None:
        """A stopped server cannot remove a newer server's discovery record."""
        try:
            with _locked_directory(self.path) as directory:
                raw = load_private_file_bytes(str(self.path), field="Herdr connection", maximum_bytes=MAX_CONNECTION_BYTES)
                data = json.loads(raw)
                if isinstance(data, dict) and data.get("instance_id") == self.instance_id:
                    os.unlink(self.path.name, dir_fd=directory)
        except (OSError, ValueError):
            pass


def publish_connection(*, socket_path: str, host: str, port: int, environ: Mapping[str, str]) -> ConnectionRegistration | None:
    token = validate_bearer_token(environ.get("HERDR_HARNESS_API_TOKEN"), field="Herdr API token")
    if not token:
        return None
    normalized = normalized_socket_path(socket_path, home=environ.get("HOME"))
    path = connection_path(normalized, environ)
    instance = secrets.token_hex(16)
    data = json.dumps({
        "version": 1,
        "instance_id": instance,
        "socket_path": normalized,
        "url": bound_origin(host, port),
        "token": token,
    }, separators=(",", ":")).encode("utf-8")
    if len(data) > MAX_CONNECTION_BYTES:
        raise ValueError("Herdr connection exceeds its size limit")
    with _locked_directory(path) as directory:
        temporary = path.stem + "." + secrets.token_hex(16) + ".tmp"
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path.name, src_dir_fd=directory, dst_dir_fd=directory)
        finally:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
    return ConnectionRegistration(path, instance)


def connection_environment(environment: Mapping[str, str]) -> dict[str, str]:
    """Resolve a native Pi session's exact companion without reading cluster secrets."""
    result = dict(environment)
    socket = environment.get("HERDR_SOCKET_PATH")
    if not socket or "HERDR_HARNESS_API_TOKEN" in environment or environment.get("HERDR_HARNESS_API_TOKEN_FILE"):
        return result
    try:
        normalized = normalized_socket_path(socket, home=environment.get("HOME"))
        path = connection_path(normalized, environment)
        payload = json.loads(load_private_file_bytes(str(path), field="Herdr connection", maximum_bytes=MAX_CONNECTION_BYTES))
        if not isinstance(payload, dict) or payload.get("version") != 1 or payload.get("socket_path") != normalized:
            raise ValueError()
        import urllib.parse
        parsed = urllib.parse.urlsplit(payload.get("url", ""))
        if parsed.scheme != "http" or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path:
            raise ValueError()
        # Validate against the exact format written by bound_origin, including
        # literal bind addresses and a concrete port.
        if parsed.port is None or bound_origin(parsed.hostname or "", parsed.port) != payload["url"]:
            raise ValueError()
        token = validate_bearer_token(payload.get("token"), field="Herdr API token", required=True)
    except (OSError, ValueError, TypeError):
        raise ValueError("The configured Herdr companion connection for this terminal is unavailable") from None
    result.setdefault("HERDR_HARNESS_URL", payload["url"])
    result["HERDR_HARNESS_API_TOKEN"] = token
    return result
