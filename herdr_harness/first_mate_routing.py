"""Typed, side-effect-free First Mate model routing policy."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Mapping


ModelProfile = Literal["coordinator", "planning", "execution"]
SelectionSource = Literal["feature_override", "host_policy", "assignment_override", "pi_default"]
DELEGATION_PROFILES = frozenset({"planning", "execution"})


@dataclass(frozen=True)
class DispatchPolicy:
    profile: ModelProfile
    requested_model: str
    requested_thinking: str
    source: SelectionSource

    def selection(self, *, actual_model: str | None = None,
                  actual_thinking: str | None = None) -> dict:
        return {
            "profile": self.profile,
            "requested_model": self.requested_model,
            "requested_thinking": self.requested_thinking,
            "actual_model": actual_model,
            "actual_thinking": actual_thinking,
            "source": self.source,
        }


def delegation_profile(value: object, *, stage_key: str | None) -> Literal["planning", "execution"]:
    """Validate an explicit profile, or use only the exact planning stage key."""
    if value is not None:
        if not isinstance(value, str) or value not in DELEGATION_PROFILES:
            raise ValueError("model_profile must be planning or execution")
        return value
    return "planning" if stage_key == "planning" else "execution"


def resolve_dispatch_policy(*, kind: str, feature: Mapping[str, object],
                            claim: Mapping[str, object], environ: Mapping[str, str],
                            stage_key: str | None = None) -> DispatchPolicy:
    """Resolve requested routing for a dispatch without claiming an actual model."""
    legacy_model = str(environ.get("HERDR_FIRST_MATE_MODEL") or "")
    metadata = claim.get("metadata") if isinstance(claim.get("metadata"), Mapping) else {}

    if kind == "coordinator":
        profile: ModelProfile = "coordinator"
        feature_model = str(feature.get("coordinator_model") or "")
        feature_thinking = str(feature.get("coordinator_thinking") or "")
        host_thinking = str(environ.get("HERDR_FIRST_MATE_COORDINATOR_THINKING") or "")
        if feature_model or feature_thinking:
            return DispatchPolicy(profile, feature_model or legacy_model,
                                  feature_thinking or host_thinking, "feature_override")
        if legacy_model or host_thinking:
            return DispatchPolicy(profile, legacy_model, host_thinking, "host_policy")
        return DispatchPolicy(profile, "", "", "pi_default")

    if kind == "advisor":
        profile = "execution"
    else:
        profile = delegation_profile(metadata.get("model_profile"), stage_key=stage_key)
    prefix = "PLANNER" if profile == "planning" else "WORKER"
    role_model = str(environ.get(f"HERDR_FIRST_MATE_{prefix}_MODEL") or "")
    role_thinking = str(environ.get(f"HERDR_FIRST_MATE_{prefix}_THINKING") or "")
    assignment_model = str(claim.get("model") or "")
    if role_model or role_thinking:
        return DispatchPolicy(profile, role_model or assignment_model or legacy_model,
                              role_thinking, "host_policy")
    if assignment_model:
        return DispatchPolicy(profile, assignment_model, "", "assignment_override")
    if legacy_model:
        return DispatchPolicy(profile, legacy_model, "", "host_policy")
    return DispatchPolicy(profile, "", "", "pi_default")


def policy_from_selection(selection: Mapping[str, object]) -> DispatchPolicy:
    """Rebuild a policy from a persisted public selection."""
    return DispatchPolicy(
        selection.get("profile", "execution"),  # type: ignore[arg-type]
        str(selection.get("requested_model") or ""),
        str(selection.get("requested_thinking") or ""),
        selection.get("source", "pi_default"),  # type: ignore[arg-type]
    )
