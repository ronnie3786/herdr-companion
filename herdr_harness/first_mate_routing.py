"""Typed, side-effect-free First Mate model routing policy."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Mapping


ModelProfile = Literal["coordinator", "planning", "execution", "architect", "research_scout"]
SelectionSource = Literal["feature_override", "host_policy", "assignment_override", "pi_default"]
DELEGATION_PROFILES = frozenset({"planning", "execution", "architect", "research_scout"})
THINKING_LEVELS = frozenset({"off", "minimal", "low", "medium", "high", "xhigh", "max"})


class SpecialistConfigurationError(ValueError):
    """An explicitly requested specialist cannot fall back to another profile."""


class ArchitectConfigurationError(SpecialistConfigurationError):
    """Architect work has no safe model fallback on this host."""


class ResearchScoutConfigurationError(SpecialistConfigurationError):
    """Research Scout needs an exact host model and private instructions."""


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


def delegation_profile(value: object, *, stage_key: str | None) -> Literal["planning", "execution", "architect", "research_scout"]:
    """Validate an explicit profile, or use only the exact planning stage key."""
    if value is not None:
        if not isinstance(value, str) or value not in DELEGATION_PROFILES:
            raise ValueError("model_profile must be planning, execution, or architect; research_scout is also supported")
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
    if profile in {"architect", "research_scout"}:
        label = "Architect" if profile == "architect" else "Research Scout"
        error_type = ArchitectConfigurationError if profile == "architect" else ResearchScoutConfigurationError
        prefix = profile.upper()
        specialist_model = str(environ.get(f"HERDR_FIRST_MATE_{prefix}_MODEL") or "").strip()
        specialist_thinking = str(environ.get(f"HERDR_FIRST_MATE_{prefix}_THINKING") or "").strip()
        if not specialist_model:
            raise error_type(
                f"{label} work requires first_mate.{profile}_model "
                f"(HERDR_FIRST_MATE_{prefix}_MODEL); no fallback is allowed"
            )
        if "/" not in specialist_model or specialist_model.startswith("/") or specialist_model.endswith("/"):
            raise error_type(
                f"first_mate.{profile}_model must be an exact provider/model identity"
            )
        if specialist_thinking and specialist_thinking not in THINKING_LEVELS:
            raise error_type(
                f"first_mate.{profile}_thinking must be off, minimal, low, medium, high, xhigh, or max"
            )
        if profile == "research_scout":
            from .first_mate_research import read_research_instructions
            read_research_instructions(environ)
        return DispatchPolicy(profile, specialist_model, specialist_thinking, "host_policy")
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
