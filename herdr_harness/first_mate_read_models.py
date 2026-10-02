"""Additive compact read shapes. Legacy endpoints retain their full contracts."""
from __future__ import annotations

import json


MESSAGE_PROVENANCE_FIELDS = (
    "in_reply_to", "turn_id", "visit_id", "checkpoint", "assignment_id",
    "relayed_by", "lead_message_id", "lead_machine", "origin", "notice", "initial",
)
EVIDENCE_SUMMARY_BYTES = 4096
EVENT_PAYLOAD_BYTES = 8192


def _encoded_size(value) -> int:
    return len(json.dumps(value, ensure_ascii=False).encode())


def _evidence_preview(value, *, depth: int = 0):
    """A bounded display sample, never evidence used to authorize a mutation."""
    if isinstance(value, str):
        return value if len(value) <= 500 else value[:500] + " [truncated]"
    if depth >= 5 and isinstance(value, (dict, list)):
        return {"count": len(value), "truncated": True}
    if isinstance(value, list):
        return [_evidence_preview(item, depth=depth + 1) for item in value[:3]]
    if isinstance(value, dict):
        result = {key: _evidence_preview(item, depth=depth + 1)
                  for key, item in list(value.items())[:30]}
        for key, item in list(value.items())[:30]:
            if isinstance(item, list):
                result[key + "_count"] = len(item)
                result[key + "_truncated"] = len(item) > 3
        if len(value) > 30:
            result["fields_truncated"] = True
        return result
    return value


def evidence_summary(value: dict | None) -> dict:
    """Small historical verdict plus exact counts and sampled proof references."""
    value = value or {}
    result = verification_summary(value)
    # Keep exact status and totals, even when the sampled historical gate list
    # cannot contain every suite. The detailed API retains the complete proof.
    counts = result.get("counts", {})
    prior_counts = value.get("counts")
    if isinstance(prior_counts, dict):
        counts = {key: prior_counts[key] if type(prior_counts.get(key)) is int
                  and 0 <= prior_counts[key] <= 2 ** 53 - 1 else total for key, total in counts.items()}
    result["counts"] = counts
    result["gate_set"] = _evidence_preview(result.get("gate_set", []))
    result["gate_set_truncated"] = bool(value.get("gate_set_truncated")) or len(value.get("gate_set", [])) > 3
    for key in ("assessed_revisions", "source_revisions", "tested_revisions"):
        if key in result:
            samples = dict(list(result[key].items())[:3]) if isinstance(result[key], dict) else result[key]
            result[key] = _evidence_preview(samples)
            if isinstance(value.get(key), (dict, list)):
                result[key + "_count"] = value.get(key + "_count", len(value[key]))
                result[key + "_truncated"] = bool(value.get(key + "_truncated")) or len(value[key]) > 3
    result["summary"] = True
    # Per-node samples alone are not a byte budget: multibyte labels and many
    # workspace keys can still multiply. Drop optional proof samples until the
    # serialized record fits, keeping exact totals and a visible truncation flag.
    while result["gate_set"] and _encoded_size(result) > EVIDENCE_SUMMARY_BYTES:
        result["gate_set"].pop()
        result["gate_set_truncated"] = True
    for key in ("assessed_revisions", "source_revisions", "tested_revisions"):
        if _encoded_size(result) > EVIDENCE_SUMMARY_BYTES and key in result:
            result[key] = {} if isinstance(result[key], dict) else []
            result[key + "_truncated"] = True
    if _encoded_size(result) > EVIDENCE_SUMMARY_BYTES:
        result = {"status": str(value.get("status", ""))[:64],
                  "label": str(value.get("label", ""))[:200],
                  "counts": counts, "summary": True, "detail_truncated": True,
                  "gate_set": [], "gate_set_truncated": bool(value.get("gate_set"))}
    return result


def verification_presentation(value: dict | None) -> dict:
    """Keep all current failures and scope; compact only retained history."""
    value = value or {}
    history = value.get("historical_evidence")
    if not isinstance(history, dict):
        return value
    return {**value, "historical_evidence": evidence_summary(history),
            "historical_evidence_summary": True}


def message_presentation(message: dict) -> dict:
    metadata = message.get("metadata")
    if not isinstance(metadata, dict):
        return message
    # IDs are retained exactly or omitted with their detail reference. Never
    # produce a shortened ID that could point at a different conversation.
    presented = {key: metadata[key] for key in MESSAGE_PROVENANCE_FIELDS
                 if key in metadata and (type(metadata[key]) is bool
                     or isinstance(metadata[key], str) and _encoded_size(metadata[key]) <= 256)}
    if isinstance(metadata.get("verification"), dict):
        presented["verification"] = evidence_summary(metadata["verification"])
    if presented == metadata:
        return message
    return {**message, "metadata": presented, "metadata_summary": True,
            "metadata_detail_reference": {"feature_id": message.get("feature_id"),
                                          "message_id": message.get("id")}}


def event_presentation(event: dict) -> dict:
    payload = event.get("payload")
    if _encoded_size(payload) <= EVENT_PAYLOAD_BYTES:
        return event
    presented = dict(payload) if isinstance(payload, dict) else {"detail_truncated": True}
    if isinstance(presented.get("verification"), dict):
        presented["verification"] = evidence_summary(presented["verification"])
    if _encoded_size(presented) > EVENT_PAYLOAD_BYTES:
        presented = _evidence_preview(presented)
    if _encoded_size(presented) > EVENT_PAYLOAD_BYTES:
        # Keep an exact producer reference when even a structural sample is
        # too large. The event envelope and raw-event page remain authoritative.
        presented = {key: payload[key] for key in ("assignment_id", "visit_id", "native_session_id", "message_id")
                     if isinstance(payload.get(key), str) and _encoded_size(payload[key]) <= 256}
        presented.update({"field_count": len(payload), "detail_truncated": True})
    return {**event, "payload": presented, "payload_summary": True,
            "payload_detail_reference": {"feature_id": event.get("feature_id"),
                                         "after": max(0, event["sequence"] - 1), "limit": 1}}


def activity_presentation(value: dict) -> dict:
    """Compact human read surfaces without rewriting retained ledger evidence.

    Message metadata remains available in the legacy feature detail snapshot;
    event references identify a page of the authenticated feature events API.
    """
    result = dict(value)
    if isinstance(result.get("feature"), dict):
        feature = result["feature"]
        result["feature"] = {**feature, "verification": verification_presentation(feature.get("verification"))}
    for key, present in (("messages", message_presentation), ("events", event_presentation), ("journal", event_presentation)):
        if key in result:
            result[key] = [present(row) for row in result[key]]
    return result


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
