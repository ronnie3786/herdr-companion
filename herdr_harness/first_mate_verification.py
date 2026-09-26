"""Deterministic First Mate verification coverage assessment.

The durable ledger records what a feature actually ran. This module owns the
pure validation and coverage rules that turn explicit suite inventories and
append-only gate runs into one authoritative verdict. Nothing here reads the
filesystem or executes evidence text, so the same retained inputs always
produce the same assessment.

Suite identity is package-qualified. Two suites with the same display name in
different packages, or with different test configurations, remain distinct.
Inside an assessment, history and coverage keys are additionally
workspace-qualified, so identically named packages in two deliverable
worktrees never cover each other. Unknown fields, missing revisions, and
malformed outcomes are rejected rather than silently normalized into trusted
evidence.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Iterable, Mapping

VERIFICATION_CAPABILITY = "first-mate-verification-v1"

INVENTORY_STATES = ("complete", "incomplete")
RUN_STATUSES = ("completed", "failed", "interrupted")
GATE_OUTCOMES = ("passed", "failed", "error", "skipped")
FAILING_OUTCOMES = ("failed", "error")
SOURCE_STATES = ("clean", "dirty", "unavailable")

STATUS_VERIFIED = "verified"
STATUS_PARTIALLY_VERIFIED = "partially_verified"
STATUS_FAILED = "failed"
STATUS_UNAVAILABLE = "unavailable"
STATUS_LABELS = {
    STATUS_VERIFIED: "Verified",
    STATUS_PARTIALLY_VERIFIED: "Partially verified",
    STATUS_FAILED: "Failed",
    STATUS_UNAVAILABLE: "Verification unavailable",
}

INVENTORY_SUITE_LIMIT = 500
GATE_LIMIT = 1000
SELECTION_LIMIT = 200


class VerificationValidationError(ValueError):
    """A caller-supplied verification payload is not trustworthy evidence."""


def _clean(value: Any, name: str, maximum: int, *, optional: bool = False) -> str:
    if not isinstance(value, str) or "\x00" in value or len(value) > maximum:
        raise VerificationValidationError(f"Invalid {name}")
    text = value.strip()
    if not text and not optional:
        raise VerificationValidationError(f"Invalid {name}")
    return text


def _integer(value: Any, name: str, *, optional: bool = False, minimum: int = 0) -> int | None:
    if value is None and optional:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise VerificationValidationError(f"Invalid {name}")
    return value


def _mapping(value: Any, name: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise VerificationValidationError(f"Invalid {name}")
    return value


def normalize_suite(value: Any) -> dict:
    """Validate one package-qualified suite identity.

    ``package`` is the repository-relative package directory (an empty string
    means the repository root). ``configuration`` distinguishes the same suite
    across build/test configurations. ``selector`` preserves the exact runner
    selector for display and replay evidence.
    """
    suite = _mapping(value, "suite")
    allowed = {"package", "suite", "configuration", "selector"}
    if set(suite) - allowed:
        raise VerificationValidationError("Suite contains an unsupported field")
    package = _clean(suite.get("package", ""), "suite package", 300, optional=True)
    display = _clean(suite.get("suite"), "suite name", 300)
    configuration = _clean(suite.get("configuration", ""), "suite configuration", 200, optional=True)
    selector = _clean(suite.get("selector", ""), "suite selector", 500, optional=True)
    return {"package": package, "suite": display, "configuration": configuration, "selector": selector}


def suite_key(suite: Mapping[str, Any]) -> str:
    """Stable identity: package, display name, and configuration."""
    return f"{suite.get('package', '')}\u0000{suite.get('suite', '')}\u0000{suite.get('configuration', '')}"


def suite_label(suite: Mapping[str, Any]) -> str:
    package = str(suite.get("package", ""))
    name = str(suite.get("suite", ""))
    label = f"{package}/{name}" if package else name
    configuration = str(suite.get("configuration", ""))
    return f"{label} ({configuration})" if configuration else label


def normalize_inventory(value: Any) -> dict:
    """Validate one discovery inventory for a workspace package."""
    inventory = _mapping(value, "inventory")
    allowed = {"workspace", "package", "state", "revision", "suites", "evidence", "source"}
    if set(inventory) - allowed:
        raise VerificationValidationError("Inventory contains an unsupported field")
    workspace = _clean(inventory.get("workspace", "project"), "inventory workspace", 200)
    package = _clean(inventory.get("package", ""), "inventory package", 300, optional=True)
    state = inventory.get("state")
    if state not in INVENTORY_STATES:
        raise VerificationValidationError("Inventory state must be complete or incomplete")
    revision = _clean(inventory.get("revision", ""), "inventory revision", 200, optional=True)
    raw_suites = inventory.get("suites", [])
    if not isinstance(raw_suites, list) or len(raw_suites) > INVENTORY_SUITE_LIMIT:
        raise VerificationValidationError("Inventory suites must be a bounded list")
    suites = [normalize_suite(item) for item in raw_suites]
    keys = [suite_key(item) for item in suites]
    if len(set(keys)) != len(keys):
        raise VerificationValidationError("Inventory contains a duplicate suite identity")
    evidence = _clean(inventory.get("evidence", ""), "inventory evidence", 8000, optional=True)
    source = _clean(inventory.get("source", ""), "inventory source", 500, optional=True)
    return {"workspace": workspace, "package": package, "state": state, "revision": revision,
            "suites": suites, "evidence": evidence, "source": source}


def normalize_gate(value: Any) -> dict:
    """Validate one suite result inside a recorded gate batch."""
    gate = _mapping(value, "gate")
    allowed = {"suite", "outcome", "passed_count", "failed_count", "skipped_count",
               "duration_seconds", "detail"}
    if set(gate) - allowed:
        raise VerificationValidationError("Gate contains an unsupported field")
    suite = normalize_suite(gate.get("suite"))
    outcome = gate.get("outcome")
    if outcome not in GATE_OUTCOMES:
        raise VerificationValidationError("Gate outcome must be passed, failed, error or skipped")
    result = {
        "suite": suite,
        "outcome": outcome,
        "passed_count": _integer(gate.get("passed_count"), "passed_count", optional=True),
        "failed_count": _integer(gate.get("failed_count"), "failed_count", optional=True),
        "skipped_count": _integer(gate.get("skipped_count"), "skipped_count", optional=True),
    }
    duration = gate.get("duration_seconds")
    if duration is not None:
        if isinstance(duration, bool) or not isinstance(duration, (int, float)) or duration < 0:
            raise VerificationValidationError("Invalid duration_seconds")
        result["duration_seconds"] = float(duration)
    result["detail"] = _clean(gate.get("detail", ""), "gate detail", 4000, optional=True)
    return result


def normalize_gate_run(value: Any) -> dict:
    """Validate one append-only gate batch, including failures and interruptions."""
    run = _mapping(value, "run")
    allowed = {"workspace", "revision", "observed_revision", "status", "gates", "summary",
               "inventory", "run_status", "source_state"}
    if set(run) - allowed:
        raise VerificationValidationError("Gate run contains an unsupported field")
    workspace = _clean(run.get("workspace", "project"), "run workspace", 200)
    revision = _clean(run.get("revision"), "tested revision", 200)
    observed = _clean(run.get("observed_revision", ""), "observed revision", 200, optional=True)
    source_state = run.get("source_state", "")
    if source_state not in ("",) + SOURCE_STATES:
        raise VerificationValidationError("Source state must be clean, dirty or unavailable")
    raw_gates = run.get("gates")
    if not isinstance(raw_gates, list) or not raw_gates or len(raw_gates) > GATE_LIMIT:
        raise VerificationValidationError("A gate run needs a bounded non-empty gate list")
    gates = [normalize_gate(item) for item in raw_gates]
    keys = [suite_key(item["suite"]) for item in gates]
    if len(set(keys)) != len(keys):
        raise VerificationValidationError("A gate run cannot repeat a suite identity")
    status = run.get("status", run.get("run_status"))
    if status is None:
        # A batch with a failing suite is a failed batch even when the caller
        # reports a final successful summary.
        status = "failed" if any(item["outcome"] in FAILING_OUTCOMES for item in gates) else "completed"
    if status not in RUN_STATUSES:
        raise VerificationValidationError("Run status must be completed, failed or interrupted")
    summary = _clean(run.get("summary", ""), "run summary", 8000, optional=True)
    inventory = normalize_inventory(run["inventory"]) if run.get("inventory") is not None else None
    return {"workspace": workspace, "revision": revision, "observed_revision": observed,
            "status": status, "gates": gates, "summary": summary, "inventory": inventory,
            "source_state": source_state}


def normalize_selection(value: Any, *, maximum: int | None = SELECTION_LIMIT) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or (maximum is not None and len(value) > maximum):
        raise VerificationValidationError("Verification selection must be a bounded list of run IDs")
    selected: list[str] = []
    for item in value:
        identity = _clean(item, "verification run id", 200)
        if identity in selected:
            raise VerificationValidationError("Verification selection contains a duplicate run ID")
        selected.append(identity)
    return selected


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def scoped_suite_key(workspace: str, suite: Mapping[str, Any]) -> str:
    """Workspace-qualified identity for assessment and history lookups.

    Two worktrees can each contain the same package and suite name. Suite
    identity must never collapse across workspaces, or one worktree's pass
    could cover the other's missing or failing result.
    """
    return f"{workspace}\u0000{suite_key(suite)}"


def _suite_reference(workspace: str, suite: Mapping[str, Any]) -> dict:
    return {"key": scoped_suite_key(workspace, suite), "label": suite_label(suite),
            "workspace": workspace,
            "package": suite.get("package", ""), "suite": suite.get("suite", ""),
            "configuration": suite.get("configuration", "")}


def _best_package(path: str, packages: Iterable[str]) -> str | None:
    """Longest declared package directory containing the repository-relative path."""
    matches = [package for package in packages
               if package == "" or path == package or path.startswith(package.rstrip("/") + "/")]
    if not matches:
        return None
    return max(matches, key=len)


def _named(labels: Iterable[str], limit: int = 8) -> str:
    """Deterministic bounded list that explicitly discloses the remainder."""
    names = list(labels)
    shown = ", ".join(names[:limit])
    if len(names) > limit:
        shown += f" and {len(names) - limit} more"
    return shown


def evaluate_coverage(*, revision_by_workspace: Mapping[str, str] | None = None,
                      changed_paths_by_workspace: Mapping[str, Iterable[str]] | None = None,
                      inventories: list[dict] | None = None,
                      runs: list[dict] | None = None,
                      selected_run_ids: list[str] | None = None,
                      feature_revision: int | None = None,
                      scope_complete: bool = True,
                      scope_reasons: Iterable[str] = (),
                      workspace_aliases: Mapping[str, Iterable[str]] | None = None) -> dict:
    """Assess cumulative feature coverage from retained structured evidence.

    Only a complete, current, passing gate set that covers every suite belonging
    to every changed package at the current workspace revision reaches
    ``verified``. Suite identity is workspace-qualified, so identically named
    packages in two deliverable worktrees never cover each other.

    ``workspace_aliases`` maps a superseded worktree to the leaf deliverable(s)
    that inherited its commits. Retained runs and inventories are replicated
    into those leaves so inherited packages stay required and a re-run at the
    leaf counts as the same suite, while a native inventory always wins over an
    aliased one for the same package.

    Historical passes remain history: a suite that was ever green and lacks a
    current fresh passing result is reported in ``previously_green_missing``
    even when its latest recorded outcome is skipped or it dropped out of a
    replacement inventory. A current failure stays visible until a later
    completed, clean, current passing run supersedes it; stale, interrupted, or
    failed batches never clear a failure and never establish verification.
    Inventory discovery only counts when it was recorded at the current
    workspace revision, so a suite added after discovery cannot be silently
    missed.
    """
    revisions = {str(key): str(value) for key, value in (revision_by_workspace or {}).items()}
    changed = {str(key): sorted({str(item).lstrip("/") for item in value if str(item).strip()})
               for key, value in (changed_paths_by_workspace or {}).items()}
    alias_map = {str(key): [str(target) for target in value]
                 for key, value in (workspace_aliases or {}).items()} if workspace_aliases else {}

    chosen_inventories: dict[tuple[str, str], tuple[bool, str, dict]] = {}
    for raw_inventory in (inventories or []):
        workspace = str(raw_inventory.get("workspace") or "project")
        package = str(raw_inventory.get("package") or "")
        targets = alias_map.get(workspace)
        rows = [(workspace, False, raw_inventory)] if not targets else [
            (target, True, {**raw_inventory, "workspace": target}) for target in targets]
        for target, aliased, row in rows:
            key = (target, package)
            timestamp = str(row.get("updated_at") or row.get("created_at") or "")
            previous = chosen_inventories.get(key)
            if (previous is None or (previous[0] and not aliased)
                    or (previous[0] == aliased and timestamp >= previous[1])):
                chosen_inventories[key] = (aliased, timestamp, row)
    inventory_rows = [row for _aliased, _timestamp, row in chosen_inventories.values()]

    expanded_runs: list[dict] = []
    for raw_run in (runs or []):
        workspace = str(raw_run.get("workspace") or "project")
        targets = alias_map.get(workspace)
        if not targets:
            expanded_runs.append(raw_run)
            continue
        expanded_runs.extend({**raw_run, "workspace": target} for target in targets)

    def _run_view(run: Mapping[str, Any]) -> dict:
        """Accept both the evaluator's natural shape and persisted SQLite rows."""
        return {
            "id": str(run.get("id") or ""),
            "workspace": str(run.get("workspace") or "project"),
            "revision": str(run.get("revision") or run.get("tested_revision") or ""),
            "status": str(run.get("status") or run.get("run_status") or "completed"),
            "source_state": str(run.get("source_state") or run.get("recorded_source_state") or ""),
            "gates": list(run.get("gates") or []),
            "created_at": run.get("created_at"),
        }

    run_rows = [_run_view(run) for run in expanded_runs]
    reasons: list[str] = [str(reason) for reason in scope_reasons if str(reason).strip()]

    # ---- required suites from every changed package's discovery inventory ----
    inventories_by_workspace: dict[str, dict[str, dict]] = {}
    for inventory in inventory_rows:
        workspace = str(inventory.get("workspace") or "project")
        package = str(inventory.get("package") or "")
        inventories_by_workspace.setdefault(workspace, {})[package] = inventory

    changed_packages: list[dict] = []
    unmapped_paths: list[dict] = []
    incomplete_inventories: list[dict] = []
    stale_inventories: list[dict] = []
    required: dict[str, dict] = {}
    covered_packages: set[tuple[str, str]] = set()
    for workspace, paths in changed.items():
        packages = inventories_by_workspace.get(workspace, {})
        current_revision = revisions.get(workspace)
        for path in paths:
            package = _best_package(path, packages)
            if package is None:
                unmapped_paths.append({"workspace": workspace, "path": path})
                reasons.append(f"Changed path {path!r} is not covered by any discovered package inventory")
                continue
            identity = (workspace, package)
            if identity in covered_packages:
                continue
            covered_packages.add(identity)
            inventory = packages[package]
            changed_packages.append({"workspace": workspace, "package": package})
            if inventory.get("state") != "complete":
                incomplete_inventories.append({"workspace": workspace, "package": package,
                                               "state": inventory.get("state")})
                reasons.append(f"Discovery for package {package or '<root>'} is incomplete")
                continue
            revision = str(inventory.get("revision") or "")
            if not current_revision or not revision or revision != current_revision:
                # Discovery describes a different source revision; its suite set
                # may have gained or lost suites. Keep its suites as required
                # evidence but never trust its completeness until revalidated.
                stale_inventories.append({"workspace": workspace, "package": package,
                                          "state": inventory.get("state"), "revision": revision,
                                          "current_revision": current_revision or ""})
                reasons.append(
                    f"Discovery for package {package or '<root>'} was recorded at revision "
                    f"{revision or '<missing>'} rather than the current revision "
                    f"{current_revision or '<unavailable>'}; revalidate the inventory")
            for raw_suite in inventory.get("suites", []):
                normalized = raw_suite if isinstance(raw_suite, dict) else normalize_suite(raw_suite)
                key = scoped_suite_key(workspace, normalized)
                required[key] = {**normalized, "workspace": workspace, "package": package}
    if not scope_complete:
        pass  # scope_reasons already explain why the changed set is unknown.
    if changed and not inventory_rows:
        reasons.append("No suite discovery inventory was recorded for the changed workspace")

    # ---- selected gate set, evaluated in recorded order ---------------------
    by_id: dict[str, dict] = {}
    for run in run_rows:
        identity = str(run.get("id") or "")
        if identity:
            by_id[identity] = run
    requested = (list(selected_run_ids) if selected_run_ids is not None
                 else [str(run.get("id")) for run in run_rows if run.get("id")])
    selection_complete = True
    selected_ids: list[str] = []
    for identity in requested:
        run = by_id.get(str(identity))
        if run is None:
            selection_complete = False
            reasons.append(f"Selected verification run {identity!r} is not retained for this feature")
            continue
        selected_ids.append(str(run.get("id")))
    selected_set = set(selected_ids)
    selected_runs = [run for run in run_rows if str(run.get("id")) in selected_set]

    def _fresh(run: Mapping[str, Any]) -> tuple[bool, str]:
        workspace = str(run.get("workspace") or "project")
        revision = str(run.get("revision") or "")
        current = revisions.get(workspace)
        if str(run.get("status") or "completed") == "interrupted":
            return False, "the run was interrupted"
        if str(run.get("status") or "completed") == "failed":
            return False, "the batch reported a failure"
        source_state = str(run.get("source_state") or "")
        if source_state != "clean":
            return False, ("the recording-time source state was " + source_state
                           if source_state else
                           "the recording-time source state was not recorded as clean")
        if not current:
            return False, "the current workspace revision is unavailable"
        if not revision or revision != current:
            return False, f"recorded revision {revision or '<missing>'} does not match current {current}"
        return True, ""

    stale_evidence: list[dict] = []
    gate_entries: dict[str, dict] = {}
    for run in selected_runs:
        fresh, reason = _fresh(run)
        if not fresh:
            stale_evidence.append({"run_id": run.get("id"), "workspace": run.get("workspace"),
                                   "tested_revision": run.get("revision"), "reason": reason})
            reasons.append(f"Selected evidence from run {run.get('id')} is stale: {reason}")
        workspace = str(run.get("workspace") or "project")
        for gate in run.get("gates", []):
            suite = gate.get("suite", {})
            key = scoped_suite_key(workspace, suite)
            gate_entries[key] = {
                **_suite_reference(workspace, suite),
                "outcome": gate.get("outcome"),
                "passed_count": gate.get("passed_count"),
                "failed_count": gate.get("failed_count"),
                "skipped_count": gate.get("skipped_count"),
                "run_id": run.get("id"),
                "tested_revision": run.get("revision"),
                "fresh": fresh,
                "reason": reason,
                "source_state": run.get("source_state"),
            }
    gate_set = list(gate_entries.values())
    fresh_passed = {key for key, entry in gate_entries.items()
                    if entry["fresh"] and entry["outcome"] == "passed"}

    # ---- current failures remain visible regardless of the selected subset --
    # A failure stays current until a later completed, clean, current passing
    # result supersedes it. Stale, interrupted, or failed batches cannot clear
    # it, and their passing gates cannot establish verification.
    current_failures: dict[str, dict] = {}
    for run in run_rows:
        run_fresh, _run_reason = _fresh(run)
        workspace = str(run.get("workspace") or "project")
        for gate in run.get("gates", []):
            key = scoped_suite_key(workspace, gate.get("suite", {}))
            outcome = gate.get("outcome")
            if outcome in FAILING_OUTCOMES:
                current_failures[key] = {"gate": gate, "run": run, "fresh": run_fresh}
            elif outcome == "passed" and run_fresh:
                current_failures.pop(key, None)
    failing_suites: list[dict] = []
    for key, latest in sorted(current_failures.items(), key=lambda item: item[0]):
        gate, run = latest["gate"], latest["run"]
        workspace = str(run.get("workspace") or "project")
        suite = gate.get("suite", {})
        reference = {**_suite_reference(workspace, suite), "outcome": gate.get("outcome"),
                     "run_id": run.get("id"), "tested_revision": run.get("revision")}
        failing_suites.append(reference)
        selected_entry = gate_entries.get(key)
        if selected_entry is None:
            reasons.append(f"Current failure in {reference['label']} was omitted from the selected gate set")
        elif selected_entry.get("run_id") != run.get("id"):
            reasons.append(f"Current failure in {reference['label']} supersedes an earlier selected result")

    # ---- ever-green history, independent of the latest recorded outcome -----
    ever_passed: dict[str, dict] = {}
    for run in run_rows:
        workspace = str(run.get("workspace") or "project")
        for gate in run.get("gates", []):
            if gate.get("outcome") == "passed":
                suite = gate.get("suite", {})
                ever_passed.setdefault(scoped_suite_key(workspace, suite),
                                       {"suite": suite, "workspace": workspace})
    previously_green_missing = [
        _suite_reference(record["workspace"], record["suite"])
        for key, record in ever_passed.items() if key not in fresh_passed
    ]
    previously_green_missing.sort(key=lambda item: (item["label"], item["key"]))

    missing_suites = [
        {**_suite_reference(suite.get("workspace", "project"), suite),
         "reason": ("never run" if key not in gate_entries else "no current passing result")}
        for key, suite in required.items() if key not in fresh_passed
    ]

    # ---- tested revisions come from selected runs, never from current HEAD --
    tested_revisions = sorted({str(run.get("revision") or "") for run in selected_runs
                               if str(run.get("revision") or "")})

    # ---- verdict ------------------------------------------------------------
    has_evidence = bool(run_rows or inventory_rows)
    if current_failures:
        status = STATUS_FAILED
    elif not has_evidence:
        status = STATUS_UNAVAILABLE
        reasons.append("No structured suite discovery or gate run evidence is retained")
    else:
        complete = (
            scope_complete
            and selection_complete
            and not unmapped_paths
            and not incomplete_inventories
            and not stale_inventories
            and not missing_suites
            and not previously_green_missing
            and not stale_evidence
            and bool(fresh_passed)
            and all(entry["outcome"] == "passed" for entry in gate_entries.values())
        )
        status = STATUS_VERIFIED if complete else STATUS_PARTIALLY_VERIFIED
        if status != STATUS_VERIFIED:
            if missing_suites:
                reasons.append(f"{len(missing_suites)} required suite(s) lack a current passing result: "
                               + _named(item["label"] for item in missing_suites))
            if previously_green_missing:
                reasons.append("Previously passing suite(s) are missing from the current gate set: "
                               + _named(item["label"] for item in previously_green_missing))
            if not gate_entries:
                reasons.append("No selected gate results establish current passing coverage")
    return {
        "status": status,
        "label": STATUS_LABELS[status],
        "feature_revision": feature_revision,
        "assessed_revisions": dict(revisions),
        "source_revisions": tested_revisions,
        "tested_revisions": tested_revisions,
        "gate_set": sorted(gate_set, key=lambda entry: (entry["workspace"], entry["package"],
                                                         entry["suite"], entry["configuration"])),
        "required_suites": [_suite_reference(suite.get("workspace", "project"), suite)
                            for suite in required.values()],
        "missing_suites": missing_suites,
        "previously_green_missing": previously_green_missing,
        "failing_suites": failing_suites,
        "stale_evidence": stale_evidence,
        "coverage_reasons": reasons,
        "unmapped_paths": unmapped_paths,
        "incomplete_inventories": incomplete_inventories,
        "stale_inventories": stale_inventories,
        "changed_packages": changed_packages,
        "selected_run_ids": selected_ids,
        "recorded_run_ids": [str(run.get("id")) for run in run_rows if run.get("id")],
        "run_count": len(run_rows),
        "inventory_count": len(inventory_rows),
        "evidence_present": has_evidence,
        "computed_at": _now(),
    }
