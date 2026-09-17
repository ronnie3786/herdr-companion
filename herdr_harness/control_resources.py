"""Typed, durable resource actions for agent-control-v1."""
from __future__ import annotations

import threading
from pathlib import Path
from typing import Any, Optional

from .client import HerdrAPIError, HerdrClientError
from .control_store import ControlStore
from .control_validation import ControlError, validate_parameters
from .pi_semantic import PiSemanticError, valid_pi_session_id


def _object_schema(properties: Optional[dict] = None, required: Optional[list[str]] = None) -> dict:
    value: dict[str, Any] = {
        "type": "object",
        "properties": properties or {},
        "additionalProperties": False,
    }
    if required:
        value["required"] = required
    return value


def _string_schema(*values: str) -> dict:
    value: dict[str, Any] = {"type": "string"}
    if values:
        value["enum"] = list(values)
    return value


RESOURCE_ACTIONS = [
    {
        "id": "workspace.create",
        "title": "Create workspace",
        "parameters": _object_schema({"name": _string_schema(), "cwd": _string_schema()}, ["name", "cwd"]),
        "targetKinds": [],
        "effect": "mutation",
        "enabled": True,
    },
    {
        "id": "tab.create",
        "title": "Create tab",
        "parameters": _object_schema({"name": _string_schema(), "cwd": _string_schema()}),
        "targetKinds": ["workspace"],
        "effect": "mutation",
        "enabled": True,
    },
    {
        "id": "chat.create",
        "title": "Create Pi chat",
        "parameters": _object_schema(
            {"name": _string_schema(), "cwd": _string_schema(), "parentSessionId": _string_schema()}
        ),
        "targetKinds": ["workspace", "tab"],
        "effect": "mutation",
        "enabled": True,
    },
    {
        "id": "workspace.rename",
        "title": "Rename workspace",
        "parameters": _object_schema({"name": _string_schema()}, ["name"]),
        "targetKinds": ["workspace"],
        "effect": "mutation",
        "enabled": True,
    },
    {
        "id": "tab.rename",
        "title": "Rename tab",
        "parameters": _object_schema({"name": _string_schema()}, ["name"]),
        "targetKinds": ["tab"],
        "effect": "mutation",
        "enabled": True,
    },
    {
        "id": "pane.rename",
        "title": "Rename pane",
        "parameters": _object_schema({"name": _string_schema()}, ["name"]),
        "targetKinds": ["pane"],
        "effect": "mutation",
        "enabled": True,
    },
    {
        "id": "pane.star",
        "title": "Set pane star",
        "parameters": _object_schema({"starred": {"type": "boolean"}}, ["starred"]),
        "targetKinds": ["pane"],
        "effect": "mutation",
        "enabled": True,
    },
    {
        "id": "pane.split",
        "title": "Split pane",
        "parameters": _object_schema({"direction": _string_schema("right", "down")}, ["direction"]),
        "targetKinds": ["pane"],
        "effect": "mutation",
        "enabled": True,
    },
    {
        "id": "pane.close",
        "title": "Close pane",
        "parameters": _object_schema(),
        "targetKinds": ["pane"],
        "effect": "mutation",
        "enabled": True,
    },
    {
        "id": "pane.retire",
        "title": "End Pi and close pane",
        "parameters": _object_schema(),
        "targetKinds": ["pane"],
        "effect": "mutation",
        "enabled": True,
    },
    {
        "id": "pane.compact",
        "title": "Compact Pi context",
        "parameters": _object_schema(),
        "targetKinds": ["pane"],
        "effect": "mutation",
        "enabled": True,
    },
    {
        "id": "pane.interrupt",
        "title": "Interrupt Pi",
        "parameters": _object_schema(),
        "targetKinds": ["pane"],
        "effect": "mutation",
        "enabled": True,
    },
    {
        "id": "pane.focus-terminal",
        "title": "Focus terminal pane",
        "parameters": _object_schema(),
        "targetKinds": ["pane"],
        "effect": "navigation",
        "enabled": True,
    },
    {
        "id": "pane.zoom-terminal",
        "title": "Set terminal zoom",
        "parameters": _object_schema({"mode": _string_schema("on", "off")}, ["mode"]),
        "targetKinds": ["pane"],
        "effect": "navigation",
        "enabled": True,
    },
]

