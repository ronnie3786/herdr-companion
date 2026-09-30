"""Additive compact read shapes. Legacy endpoints retain their full contracts."""
from __future__ import annotations


def verification_summary(value: dict | None) -> dict:
    value = value or {}
    if not value:
        return {}
    result = {key: value[key] for key in (
        "status", "label", "feature_revision", "evidence_present", "computed_at",
        "assessed_revisions", "source_revisions", "tested_revisions",
    )
              if key in value}
    gate_fields = (
        "key", "label", "package", "suite", "configuration", "workspace",
        "outcome", "tested_revision", "run_id", "fresh",
    )
    result["gate_set"] = [
        {key: gate[key] for key in gate_fields if key in gate}
        for gate in value.get("gate_set") or [] if isinstance(gate, dict)
    ]
    result["summary"] = True
    result["counts"] = {key: len(value.get(key) or []) for key in (
        "gate_set", "required_suites", "missing_suites", "failing_suites", "previously_green_missing",
        "stale_evidence", "coverage_reasons", "unmapped_paths", "incomplete_inventories",
        "stale_inventories", "changed_packages", "selected_run_ids", "recorded_run_ids",
    )}
    run_count, inventory_count = value.get("run_count"), value.get("inventory_count")
    result["counts"]["runs"] = (run_count if type(run_count) is int and run_count >= 0
                                  else result["counts"]["recorded_run_ids"])
    result["counts"]["inventories"] = (inventory_count if type(inventory_count) is int and inventory_count >= 0
                                         else 0)
    return result


def feature_summary(feature: dict) -> dict:
    return {**feature, "verification": verification_summary(feature.get("verification"))}


def stable_verification(value: dict) -> dict:
    return {key: item for key, item in value.items() if key != "computed_at"}
