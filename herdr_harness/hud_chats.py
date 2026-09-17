"""Durable HUD conversations: separate storage, normal Pi tools, explicit handoff."""
from __future__ import annotations

from pathlib import Path
import re

from .agent_runs import AgentRunError, TERMINAL_STATUSES

PROFILE = "hud-chat-v1"


def fail(message: str, code: str = "hud_chat_conflict", status: int = 409) -> None:
    raise AgentRunError(message, code=code, status=status)


def canonical_directory(manager, value: object) -> str:
    """Resolve a HUD directory on the server without interpreting client paths."""
    if not isinstance(value, str) or not value or "\x00" in value:
        fail("HUD chat cwd is invalid.", "invalid_agent_cwd", 400)
    if value == "~":
        value = manager.environ.get("HOME") or str(Path.home())
    elif not Path(value).is_absolute():
        fail("HUD chat cwd must be an absolute path.", "invalid_agent_cwd", 400)
    try:
        directory = Path(value).resolve()
    except (OSError, RuntimeError, TypeError) as exc:
        raise AgentRunError(
            "HUD chat cwd is unavailable.", code="invalid_agent_cwd", status=400
        ) from exc
    if not directory.is_dir():
        fail("HUD chat cwd must be an existing directory.", "invalid_agent_cwd", 400)
    return str(directory)


def start(manager, **arguments) -> dict:
    """Serialize appends with promotion/deletion. Never silently fork a HUD chat."""
    if arguments.get("mode") != "act":
        fail("HUD chats must use action mode.")
    cwd_explicit = arguments.pop("_cwd_explicit", "cwd" in arguments)
    parent = arguments.get("continue_from_run_id")
    requested_cwd = (
        canonical_directory(manager, arguments.get("cwd"))
        if cwd_explicit or parent is None
        else None
    )
    if requested_cwd is not None:
        arguments["cwd"] = requested_cwd
    with manager._lock:
        sequence = 0
        if parent:
            referenced = manager._read(parent)
            root = manager._read(manager._thread_root_id(referenced))
            if root.get("profile") != PROFILE:
                fail("This older chat must be saved to HUD history before continuing.")
            members = manager._thread_runs(root["id"])
            if any(r.get("retainSession") or r["status"] == "promoted" for r in members):
                fail("This chat has continued in a terminal. Open that session to reply.")
            if any(r["status"] not in TERMINAL_STATUSES for r in members):
                fail("A reply is already running in this HUD chat.")
            latest = max(members, key=sort_key)
            if latest["id"] != parent:
                fail("This chat has a newer reply. Reopen it from HUD history.")
            root_cwd = canonical_directory(manager, root.get("cwd"))
            if cwd_explicit and requested_cwd != root_cwd:
                fail("This HUD chat must continue in its original working folder.")
            arguments["cwd"] = root_cwd
            if manager._find_session_file(root) is None:
                fail("The saved Pi session is missing. History is preserved; start a new chat.")
            sequence = latest.get("hudSequence", 0) + 1
        return manager.start(**arguments, _assistant={"profile": PROFILE, "hudSequence": sequence})


def sort_key(run: dict) -> tuple:
    return (run.get("hudSequence", 0), run.get("createdAt") or "", run["id"])


def migrate_legacy(manager) -> None:
    """Preserve still-present HUD action sessions before the old reaper runs.

    Legacy HUD was the action profile; questions and internal ask jobs are not
    migrated. Existing explicit profiles keep their permissions and lifecycle.
    """
    threads: dict[str, list[dict]] = {}
    for directory in manager.runs_root.glob("agr_*"):
        if directory.is_symlink() or not directory.is_dir():
            continue
        try:
            run = manager._read(directory.name)
        except AgentRunError:
            continue
        threads.setdefault(manager._thread_root_id(run), []).append(run)
    for members in threads.values():
        if not all(r.get("mode") == "act" and r.get("profile") in (None, PROFILE) for r in members) or all(r.get("profile") == PROFILE for r in members):
            continue
        for index, run in enumerate(sorted(members, key=lambda r: (r.get("createdAt") or "", r["id"]))):
            run.update(profile=PROFILE, hudSequence=index)
            manager._write(run)


def all_threads(manager) -> dict[str, list[dict]]:
    threads: dict[str, list[dict]] = {}
    for directory in manager.runs_root.glob("agr_*"):
        if directory.is_symlink() or not directory.is_dir():
            continue
        try:
            run = manager._read(directory.name)
        except AgentRunError:
            continue
        if run.get("profile") == PROFILE:
            threads.setdefault(manager._thread_root_id(run), []).append(run)
    return threads


