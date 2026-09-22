"""Bounded cross-client discovery over live and durably saved Herdr state."""
from __future__ import annotations

import copy
import re
import uuid
from datetime import datetime, timezone
from typing import Any, Optional

from .chat_tab_colors import (
    CHAT_TAB_COLOR_NONE,
    CHAT_TAB_STALE_SECONDS,
    entries_match,
    palette_color,
    searchable_colors,
    tab_label,
)
from .control_validation import ControlError, client_id as control_client_id


EXPENSIVE_PANE_LIMIT = 50
MAX_SEARCH_TEXT = 200_000
MAX_EVIDENCE = 8


def _identifier(record: dict, *keys: str) -> Optional[str]:
    for key in keys:
        value = record.get(key)
        if isinstance(value, (str, int)) and str(value):
            return str(value)
    return None


def _timestamp(record: dict) -> Optional[str]:
    for key in (
        "last_activity_at",
        "lastActivityAt",
        "updated_at",
        "updatedAt",
        "generatedAt",
        "finishedAt",
        "created_at",
        "createdAt",
    ):
        value = record.get(key)
        if isinstance(value, str) and value:
            try:
                datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                continue
            return value
    return None


def _timestamp_value(value: Optional[str]) -> float:
    if not value:
        return float("-inf")
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return float("-inf")


def _excerpt(text: str, start: int, length: int) -> str:
    left = max(0, start - 80)
    right = min(len(text), start + max(1, length) + 120)
    value = " ".join(text[left:right].split())
    if left:
        value = "…" + value
    if right < len(text):
        value += "…"
    return value[:360]


def _strings(value: Any, *, budget: int = MAX_SEARCH_TEXT) -> str:
    parts: list[str] = []
    used = 0

    def visit(item: Any) -> None:
        nonlocal used
        if used >= budget:
            return
        if isinstance(item, str):
            remaining = budget - used
            parts.append(item[:remaining])
            used += min(len(item), remaining)
        elif isinstance(item, dict):
            for child in item.values():
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)

    visit(value)
    return "\n".join(parts)


def _session_id(pane: dict) -> Optional[str]:
    value = _identifier(pane, "session_id", "sessionId")
    if value:
        return value
    semantic = pane.get("pi_semantic") or pane.get("piSemantic")
    if isinstance(semantic, dict):
        value = _identifier(semantic, "session_id", "sessionId")
        if value:
            return value
    info = pane.get("agent_info") or pane.get("agentInfo")
    return _identifier(info, "session_id", "sessionId", "id") if isinstance(info, dict) else None


def _record_fields(record: dict) -> dict[str, str]:
    fields = record.pop("_fields", {})
    return {key: str(value) for key, value in fields.items() if value is not None and str(value)}


def _session_lookup_key(value: Any) -> Optional[str]:
    if not isinstance(value, str) or not value:
        return None
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError):
        return value


def _external_native_session_id(value: Any) -> Optional[str]:
    if not isinstance(value, str) or not value:
        return None
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError):
        return None


def _tab_color_entries(tab: Any) -> Optional[list[dict]]:
    """Return a tab's publisher entries, or None when it has no color metadata."""

    if not isinstance(tab, dict) or "chatTabColors" not in tab:
        return None
    entries = tab.get("chatTabColors")
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, dict)]


