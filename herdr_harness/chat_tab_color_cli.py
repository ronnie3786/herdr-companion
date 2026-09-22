"""Shared read-only helpers for tab-color discovery, capability, and grouping.

``herdr-control find`` and ``herdr-hud-chats --scope terminal`` project the same
companion discovery data, so they use the same palette choices, query parameter
names, capability check, and page-scoped grouping shape. This module never
assigns a color or renames a label: it only reshapes values the companion
already returned. Saved HUD chats are never joined to terminal tabs here; rows
without tab metadata stay in an explicit ``notApplicable`` group.
"""
from __future__ import annotations

from typing import Any, Optional

from .chat_tab_colors import (
    CHAT_TAB_COLOR_NONE,
    CHAT_TAB_PALETTE,
    entry_matches,
)
from .control_validation import ControlError, client_id as control_client_id


CHAT_TAB_COLORS_CAPABILITY = "chat-tab-colors-v1"
CHAT_TAB_COLOR_CHOICES = (*CHAT_TAB_PALETTE, CHAT_TAB_COLOR_NONE)
GROUP_BY_CHOICES = ("color", "label")
GROUPING_SCOPE = "page"

# Group ordering is status-first so assigned colors and labels are easy to
# scan, then publisher installation, then normalized key.
_GROUP_STATUS_ORDER = {
    "assigned": 0,
    "unassigned": 1,
    "unavailable": 2,
    "notApplicable": 3,
}
_UNKNOWN_KEY = "unknown"
_UNAVAILABLE_KEY = "unavailable"


def supports_chat_tab_colors(capabilities: Any) -> bool:
    """Return whether a companion capability list includes color discovery."""

    return isinstance(capabilities, list) and CHAT_TAB_COLORS_CAPABILITY in capabilities


def chat_tab_colors_unsupported_message() -> str:
    return (
        "Selected companion does not advertise chat-tab-colors-v1; update the "
        "companion server before filtering or grouping by tab color"
    )


def is_color_requested(
    *,
    color: Optional[str] = None,
    color_label: Optional[str] = None,
    color_client: Optional[str] = None,
    group_by: Optional[str] = None,
) -> bool:
    """Return whether any color discovery behavior was requested."""

    return any(
        value is not None
        for value in (color, color_label, color_client, group_by)
    )


def normalized_color_client(value: Optional[str]) -> Optional[str]:
    """Normalize a publisher ID exactly as the discovery contract does.

    The companion accepts a ``ui_`` installation ID case-insensitively and
    lowercases its UUID. Local grouping must use the same value the server
    used, so a mixed-case ``--color-client`` still matches its entries. A value
    the contract rejects is forwarded unchanged for the server to report.
    """

    if value is None:
        return None
    try:
        return control_client_id(value)
    except ControlError:
        return value


def color_query_parameters(
    *,
    color: Optional[str] = None,
    color_label: Optional[str] = None,
    color_client: Optional[str] = None,
) -> dict[str, str]:
    """Build the additive discovery query parameters that were supplied."""

    parameters: dict[str, str] = {}
    if color is not None:
        parameters["color"] = color
    if color_label is not None:
        parameters["colorLabel"] = color_label
    if color_client is not None:
        parameters["colorClientId"] = normalized_color_client(color_client)
    return parameters


def normalized_label(value: Any) -> Optional[str]:
    """Normalize a published label to its trimmed case-insensitive key."""

    if not isinstance(value, str):
        return None
    return value.strip().casefold() or None


def group_results(
    results: Any,
    *,
    group_by: str,
    color: Optional[str] = None,
    color_label: Optional[str] = None,
    color_client: Optional[str] = None,
) -> list[dict]:
    """Project returned page rows into page-scoped color or label groups.

    The projection is additive: ``results`` stays flat and unchanged. Each
    group is separated by publisher ``clientId`` and carries its own
    page-scoped member list, so a label shared by several colors stays one
    label group within that publisher while different publishers are never
    merged. ``unassigned``, ``unavailable``, and rows without tab metadata stay
    distinct, and every member keeps the original result object plus the exact
    publisher entry that placed it in the group. Group counts are page-scoped,
    not complete totals.
    """

    if group_by not in GROUP_BY_CHOICES:
        raise ValueError("group_by must be color or label")
    predicates = {
        "color": color,
        "color_label": color_label,
        "color_client_id": normalized_color_client(color_client),
    }
    filtered = any(value is not None for value in predicates.values())
    buckets: dict[tuple, dict] = {}

    def bucket(
        client_id: Optional[str],
        status: str,
        key: Optional[str],
        *,
        label: Optional[str] = None,
        color_value: Optional[str] = None,
    ) -> dict:
        identity = (group_by, client_id, status, key)
        group = buckets.get(identity)
        if group is None:
            group = {
                "scope": GROUPING_SCOPE,
                "groupBy": group_by,
                "clientId": client_id,
                "status": status,
                "key": key,
                "label": label,
                "color": color_value,
                "colors": [],
                "stale": False,
                "count": 0,
                "members": [],
            }
            buckets[identity] = group
        return group

    def attach(group: dict, row: dict, entry: Optional[dict]) -> None:
        group["members"].append({"result": row, "chatTabColor": entry})
        group["count"] += 1
        if not isinstance(entry, dict):
            return
        if entry.get("stale") is True:
            group["stale"] = True
        entry_color = entry.get("color")
        if (
            entry.get("status") == "assigned"
            and isinstance(entry_color, str)
            and entry_color not in group["colors"]
        ):
            group["colors"].append(entry_color)

    for row in (results if isinstance(results, list) else []):
        if not isinstance(row, dict):
            continue
        if "chatTabColors" not in row:
            attach(bucket(None, "notApplicable", None), row, None)
            continue
        entries = row.get("chatTabColors")
        if not isinstance(entries, list) or not entries:
            attach(bucket(None, "unavailable", _UNAVAILABLE_KEY), row, None)
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            if filtered and not entry_matches(entry, **predicates):
                continue
            status = entry.get("status")
            client_id = entry.get("clientId")
            if status == "assigned":
                if group_by == "color":
                    entry_color = entry.get("color")
                    entry_color = entry_color if isinstance(entry_color, str) else None
                    group = bucket(
                        client_id,
                        "assigned",
                        entry_color or _UNKNOWN_KEY,
                        color_value=entry_color,
                    )
                else:
                    entry_label = entry.get("label")
                    entry_label = entry_label if isinstance(entry_label, str) else None
                    group = bucket(
                        client_id,
                        "assigned",
                        normalized_label(entry_label) or _UNKNOWN_KEY,
                        label=entry_label,
                    )
            elif status == "unassigned":
                group = bucket(client_id, "unassigned", CHAT_TAB_COLOR_NONE)
            else:
                group = bucket(client_id, "unavailable", _UNAVAILABLE_KEY)
            attach(group, row, entry)

    groups = sorted(
        buckets.values(),
        key=lambda group: (
            _GROUP_STATUS_ORDER.get(group["status"], 4),
            group["clientId"] or "",
            group["key"] or "",
            group["color"] or "",
        ),
    )
    for group in groups:
        group["colors"].sort()
    return groups
