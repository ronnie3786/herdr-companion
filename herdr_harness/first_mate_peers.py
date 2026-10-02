"""The lead First Mate's reach into the other machines of this companion's roster.

A peer is another machine in the private configuration's ``[machines]`` roster
whose own API credential is configured on this host: exactly the machines
``herdr-control --machine <id>`` reaches from here. The lead asks a peer's
``POST /api/v1/first-mate/lead/remote`` to run the same lead action against
that machine's own features (``first-mate-lead-peers-v1``).

Credentials stay in the private configuration and are never logged or
returned. Connection failures use a short outage backoff. Slow requests and
server errors stay distinguishable from a confirmed connection failure.
"""
from __future__ import annotations

import math
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Mapping

from .alerts import utc_now
from .config import load_configuration
from .control_cli import CLIError, _configuration_environment, machine_client
from .first_mate_store import FirstMateError

CAPABILITY = "first-mate-lead-peers-v1"
REMOTE_PATH = "/api/v1/first-mate/lead/remote"
TIMEOUT_SECONDS = 60.0
OFFLINE_SECONDS = 30.0
ROSTER_SECONDS = 300.0
# A slow operation, HTTP error or invalid response does not prove a machine
# is offline. Only connection failures enter the short outage backoff.
_UNREACHABLE = {"herdr_unavailable"}


def _request_timeout(environ: Mapping[str, str]) -> float:
    try:
        value = float(environ.get("HERDR_FIRST_MATE_PEER_TIMEOUT_SECONDS", TIMEOUT_SECONDS))
    except (TypeError, ValueError):
        return TIMEOUT_SECONDS
    return min(300.0, max(15.0, value)) if math.isfinite(value) else TIMEOUT_SECONDS


@dataclass(frozen=True)
class Peer:
    id: str
    name: str
    url: str

    def public(self) -> dict:
        return {"id": self.id, "name": self.name, "url": self.url}


class PeerDirectory:
    """This machine's identity and the peers its lead reaches, with their health."""

    def __init__(self, environ: Mapping[str, str], *, opener: Callable[..., Any] | Any | None = None,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self.environ = dict(environ)
        self.timeout = _request_timeout(self.environ)
        self.opener = opener
        self.clock = clock
        self._lock = threading.Lock()
        self._loaded_at: float | None = None
        self._local: dict | None = None
        self._peers: list[Peer] = []
        self._clients: dict[str, Any] = {}
        self._offline_until: dict[str, float] = {}
        self._last_seen: dict[str, str] = {}

    def _load(self) -> None:
        with self._lock:
            if self._loaded_at is not None and self.clock() - self._loaded_at < ROSTER_SECONDS:
                return
            self._loaded_at = self.clock()
            config, local = self.environ.get("HERDR_CONFIG"), self.environ.get("HERDR_MACHINE")
            peers, clients, identity = [], {}, None
            if config and local:
                try:
                    roster = {record["id"]: record for record in load_configuration(
                        config, environ=_configuration_environment(self.environ),
                        resolve_secrets=False).public_machines()}
                except (OSError, ValueError):
                    roster = {}
                if local in roster:
                    identity = {"id": local, "name": roster[local].get("name") or local}
                for machine_id, record in roster.items():
                    if machine_id == local or not record.get("url"):
                        continue
                    try:
                        clients[machine_id] = machine_client(config, machine_id, self.environ, roster=roster,
                                                             opener=self.opener, timeout=self.timeout)
                    except CLIError:
                        continue  # No credential for it on this host: not a peer.
                    peers.append(Peer(machine_id, record.get("name") or machine_id, record["url"]))
            self._local, self._peers, self._clients = identity, peers, clients

    def local(self) -> dict | None:
        """This machine's roster ID and name, when the configuration names it."""
        self._load()
        return self._local

    def peers(self) -> list[Peer]:
        self._load()
        return list(self._peers)

    def peer(self, machine_id: str) -> Peer | None:
        return next((peer for peer in self.peers() if peer.id == machine_id), None)

    def offline(self, machine_id: str) -> bool:
        with self._lock:
            return self._offline_until.get(machine_id, 0.0) > self.clock()

    def last_seen(self, machine_id: str) -> str | None:
        with self._lock:
            return self._last_seen.get(machine_id)

    def call(self, machine_id: str, action: str, params: Mapping[str, Any], *, request_id: str,
             lead: Mapping[str, str]) -> Any:
        """Runs one lead action on a peer and returns its result. Blocking: the
        runtime calls it off its loop."""
        peer = self.peer(machine_id)
        client = self._clients.get(machine_id)
        if peer is None or client is None:
            raise FirstMateError("Name a machine from fm_fleet", code="unknown_machine", status=400)
        if self.offline(machine_id):
            raise FirstMateError(f"{peer.name} is offline right now", code="machine_offline", status=503)
        try:
            response = client.request("POST", REMOTE_PATH, {
                "action": action, "params": dict(params), "request_id": request_id, "lead": dict(lead),
            }, has_payload=True)
        except CLIError as exc:
            if exc.http_status in {404, 405, 501}:
                raise FirstMateError(f"{peer.name}'s companion needs an update before First Mate can reach it",
                                     code="machine_unsupported", status=503) from None
            if exc.code == "herdr_timeout" or exc.http_status in {408, 504}:
                raise FirstMateError(
                    f"{peer.name}'s request timed out; its activity is currently unknown. "
                    "If this was a write, inspect its receipt before sending it again.",
                    code="machine_timeout", status=504) from None
            if exc.code in _UNREACHABLE and exc.http_status is None:
                with self._lock:
                    self._offline_until[machine_id] = self.clock() + OFFLINE_SECONDS
                raise FirstMateError(f"{peer.name} is offline right now", code="machine_offline", status=503) from None
            raise FirstMateError(exc.message, code=exc.code, status=exc.http_status or 409) from None
        with self._lock:
            self._offline_until.pop(machine_id, None)
            self._last_seen[machine_id] = utc_now()
        return response.get("result")
