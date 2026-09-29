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

import re
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

# Plan, Build, Review, QA, PR, Merge.
STEP_COUNT = 6
# Checked in this order, so the first step with a matching token wins:
# "code-review-pre-pr" is PR, not Review.
_STEP_KEYWORDS = (
    (5, ("merge",)),
    (4, ("pr",)),
    (3, ("proof", "qa", "test")),
    (2, ("review",)),
    (1, ("implement", "build")),
    (0, ("plan",)),
)
# Two-letter keywords must be the whole token; a prefix would read "proof",
# "prepare", or "preflight" as a pull request.
_WHOLE_TOKEN_KEYWORDS = frozenset({"pr", "qa"})
_STAGE_KEY_SPLIT = re.compile(r"[-_\s]+")

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

    A visible pull request link means finished work is waiting. Otherwise only
    a completed stage result at Review, PR, or Merge counts; a question, a
    human gate, or a plan revision is the human's turn.
    """
    if has_pull_request:
        return True
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
    tokens = [token for token in _STAGE_KEY_SPLIT.split(stage_key.lower()) if token]
    for index, keywords in _STEP_KEYWORDS:
        for keyword in keywords:
            whole = keyword in _WHOLE_TOKEN_KEYWORDS
            if any(token == keyword if whole else token.startswith(keyword) for token in tokens):
                return index
    return None


def step_progress(stage_key: str | None, visit_status: str | None) -> tuple[int | None, float | None, int | None]:
    """(step_index, step_fraction, percent); all three are None when unknown."""
    index = step_index(stage_key)
    if index is None:
        return None, None, None
    fraction = 1.0 if visit_status == "completed" else 0.0
    return index, fraction, round((index + fraction) / STEP_COUNT * 100)


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
    index, fraction, percent = step_progress(row.get("stage_key"), row.get("visit_status"))
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
