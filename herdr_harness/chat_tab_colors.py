"""Client-scoped chat tab color publication, snapshot projection, and discovery.

This module defines the read-only ``chat-tab-colors-v1`` contract described in
``docs/chat-tab-color-api.md``. It never reads or writes a client's local color
store: publishers send their own effective values, the companion keeps one
discovery copy per installation, and readers only project that data onto copies
of snapshot state.
"""
from __future__ import annotations

import re
import unicodedata
from typing import Any, Iterable, Optional

from .control_validation import ControlError, short_string, validate_json


CHAT_TAB_PALETTE = ("lavender", "iris", "rose", "clay", "sage", "slate")
CHAT_TAB_COLOR_NONE = "none"
CHAT_TAB_STATUSES = ("assigned", "unassigned", "unavailable")
CHAT_TAB_STALE_SECONDS = 60.0
CHAT_TAB_HEARTBEAT_SECONDS = 20
MAX_CHAT_TAB_PUBLISHERS = 64
MAX_CHAT_TAB_ENTRIES = 2048
MAX_CHAT_TAB_PUBLICATION_BYTES = 512 * 1024
MAX_CHAT_TAB_LABEL_CODEPOINTS = 1024
MAX_CHAT_TAB_LABEL_BYTES = 4096
MAX_CHAT_TAB_CLIENT_NAME_CHARACTERS = 120

PUBLICATION_FIELDS = frozenset(
    {"serverId", "platform", "clientName", "enabled", "revision", "tabs"}
)
PUBLICATION_BODY_FIELDS = PUBLICATION_FIELDS | {"publisherToken"}
TAB_ENTRY_FIELDS = frozenset({"workspaceId", "tabId", "color", "label"})

# Agent control may not rewrite local tab colors. The relay catalog reports the
# action as unavailable and both admission and claim refuse it.
DISABLED_RELAY_ACTIONS = {
    "chat.tab-color": "Tab colors are read-only through agent control; edit them in the app",
}

_TAB_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._-]{0,255}$")
_PLATFORM_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
# Directional formatting and line separators could spoof or corrupt terminal
# output. Zero-width joiners remain allowed so emoji label sequences survive.
_UNSAFE_LABEL_CHARACTERS = frozenset(
    "\u2028\u2029\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069"
)


def disabled_action_reason(action: Any) -> Optional[str]:
    if not isinstance(action, str):
        return None
    return DISABLED_RELAY_ACTIONS.get(action)


def disable_relay_actions(actions: Any) -> list:
    """Return a copy of relay action descriptors with disabled actions marked."""

    result: list = []
    if not isinstance(actions, list):
        return result
    for descriptor in actions:
        if not isinstance(descriptor, dict):
            continue
        reason = disabled_action_reason(descriptor.get("id"))
        if reason is not None:
            descriptor = {**descriptor, "enabled": False, "disabledReason": reason}
        result.append(descriptor)
    return result


def tab_identifier(value: Any, *, label: str) -> str:
    if not isinstance(value, str) or not _TAB_IDENTIFIER_RE.fullmatch(value):
        raise ControlError(f"{label} is invalid")
    return value


def palette_color(value: Any, *, label: str = "color") -> Optional[str]:
    if value is None:
        return None
    if not isinstance(value, str) or value not in CHAT_TAB_PALETTE:
        raise ControlError(
            f"{label} must be null or one of {', '.join(CHAT_TAB_PALETTE)}"
        )
    return value


def tab_label(value: Any, *, label: str = "label") -> Optional[str]:
    """Validate an effective color label without conflating grapheme counts.

    Swift limits user-facing labels in extended grapheme clusters. Python counts
    Unicode code points, so the accepted code-point and byte budgets are wider
    than any valid 128-grapheme Swift label and never reject one.
    """

    if value is None:
        return None
    if not isinstance(value, str):
        raise ControlError(f"{label} must be a string or null")
    if len(value) > MAX_CHAT_TAB_LABEL_CODEPOINTS:
        raise ControlError(f"{label} exceeds {MAX_CHAT_TAB_LABEL_CODEPOINTS} Unicode characters")
    text = value.strip()
    if not text:
        raise ControlError(f"{label} must not be blank")
    for character in text:
        if unicodedata.category(character) == "Cc" or character in _UNSAFE_LABEL_CHARACTERS:
            raise ControlError(f"{label} contains unsupported control characters")
    if len(text.encode("utf-8")) > MAX_CHAT_TAB_LABEL_BYTES:
        raise ControlError(f"{label} exceeds {MAX_CHAT_TAB_LABEL_BYTES} UTF-8 bytes")
    return text


