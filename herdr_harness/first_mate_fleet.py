"""Pure presentation rules for the First Mate fleet (capability first-mate-fleet-v1).

One small summary per feature for the chat window list, the Dock badge, and the
HUD. Everything here is a pure function of one store row, so the rules are easy
to test and to change. The store supplies the row in one SQL query; nothing
here reads the database, the runtime, or the network.

The default emoji must stay identical to the Swift client fallback
(FirstMateDefaultEmoji), or an avatar would change when a server upgrades. The
palette order and the hash are part of the contract; see the shared test vectors
in tests/test_first_mate_fleet.py.
"""
from __future__ import annotations

import unicodedata
from typing import Any, Iterable, Mapping

from . import skim as skim_format

CAPABILITY = "first-mate-fleet-v1"
FLEET_VIEWS = ("active", "archived", "all")
HUD_STATUSES = ("blocked", "turn", "ready", "working", "idle", "done")
NEEDS_YOU = frozenset({"blocked", "turn", "ready"})

LABEL_LIMIT = 24
EMOJI_LIMIT = 16
NOW_LIMIT = 120
LATEST_TEXT_LIMIT = 200
ELLIPSIS = "…"

# Only whole, explicit phase names are a phase declaration. Free-form keys
# such as test-fixture-cleanup and code-review-pre-pr do not establish QA or PR.
_STAGE_PHASES = {
    "plan": 0, "planning": 0,
    "build": 1, "building": 1, "implement": 1, "implementation": 1,
    "review": 2, "code-review": 2,
    "qa": 3, "quality-assurance": 3,
    "pr": 4, "pull-request": 4,
    "merge": 5, "merging": 5,
}
# An active assignment describes the current work, including revisions that
# return to implementation inside an older review or QA stage. Mixed or custom
# roles have no single phase; keep those honestly labeled Working.
_ROLE_PHASES = {"planner": 0, "coder": 1, "implementer": 1, "reviewer": 2, "qa": 3}

# A stage result waiting at Review, PR, or Merge asks for approval of finished
# work ("ready"); anything else waiting on the human is "turn".
_READY_STEPS = frozenset({2, 4, 5})

# 16 single scalars with default emoji presentation. Never reorder: the index
# is shared with the Swift client.
EMOJI_PALETTE = ("🧭", "📦", "🧪", "🔍", "🧾", "📋", "🧩", "🚀",
                 "🔔", "🎨", "📚", "🌱", "💡", "🔧", "🧰", "🪁")
_FNV_OFFSET, _FNV_PRIME = 0x811C9DC5, 0x01000193


class PresentationError(ValueError):
    """An invalid label or emoji. The store reports it as invalid_request."""


# ---------------------------------------------------------------- status

def awaiting_direction_is_ready(*, attention_type: str | None, visit_status: str | None,
                                step_index: int | None, has_pull_request: bool) -> bool:
    """The one place that splits "ready" (review finished work) from "turn".

    A saved URL says nothing about draft, review, or merge readiness. Only a
    completed stage result at Review, PR, or Merge counts; a question, a
    human gate, or a plan revision is the human's turn.
    """
    return (attention_type == "visit.awaiting_direction" and visit_status == "completed"
            and step_index in _READY_STEPS)


def hud_status(status: str | None, *, awaiting_turn: bool = False, attention_type: str | None = None,
               visit_status: str | None = None, step_index: int | None = None,
               has_pull_request: bool = False, automatic_recovery: bool = True) -> str:
    """Map a raw First Mate feature status to the six HUD statuses."""
    if status == "blocked":
        return "blocked"
    if status == "recovering":
        # Exhausted recovery already flips the status to blocked; without
        # automatic recovery, a recovering feature waits for the human.
        return "working" if automatic_recovery else "blocked"
    if status == "awaiting_direction":
        ready = awaiting_direction_is_ready(attention_type=attention_type, visit_status=visit_status,
                                            step_index=step_index, has_pull_request=has_pull_request)
        return "ready" if ready else "turn"
    if status in {"running", "coordinating"}:
        return "turn" if awaiting_turn else "working"
    if status in {"ready", "paused"}:
        return "idle"
    if status == "completed":
        return "done"
    return "idle"  # cancelled and unknown values never manufacture attention