_ACTION_BY_ID = {item["id"]: item for item in RESOURCE_ACTIONS}


def _field(record: dict, *keys: str) -> Optional[str]:
    for key in keys:
        value = record.get(key)
        if isinstance(value, (str, int)) and str(value):
            return str(value)
    return None


def _pane_session_id(pane: dict) -> Optional[str]:
    session_id = _field(pane, "session_id", "sessionId")
    semantic = pane.get("pi_semantic") or pane.get("piSemantic")
    if session_id is None and isinstance(semantic, dict):
        session_id = _field(semantic, "session_id", "sessionId")
    info = pane.get("agent_info") or pane.get("agentInfo")
    if session_id is None and isinstance(info, dict):
        session_id = _field(info, "session_id", "sessionId", "id")
    return session_id


def _collect_ids(value: Any, key: str) -> set[str]:
    result: set[str] = set()

    def visit(item: Any) -> None:
        if isinstance(item, dict):
            candidate = item.get(key)
            if isinstance(candidate, (str, int)) and str(candidate):
                result.add(str(candidate))
            for child in item.values():
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)

    visit(value)
    return result


class ResourceActionService:
    def __init__(self, service: Any, store: ControlStore) -> None:
        self.service = service
        self.store = store
        self.server_id = store.server_id
        self._lock = threading.RLock()

    def actions(self) -> list[dict]:
        return RESOURCE_ACTIONS

    def operation(self, request_id: str) -> dict:
        # Do not expose the internal reservation as a terminal receipt while
        # an in-process mutation is still executing.
        with self._lock:
            return self.store.operation(request_id)

    def invoke(self, payload: dict) -> dict:
        request_id = payload["requestId"]
        action = payload["action"]
        target = payload.get("target")
        parameters = payload["parameters"]
        dry_run = payload.get("dryRun", False)

        # Serialize reservation and execution. For mutations, reserve the exact
        # caller payload before revalidating paths or current topology so a
        # retry returns its prior receipt even when the environment changed.
        with self._lock:
            if dry_run:
                self._validate_invocation(action, target, parameters)
                resolved = self._resolve_target(target) if target is not None else None
                return {
                    "requestId": request_id,
                    "action": action,
                    "status": "completed",
                    "result": {
                        "dryRun": True,
                        **({"target": resolved} if resolved is not None else {}),
                    },
                }
            operation, created = self.store.reserve_operation(request_id, action, payload)
            if not created:
                return operation
            effect_started = {"value": False}
            try:
                self._validate_invocation(action, target, parameters)
                resolved = self._resolve_target(target) if target is not None else None
                result = self._execute(
                    request_id, action, resolved, parameters, effect_started=effect_started
                )
            except HerdrAPIError as exc:
                # A structured Herdr rejection is authoritative: the requested
                # operation was rejected rather than accepted with a lost reply.
                return self.store.finish_operation(
                    request_id,
                    status="failed",
                    error={"code": exc.code, "message": str(exc)},
                )
            except PiSemanticError as exc:
                uncertain = effect_started["value"] and exc.status >= 500
                return self.store.finish_operation(
                    request_id,
                    status="outcome_unknown" if uncertain else "failed",
                    error={"code": exc.code, "message": str(exc)},
                )
            except (ControlError, HerdrClientError) as exc:
                return self.store.finish_operation(
                    request_id,
                    status="outcome_unknown" if effect_started["value"] else "failed",
                    error={"code": exc.code, "message": str(exc)},
                )
            except Exception:
                return self.store.finish_operation(
                    request_id,
                    status="outcome_unknown",
                    error={
                        "code": "operation_outcome_unknown",
                        "message": "The operation outcome could not be determined",
                    },
                )
            return self.store.finish_operation(request_id, status="completed", result=result)

    def _validate_invocation(
        self, action: str, target: Optional[dict], parameters: dict
    ) -> None:
        descriptor = _ACTION_BY_ID.get(action)
        if descriptor is None:
            raise ControlError(
                "Resource action is not supported", code="unsupported_action", status=404
            )
        validate_parameters(parameters, descriptor["parameters"])
        self._validate_parameter_values(parameters)
        expected_kinds = descriptor["targetKinds"]
        if expected_kinds:
            if target is None or target.get("kind") not in expected_kinds:
                raise ControlError("Action target kind is invalid")
        elif target is not None:
            raise ControlError("This action does not accept a target")
        if target is not None and target.get("serverId") not in {None, self.server_id}:
            raise ControlError("Target belongs to another server", code="stale_target", status=409)

    def _validate_parameter_values(self, parameters: dict) -> None:
        name = parameters.get("name")
        if name is not None and (
            not isinstance(name, str) or not name.strip() or "\x00" in name or len(name) > 120
        ):
            raise ControlError("parameters.name is invalid")
        cwd = parameters.get("cwd")
        if cwd is not None:
            if not isinstance(cwd, str) or "\x00" in cwd or len(cwd) > 4096:
                raise ControlError("parameters.cwd is invalid")
            candidate = Path(cwd).expanduser()
            if not candidate.is_absolute() or not candidate.is_dir():
                raise ControlError("parameters.cwd must be an existing absolute directory")
        parent = parameters.get("parentSessionId")
        if parent is not None and not valid_pi_session_id(parent):
            raise ControlError("parameters.parentSessionId is invalid")

    def _fresh_snapshot(self) -> dict:
        snapshot = self.service.refresh_snapshot(force=True)
        if not isinstance(snapshot, dict):
            raise HerdrClientError("Herdr returned an invalid snapshot", code="invalid_herdr_response")
        return snapshot

    def _resolve_target(self, target: dict) -> dict:
        snapshot = self._fresh_snapshot()
        kind = target.get("kind")
        if kind == "workspace":
            workspace_id = target.get("workspaceId")
            workspace = next(
                (
                    item
                    for item in snapshot.get("workspaces", [])
                    if isinstance(item, dict) and _field(item, "workspace_id", "workspaceId") == workspace_id
                ),
                None,
            )
            if workspace is None:
                raise ControlError("Workspace not found", code="not_found", status=404)
            return {"kind": "workspace", "serverId": self.server_id, "workspaceId": workspace_id}
        if kind == "tab":
            tab_id = target.get("tabId")
            tab = next(
                (
                    item
                    for item in snapshot.get("tabs", [])
                    if isinstance(item, dict) and _field(item, "tab_id", "tabId") == tab_id
                ),
                None,
            )
            if tab is None:
                raise ControlError("Tab not found", code="not_found", status=404)
            workspace_id = _field(tab, "workspace_id", "workspaceId")
            if target.get("workspaceId") is not None and target.get("workspaceId") != workspace_id:
                raise ControlError("Tab target is stale", code="stale_target", status=409)
            return {
                "kind": "tab",
                "serverId": self.server_id,
                "workspaceId": workspace_id,
                "tabId": tab_id,
            }
        if kind == "pane":
            pane_id = target.get("paneId")
            pane = next(
                (
                    item
                    for item in snapshot.get("panes", [])
                    if isinstance(item, dict) and _field(item, "pane_id", "paneId") == pane_id
                ),
                None,
            )
            if pane is None:
                raise ControlError("Pane not found", code="not_found", status=404)
            terminal_id = _field(pane, "terminal_id", "terminalId")
            if not target.get("terminalId"):
                raise ControlError("Pane target requires terminalId", code="stale_target", status=409)
            if terminal_id != target.get("terminalId"):
                raise ControlError("Pane terminal identity is stale", code="stale_target", status=409)
            workspace_id = _field(pane, "workspace_id", "workspaceId")
            tab_id = _field(pane, "tab_id", "tabId")
            if target.get("workspaceId") is not None and target.get("workspaceId") != workspace_id:
                raise ControlError("Pane workspace identity is stale", code="stale_target", status=409)
            if target.get("tabId") is not None and target.get("tabId") != tab_id:
                raise ControlError("Pane tab identity is stale", code="stale_target", status=409)
            session_id = _pane_session_id(pane)
            try:
                capability = self.service.pi_semantic.capability(pane_id)
                if isinstance(capability, dict):
                    session_id = _field(capability, "session_id", "sessionId") or session_id
            except Exception as exc:
                raise ControlError(
                    "Pane session identity could not be verified",
                    code="target_identity_unavailable",
                    status=503,
                ) from exc
            if session_id and target.get("sessionId") != session_id:
                raise ControlError("Pane session identity is stale", code="stale_target", status=409)
            if not session_id and target.get("sessionId") is not None:
                raise ControlError("Pane session identity is stale", code="stale_target", status=409)
            result = {
                "kind": "pane",
                "serverId": self.server_id,
                "workspaceId": workspace_id,
                "tabId": tab_id,
                "paneId": pane_id,
                "terminalId": terminal_id,
            }
            if session_id:
                result["sessionId"] = session_id
            return result
        raise ControlError("Target kind is invalid")

    def _execute(
        self,
        request_id: str,
        action: str,
        target: Optional[dict],
        parameters: dict,
        *,
        effect_started: dict[str, bool],
    ) -> dict:
        def begin_effect() -> None:
            effect_started["value"] = True

        if action == "workspace.create":
            begin_effect()
            response = self.service.invoke(
                "workspace.create",
                {"label": parameters["name"], "cwd": parameters["cwd"], "focus": False, "env": {}},
            )
            return {"target": self._created_target(response.get("result"), "workspace")}
        if action == "tab.create":
            assert target is not None
            native = {"workspace_id": target["workspaceId"], "focus": False, "env": {}}
            if parameters.get("name") is not None:
                native["label"] = parameters["name"]
            if parameters.get("cwd") is not None:
                native["cwd"] = parameters["cwd"]
            begin_effect()
            response = self.service.invoke("tab.create", native)
            created = self._created_target(response.get("result"), "tab")
            if created.get("workspaceId") != target["workspaceId"]:
                raise HerdrClientError(
                    "Created tab membership could not be verified", code="operation_outcome_unknown"
                )
            return {"target": created}
        if action == "chat.create":
            assert target is not None
            begin_effect()
            response = self.service.quick_pi_session(
                parameters.get("name") or "New chat",
                workspace_id=target["workspaceId"],
                tab_id=target.get("tabId"),
                cwd=parameters.get("cwd"),
                parent_session_id=parameters.get("parentSessionId"),
                request_id=request_id,
                focus=False,
            )
            pane_id = response.get("pane_id")
            if not pane_id:
                raise HerdrClientError(
                    "Created chat did not return a pane", code="operation_outcome_unknown"
                )
            created = self._target_for_pane(str(pane_id))
            returned_session = _field(response, "session_id", "sessionId")
            if returned_session and created.get("sessionId") != returned_session:
                raise HerdrClientError(
                    "Created chat session identity could not be verified",
                    code="operation_outcome_unknown",
                )
            return {"target": created}
        assert target is not None
        begin_effect()
        if action == "workspace.rename":
            self.service.invoke(
                "workspace.rename", {"workspace_id": target["workspaceId"], "label": parameters["name"]}
            )
        elif action == "tab.rename":
            self.service.invoke("tab.rename", {"tab_id": target["tabId"], "label": parameters["name"]})
        elif action == "pane.rename":
            self.service.invoke("pane.rename", {"pane_id": target["paneId"], "label": parameters["name"]})
        elif action == "pane.star":
            result = self.service.set_pane_star(target["paneId"], parameters["starred"])
            if result is None:
                raise ControlError("Pane outcome could not be verified", code="operation_outcome_unknown")
        elif action == "pane.split":
            response = self.service.invoke(
                "pane.split",
                {
                    "target_pane_id": target["paneId"],
                    "direction": parameters["direction"],
                    "focus": False,
                    "env": {},
                },
            )
            return {"target": self._created_target(response.get("result"), "pane")}
        elif action == "pane.close":
            self.service.invoke("pane.close", {"pane_id": target["paneId"]})
        elif action == "pane.retire":
            self.service.pane_lifecycle.retire(
                target["paneId"],
                request_id=request_id,
                terminal_id=target["terminalId"],
                session_id=target.get("sessionId"),
            )
        elif action == "pane.compact":
            self.service.pi_command(target["paneId"], "compact", {})
        elif action == "pane.interrupt":
            self.service.pi_command(target["paneId"], "abort", {})
        elif action == "pane.focus-terminal":
            self.service.invoke("pane.focus", {"pane_id": target["paneId"]})
        elif action == "pane.zoom-terminal":
            self.service.invoke(
                "pane.zoom", {"pane_id": target["paneId"], "mode": parameters["mode"]}
            )
        else:
            raise ControlError("Resource action is not supported", code="unsupported_action", status=404)
        return {"target": target}

    def _created_target(self, raw: Any, kind: str) -> dict:
        key = {"workspace": "workspace_id", "tab": "tab_id", "pane": "pane_id"}[kind]
        camel_key = {"workspace": "workspaceId", "tab": "tabId", "pane": "paneId"}[kind]
        collection = {"workspace": "workspaces", "tab": "tabs", "pane": "panes"}[kind]
        candidates = _collect_ids(raw, key) | _collect_ids(raw, camel_key)
        if len(candidates) != 1:
            raise HerdrClientError(
                f"Created {kind} response did not contain one exact identity",
                code="operation_outcome_unknown",
            )
        identifier = next(iter(candidates))
        after = self._fresh_snapshot()
        created_record = next(
            (
                item
                for item in after.get(collection, [])
                if isinstance(item, dict) and _field(item, key, camel_key) == identifier
            ),
            None,
        )
        if created_record is None:
            raise HerdrClientError(
                f"Created {kind} identity could not be verified",
                code="operation_outcome_unknown",
            )
        if kind == "workspace":
            return {"kind": "workspace", "serverId": self.server_id, "workspaceId": identifier}
        if kind == "tab":
            workspace_id = _field(created_record, "workspace_id", "workspaceId")
            if not workspace_id:
                raise HerdrClientError(
                    "Created tab membership could not be verified", code="operation_outcome_unknown"
                )
            return {
                "kind": "tab",
                "serverId": self.server_id,
                "workspaceId": workspace_id,
                "tabId": identifier,
            }
        return self._target_for_pane(identifier, snapshot=after)

    def _target_for_pane(self, pane_id: str, *, snapshot: Optional[dict] = None) -> dict:
        snapshot = snapshot or self._fresh_snapshot()
        pane = next(
            (
                item
                for item in snapshot.get("panes", [])
                if isinstance(item, dict) and _field(item, "pane_id", "paneId") == pane_id
            ),
            None,
        )
        terminal_id = _field(pane, "terminal_id", "terminalId") if isinstance(pane, dict) else None
        workspace_id = _field(pane, "workspace_id", "workspaceId") if isinstance(pane, dict) else None
        tab_id = _field(pane, "tab_id", "tabId") if isinstance(pane, dict) else None
        if pane is None or not terminal_id or not workspace_id or not tab_id:
            raise HerdrClientError("Created pane identity could not be verified", code="operation_outcome_unknown")
        target = {
            "kind": "pane",
            "serverId": self.server_id,
            "workspaceId": workspace_id,
            "tabId": tab_id,
            "paneId": pane_id,
            "terminalId": terminal_id,
        }
        session_id = _pane_session_id(pane)
        try:
            capability = self.service.pi_semantic.capability(pane_id)
            if isinstance(capability, dict):
                session_id = _field(capability, "session_id", "sessionId") or session_id
        except Exception:
            pass
        if session_id:
            target["sessionId"] = session_id
        return target