def client_name(value: Any) -> str:
    text = short_string(value, "clientName", maximum=MAX_CHAT_TAB_CLIENT_NAME_CHARACTERS)
    text = text.strip()
    if not text:
        raise ControlError("clientName must not be blank")
    for character in text:
        if unicodedata.category(character) == "Cc":
            raise ControlError("clientName contains unsupported control characters")
    return text


def platform(value: Any) -> str:
    if not isinstance(value, str) or not _PLATFORM_RE.fullmatch(value):
        raise ControlError("platform is invalid")
    return value


def tab_entry(value: Any, *, label: str = "tabs[]") -> dict:
    if not isinstance(value, dict):
        raise ControlError(f"{label} must be an object")
    extra = set(value) - TAB_ENTRY_FIELDS
    if extra:
        raise ControlError(f"{label} contains an unsupported field")
    workspace_id = tab_identifier(value.get("workspaceId"), label=f"{label}.workspaceId")
    tab_id = tab_identifier(value.get("tabId"), label=f"{label}.tabId")
    color = palette_color(value.get("color"), label=f"{label}.color")
    text = tab_label(value.get("label"), label=f"{label}.label")
    if color is None and text is not None:
        raise ControlError(f"{label}.label requires a color")
    if color is not None and text is None:
        raise ControlError(f"{label}.color requires an effective label")
    return {"workspaceId": workspace_id, "tabId": tab_id, "color": color, "label": text}


def publication_payload(body: Any) -> dict:
    """Validate a publication request body into its canonical stored payload."""

    if not isinstance(body, dict):
        raise ControlError("publication must be an object")
    extra = set(body) - PUBLICATION_BODY_FIELDS
    if extra:
        raise ControlError("publication contains an unsupported field")
    missing = PUBLICATION_FIELDS - set(body)
    if missing:
        raise ControlError("publication is missing a required field")
    server_id = short_string(body.get("serverId"), "serverId", maximum=128)
    client_platform = platform(body.get("platform"))
    name = client_name(body.get("clientName"))
    enabled = body.get("enabled")
    if not isinstance(enabled, bool):
        raise ControlError("enabled must be a boolean")
    revision = body.get("revision")
    if not isinstance(revision, int) or isinstance(revision, bool) or not 1 <= revision <= 2**53 - 1:
        raise ControlError("revision must be an integer between 1 and 9007199254740991")
    tabs = body.get("tabs")
    if not isinstance(tabs, list):
        raise ControlError("tabs must be an array")
    if len(tabs) > MAX_CHAT_TAB_ENTRIES:
        raise ControlError(
            "publication contains too many tab entries",
            code="publication_too_large",
            status=413,
        )
    if not enabled and tabs:
        raise ControlError("a disabled publication cannot carry tab entries")
    normalized: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for index, raw in enumerate(tabs):
        entry = tab_entry(raw, label=f"tabs[{index}]")
        identity = (entry["workspaceId"], entry["tabId"])
        if identity in seen:
            raise ControlError("publication contains a duplicate tab entry")
        seen.add(identity)
        normalized.append(entry)
    payload = {
        "serverId": server_id,
        "platform": client_platform,
        "clientName": name,
        "enabled": enabled,
        "revision": revision,
        "tabs": normalized,
    }
    validate_json(payload, "publication", maximum_bytes=MAX_CHAT_TAB_PUBLICATION_BYTES)
    return payload


def publication_index(publications: Iterable[dict]) -> list[tuple[dict, dict[tuple[str, str], dict]]]:
    result: list[tuple[dict, dict[tuple[str, str], dict]]] = []
    for publication in publications:
        entries: dict[tuple[str, str], dict] = {}
        tabs = publication.get("tabs") if isinstance(publication, dict) else None
        if isinstance(tabs, list):
            for entry in tabs:
                if not isinstance(entry, dict):
                    continue
                workspace_id = entry.get("workspaceId")
                tab_id = entry.get("tabId")
                if isinstance(workspace_id, str) and isinstance(tab_id, str):
                    entries[(workspace_id, tab_id)] = entry
        result.append((publication, entries))
    return result


