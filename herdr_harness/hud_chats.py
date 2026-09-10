"""Durable HUD conversations: separate storage, normal Pi tools, explicit handoff."""
from __future__ import annotations

from pathlib import Path

from .agent_runs import AgentRunError, TERMINAL_STATUSES

PROFILE = "hud-chat-v1"


def fail(message: str, code: str = "hud_chat_conflict") -> None:
    raise AgentRunError(message, code=code, status=409)


def start(manager, **arguments) -> dict:
    """Serialize appends with promotion/deletion. Never silently fork a HUD chat."""
    if arguments.get("mode") != "act":
        fail("HUD chats must use action mode.")
    with manager._lock:
        parent = arguments.get("continue_from_run_id")
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
            if not Path(root.get("cwd") or "").is_dir():
                fail("This chat’s working folder is no longer available.")
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


def catalog(manager, query: str = "", offset: int = 0) -> dict:
    with manager._lock:
        matches = []
        needle = query.strip().casefold()
        for root_id, members in all_threads(manager).items():
            members.sort(key=sort_key)
            if needle and not any(needle in str(r.get(k) or "").casefold()
                                  for r in members for k in ("prompt", "response", "label", "sessionId")):
                continue
            root, latest = members[0], members[-1]
            promoted = next((r for r in members if r.get("promotedPaneId")), None)
            matches.append({"id": root_id, "title": root.get("label") or "HUD chat",
                            "updatedAt": latest.get("finishedAt") or latest["createdAt"],
                            "latestRunId": latest["id"], "turnCount": len(members),
                            "status": "promoted" if promoted else latest["status"],
                            "sessionId": root.get("sessionId"),
                            "promotedPaneId": promoted.get("promotedPaneId") if promoted else None})
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
