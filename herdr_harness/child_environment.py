"""Limit inherited Herdr settings to the capabilities an agent actually uses.

Ordinary process variables (including configured model-provider credentials) are
preserved. Server administration, cluster peer, APNs, transcription, and fleet
settings are not propagated into agent processes.
"""
from __future__ import annotations

from typing import Mapping

_AGENT_SETTINGS = frozenset({
    "HERDR_HARNESS_API_TOKEN", "HERDR_HARNESS_API_TOKEN_FILE",
    "HERDR_HARNESS_URL", "HERDR_HARNESS_BASE_URL", "HERDR_NOTES_BASE_URL",
    "HERDR_SEND_TO_HERDR_URL", "HERDR_SOCKET_PATH", "HERDR_SESSION", "HERDR_CONFIG_PATH",
    "HERDR_PANE_ID", "HERDR_AGENT_RUN_ID", "HERDR_AGENT_RUN_MODE",
    "HERDR_PI_SEMANTIC_MAX_QUEUE_RECORDS", "HERDR_PI_SEMANTIC_MAX_QUEUE_BYTES",
    "HERDR_PI_SEMANTIC_MAX_REPLAY_RECORDS", "HERDR_PI_SEMANTIC_MAX_REPLAY_BYTES",
})


def agent_environment(environment: Mapping[str, str], *, integration: bool = True) -> dict[str, str]:
    """Return a new environment without exporting private cluster configuration.

    integration=False is appropriate for read-only model discovery, which needs
    provider authentication but never a Herdr control API token.
    """
    result = {
        name: value for name, value in environment.items()
        if not name.startswith("HERDR_") or (integration and name in _AGENT_SETTINGS)
    }
    if integration and not result.get("HERDR_HARNESS_URL"):
        port = environment.get("HERDR_HARNESS_PORT", "9092")
        try:
            normalized = int(port)
        except (TypeError, ValueError) as exc:
            raise ValueError("Configured Herdr port is invalid") from exc
        if not 1 <= normalized <= 65535:
            raise ValueError("Configured Herdr port is invalid")
        result["HERDR_HARNESS_URL"] = f"http://127.0.0.1:{normalized}"
    return result