class DiscoveryService:
    def __init__(self, service: Any, server_id: str) -> None:
        self.service = service
        self.server_id = server_id

    def search(
        self,
        *,
        kind: str,
        query: str,
        ticket: str,
        sort: str,
        limit: int,
        offset: int,
        color: Optional[str] = None,
        color_label: Optional[str] = None,
        color_client_id: Optional[str] = None,
        chat_scope: Optional[str] = None,
    ) -> dict:
        if kind not in {"chats", "workspaces", "tabs", "all"}:
            raise ControlError("kind must be chats, workspaces, tabs, or all")
        if sort not in {"updated", "relevance"}:
            raise ControlError("sort must be updated or relevance")
        if len(query) > 1000 or "\x00" in query:
            raise ControlError("q is invalid")
        if len(ticket) > 128 or "\x00" in ticket:
            raise ControlError("ticket is invalid")
        if chat_scope is not None and chat_scope != "terminal":
            raise ControlError("chatScope must be terminal")
        if color is not None and color != CHAT_TAB_COLOR_NONE:
            color = palette_color(color, label="color")
        color_label = tab_label(color_label, label="colorLabel")
        color_client_id = (
            control_client_id(color_client_id) if color_client_id is not None else None
        )
        records, coverage, generated_at = self._records(
            include_expensive=bool(query or ticket), query=query, ticket=ticket
        )
        allowed = {
            "chats": {"pane", "hud-chat", "first-mate"},
            "workspaces": {"workspace"},
            "tabs": {"tab"},
            "all": {"pane", "workspace", "tab", "hud-chat", "first-mate"},
        }[kind]
        needle = query.casefold()
        ticket_pattern = (
            re.compile(r"(?<![A-Z0-9])" + re.escape(ticket) + r"(?![A-Z0-9])", re.IGNORECASE)
            if ticket
            else None
        )
        matches: list[dict] = []
        for raw in records:
            if raw["kind"] not in allowed:
                continue
            record = copy.deepcopy(raw)
            fields = _record_fields(record)
            evidence: list[dict] = []
            score = 0
            query_match = not needle
            ticket_match = ticket_pattern is None
            for field, text in fields.items():
                folded = text.casefold()
                if needle:
                    index = folded.find(needle)
                    if index >= 0:
                        query_match = True
                        score += 3 if field == "title" else 1
                        if len(evidence) < MAX_EVIDENCE:
                            evidence.append(
                                {"field": field, "excerpt": _excerpt(text, index, len(query))}
                            )
                if ticket_pattern is not None:
                    found = ticket_pattern.search(text)
                    if found:
                        ticket_match = True
                        score += 4 if field == "title" else 2
                        if len(evidence) < MAX_EVIDENCE and not any(
                            item["field"] == field and ticket.casefold() in item["excerpt"].casefold()
                            for item in evidence
                        ):
                            evidence.append(
                                {
                                    "field": field,
                                    "excerpt": _excerpt(text, found.start(), len(found.group(0))),
                                }
                            )
            if not query_match or not ticket_match:
                continue
            if not evidence:
                evidence = [{"field": "title", "excerpt": record["title"][:360]}]
            record["matchEvidence"] = evidence
            record["_score"] = score
            matches.append(record)
        if chat_scope == "terminal":
            matches = [
                item for item in matches if item["kind"] not in {"hud-chat", "first-mate"}
            ]
        if color is not None or color_label is not None or color_client_id is not None:
            # Every supplied predicate must match one publisher's entry, and the
            # filter runs before pagination so later pages are not skipped.
            predicates = {
                "color": color,
                "color_label": color_label,
                "color_client_id": color_client_id,
            }
            matches = [
                item for item in matches if entries_match(item.get("chatTabColors"), **predicates)
            ]
        if sort == "relevance":
            matches.sort(
                key=lambda item: (
                    -item["_score"],
                    -_timestamp_value(item.get("updatedAt")),
                    item["kind"],
                    item["id"],
                )
            )
        else:
            matches.sort(
                key=lambda item: (
                    -_timestamp_value(item.get("updatedAt")),
                    item["kind"],
                    item["id"],
                )
            )
        page = matches[offset : offset + limit]
        for item in page:
            item.pop("_score", None)
        next_offset = offset + limit if len(matches) > offset + limit else None
        return {
            "ok": True,
            "serverId": self.server_id,
            "results": page,
            "nextOffset": next_offset,
            "coverage": coverage,
            "generatedAt": generated_at,
        }

    def inspect(self, target: dict) -> dict:
        supplied_server = target.get("serverId")
        if supplied_server is not None and supplied_server != self.server_id:
            raise ControlError("Target belongs to another server", code="stale_target", status=409)
        kind = target.get("kind")
        identity_fields = {
            "pane": ("paneId",),
            "workspace": ("workspaceId",),
            "tab": ("tabId",),
            "hud-chat": ("hudChatId",),
            "first-mate": ("featureId",),
        }
        if kind is not None and kind not in identity_fields:
            raise ControlError("Target kind is invalid")
        if kind == "hud-chat" or (kind is None and target.get("hudChatId")):
            return self._inspect_hud(target)
        if kind == "first-mate" or (kind is None and target.get("featureId")):
            return self._inspect_first_mate(target)
        try:
            self.service.refresh_snapshot(force=True)
        except Exception as exc:
            raise ControlError(
                "Current topology could not be refreshed",
                code="discovery_unavailable",
                status=503,
            ) from exc
        records, _, _ = self._records(include_expensive=False)
        candidate_kinds = [kind] if kind is not None else list(identity_fields)
        for candidate_kind in candidate_kinds:
            if candidate_kind == "hud-chat" and target.get("hudChatId"):
                return self._inspect_hud(target)
            if candidate_kind == "first-mate" and target.get("featureId"):
                return self._inspect_first_mate(target)
            required = identity_fields[candidate_kind]
            if not all(target.get(field) for field in required):
                continue
            for raw in records:
                if raw["kind"] != candidate_kind:
                    continue
                record_target = raw["target"]
                if not all(record_target.get(field) == target.get(field) for field in required):
                    continue
                self._require_matching_identity(target, record_target)
                record = copy.deepcopy(raw)
                _record_fields(record)
                record["matchEvidence"] = [
                    {"field": "title", "excerpt": record["title"][:360]}
                ]
                return record
        raise ControlError("Target not found", code="not_found", status=404)

    @staticmethod
    def _require_matching_identity(supplied: dict, actual: dict) -> None:
        for exact in (
            "workspaceId",
            "tabId",
            "paneId",
            "terminalId",
            "sessionId",
            "hudChatId",
            "featureId",
        ):
            if supplied.get(exact) is not None and actual.get(exact) != supplied.get(exact):
                raise ControlError("Target identity is stale", code="stale_target", status=409)

    def _inspect_hud(self, target: dict) -> dict:
        identifier = target.get("hudChatId")
        if not identifier:
            raise ControlError("target.hudChatId is required")
        try:
            from .hud_chats import history

            response = history(self.service.agent_runs, identifier, 0)
            turns = [item for item in response.get("turns", []) if isinstance(item, dict)]
            next_offset = response.get("nextOffset")
            pages = 1
            while isinstance(next_offset, int) and pages < 20:
                page = history(self.service.agent_runs, identifier, next_offset)
                turns.extend(item for item in page.get("turns", []) if isinstance(item, dict))
                next_offset = page.get("nextOffset")
                pages += 1
            if next_offset is not None:
                raise ControlError(
                    "HUD chat is too large to inspect exactly",
                    code="inspection_truncated",
                    status=503,
                )
        except ControlError:
            raise
        except Exception as exc:
            raise ControlError("HUD chat not found", code="not_found", status=404) from exc
        if str(response.get("rootRunId") or "") != identifier:
            raise ControlError("Target identity is stale", code="stale_target", status=409)
        root = turns[0] if turns else {}
        latest = turns[-1] if turns else root
        title = str(root.get("label") or "HUD chat")
        actual = {"kind": "hud-chat", "serverId": self.server_id, "hudChatId": identifier}
        session_id = _identifier(root, "sessionId", "session_id")
        if session_id:
            actual["sessionId"] = session_id
        self._require_matching_identity(target, actual)
        return {
            "kind": "hud-chat",
            "id": identifier,
            "title": title,
            "updatedAt": _timestamp(latest),
            "status": str(latest.get("status") or "unknown"),
            "target": actual,
            "matchEvidence": [{"field": "title", "excerpt": title[:360]}],
            "openModes": ["hud"],
        }

    def _inspect_first_mate(self, target: dict) -> dict:
        identifier = target.get("featureId")
        if not identifier:
            raise ControlError("target.featureId is required")
        try:
            snapshot = self.service.first_mate_store.snapshot(identifier)
            feature = snapshot.get("feature") if isinstance(snapshot, dict) else None
        except Exception as exc:
            raise ControlError("First Mate feature not found", code="not_found", status=404) from exc
        if not isinstance(feature, dict) or str(feature.get("id") or "") != identifier:
            raise ControlError("First Mate feature not found", code="not_found", status=404)
        actual = {"kind": "first-mate", "serverId": self.server_id, "featureId": identifier}
        self._require_matching_identity(target, actual)
        title = str(feature.get("title") or "First Mate")
        return {
            "kind": "first-mate",
            "id": identifier,
            "title": title,
            "updatedAt": _timestamp(feature),
            "status": str(feature.get("status") or "unknown"),
            **({"cwd": feature["cwd"]} if isinstance(feature.get("cwd"), str) else {}),
            "target": actual,
            "matchEvidence": [{"field": "title", "excerpt": title[:360]}],
            "openModes": ["first-mate"],
        }

    def _records(
        self, *, include_expensive: bool, query: str = "", ticket: str = ""
    ) -> tuple[list[dict], dict, str]:
        records: list[dict] = []
        coverage: dict[str, Any] = {
            "liveTopology": {"searched": False, "truncated": False},
            "currentPiText": {"searched": False, "truncated": False},
            "savedHudChats": {"searched": False, "truncated": False},
            "firstMate": {"searched": False, "truncated": False},
            "historicalPiArchives": {
                "searched": False,
                "truncated": False,
                "reason": "Historical closed Pi archives are not indexed by discovery-v1",
            },
            "linkedTickets": {"searched": False, "truncated": False},
            "chatTabColors": {
                "searched": False,
                "staleAfterSeconds": CHAT_TAB_STALE_SECONDS,
            },
        }
        generated_at = ""
        response: Optional[dict] = None
        chat_tab_sources: Optional[list[dict]] = None
        try:
            response = self.service.snapshot_response()
            raw_snapshot = response.get("snapshot") if isinstance(response, dict) else None
            snapshot = copy.deepcopy(raw_snapshot) if isinstance(raw_snapshot, dict) else {}
            lifecycle_by_pane = self.service.panes_seen.lifecycle_map()
            if not isinstance(lifecycle_by_pane, dict):
                lifecycle_by_pane = {}
            for pane in snapshot.get("panes", []):
                if not isinstance(pane, dict):
                    continue
                pane_id = _identifier(pane, "pane_id", "paneId")
                lifecycle = lifecycle_by_pane.get(pane_id) if pane_id else None
                if not isinstance(lifecycle, dict):
                    continue
                pane["first_seen_at"] = lifecycle.get("firstSeenAt")
                pane["last_activity_at"] = lifecycle.get("lastActivityAt")
                working_since = lifecycle.get("workingSince")
                if working_since is not None:
                    pane["working_since"] = working_since
            source_generated_at = _timestamp(response) if isinstance(response, dict) else None
            if source_generated_at:
                generated_at = source_generated_at
                coverage["liveTopology"]["generatedAt"] = source_generated_at
            else:
                coverage["liveTopology"]["freshness"] = "unknown"
            coverage["liveTopology"]["searched"] = True
            raw_sources = response.get("chatTabColorSources") if isinstance(response, dict) else None
            if isinstance(raw_sources, list):
                chat_tab_sources = [item for item in raw_sources if isinstance(item, dict)]
        except Exception as exc:
            snapshot = {}
            coverage["liveTopology"]["error"] = type(exc).__name__
            coverage["liveTopology"]["freshness"] = "unknown"
        if chat_tab_sources is None:
            coverage["chatTabColors"]["reason"] = (
                "This companion response does not expose chat tab color publishers"
            )
        else:
            enabled_publishers = [item for item in chat_tab_sources if item.get("enabled") is True]
            current_publishers = [item for item in enabled_publishers if not item.get("stale")]
            stale_publishers = [item for item in enabled_publishers if item.get("stale")]
            disabled_publishers = [item for item in chat_tab_sources if item.get("enabled") is not True]
            coverage["chatTabColors"].update(
                {
                    "searched": True,
                    "publisherCount": len(chat_tab_sources),
                    "currentPublisherCount": len(current_publishers),
                    "stalePublisherCount": len(stale_publishers),
                    "disabledPublisherCount": len(disabled_publishers),
                    "available": bool(enabled_publishers),
                    "freshness": (
                        "current"
                        if current_publishers
                        else ("stale" if enabled_publishers else "none")
                    ),
                }
            )
        tickets_by_identity, tickets_by_work_item = self._ticket_associations(coverage)
        workspaces = [item for item in snapshot.get("workspaces", []) if isinstance(item, dict)]
        tabs = [item for item in snapshot.get("tabs", []) if isinstance(item, dict)]
        panes = [item for item in snapshot.get("panes", []) if isinstance(item, dict)]
        workspace_by_id = {
            _identifier(item, "workspace_id", "workspaceId"): item for item in workspaces
        }
        tab_by_id = {_identifier(item, "tab_id", "tabId"): item for item in tabs}
        pane_updates: dict[str, list[str]] = {}
        tab_updates: dict[str, list[str]] = {}
        for pane in panes:
            updated = _timestamp(pane)
            workspace_id = _identifier(pane, "workspace_id", "workspaceId")
            tab_id = _identifier(pane, "tab_id", "tabId")
            if updated and workspace_id:
                pane_updates.setdefault(workspace_id, []).append(updated)
            if updated and tab_id:
                tab_updates.setdefault(tab_id, []).append(updated)
        for workspace in workspaces:
            workspace_id = _identifier(workspace, "workspace_id", "workspaceId")
            if not workspace_id:
                continue
            title = str(workspace.get("label") or workspace.get("name") or workspace_id)
            cwd = workspace.get("cwd")
            worktree = workspace.get("worktree")
            if not cwd and isinstance(worktree, dict):
                cwd = worktree.get("checkout_path") or worktree.get("cwd")
            updated = _timestamp(workspace) or max(
                pane_updates.get(workspace_id, []), key=_timestamp_value, default=None
            )
            records.append(
                {
                    "kind": "workspace",
                    "id": workspace_id,
                    "title": title,
                    "updatedAt": updated,
                    "status": str(workspace.get("agent_status") or "open"),
                    **({"cwd": str(cwd)} if isinstance(cwd, str) else {}),
                    "target": {
                        "kind": "workspace",
                        "serverId": self.server_id,
                        "workspaceId": workspace_id,
                    },
                    "openModes": ["workspace"],
                    "_fields": {
                        "title": title,
                        "cwd": cwd,
                        "workspaceId": workspace_id,
                    },
                }
            )
        for tab in tabs:
            tab_id = _identifier(tab, "tab_id", "tabId")
            workspace_id = _identifier(tab, "workspace_id", "workspaceId")
            if not tab_id or not workspace_id:
                continue
            workspace = workspace_by_id.get(workspace_id) or {}
            workspace_name = str(workspace.get("label") or workspace.get("name") or workspace_id)
            title = str(tab.get("label") or tab.get("name") or tab_id)
            updated = _timestamp(tab) or max(
                tab_updates.get(tab_id, []), key=_timestamp_value, default=None
            )
            tab_colors = _tab_color_entries(tab)
            tab_record: dict = {
                "kind": "tab",
                "id": tab_id,
                "title": title,
                "updatedAt": updated,
                "status": str(tab.get("agent_status") or "open"),
                "workspaceName": workspace_name,
                "target": {
                    "kind": "tab",
                    "serverId": self.server_id,
                    "workspaceId": workspace_id,
                    "tabId": tab_id,
                },
                "openModes": ["workspace"],
                "_fields": {
                    "title": title,
                    "workspaceName": workspace_name,
                    "workspaceId": workspace_id,
                    "tabId": tab_id,
                    **searchable_colors(tab_colors),
                },
            }
            if tab_colors is not None:
                tab_record["chatTabColors"] = copy.deepcopy(tab_colors)
            records.append(tab_record)
        expensive = (
            sorted(panes, key=lambda item: _timestamp_value(_timestamp(item)), reverse=True)[
                :EXPENSIVE_PANE_LIMIT
            ]
            if include_expensive
            else []
        )
        coverage["currentPiText"]["searched"] = include_expensive
        coverage["currentPiText"]["truncated"] = include_expensive and len(panes) > len(expensive)
        pi_text: dict[str, str] = {}
        for pane in expensive:
            pane_id = _identifier(pane, "pane_id", "paneId")
            if not pane_id:
                continue
            try:
                pi_text[pane_id] = _strings(self.service.pi_snapshot_response(pane_id))
            except Exception:
                continue
        for pane in panes:
            pane_id = _identifier(pane, "pane_id", "paneId")
            workspace_id = _identifier(pane, "workspace_id", "workspaceId")
            tab_id = _identifier(pane, "tab_id", "tabId")
            terminal_id = _identifier(pane, "terminal_id", "terminalId")
            if not pane_id or not workspace_id or not tab_id:
                continue
            workspace = workspace_by_id.get(workspace_id) or {}
            tab = tab_by_id.get(tab_id) or {}
            workspace_name = str(workspace.get("label") or workspace.get("name") or workspace_id)
            tab_name = str(tab.get("label") or tab.get("name") or tab_id)
            title = str(
                pane.get("session_label")
                or pane.get("label")
                or pane.get("title")
                or pane.get("terminal_title_stripped")
                or pane_id
            )
            cwd = pane.get("foreground_cwd") or pane.get("cwd")
            pane_colors = _tab_color_entries(tab)
            target = {
                "kind": "pane",
                "serverId": self.server_id,
                "workspaceId": workspace_id,
                "tabId": tab_id,
                "paneId": pane_id,
            }
            if terminal_id:
                target["terminalId"] = terminal_id
            session_id = _session_id(pane)
            if session_id:
                target["sessionId"] = session_id
            fields = {
                "title": title,
                "workspaceName": workspace_name,
                "tabName": tab_name,
                "cwd": cwd,
                "workspaceId": workspace_id,
                "tabId": tab_id,
                "paneId": pane_id,
                "terminalId": terminal_id,
                "sessionId": session_id,
                **searchable_colors(pane_colors),
            }
            if pane_id in pi_text:
                fields["currentPiText"] = pi_text[pane_id]
            pane_record: dict = {
                "kind": "pane",
                "id": pane_id,
                "title": title,
                "updatedAt": _timestamp(pane),
                "status": str(pane.get("agent_status") or "unknown"),
                "workspaceName": workspace_name,
                "tabName": tab_name,
                **({"cwd": str(cwd)} if isinstance(cwd, str) else {}),
                "target": target,
                "openModes": ["chat", "terminal", "git", "skills"],
                "_fields": fields,
            }
            if pane_colors is not None:
                pane_record["chatTabColors"] = copy.deepcopy(pane_colors)
            records.append(pane_record)
        self._append_hud(
            records,
            coverage,
            include_text=include_expensive,
            query=query,
            ticket=ticket,
        )
        self._append_first_mate(records, coverage, include_text=include_expensive)
        for record in records:
            fields = record.get("_fields")
            target = record.get("target")
            if not isinstance(fields, dict) or not isinstance(target, dict):
                continue
            linked: set[str] = set()
            session_identity = _session_lookup_key(target.get("sessionId"))
            if session_identity is not None:
                linked.update(tickets_by_identity.get(session_identity, set()))
            work_item_id = fields.get("workItemId")
            if work_item_id is not None:
                linked.update(tickets_by_work_item.get(str(work_item_id), set()))
            if linked:
                fields["linkedTicket"] = " ".join(sorted(linked))
        return records, coverage, generated_at

    def _ticket_associations(
        self, coverage: dict
    ) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
        by_identity: dict[str, set[str]] = {}
        by_work_item: dict[str, set[str]] = {}
        try:
            board = self.service.active_work.board_projection()
            items = board.get("items", []) if isinstance(board, dict) else []
            unverifiable_legacy = 0
            for item in items:
                if not isinstance(item, dict):
                    continue
                tickets = {
                    str(link.get("issue_key") or link.get("key"))
                    for link in item.get("jira_links", [])
                    if isinstance(link, dict) and (link.get("issue_key") or link.get("key"))
                }
                if not tickets:
                    continue
                work_item_id = _identifier(item, "id")
                if work_item_id:
                    by_work_item.setdefault(work_item_id, set()).update(tickets)
                sessions = [
                    session for session in item.get("pi_sessions", []) if isinstance(session, dict)
                ]
                for stage in item.get("stages", []):
                    if isinstance(stage, dict):
                        sessions.extend(
                            session
                            for session in stage.get("pi_sessions", [])
                            if isinstance(session, dict)
                        )
                for session in sessions:
                    native_id = _identifier(session, "native_session_id", "nativeSessionId")
                    identity = _session_lookup_key(native_id)
                    if identity is None:
                        identity = _external_native_session_id(
                            session.get("external_id") or session.get("externalId")
                        )
                    if identity is None:
                        # The durable schema has no terminal identity with which to prove that a
                        # legacy pane reference still denotes the same conversation. Raw pane IDs,
                        # internal session_* row IDs, and machine aliases are therefore not joins.
                        unverifiable_legacy += 1
                        continue
                    by_identity.setdefault(identity, set()).update(tickets)
            coverage["linkedTickets"]["searched"] = True
            if unverifiable_legacy:
                coverage["linkedTickets"]["truncated"] = True
                coverage["linkedTickets"]["unverifiableLegacyAssociations"] = unverifiable_legacy
                coverage["linkedTickets"]["reason"] = (
                    "Legacy ticket associations without a native session identity were excluded; "
                    "pane identity cannot be verified from the stored record"
                )
        except Exception as exc:
            coverage["linkedTickets"]["error"] = type(exc).__name__
        return by_identity, by_work_item

    def _append_hud(
        self,
        records: list[dict],
        coverage: dict,
        *,
        include_text: bool,
        query: str,
        ticket: str,
    ) -> None:
        try:
            from .hud_chats import catalog, history

            response = catalog(
                self.service.agent_runs,
                query,
                0,
                ticket=ticket,
                include_match_evidence=True,
            )
            coverage["savedHudChats"]["searched"] = True
            if not isinstance(response, dict):
                return
            if response.get("nextOffset") is not None:
                coverage["savedHudChats"]["truncated"] = True
            chats_by_id = {
                str(chat["id"]): chat
                for chat in response.get("chats", [])
                if isinstance(chat, dict) and chat.get("id")
            }
            for identifier, chat in chats_by_id.items():
                title = str(chat.get("title") or "HUD chat")
                verified_catalog_text = "\n".join(
                    str(item.get("excerpt"))
                    for item in chat.get("matchEvidence", [])
                    if isinstance(item, dict)
                    and isinstance(item.get("excerpt"), str)
                    and item.get("excerpt")
                )
                saved_text = ""
                if include_text:
                    try:
                        history_response = history(self.service.agent_runs, identifier, 0)
                        saved_text = _strings(history_response)
                        if history_response.get("nextOffset") is not None:
                            coverage["savedHudChats"]["truncated"] = True
                    except Exception:
                        saved_text = ""
                records.append(
                    {
                        "kind": "hud-chat",
                        "id": identifier,
                        "title": title,
                        "updatedAt": _timestamp(chat),
                        "status": str(chat.get("status") or "unknown"),
                        "target": {
                            "kind": "hud-chat",
                            "serverId": self.server_id,
                            "hudChatId": identifier,
                            **(
                                {"sessionId": str(chat["sessionId"])}
                                if chat.get("sessionId")
                                else {}
                            ),
                        },
                        "openModes": ["hud"],
                        "_fields": {
                            "title": title,
                            "hudChatId": identifier,
                            "sessionId": chat.get("sessionId"),
                            "promotedPaneId": chat.get("promotedPaneId"),
                            "savedHudText": saved_text,
                            "verifiedCatalogText": verified_catalog_text,
                        },
                    }
                )
        except Exception as exc:
            coverage["savedHudChats"]["error"] = type(exc).__name__

    def _append_first_mate(
        self, records: list[dict], coverage: dict, *, include_text: bool
    ) -> None:
        try:
            features = self.service.first_mate_store.list_features()
            coverage["firstMate"]["searched"] = True
            coverage["firstMate"]["truncated"] = len(features) > 1000
            detailed_ids = {
                str(item.get("id"))
                for item in sorted(
                    (item for item in features if isinstance(item, dict)),
                    key=lambda item: _timestamp_value(_timestamp(item)),
                    reverse=True,
                )[:EXPENSIVE_PANE_LIMIT]
                if item.get("id")
            } if include_text else set()
            if include_text and len(features) > len(detailed_ids):
                coverage["firstMate"]["truncated"] = True
            for feature in features[:1000]:
                if not isinstance(feature, dict) or not feature.get("id"):
                    continue
                identifier = str(feature["id"])
                title = str(feature.get("title") or "First Mate")
                feature_text = ""
                if identifier in detailed_ids:
                    try:
                        feature_text = _strings(
                            self.service.first_mate_store.snapshot(identifier)
                        )
                    except Exception:
                        feature_text = ""
                records.append(
                    {
                        "kind": "first-mate",
                        "id": identifier,
                        "title": title,
                        "updatedAt": _timestamp(feature),
                        "status": str(feature.get("status") or "unknown"),
                        **({"cwd": feature["cwd"]} if isinstance(feature.get("cwd"), str) else {}),
                        "target": {
                            "kind": "first-mate",
                            "serverId": self.server_id,
                            "featureId": identifier,
                        },
                        "openModes": ["first-mate"],
                        "_fields": {
                            "title": title,
                            "featureId": identifier,
                            "goal": feature.get("goal"),
                            "cwd": feature.get("cwd"),
                            "workItemId": feature.get("work_item_id") or feature.get("workItemId"),
                            "firstMateText": feature_text,
                        },
                    }
                )
        except Exception as exc:
            coverage["firstMate"]["error"] = type(exc).__name__
