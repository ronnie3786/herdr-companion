"""Approved Original avatar IDs and icons, shared with clients and builders.

IDs are copied from watchers-prototype/v2-core.js. Drawings stay client-side.
"""
from __future__ import annotations

import secrets

CHARACTERS = (
    "pip", "hoot", "mochi", "bolt", "sprout", "juno", "rook", "nimbus", "echo",
    "clove", "atlas", "wren", "lumen", "tally", "quill", "orbit", "kit", "remy",
    "moss", "ziggy",
)
INSTRUMENTS = (
    "gauge", "cog", "metronome", "hourglass", "beacon", "relay", "terminal", "valve",
)
STEP_ICONS = (
    "terminal", "github", "folder", "clock", "inbox", "slack", "check", "globe",
    "desktop", "laptop", "bell", "sparkles", "file", "search", "refresh",
)
CHIP_KINDS = ("time", "gh", "script", "agent", "skill", "slack", "inbox", "repo", "pc")


def pick_avatar(has_agent: bool, used=()) -> str:
    """Prefer an unused member of the appropriate approved family."""
    family = CHARACTERS if has_agent else INSTRUMENTS
    available = [value for value in family if value not in used]
    return secrets.choice(available or family)


def asset_catalog() -> dict:
    return {
        "characters": [{"id": value, "name": value.title(), "family": "character"} for value in CHARACTERS],
        "instruments": [{"id": value, "name": value.title(), "family": "instrument"} for value in INSTRUMENTS],
        "icons": list(STEP_ICONS),
        "chips": list(CHIP_KINDS),
    }