def _match_excerpt(text: str, start: int, length: int) -> str:
    left = max(0, start - 80)
    right = min(len(text), start + max(1, length) + 120)
    excerpt = " ".join(text[left:right].split())
    if left:
        excerpt = "…" + excerpt
    if right < len(text):
        excerpt += "…"
    return excerpt[:360]


def catalog(
    manager,
    query: str = "",
    offset: int = 0,
    *,
    ticket: str = "",
    include_match_evidence: bool = False,
) -> dict:
    with manager._lock:
        matches = []
        needle = query.strip().casefold()
        ticket_pattern = (
            re.compile(r"(?<![A-Z0-9])" + re.escape(ticket) + r"(?![A-Z0-9])", re.IGNORECASE)
            if ticket
            else None
        )
        for root_id, members in all_threads(manager).items():
            members.sort(key=sort_key)
            query_match = not needle
            ticket_match = ticket_pattern is None
            evidence = []
            query_evidence = False
            ticket_evidence = False
            for member in members:
                for key in ("prompt", "response", "label", "sessionId"):
                    text = str(member.get(key) or "")
                    if needle:
                        index = text.casefold().find(needle)
                        if index >= 0:
                            query_match = True
                            if include_match_evidence and not query_evidence:
                                evidence.append(
                                    {"field": key, "excerpt": _match_excerpt(text, index, len(query.strip()))}
                                )
                                query_evidence = True
                    if ticket_pattern is not None:
                        found = ticket_pattern.search(text)
                        if found:
                            ticket_match = True
                            if include_match_evidence and not ticket_evidence:
                                evidence.append(
                                    {
                                        "field": key,
                                        "excerpt": _match_excerpt(
                                            text, found.start(), len(found.group(0))
                                        ),
                                    }
                                )
                                ticket_evidence = True
            if not query_match or not ticket_match:
                continue
            root, latest = members[0], members[-1]
            promoted = next((r for r in members if r.get("promotedPaneId")), None)
            chat = {"id": root_id, "title": root.get("label") or "HUD chat",
                    "updatedAt": latest.get("finishedAt") or latest["createdAt"],
                    "latestRunId": latest["id"], "turnCount": len(members),
                    "status": "promoted" if promoted else latest["status"],
                    "cwd": root.get("cwd"), "sessionId": root.get("sessionId"),
                    "promotedPaneId": promoted.get("promotedPaneId") if promoted else None}
            if include_match_evidence:
                chat["matchEvidence"] = evidence
            matches.append(chat)
        matches.sort(key=lambda r: (r["updatedAt"], r["id"]), reverse=True)
        return {"ok": True, "chats": matches[offset:offset + 50],
                "nextOffset": offset + 50 if len(matches) > offset + 50 else None}


def history(manager, run_id: str, offset: int = 0) -> dict:
    with manager._lock:
        run = manager._read(run_id)
        if run.get("profile") != PROFILE:
            fail("This run is not a saved HUD chat.")
        members = sorted(manager._thread_runs(manager._thread_root_id(run)), key=sort_key)
        promoted = next((r for r in members if r.get("promotedPaneId")), None)
        return {"ok": True, "turns": [manager._public(r) for r in members[offset:offset + 50]],
                "rootRunId": manager._thread_root_id(run), "latestRunId": members[-1]["id"],
                "promotedPaneId": promoted.get("promotedPaneId") if promoted else None,
                "nextOffset": offset + 50 if len(members) > offset + 50 else None}


def retain_legacy(manager, run_id: str) -> dict:
    """Explicitly save an existing action thread, before the old TTL reaps it."""
    with manager._lock:
        run = manager._read(run_id)
        members = sorted(manager._thread_runs(manager._thread_root_id(run)), key=sort_key)
        if all(r.get("profile") == PROFILE for r in members):
            return {"ok": True, "rootRunId": manager._thread_root_id(run)}
        if any(r.get("mode") != "act" or r.get("profile") not in (None, PROFILE) for r in members):
            fail("Only HUD action chats can be saved here.")
        if any(r["status"] not in TERMINAL_STATUSES for r in members):
            fail("Wait for this chat to finish before saving it.")
        for index, member in enumerate(members):
            member.update(profile=PROFILE, hudSequence=index)
            manager._write(member)
        return {"ok": True, "rootRunId": manager._thread_root_id(run)}