# ---------------------------------------------------------------- steps

def step_index(stage_key: str | None) -> int | None:
    """The HUD step for a visit's free-form stage key, or None when unknown."""
    if not isinstance(stage_key, str):
        return None
    return _STAGE_PHASES.get(stage_key.strip().lower().replace("_", "-"))


def current_step(row: Mapping[str, Any]) -> int | None:
    if row.get("pending_human_message") or row.get("coordinator_owner"):
        return None  # New direction is being interpreted, not a phase transition.
    roles = row.get("active_roles")
    if roles:
        phases = {_ROLE_PHASES.get(role) for role in roles}
        return next(iter(phases)) if len(phases) == 1 else None
    return step_index(row.get("stage_key"))


# ---------------------------------------------------------------- label and emoji

def fnv1a32(text: str) -> int:
    value = _FNV_OFFSET
    for byte in text.encode("utf-8"):
        value = ((value ^ byte) * _FNV_PRIME) & 0xFFFFFFFF
    return value


def default_emoji(feature_id: str) -> str:
    value = fnv1a32(feature_id)
    return EMOJI_PALETTE[((value >> 16) ^ (value & 0xFFFF)) % len(EMOJI_PALETTE)]


def _has_control(text: str) -> bool:
    return any(unicodedata.category(character) == "Cc" for character in text)


def _breaks_line(text: str) -> bool:
    """Control characters or a line or paragraph separator (U+2028, U+2029)."""
    return any(unicodedata.category(character) in {"Cc", "Zl", "Zp"} for character in text)


def default_label(title: str) -> str:
    """The title on one line, cut to the label limit."""
    return clip(title, LABEL_LIMIT) or ""


def normalize_label(value: Any) -> str | None:
    """A user label, or None to reset to the default. Limits count code points."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise PresentationError("label must be a string or null")
    text = value.strip()
    if not text:
        return None
    if _breaks_line(text):
        raise PresentationError("label must be one line without control characters")
    if len(text) > LABEL_LIMIT:
        raise PresentationError(f"label exceeds {LABEL_LIMIT} characters")
    return text


def normalize_emoji(value: Any) -> str | None:
    """A user emoji, or None to reset to the default.

    The standard library has no grapheme segmentation, so this is a bound, not
    an emoji check: at most 16 code points (room for ZWJ sequences, skin tones,
    and flags) with no whitespace or control characters.
    """
    if value is None:
        return None
    if not isinstance(value, str):
        raise PresentationError("emoji must be a string or null")
    text = value.strip()
    if not text:
        return None
    if any(character.isspace() for character in text) or _has_control(text):
        raise PresentationError("emoji must not contain whitespace or control characters")
    if len(text) > EMOJI_LIMIT:
        raise PresentationError(f"emoji exceeds {EMOJI_LIMIT} characters")
    return text


# ---------------------------------------------------------------- text

def clip(text: Any, limit: int) -> str | None:
    """Collapse whitespace and cut at a word boundary to at most limit characters.

    A cut line ends with an ellipsis, which counts toward the limit. One word
    longer than the limit is cut mid-word rather than dropped.
    """
    if not isinstance(text, str):
        return None
    line = " ".join(text.split())
    if not line:
        return None
    if len(line) <= limit:
        return line
    head = line[:limit - 1]
    if line[limit - 1] != " " and " " in head:
        head = head.rsplit(" ", 1)[0]
    head = head.rstrip(" ,.;:") or line[:limit - 1].rstrip()
    return head + ELLIPSIS


def skim_say(tokens: Any) -> str | None:
    """Plain text of a ready skim's first say block (its token list)."""
    if not isinstance(tokens, list):
        return None
    try:
        text = skim_format.plain(tokens)
    except (KeyError, TypeError):
        return None
    return " ".join(text.split()) or None