def entries_for_tab(
    index: list[tuple[dict, dict[tuple[str, str], dict]]],
    workspace_id: Any,
    tab_id: Any,
) -> list[dict]:
    """Build one tab's per-publisher entries, including unknown/withdrawn ones."""

    entries: list[dict] = []
    for publication, published in index:
        entry = published.get((workspace_id, tab_id)) if publication.get("enabled") else None
        color = None
        label = None
        if entry is None:
            status = "unavailable"
        elif entry.get("color") is None:
            status = "unassigned"
        else:
            status = "assigned"
            color = entry.get("color")
            label = entry.get("label")
        entries.append(
            {
                "clientId": publication.get("clientId"),
                "color": color,
                "label": label,
                "status": status,
                "updatedAt": publication.get("updatedAt"),
                "lastSeenAt": publication.get("lastSeenAt"),
                "stale": bool(publication.get("stale")),
            }
        )
    return entries


def project_snapshot(
    snapshot: dict,
    publications: Iterable[dict],
    *,
    include_empty: bool = False,
) -> dict:
    """Add ``chatTabColors`` to each tab copy when publisher metadata is known.

    With no publishers and ``include_empty`` false the snapshot is returned
    unchanged, so installations that never use agent control keep their existing
    response shape exactly. When the companion knows about publishers, every tab
    reports an array (empty until something is published).
    """

    publication_list = list(publications)
    if not publication_list and not include_empty:
        return snapshot
    index = publication_index(publication_list)
    tabs = snapshot.get("tabs")
    if not isinstance(tabs, list):
        return snapshot
    for tab in tabs:
        if not isinstance(tab, dict):
            continue
        workspace_id = tab.get("workspace_id", tab.get("workspaceId"))
        tab_id = tab.get("tab_id", tab.get("tabId"))
        tab["chatTabColors"] = entries_for_tab(index, workspace_id, tab_id)
    return snapshot


def sources_response(publications: Iterable[dict]) -> list[dict]:
    """Public publisher list for a snapshot response (never includes tab data)."""

    return [
        {
            "clientId": publication.get("clientId"),
            "platform": publication.get("platform"),
            "clientName": publication.get("clientName"),
            "enabled": bool(publication.get("enabled")),
            "revision": publication.get("revision"),
            "updatedAt": publication.get("updatedAt"),
            "lastSeenAt": publication.get("lastSeenAt"),
            "stale": bool(publication.get("stale")),
        }
        for publication in publications
    ]


def publication_response(publication: dict) -> dict:
    """Summary returned by a successful publication request."""

    tabs = publication.get("tabs")
    return {
        "clientId": publication.get("clientId"),
        "platform": publication.get("platform"),
        "clientName": publication.get("clientName"),
        "enabled": bool(publication.get("enabled")),
        "revision": publication.get("revision"),
        "tabCount": len(tabs) if isinstance(tabs, list) else 0,
        "updatedAt": publication.get("updatedAt"),
        "lastSeenAt": publication.get("lastSeenAt"),
        "stale": bool(publication.get("stale")),
    }


def entry_matches(
    entry: Any,
    *,
    color: Optional[str] = None,
    color_label: Optional[str] = None,
    color_client_id: Optional[str] = None,
) -> bool:
    """Return whether one publisher entry satisfies every supplied predicate."""

    if not isinstance(entry, dict):
        return False
    status = entry.get("status")
    if color_client_id is not None and entry.get("clientId") != color_client_id:
        return False
    if color is not None:
        if color == CHAT_TAB_COLOR_NONE:
            if status != "unassigned" or entry.get("color") is not None:
                return False
        elif status != "assigned" or entry.get("color") != color:
            return False
    if color_label is not None:
        if status != "assigned":
            return False
        published = entry.get("label")
        if not isinstance(published, str) or published.strip().casefold() != color_label.strip().casefold():
            return False
    if color is None and color_label is None and color_client_id is not None and status == "unavailable":
        # A client-only filter selects that client's reported tabs, not tabs it
        # has said nothing about.
        return False
    return True


def entries_match(entries: Any, **predicates: Optional[str]) -> bool:
    if not isinstance(entries, list):
        return False
    return any(entry_matches(entry, **predicates) for entry in entries)


def searchable_colors(entries: Any) -> dict[str, str]:
    """Deterministic assigned color/label text for search evidence."""

    colors: list[str] = []
    labels: list[str] = []
    if isinstance(entries, list):
        for entry in entries:
            if not isinstance(entry, dict) or entry.get("status") != "assigned":
                continue
            color = entry.get("color")
            if isinstance(color, str) and color and color not in colors:
                colors.append(color)
            label = entry.get("label")
            if isinstance(label, str) and label not in labels:
                labels.append(label)
    return {"tabColor": " ".join(colors), "tabColorLabel": " ".join(labels)}