def now_line(hud: str, *, needs_user_prompt: str | None, progress_summary: str | None,
             skim_say_text: str | None, first_mate_text: str | None) -> str | None:
    """One line about what is happening now."""
    candidates: Iterable[str | None]
    if hud in NEEDS_YOU:
        candidates = (needs_user_prompt, skim_say_text, first_mate_text)
    elif hud == "working":
        candidates = (progress_summary, skim_say_text, first_mate_text)
    else:
        candidates = (skim_say_text, first_mate_text)
    for candidate in candidates:
        line = clip(candidate, NOW_LIMIT)
        if line:
            return line
    return None


# ---------------------------------------------------------------- read markers

def is_after(created_at: str | None, message_id: str | None,
             marker_created_at: str | None, marker_id: str | None) -> bool:
    """Whether a message is newer than a read marker, by (created_at, id)."""
    if created_at is None or message_id is None:
        return False
    if marker_created_at is None or marker_id is None:
        return True
    return (created_at, message_id) > (marker_created_at, marker_id)


# ---------------------------------------------------------------- the entry

def _needs_user_prompt(row: Mapping[str, Any], hud: str) -> str | None:
    status = row.get("status")
    if status in {"awaiting_direction", "blocked"}:
        return row.get("needs_user_prompt") or (
            "Needs your direction" if status == "awaiting_direction" else "Recovery needs your direction")
    if status == "recovering" and hud == "blocked":
        return "Recovery needs your direction"
    if hud == "turn":
        return row.get("first_mate_text")
    return None


def entry(row: Mapping[str, Any], *, automatic_recovery: bool = True) -> dict:
    """The public fleet entry for one store row (FirstMateStore.fleet_rows)."""
    index = current_step(row)
    # A phase is not a completion percentage or an ordered six-stage plan.
    fraction, percent = None, None
    hud = hud_status(row.get("status"), awaiting_turn=bool(row.get("awaiting_turn")),
                     attention_type=row.get("attention_type"), visit_status=row.get("visit_status"),
                     step_index=index, has_pull_request=bool(row.get("has_pull_request")),
                     automatic_recovery=automatic_recovery)
    say = skim_say(row.get("skim_say_tokens"))
    latest = None
    if row.get("latest_id"):
        latest = {"id": row["latest_id"], "role": row.get("latest_role"),
                  "text": clip(row.get("latest_text"), LATEST_TEXT_LIMIT) or "",
                  "created_at": row.get("latest_created_at")}
        if say and row["latest_id"] == row.get("first_mate_id"):
            latest["skim_say"] = say
    first_mate_id = row.get("first_mate_id")
    label, emoji = row.get("label"), row.get("emoji")
    return {
        "feature_id": row["id"],
        "title": row.get("title") or "",
        "label": label or default_label(row.get("title") or ""),
        "label_source": "user" if label else "default",
        "emoji": emoji or default_emoji(row["id"]),
        "emoji_source": "user" if emoji else "default",
        "status": row.get("status"),
        "hud_status": hud,
        "step_index": index,
        "step_fraction": fraction,
        "percent": percent,
        "now": now_line(hud, needs_user_prompt=_needs_user_prompt(row, hud),
                        progress_summary=row.get("progress_summary"), skim_say_text=say,
                        first_mate_text=row.get("first_mate_text")),
        "latest_message": latest,
        "latest_first_mate_message_id": first_mate_id,
        "read_through_message_id": row.get("read_through_message_id"),
        "unread": is_after(row.get("first_mate_created_at"), first_mate_id,
                           row.get("read_through_created_at"), row.get("read_through_message_id")),
        "working_on_reply": bool(row.get("pending_human_message") or row.get("coordinator_owner")),
        "activity_at": row.get("activity_at"),
        "updated_at": row.get("updated_at"),
        "archived_at": row.get("archived_at"),
    }
