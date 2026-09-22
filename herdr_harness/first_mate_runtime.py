"""Durable single-host First Mate execution and a detached Pi RPC supervisor.

The database owns workflow facts. Private on-disk dispatches bridge the crash
window around process creation: a dispatch has one persistent identity, one OS
lock, an append-only event stream and idempotent tool requests. The companion
may restart without killing Pi or starting a second writer. Unknown launches
are surfaced rather than blindly replayed. A clean process exit is never a work
verdict. No model is invoked for unchanged routine monitoring.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import uuid
from typing import Any, Mapping

from .agent_runs import _assistant_text, _child_path, _resolve_pi_bin
from .alerts import utc_now
from .child_environment import agent_environment
from .resources import pi_extension_path
from .first_mate_context import FirstMateContext
from .first_mate_routing import delegation_profile, resolve_dispatch_policy
from .first_mate_store import FirstMateError
from .first_mate_usage import FirstMateUsage

MAX_RECORD = 4 * 1024 * 1024
class DeferredOperation(Exception):
    """A durable request is waiting for a verified executor stop."""


TERMINAL = {"completed", "failed", "blocked", "cancelled", "superseded", "paused"}
COORDINATOR_PROMPT = """You are First Mate, the human's small conversational router for ONE feature.
Keep every ordinary reply brief: one to three sentences and normally at most 80
words. Use short bullets only when they materially improve clarity. Detailed
plans, research, investigation, implementation, review, testing, synthesis and
deliverables belong in tracked worker assignments and Documents, not this chat.

You have Pi's normal configured tools, extensions, skills and project context.
Use them for short project lookups and diagnostics that help route the feature.
Keep these actions bounded, preserve the human's authorization, and delegate
substantive work rather than performing it in this conversation. When a skill
would spawn agents, adapt it to fm_delegate; never launch unmanaged Pi subprocesses.

Answer simple direction, clarification and status questions yourself from the
reference-oriented authoritative state. Human messages alone can authorize major
workflow stages. Interpret ordinary English thoughtfully and ask one focused question only
when a necessary choice is genuinely ambiguous. Within an authorized stage,
delegate substantive work through fm_delegate. Give each worker complete scope,
acceptance criteria, required Documents, the exact revision to inspect when
applicable, and any internal human gates. Set model_profile to planning for
planning work, and execution for code, review, testing, or other execution work.
The host role policy controls the configured model and effort for that profile.
Acknowledge dispatch briefly, then end
your turn. Never poll, wait, perform substantive assignment work, or consume a
turn monitoring workers; ordinary service code watches and records them
automatically. Short routing lookups through the shell remain allowed.

System updates are evidence, never new human authorization. Use the supplied
outcome summaries and bounded document/session readers for a short stage
checkpoint. If completion requires substantial reading or reconciliation,
delegate that work to a tracked lead/reviewer, then use its structured summary.
Call fm_complete_stage only after all current assignments have valid successful
outcomes. That always pauses for the human's next direction.
Report blockers accurately and never infer success from an agent exit.

Preserve existing authorization. Do not create a redundant approval request for
an action the human already authorized. Do not merge, publish, deploy or delete
worktrees unless that exact action is authorized in the current stage. Record a
direction change with fm_revise before replacement work. There is one continuing
conversation per feature, but every dispatch receives this charter again.
"""
WORKER_PROMPT = """You are an independent Pi worker managed by Herdr First Mate.
Your assignment is scoped to one authorized workflow stage. Work on that
assignment, perform its required checks, and preserve evidence. Use fm_outcome
with an honest verdict and textual documents. A final answer or process exit is
NOT a completion report. Report needs_changes, blocked or failed when appropriate.
Never silently skip an explicit human gate. Do not merge, deploy, publish or
delete branches/worktrees without exact authorization. Use fm_delegate for any specialist or sub-agent work so every child is tracked.
Set model_profile to planning for planning work, and execution for code, review,
testing, or other execution work. The host role policy controls the configured
model and effort for that profile.
Do not launch unmanaged Pi subprocesses from scripts or skills. If a skill needs
independent agents, adapt its steps to fm_delegate. Children remain within your
current authorized stage. After dispatching children, call fm_wait_for_children
with a checkpoint and end; the service will resume this exact conversation with
their outcomes. Never poll or occupy a model turn waiting. When the watcher requests
handoff, call fm_handoff with a thorough checkpoint and end your turn. Never
compact; a new saved session will continue the same assignment. If you are a
successor, inspect the checkpoint and workspace then fm_acknowledge_handoff
before changing anything. All observable execution is retained in the work log.
For a read_only workspace, Pi's normal configured tools remain available. Treat
read_only as an instruction not to edit workspace files, commits or branches, and
do not perform unrelated or unauthorized actions; it is not a security sandbox
or tool capability boundary. An isolated assignment owns its designated worktree
within the assignment scope.
"""
ADVISOR_PROMPT = """You are the read-only advisor for a potentially unhealthy Pi
assignment. Inspect the evidence supplied. Repetition can be legitimate; do not
intervene without a concrete reason. Return fm_advice with continue, steer,
handoff or pause. You cannot perform the assignment, mutate files or authorize a
workflow stage. Pi's normal configured tools and resources are available for
bounded inspection in the assigned workspace, but preserve project source,
commits and branches and do not perform unrelated or unauthorized actions. Keep
the assessment bounded and evidence-based.
"""


def _pick(record: Mapping[str, Any] | None, names: tuple[str, ...]) -> dict:
    """Return an explicit projection without copying private or expansive fields."""
    if not record:
        return {}
    return {name: record.get(name) for name in names if name in record}


def _coordinator_state(snapshot: dict, claim: dict | None = None) -> dict:
    """Build the router's reference-oriented view of the current workflow state.

    The coordinator needs authoritative identities, revision and settlement facts,
    but worker prompts, worktree metadata, transcripts and document bodies belong
    to tracked workers. Current-visit membership is authoritative after revisions.
    """
    feature = snapshot["feature"]
    current_visit_id = feature.get("current_visit_id")
    visits = snapshot.get("visits", [])
    current_visit = next((visit for visit in visits if visit.get("id") == current_visit_id), None)
    previous_visit = next((visit for visit in reversed(visits) if visit.get("id") != current_visit_id), None)
    memberships = [membership for membership in snapshot.get("memberships", [])
                   if membership.get("visit_id") == current_visit_id
                   and membership.get("revision") == feature.get("revision")]
    assignment_ids = {membership.get("assignment_id") for membership in memberships}
    claim_assignment_id = (claim or {}).get("metadata", {}).get("assignment_id")
    if claim_assignment_id:
        assignment_ids.add(claim_assignment_id)
    assignments = [assignment for assignment in snapshot.get("assignments", [])
                   if assignment.get("id") in assignment_ids]
    documents = [document for document in snapshot.get("documents", [])
                 if document.get("assignment_id") in assignment_ids]
    return {
        "feature": _pick(feature, ("id", "title", "goal", "status", "revision",
                                     "current_visit_id", "work_item_id")),
        "current_visit": _pick(current_visit, ("id", "stage_key", "title", "status",
                                                  "revision", "summary", "recommendation")),
        "previous_visit": _pick(previous_visit, ("id", "stage_key", "title", "status", "revision")),
        "current_memberships": [_pick(membership, ("visit_id", "assignment_id", "revision",
                                                       "authorization_message_id", "carried_from_visit_id"))
                                for membership in memberships],
        "assignments": [{**_pick(assignment, ("id", "visit_id", "title", "role", "status", "verdict",
                                                   "generation", "input_revision", "summary", "code_revision",
                                                   "native_session_id")),
                         "operational": _pick(assignment.get("metadata", {}),
                                              ("parent_assignment_id", "source_assignment_id",
                                               "expected_code_revision", "human_gate"))}
                        for assignment in assignments],
        "document_references": [_pick(document, ("id", "visit_id", "assignment_id", "title",
                                                     "media_type", "content_hash", "generation",
                                                     "input_revision", "native_session_id"))
                                for document in documents],
        "counts": {name: len(snapshot.get(name, [])) for name in
                   ("visits", "assignments", "documents", "handoffs")},
    }


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    with temporary.open("x", encoding="utf-8") as handle:
        os.chmod(temporary, 0o600)
        json.dump(value, handle, ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    # Dispatch metadata must survive power loss as well as process restarts.
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _read_json(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError):
        return default


def _records(path: Path, offset: int = 0) -> tuple[list[dict], int]:
    """Read complete JSONL records only, preserving partial writes for replay."""
    result = []
    try:
        with path.open("rb") as handle:
            handle.seek(offset)
            while True:
                before = handle.tell()
                line = handle.readline(MAX_RECORD + 1)
                if not line:
                    return result, before
                if len(line) > MAX_RECORD:
                    # Consume the rest but never interpret an oversized record.
                    while line and not line.endswith(b"\n"):
                        line = handle.readline(MAX_RECORD + 1)
                    offset = handle.tell()
                    continue
                if not line.endswith(b"\n"):
                    return result, before
                try:
                    value = json.loads(line)
                    if isinstance(value, dict):
                        result.append(value)
                except (ValueError, UnicodeError):
                    pass
                offset = handle.tell()
    except OSError:
        return result, offset


def _locked(path: Path) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(handle, fcntl.LOCK_UN)
            return False
        except BlockingIOError:
            return True


def _ledger_event(event: dict) -> dict:
    """Keep the SQL ledger referential; exact raw evidence stays in its spool.

    A status tool result contains projections derived from this ledger. Putting
    that result back into the ledger recursively would grow every later status
    response and eventually exhaust the coordinator's context window.
    """
    data = dict(event)
    if "result" in data:
        encoded = json.dumps(data.pop("result"), ensure_ascii=False, default=str)
        data["result_reference"] = {"sha256": hashlib.sha256(encoded.encode()).hexdigest(), "bytes": len(encoded.encode())}
    if "args" in data:
        encoded_args = json.dumps(data["args"], ensure_ascii=False, default=str)
        if len(encoded_args) > 8192:
            data["args"] = {"keys": list(data["args"]) if isinstance(data["args"], dict) else [],
                            "sha256": hashlib.sha256(encoded_args.encode()).hexdigest(), "bytes": len(encoded_args.encode())}
    message = data.get("message")
    if isinstance(message, dict):
        encoded = json.dumps(message, ensure_ascii=False, default=str)
        data["message_reference"] = {"sha256": hashlib.sha256(encoded.encode()).hexdigest(), "bytes": len(encoded.encode())}
        if message.get("role") == "toolResult":
            data["message"] = {"role": "toolResult", "toolName": message.get("toolName"), "toolCallId": message.get("toolCallId")}
        else:
            data["message"] = {"role": message.get("role"), "stopReason": message.get("stopReason"),
                               "text": _assistant_text(message)[:6000]}
    if "messages" in data:
        data["message_count"] = len(data.pop("messages"))
    return data


def _bounded(environment: Mapping[str, str], key: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(environment.get(key, default))
        return max(minimum, min(maximum, value))
    except (ValueError, TypeError):
        return default


class FirstMateRuntime:
    """Run saved Pi coordinators and workers independently of client windows."""

    def __init__(self, store: Any, *, environ: Mapping[str, str] | None = None,
                 runtime_root: str | Path | None = None) -> None:
        self.store = store
        self.environ = dict(os.environ if environ is None else environ)
        self.root = Path(runtime_root or self.environ.get("HERDR_HARNESS_FIRST_MATE_RUNS_ROOT") or self.environ.get("HERDR_FIRST_MATE_RUNTIME_ROOT")
                         or str(Path(self.environ.get("HERDR_STATE_DIR") or "~/.local/share/herdr-companion").expanduser() / "first-mate-runs")).expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        self.jobs_root = self.root / "jobs"
        self.jobs_root.mkdir(exist_ok=True, mode=0o700)
        self.pi_bin = _resolve_pi_bin(self.environ)
        extension_package = pi_extension_path(self.environ)
        self.extension = extension_package / "extensions/first-mate.ts" if extension_package else None
        self.owner = "runtime_" + uuid.uuid4().hex
        self.max_workers = _bounded(self.environ, "HERDR_FIRST_MATE_MAX_WORKERS", 8, 1, 32)
        self.context_target = _bounded(self.environ, "HERDR_FIRST_MATE_CONTEXT_TARGET", 150000, 8192, 1000000)
        self.stall_seconds = _bounded(self.environ, "HERDR_FIRST_MATE_STALL_SECONDS", 600, 30, 86400)
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread: threading.Thread | None = None
        self._mutex = threading.RLock()
        self._manager_lock = None
        self._last_watch = 0.0
        self._catalog_lock = threading.Lock()
        self._catalog_cache = None
        self._catalog_at = 0.0
        self.usage = FirstMateUsage(self.root / "sessions")
        self.context = FirstMateContext(self.jobs_root, self.context_target)

    def capabilities(self) -> dict:
        return {"available": bool(self.pi_bin and self.extension and self.extension.is_file()),
                "pi_available": bool(self.pi_bin), "saved_sessions": True,
                "durable_dispatch": True, "context_handoff_target": self.context_target,
                "max_workers": self.max_workers,
                "reason": ("Pi is not installed or executable on this host" if not self.pi_bin else
                           "The managed First Mate Pi extension is unavailable" if not self.extension or not self.extension.is_file() else None)}

    def model_catalog(self) -> dict:
        from .first_mate_models import read_model_catalog
        with self._catalog_lock:
            if self._catalog_cache is None or time.monotonic() - self._catalog_at > 30:
                self._catalog_cache = read_model_catalog(self.pi_bin, self.environ, self.root)
                self._catalog_at = time.monotonic()
            return self._catalog_cache

    def _stage_key(self, feature: Mapping[str, Any]) -> str | None:
        visit_id = feature.get("current_visit_id")
        if not visit_id:
            return None
        return next((visit.get("stage_key") for visit in self.store.snapshot(feature["id"])["visits"]
                     if visit.get("id") == visit_id), None)

    def _policy(self, feature: Mapping[str, Any], *, kind: str,
                claim: Mapping[str, Any]):
        metadata = claim.get("metadata") if isinstance(claim.get("metadata"), Mapping) else {}
        needs_stage = kind == "worker" and metadata.get("model_profile") is None
        return resolve_dispatch_policy(kind=kind, feature=feature, claim=claim,
                                       environ=self.environ,
                                       stage_key=self._stage_key(feature) if needs_stage else None)

    def _apply_policy(self, job: dict, feature: Mapping[str, Any]) -> None:
        policy = self._policy(feature, kind=job["kind"], claim=job["claim"])
        job["model"] = policy.requested_model
        job["thinking"] = policy.requested_thinking
        job["model_selection"] = policy.selection()
        if job["kind"] == "coordinator":
            job["model_settings_revision"] = feature.get("model_settings_revision", 0)

    @staticmethod
    def _selection(job: Mapping[str, Any] | None, parsed: Mapping[str, Any] | None = None) -> dict | None:
        selection = dict(job.get("model_selection", {})) if job else {}
        validated_history = bool((parsed or {}).get("_identity_valid")) and not (parsed or {}).get("stale")
        actual_model = ((parsed or {}).get("_actual_model") if validated_history else None) or (job or {}).get("actual_model")
        actual_thinking = ((parsed or {}).get("_actual_thinking") if validated_history else None) or (job or {}).get("actual_thinking")
        if not selection and not actual_model and not actual_thinking:
            return None
        if not selection:
            kind = (job or {}).get("kind")
            selection = {
                "profile": "coordinator" if kind == "coordinator" else "execution",
                "requested_model": str((job or {}).get("model") or ""),
                "requested_thinking": str((job or {}).get("thinking") or ""),
                "source": "pi_default",
            }
        selection["actual_model"] = actual_model if isinstance(actual_model, str) and actual_model else None
        selection["actual_thinking"] = actual_thinking if isinstance(actual_thinking, str) and actual_thinking else None
        return selection

    def _usage_account(self, feature: dict, *, assignments: list[dict] | None = None,
                       jobs: list[dict] | None = None,
                       ledger_sessions: list[dict] | None = None) -> dict:
        return self.usage.account(
            feature_id=feature["id"],
            assignments=assignments if assignments is not None else self.store.list_assignments(feature_id=feature["id"]),
            ledger_sessions=ledger_sessions if ledger_sessions is not None else self.store.list_session_records(),
            jobs=jobs if jobs is not None else self._jobs(),
            jobs_root=self.jobs_root,
            updated_at=feature.get("updated_at") or utc_now(),
        )

    def list_features(self, view: str = "active") -> list[dict]:
        jobs = self._jobs()
        ledger_sessions = self.store.list_session_records()
        result = []
        for feature in self.store.list_features(view):
            account = self._usage_account(feature, jobs=jobs, ledger_sessions=ledger_sessions)
            selection = self._policy(feature, kind="coordinator", claim={}).selection()
            result.append({**feature, "usage": account["usage"], "model_selection": selection,
                           "coordinator_context": self.context.project(feature, jobs)})
        return result

    def feature(self, feature_id: str) -> dict:
        feature = self.store.get_feature(feature_id)
        jobs = self._jobs()
        selection = self._policy(feature, kind="coordinator", claim={}).selection()
        return {**feature, "usage": self._usage_account(feature, jobs=jobs)["usage"],
                "model_selection": selection,
                "coordinator_context": self.context.project(feature, jobs)}

    def snapshot(self, feature_id: str) -> dict:
        snapshot = self.store.snapshot(feature_id)
        jobs = self._jobs()
        account = self._usage_account(snapshot["feature"], assignments=snapshot["assignments"], jobs=jobs)
        result = dict(snapshot)
        feature_selection = self._policy(snapshot["feature"], kind="coordinator", claim={}).selection()
        result["feature"] = {**snapshot["feature"], "usage": account["usage"],
                             "model_selection": feature_selection,
                             "coordinator_context": self.context.project(snapshot["feature"], jobs)}
        assignment_jobs: dict[str, list[dict]] = {}
        for job in jobs:
            if job.get("kind") == "worker" and job.get("claim", {}).get("id"):
                assignment_jobs.setdefault(job["claim"]["id"], []).append(job)
        assignment_sessions: dict[str, list[dict]] = {}
        for session in account["sessions"]:
            if session.get("assignment_id"):
                assignment_sessions.setdefault(session["assignment_id"], []).append(session)
        result["assignments"] = []
        for assignment in snapshot["assignments"]:
            latest_job = max(assignment_jobs.get(assignment["id"], []),
                             key=lambda job: (job.get("claim", {}).get("generation", 0), job.get("created_at", "")),
                             default=None)
            if latest_job:
                selection = dict(latest_job.get("model_selection") or {})
                if not selection:
                    persisted_model = str(latest_job.get("model") or "")
                    persisted_thinking = str(latest_job.get("thinking") or "")
                    claim_model = str(latest_job.get("claim", {}).get("model") or "")
                    profile = latest_job.get("claim", {}).get("metadata", {}).get("model_profile")
                    if not isinstance(profile, str) or profile not in {"planning", "execution"}:
                        profile = "execution"
                    source = ("assignment_override" if claim_model and claim_model == persisted_model else
                              "host_policy" if persisted_model or persisted_thinking else "pi_default")
                    selection = {"profile": profile, "requested_model": persisted_model,
                                 "requested_thinking": persisted_thinking,
                                 "actual_model": None, "actual_thinking": None,
                                 "source": source}
                exact_native_id = latest_job.get("native_session_id")
            else:
                selection = self._policy(snapshot["feature"], kind="worker", claim=assignment).selection()
                exact_native_id = assignment.get("native_session_id")
            latest_session = max((session for session in assignment_sessions.get(assignment["id"], [])
                                  if exact_native_id and session.get("native_session_id") == exact_native_id),
                                 key=lambda session: (session.get("generation", 0), session.get("created_at", "")),
                                 default=None)
            historical = (latest_session or {}).get("model_selection")
            if historical:
                selection = {**selection,
                             "actual_model": historical.get("actual_model"),
                             "actual_thinking": historical.get("actual_thinking")}
            else:
                selection = {**selection, "actual_model": None, "actual_thinking": None}
            result["assignments"].append({
                **assignment,
                "usage": account["assignment_usage"][assignment["id"]],
                "subtree_usage": account["subtree_usage"][assignment["id"]],
                "model_selection": selection,
            })
        result["sessions"] = account["sessions"][:1000]
        result["sessions_truncated"] = len(account["sessions"]) > 1000
        return result

    def start(self) -> None:
        with self._mutex:
            if self._thread and self._thread.is_alive():
                return
            handle = (self.root / "manager.lock").open("a")
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                handle.close()
                return
            self._manager_lock = handle
            self._stop.clear()
            self._thread = threading.Thread(target=self._loop, name="first-mate-runtime", daemon=True)
            self._thread.start()

    def stop(self) -> None:
        """Stop reconciliation, preserving detached Pi workers for reattachment."""
        self._stop.set()
        self._wake.set()
        if self._thread and self._thread is not threading.current_thread():
            self._thread.join(timeout=5)
        if self._manager_lock:
            self._manager_lock.close()
            self._manager_lock = None

    def wake(self) -> None:
        self._wake.set()

    def action(self, feature_id: str, action: str, request_id: str, expected_revision: int | None = None) -> dict:
        if action not in {"pause", "resume", "cancel", "complete"}:
            raise FirstMateError("Unsupported feature action", code="invalid_request", status=400)
        if action == "cancel":
            # Persist the desired terminal action before asking writers to stop.
            # The visible pause is immediate; cancellation is committed after
            # every assignment has an acknowledged stop.
            identity = hashlib.sha256((feature_id + ":" + request_id).encode()).hexdigest()
            path = self.root / "actions" / (identity + ".json")
            pending = {"feature_id": feature_id, "action": action, "request_id": request_id,
                       "expected_revision": expected_revision}
            if path.exists() and _read_json(path) != pending:
                raise FirstMateError("Action request ID was reused with another payload")
            feature = self.store.get_feature(feature_id)
            if feature["status"] == "cancelled":
                return feature
            result = self.store.feature_action(feature_id, "pause", "cancel-pause:" + request_id, expected_revision)
            _write_json(path, pending)
        else:
            result = self.store.feature_action(feature_id, action, request_id, expected_revision)
        self.wake()
        return result

    def _actions(self) -> None:
        for path in (self.root / "actions").glob("*.json"):
            pending = _read_json(path)
            if not pending:
                continue
            if not self._quiesce(pending["feature_id"], "Human requested cancellation"):
                continue
            for assignment in self.store.list_assignments(feature_id=pending["feature_id"]):
                if assignment["status"] in {"dispatching", "running", "handoff_pending", "awaiting_ack", "recovering", "waiting_children"}:
                    self.store.acknowledge_stopped(assignment["id"], assignment["generation"],
                        "cancel-stopped:" + pending["request_id"] + ":" + assignment["id"], status="cancelled")
            self.store.feature_action(pending["feature_id"], pending["action"], pending["request_id"], pending["expected_revision"])
            path.unlink()

    def _quiesce(self, feature_id: str, reason: str, assignment_ids: list[str] | None = None) -> bool:
        stopped = True
        for job in self._jobs():
            if job["feature_id"] != feature_id or job["kind"] != "worker":
                continue
            if assignment_ids is not None and job["claim"]["id"] not in assignment_ids:
                continue
            directory = self._job_dir(job)
            if (directory / "finalized.json").exists():
                continue
            state = _read_json(directory / "status.json", {})
            if not state.get("ended") or _locked(directory / "writer.lock"):
                stopped = False
                if not job.get("cancel_requested"):
                    self._control(job, "abort", reason)
                    job["cancel_requested"] = True
                    self._save_job(job)
        return stopped

    def _event(self, feature_id: str, kind: str, summary: str, payload: dict,
               request_id: str) -> None:
        self.store.append_event(feature_id, kind, summary, payload, request_id=request_id)

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                self.reconcile()
            except Exception as exc:
                _write_json(self.root / "runtime-error.json", {"time": utc_now(), "error": str(exc)[:1000]})
            self._wake.wait(0.25)
            self._wake.clear()

    def _jobs(self) -> list[dict]:
        return [value for path in sorted(self.jobs_root.glob("*/job.json"))
                if isinstance((value := _read_json(path)), dict)]

    def _job_dir(self, job: dict) -> Path:
        return self.jobs_root / job["id"]

    def _save_job(self, job: dict) -> None:
        _write_json(self._job_dir(job) / "job.json", job)

    def _control(self, job: dict, action: str, text: str = "") -> None:
        directory = self._job_dir(job) / "controls"
        _write_json(directory / (uuid.uuid4().hex + ".json"), {"action": action, "text": text})

    def _launch(self, job: dict) -> None:
        directory = self._job_dir(job)
        refresh_lock = (directory / "writer.lock").open("a")
        try:
            fcntl.flock(refresh_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            refresh_lock.close()
            return
        try:
            if (directory / "started.json").exists():
                return
            # Refresh under the dispatch lock. A supervisor reads job.json only
            # after acquiring this same lock, so it cannot launch stale policy.
            current_extension = str(self.extension) if self.extension else job.get("extension")
            if current_extension and job.get("extension") != current_extension:
                job["previous_extension"] = job.get("extension")
                job["extension"] = current_extension
                job["extension_selected_at"] = utc_now()
            previous_selection = job.get("model_selection")
            previous_revision = job.get("model_settings_revision")
            self._apply_policy(job, self.store.get_feature(job["feature_id"]))
            if previous_selection != job.get("model_selection"):
                job["previous_model_selection"] = previous_selection
                job["model_selected_at"] = utc_now()
            if previous_revision != job.get("model_settings_revision"):
                job["previous_model_settings_revision"] = previous_revision
            self._save_job(job)
        finally:
            fcntl.flock(refresh_lock, fcntl.LOCK_UN)
            refresh_lock.close()
        child_env = agent_environment({**os.environ, **self.environ}, integration=False)
        child_env["PATH"] = _child_path(self.pi_bin or "pi", child_env.get("PATH"))
        child_env["PYTHONPATH"] = str(Path(__file__).resolve().parent.parent)
        child_env["HERDR_FIRST_MATE_JOB_DIR"] = str(directory)
        # New managed identity keeps older auto-discovered First Mate extensions
        # dormant while every unrelated configured extension remains available.
        child_env.pop("HERDR_FIRST_MATE_ROLE", None)
        child_env["HERDR_FIRST_MATE_MANAGED_ROLE"] = job["kind"]
        child_env["HERDR_FIRST_MATE_CONTEXT_TARGET"] = str(self.context_target)
        child_env["PI_SKIP_VERSION_CHECK"] = "1"
        with (directory / "supervisor.log").open("ab") as output:
            child = subprocess.Popen([sys.executable, "-m", "herdr_harness.first_mate_runtime", "--runner", str(directory)],
                             cwd=job["cwd"], env=child_env, stdin=subprocess.DEVNULL,
                             stdout=output, stderr=output, start_new_session=True)
            # Reap the detached supervisor when this service remains alive;
            # the daemon thread is not required for execution or recovery.
            threading.Thread(target=child.wait, name="first-mate-reap", daemon=True).start()

    def _new_job(self, feature: dict, *, kind: str, prompt: str, claim: dict,
                 parent_job: dict | None = None, handoff_id: str | None = None) -> dict:
        # Assignment dispatch IDs and inbox message IDs are durable identities.
        key = claim.get("dispatch_id") if kind == "worker" else claim.get("id")
        index = 0
        while True:
            identifier = "fmj_" + hashlib.sha256(f"{kind}:{key}:{index}".encode()).hexdigest()[:32]
            existing = _read_json(self.jobs_root / identifier / "job.json")
            if existing and kind == "coordinator" and (self.jobs_root / identifier / "finalized.json").exists():
                index += 1
                continue
            if existing:
                return existing
            break
        session = (Path(feature["session_file"]) if kind == "coordinator" and feature.get("session_file")
                   else self.root / "sessions" / identifier / "session.jsonl")
        if kind == "coordinator" and not feature.get("native_session_id"):
            checkpoint = _read_json(self.root / "checkpoints" / (feature["id"] + ".json"))
            if checkpoint:
                prompt += "\n\nRetained First Mate checkpoint from the predecessor conversation. Use it as evidence; current authoritative state above takes precedence:\n" + json.dumps(checkpoint, ensure_ascii=False)
        session.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        job = {"id": identifier, "kind": kind, "feature_id": feature["id"], "cwd": feature["cwd"],
               "session_file": str(session), "prompt": prompt, "claim": claim, "owner": claim.get("owner") or self.owner,
               "pi_bin": self.pi_bin, "extension": str(self.extension), "created_at": utc_now(),
               "context_target": self.context_target,
               "timeout_seconds": _bounded(self.environ, "HERDR_FIRST_MATE_COORDINATOR_TIMEOUT_SECONDS", 180, 30, 600) if kind in {"coordinator", "advisor"} else 86400, "handoff_id": handoff_id,
               "parent_job_id": parent_job["id"] if parent_job else None,
               "workspace_mode": claim.get("metadata", {}).get("workspace_mode", "read_only"),
               "charter": {"coordinator": COORDINATOR_PROMPT, "worker": WORKER_PROMPT, "advisor": ADVISOR_PROMPT}[kind]}
        self._apply_policy(job, self.store.get_feature(feature["id"]))
        if kind == "worker":
            if claim.get("attempt", 0) > 1 and not handoff_id:
                predecessors = [j for j in self._jobs() if j["kind"] == "worker" and j["claim"]["id"] == claim["id"]]
                if predecessors:
                    previous = max(predecessors, key=lambda j: j["claim"]["generation"])
                    job["prompt"] += "\n\nPrior execution recovery checkpoint:\n" + previous.get("recovery_brief", "Inspect the retained predecessor session before repeating any side effects: " + str(previous.get("native_session_id")))
            job["cwd"] = claim.get("metadata", {}).get("worktree_path") or feature["cwd"]
            if parent_job:
                job["cwd"] = parent_job["cwd"]
                job["workspace_mode"] = parent_job.get("workspace_mode", job["workspace_mode"])
        self._save_job(job)
        return job

    def _git(self, cwd: str, *args: str) -> str:
        result = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise FirstMateError("Git workspace operation failed: " + result.stderr.strip()[:500])
        return result.stdout.strip()

    def _workspace(self, feature: dict, params: dict, request_id: str) -> dict:
        mode = params.get("workspace_mode", "read_only")
        if mode not in {"read_only", "isolated"}:
            raise FirstMateError("Assignments use read_only or isolated workspaces")
        token = hashlib.sha256((feature["id"] + request_id).encode()).hexdigest()[:20]
        prepared_path = self.root / "workspace-plans" / (token + ".json")
        prepared = _read_json(prepared_path)
        if prepared and prepared["params"] != params:
            raise FirstMateError("A workspace request ID cannot be reused with changed instructions")
        if not prepared:
            source = feature["cwd"]
            source_assignment = params.get("source_assignment_id")
            if source_assignment:
                source_record = self.store.get_assignment(source_assignment)
                if source_record["feature_id"] != feature["id"]:
                    raise FirstMateError("Source assignment belongs to another feature")
                source = source_record.get("metadata", {}).get("worktree_path") or source
            try:
                baseline = self._git(source, "rev-parse", "HEAD")
            except FirstMateError:
                if mode == "isolated":
                    raise FirstMateError("Writable assignments need a Git repository for isolated worktrees")
                baseline = None
            metadata = {"workspace_mode": mode, "worktree_path": source, "source_assignment_id": source_assignment,
                        "base_revision": baseline}
            if baseline and mode == "read_only" and (source_assignment or "review" in str(params.get("role", "")).lower()):
                metadata["expected_code_revision"] = baseline
            if mode == "isolated":
                metadata.update(worktree_path=str(self.root / "worktrees" / token), branch="codex/first-mate-" + token)
            prepared = {"params": params, "source": source, "metadata": metadata}
            # Freeze derived HEAD and paths BEFORE any worktree mutation or DB
            # receipt. Replaying an uncertain tool cannot change its payload.
            _write_json(prepared_path, prepared)
        metadata = prepared["metadata"]
        if mode == "isolated":
            path, branch = Path(metadata["worktree_path"]), metadata["branch"]
            if path.exists():
                actual = self._git(str(path), "rev-parse", "--show-toplevel")
                if Path(actual).resolve() != path.resolve() or self._git(str(path), "branch", "--show-current") != branch:
                    raise FirstMateError("Existing path does not belong to the requested assignment worktree")
            else:
                path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                self._git(prepared["source"], "worktree", "add", "-b", branch, str(path), metadata["base_revision"])
        return metadata

    def reconcile(self) -> None:
        """One deterministic pass, also callable in integration tests."""
        with self._mutex:
            self._recover_claim_gaps()
            jobs = self._jobs()
            active_features = set()
            worker_count = 0
            for job in jobs:
                directory = self._job_dir(job)
                if (directory / "finalized.json").exists():
                    continue
                try:
                    self._observe(job)
                    self._requests(job)
                    state = _read_json(directory / "status.json", {})
                    feature = self.store.get_feature(job["feature_id"])
                    if feature["status"] in {"paused", "cancelled"} and not state.get("ended"):
                        if not job.get("cancel_requested"):
                            self._control(job, "abort", "Feature paused or cancelled by the human")
                            job["cancel_requested"] = True
                            self._save_job(job)
                    if job["kind"] == "coordinator" and job["claim"]["role"] == "system" and not state.get("ended"):
                        human_pending = any(m["role"] == "user" and m["status"] == "queued"
                                            for m in self.store.pending_messages(job["feature_id"]))
                        if human_pending and not job.get("preempt_requested"):
                            self._control(job, "abort", "Yield background coordination to the waiting human")
                            job["preempt_requested"] = True
                            self._save_job(job)
                    if job["kind"] == "worker":
                        assignment = next((a for a in self.store.snapshot(feature["id"])["assignments"]
                                           if a["id"] == job["claim"]["id"]), {})
                        if assignment.get("status") in {"paused", "cancelled", "superseded"} or (assignment.get("input_revision") != feature["revision"] and not self.store.assignment_is_in_current_visit(assignment["id"])):
                            if not job.get("cancel_requested"):
                                self._control(job, "abort", "Assignment no longer owns the active plan revision")
                                job["cancel_requested"] = True
                                self._save_job(job)
                    if job.get("cancel_requested") and not (directory / "started.json").exists():
                        state = {"ended": True, "interrupted": True, "error": "Cancelled before launch"}
                        _write_json(directory / "status.json", state)
                    if state.get("ended"):
                        self._finish(job, state)
                    elif (directory / "started.json").exists() and not _locked(directory / "writer.lock"):
                        # The supervisor writes its final receipt before releasing
                        # the writer lock. It can finish between our first status
                        # read and this lock check; re-read after observing unlock
                        # before classifying a completed dispatch as uncertain.
                        final_state = _read_json(directory / "status.json", {})
                        if final_state.get("ended"):
                            self._observe(job)
                            self._requests(job)
                            self._finish(job, final_state)
                        else:
                            # No final receipt: retain the no-replay safety rule.
                            self._unknown(job)
                    else:
                        if job["kind"] == "coordinator":
                            active_features.add(job["feature_id"])
                        if job["kind"] == "worker":
                            worker_count += 1
                        if not (directory / "started.json").exists() and self.capabilities()["available"]:
                            self._launch(job)
                except Exception as exc:
                    error = str(exc)[:1000]
                    _write_json(directory / "reconcile-error.json", {"error": error, "at": utc_now()})
                    try:
                        self._event(job["feature_id"], "runtime.error", "Execution needs attention: " + error,
                                    {"job_id": job["id"]}, "runtime-error:" + job["id"] + ":" + hashlib.sha256(error.encode()).hexdigest()[:16])
                    except Exception:
                        pass
            self._actions()
            if time.monotonic() - self._last_watch >= 10:
                self._watch(jobs)
                self._last_watch = time.monotonic()
            if not self.capabilities()["available"]:
                return
            # Archiving is presentation-only. Detached work for an archived
            # feature continues to reconcile until its workflow settles.
            for feature in self.store.list_features("all"):
                if feature["status"] in {"cancelled", "completed"}:
                    continue
                if feature["id"] not in active_features:
                    claim = self.store.claim_message(feature["id"], self.owner)
                    if claim:
                        snapshot = self.store.snapshot(feature["id"])
                        prompt = self._coordinator_input(snapshot, claim)
                        job = self._new_job(feature, kind="coordinator", prompt=prompt, claim=claim)
                        self._launch(job)
                if feature["status"] in {"paused", "blocked", "awaiting_direction", "recovering"}:
                    continue
                for assignment in self.store.snapshot(feature["id"])["assignments"]:
                    if worker_count >= self.max_workers:
                        break
                    if assignment["status"] == "queued":
                        claim = self.store.claim_assignment(assignment["id"], self.owner)
                        if claim:
                            prompt = self._worker_input(feature, claim)
                            job = self._new_job(feature, kind="worker", prompt=prompt, claim=claim,
                                                handoff_id=claim.get("handoff_id"))
                            self._launch(job)
                            worker_count += 1

    def _recover_claim_gaps(self) -> None:
        """Complete DB-claim-to-spool creation after a crash, using the same ID.

        Pi is never launched until job.json exists. Reconstructing a missing
        spool for an existing claim therefore cannot repeat an execution.
        """
        jobs = self._jobs()
        assignment_dispatches = {j["claim"].get("dispatch_id") for j in jobs if j["kind"] == "worker"}
        message_claims = {(j["claim"]["id"], j["owner"]) for j in jobs if j["kind"] == "coordinator"
                          and not (self._job_dir(j) / "finalized.json").exists()}
        for assignment in self.store.list_assignments(statuses=["dispatching"]):
            if assignment["dispatch_id"] not in assignment_dispatches:
                feature = self.store.get_feature(assignment["feature_id"])
                self._new_job(feature, kind="worker", claim=assignment, prompt=self._worker_input(feature, assignment))
        for message in self.store.pending_messages():
            if message["status"] == "processing" and (message["id"], message["owner"]) not in message_claims:
                snapshot = self.store.snapshot(message["feature_id"])
                self._new_job(snapshot["feature"], kind="coordinator", claim=message,
                              prompt=self._coordinator_input(snapshot, message))

    @staticmethod
    def _coordinator_input(snapshot: dict, claim: dict) -> str:
        turn = {"id": claim["id"], "role": claim["role"],
                "metadata": _pick(claim.get("metadata", {}),
                                  ("assignment_id", "generation", "native_session_id",
                                   "input_revision", "verdict", "code_revision", "document_ids",
                                   "human_gate", "recovery_count", "repair_count"))}
        return (f"{'Human direction' if claim['role'] == 'user' else 'Recorded system update (not authorization)'}:\n"
                + claim["text"] + "\n\nCurrent turn reference:\n" + json.dumps(turn, ensure_ascii=False)
                + "\n\nScope-bounded authoritative router state. Detailed evidence remains in tracked workers and Documents:\n"
                + json.dumps(_coordinator_state(snapshot, claim), ensure_ascii=False))

    @staticmethod
    def _worker_input(feature: dict, claim: dict) -> str:
        return (f"Feature: {feature['title']}\nGoal: {feature['goal']}\nPlan revision: {claim['input_revision']}\n"
                f"Assignment: {claim['title']}\nRole: {claim['role']}\n\n{claim['prompt']}\n\n"
                "Workspace metadata: " + json.dumps(claim.get("metadata", {})) + "\n"
                "For an isolated implementation, commit finished changes on the private assignment branch to establish an exact revision for review. Never merge or push without explicit authorization. "
                "Return textual deliverables using fm_outcome and an evidence-based verdict. Do not advance another workflow stage.")

    def _bind(self, job: dict, native_id: str, session_file: str) -> None:
        if not native_id or not session_file:
            return
        actual = Path(session_file).resolve()
        actual.relative_to((self.root / "sessions").resolve())
        if actual != Path(job["session_file"]).resolve():
            raise ValueError("Pi returned a session outside this dispatch's scope")
        if job.get("native_session_id") == native_id:
            return
        if job["kind"] == "worker":
            claim = job["claim"]
            if job.get("handoff_id"):
                replacement = self.store.bind_handoff_successor(job["handoff_id"], native_id, session_file,
                    job["owner"], "bind-successor:" + job["id"], verified_predecessor_stopped=True)
                job["claim"] = replacement
            else:
                self.store.bind_session(claim["id"], claim["generation"], job["owner"], native_id, session_file, run_id=job["id"])
        elif job["kind"] == "coordinator":
            self.store.bind_coordinator_session(job["feature_id"], job["owner"], native_id, session_file)
        job["native_session_id"] = native_id
        self._save_job(job)
        self._event(job["feature_id"], "session.bound", "Saved Pi session attached", {
            "job_id": job["id"], "native_session_id": native_id,
            "assignment_id": job["claim"]["id"] if job["kind"] == "worker" else None,
            "kind": job["kind"]}, "bound:" + job["id"])

    def _observe(self, job: dict) -> None:
        directory = self._job_dir(job)
        checkpoint = _read_json(directory / "cursor.json", {})
        for filename in ("events.jsonl", "telemetry.jsonl"):
            offset = int(checkpoint.get(filename, 0))
            records, after = _records(directory / filename, offset)
            for index, event in enumerate(records):
                identity = event.get("id") or f"{offset}:{index}"
                kind = event.get("type", "event")
                if kind == "response" and event.get("command") == "get_state" and event.get("success"):
                    data = event.get("data", {})
                    self._bind(job, data.get("sessionId", ""), data.get("sessionFile", ""))
                    raw_model = data.get("model") or data.get("currentModel")
                    model = raw_model if isinstance(raw_model, dict) else {}
                    provider = model.get("provider") or data.get("provider")
                    identity = model.get("id") or model.get("modelId") or data.get("modelId")
                    actual_model = (provider + "/" + identity
                                    if isinstance(provider, str) and isinstance(identity, str)
                                    and provider and identity else
                                    raw_model if isinstance(raw_model, str) and "/" in raw_model else None)
                    actual_thinking = data.get("thinkingLevel") or data.get("thinking_level")
                    changed = False
                    if actual_model and job.get("actual_model") != actual_model:
                        job["actual_model"] = actual_model
                        changed = True
                    if isinstance(actual_thinking, str) and actual_thinking and job.get("actual_thinking") != actual_thinking:
                        job["actual_thinking"] = actual_thinking
                        changed = True
                    if changed:
                        job["model_observed_at"] = event.get("time") or utc_now()
                        self._save_job(job)
                elif kind == "session_started":
                    self._bind(job, event.get("native_session_id", ""), event.get("session_file", ""))
                if kind == "checkpoint_requested" and not job.get("handoff_deadline"):
                    job["handoff_deadline"] = time.time() + 90
                    self._save_job(job)
                if kind in {"tool_execution_start", "tool_execution_end", "message_end", "agent_end",
                            "context_usage", "checkpoint_requested", "compaction_prevented"}:
                    summary = {"tool_execution_start": f"Started {event.get('toolName', 'tool')}",
                               "tool_execution_end": f"Finished {event.get('toolName', 'tool')}",
                               "message_end": "Agent response recorded", "agent_end": "Agent turn ended",
                               "context_usage": "Context usage measured", "checkpoint_requested": "Context handoff requested",
                               "compaction_prevented": "Compaction replaced by managed handoff"}[kind]
                    self._event(job["feature_id"], "pi." + kind, summary,
                                {"job_id": job["id"], "assignment_id": job["claim"]["id"] if job["kind"] == "worker" else None,
                                 "native_session_id": job.get("native_session_id"), "raw_event_id": identity,
                                 "raw_event_file": filename, "event": _ledger_event(event)},
                                f"observe:{job['id']}:{filename}:{identity}")
            checkpoint[filename] = after
        if checkpoint != _read_json(directory / "cursor.json", {}):
            _write_json(directory / "cursor.json", checkpoint)

    def _requests(self, job: dict) -> None:
        directory = self._job_dir(job)
        for path in sorted((directory / "requests").glob("*.json")):
            response = directory / "responses" / path.name
            if response.exists():
                continue
            request = _read_json(path)
            if not isinstance(request, dict) or request.get("request_id") != path.stem:
                continue
            try:
                self._bind(job, request.get("native_session_id", ""), request.get("session_file", ""))
                if request.get("native_session_id") != job.get("native_session_id"):
                    raise ValueError("Request session does not own this dispatch")
                result = self._tool(job, request["action"], request.get("params", {}), request["request_id"])
                _write_json(response, {"ok": True, "result": result})
            except DeferredOperation:
                continue
            except Exception as exc:
                _write_json(response, {"ok": False, "error": str(exc)[:1000]})

    def _tool(self, job: dict, action: str, params: dict, request_id: str) -> Any:
        feature_id = job["feature_id"]
        feature = self.store.get_feature(feature_id)
        claim = job["claim"]
        if action == "fm_status":
            snapshot = self.store.snapshot(feature_id)
            if job["kind"] == "coordinator":
                status = _coordinator_state(snapshot, claim)
                status["last_updates"] = [{"sequence": event["sequence"], "type": event["type"],
                                            "summary": event["summary"][:500], "created_at": event["created_at"]}
                                           for event in snapshot["events"][-10:]]
                return status
            return {"feature": snapshot["feature"], "visits": snapshot["visits"],
                    "assignments": [{key: value for key, value in a.items() if key != "prompt"} for a in snapshot["assignments"]],
                    "documents": snapshot["documents"], "memberships": snapshot.get("memberships", []),
                    "last_updates": [{"sequence": e["sequence"], "type": e["type"], "summary": e["summary"][:500], "created_at": e["created_at"]}
                                     for e in snapshot["events"][-10:]]}
        if action == "fm_read_document":
            document = self.store.get_document(params["document_id"])
            if document["feature_id"] != feature_id:
                raise FirstMateError("Document belongs to another feature")
            content = document.get("content", "")
            offset = max(0, int(params.get("offset", 0)))
            length = max(1000, min(80000, int(params.get("length", 24000))))
            return {**document, "content": content[offset:offset + length], "offset": offset,
                    "next_offset": offset + length if offset + length < len(content) else None,
                    "total_characters": len(content)}
        if action == "fm_read_session":
            requested_index = params.get("message_index")
            session = self.session(params["native_session_id"], before=(int(requested_index) + 1) if requested_index is not None else params.get("before"),
                                   limit=1 if requested_index is not None else params.get("limit", 20))
            if session["session"]["feature_id"] != feature_id:
                raise FirstMateError("Session belongs to another feature")
            offset = max(0, int(params.get("text_offset", 0))) if requested_index is not None else 0
            length = max(1000, min(80000, int(params.get("text_length", 12000)))) if requested_index is not None else 12000
            session["messages"] = [{**message, "text": message["text"][offset:offset + length],
                                    "text_offset": offset, "text_truncated": len(message["text"]) > offset + length,
                                    "next_text_offset": offset + length if len(message["text"]) > offset + length else None,
                                    "total_characters": len(message["text"])} for message in session["messages"]]
            return session
        if action == "fm_delegate" and job["kind"] == "worker":
            parent = self.store.get_assignment(claim["id"])
            if parent["generation"] != claim["generation"] or parent["native_session_id"] != job["native_session_id"] or parent["status"] != "running":
                raise FirstMateError("Only the current running parent executor can delegate children")
            if feature["status"] != "running" or not self.store.assignment_is_in_current_visit(parent["id"]):
                raise FirstMateError("Nested work must remain in the current human-authorized stage")
            if job.get("workspace_mode") == "read_only" and params.get("workspace_mode", "read_only") != "read_only":
                raise FirstMateError("A read-only parent cannot grant an isolated worktree to a child")
            depth = 0
            ancestor = parent
            while ancestor.get("metadata", {}).get("parent_assignment_id"):
                depth += 1
                ancestor = self.store.get_assignment(ancestor["metadata"]["parent_assignment_id"])
            if depth >= 4:
                raise FirstMateError("Nested delegation is limited to four levels; ask First Mate to reorganize this work")
            profile = delegation_profile(params.get("model_profile"), stage_key=self._stage_key(feature))
            parameters = {**params, "model_profile": profile,
                          "source_assignment_id": params.get("source_assignment_id") or parent["id"]}
            metadata = {**self._workspace(feature, parameters, request_id),
                        "parent_assignment_id": parent["id"], "model_profile": profile}
            return self.store.create_assignment(feature["current_visit_id"], {
                **parameters, "metadata": metadata, "request_id": request_id, "input_revision": feature["revision"]})
        if action == "fm_retry" and job["kind"] == "worker":
            child = self.store.get_assignment(params["assignment_id"])
            if child["feature_id"] != feature_id or child.get("metadata", {}).get("parent_assignment_id") != claim["id"]:
                raise FirstMateError("A worker can retry only its own directly delegated children")
            for execution in self._jobs():
                if execution["kind"] == "worker" and execution["claim"]["id"] == child["id"] and _locked(self._job_dir(execution) / "writer.lock"):
                    raise DeferredOperation()
            prepared_path = self.root / "retry-plans" / (request_id + ".json")
            metadata = _read_json(prepared_path)
            if metadata is None:
                metadata = dict(child.get("metadata", {}))
                if metadata.get("expected_code_revision"):
                    metadata["expected_code_revision"] = self._git(metadata["worktree_path"], "rev-parse", "HEAD")
                _write_json(prepared_path, metadata)
            return self.store.retry_assignment(child["id"], params["prompt"], request_id, metadata=metadata, verified_stopped=True)
        if job["kind"] == "coordinator":
            if action in {"fm_begin_stage", "fm_revise", "fm_finish_feature", "fm_resolve_gate", "fm_recover"} and claim["role"] != "user":
                raise ValueError("Only a human message can authorize a stage or change feature scope")
            if action == "fm_begin_stage":
                return self.store.start_visit(feature_id, params["stage_key"], params["title"], request_id,
                                              feature["revision"], claim["id"])
            if action == "fm_delegate":
                if not feature.get("current_visit_id") or feature["status"] != "running":
                    raise ValueError("No active human-authorized stage is available")
                profile = delegation_profile(params.get("model_profile"), stage_key=self._stage_key(feature))
                parameters = {**params, "model_profile": profile}
                metadata = {**self._workspace(feature, parameters, request_id),
                            "model_profile": profile}
                return self.store.create_assignment(feature["current_visit_id"], {
                    **parameters, "metadata": metadata, "request_id": request_id, "input_revision": feature["revision"]})
            if action == "fm_recover":
                assignment = self.store.get_assignment(params["assignment_id"])
                if assignment["feature_id"] != feature_id:
                    raise FirstMateError("Recovery target belongs to another feature")
                if any(execution["kind"] == "worker" and execution["claim"]["id"] == assignment["id"]
                       and _locked(self._job_dir(execution) / "writer.lock") for execution in self._jobs()):
                    raise FirstMateError("The prior worker is still alive; pause it before retrying an uncertain dispatch")
                result = self.store.recover_assignment(assignment["id"], assignment["generation"], params["reason"], request_id, verified_stopped=True)
                if feature["status"] == "recovering" and result["status"] == "queued":
                    self.store.feature_action(feature_id, "resume", "recover-resume:" + request_id)
                return result
            if action == "fm_resolve_gate":
                assignment = self.store.get_assignment(params["assignment_id"])
                if assignment["feature_id"] != feature_id:
                    raise FirstMateError("Human gate belongs to another feature")
                for execution in self._jobs():
                    if execution["kind"] == "worker" and execution["claim"]["id"] == assignment["id"] and _locked(self._job_dir(execution) / "writer.lock"):
                        raise DeferredOperation()
                return self.store.resolve_human_gate(assignment["id"], claim["id"], params["instruction"], request_id, verified_stopped=True)
            if action == "fm_steer":
                assignment = self.store.get_assignment(params["assignment_id"])
                if assignment["feature_id"] != feature_id or not self.store.assignment_is_in_current_visit(assignment["id"]):
                    raise FirstMateError("Assignment is outside this feature's current stage")
                target = next((j for j in reversed(self._jobs()) if j["kind"] == "worker" and j["claim"]["id"] == assignment["id"]
                               and not (self._job_dir(j) / "finalized.json").exists()), None)
                if not target or assignment["status"] != "running":
                    raise FirstMateError("Assignment does not have a running worker")
                control = self._job_dir(target) / "controls" / (request_id + ".json")
                _write_json(control, {"action": "steer", "text": params["text"]})
                self._event(feature_id, "assignment.steered", params["text"], {"assignment_id": assignment["id"],
                            "native_session_id": target.get("native_session_id")}, "steer:" + request_id)
                return {"queued": True, "assignment_id": assignment["id"]}
            if action == "fm_retry":
                assignment = self.store.get_assignment(params["assignment_id"])
                if assignment["feature_id"] != feature_id or not self.store.assignment_is_in_current_visit(assignment["id"]):
                    raise FirstMateError("Assignment is outside the current authorized stage")
                for execution in self._jobs():
                    if execution["kind"] == "worker" and execution["claim"]["id"] == assignment["id"]:
                        if _locked(self._job_dir(execution) / "writer.lock"):
                            raise DeferredOperation()
                prepared_path = self.root / "retry-plans" / (request_id + ".json")
                metadata = _read_json(prepared_path)
                if metadata is None:
                    metadata = dict(assignment.get("metadata", {}))
                    if metadata.get("expected_code_revision"):
                        metadata["expected_code_revision"] = self._git(metadata["worktree_path"], "rev-parse", "HEAD")
                    _write_json(prepared_path, metadata)
                return self.store.retry_assignment(assignment["id"], params["prompt"], request_id, metadata=metadata, verified_stopped=True)
            if action == "fm_complete_stage":
                for assignment in self.store.snapshot(feature_id)["assignments"]:
                    metadata = assignment.get("metadata", {})
                    if self.store.assignment_is_in_current_visit(assignment["id"]) and metadata.get("expected_code_revision"):
                        if self._git(metadata["worktree_path"], "rev-parse", "HEAD") != metadata["expected_code_revision"]:
                            raise FirstMateError("Reviewed code changed. Repeat the affected review against the actual current revision.")
                    for execution in self._jobs():
                        if execution["kind"] == "worker" and execution["claim"]["id"] == assignment["id"] and _locked(self._job_dir(execution) / "writer.lock"):
                            raise DeferredOperation()
                return self.store.complete_visit(feature["current_visit_id"], params["summary"], params["recommendation"], request_id)
            if action == "fm_revise":
                revisions = job.setdefault("operation_revisions", {})
                if request_id not in revisions:
                    revisions[request_id] = feature["revision"]
                    self._save_job(job)
                affected = params.get("affected_assignment_ids")
                if affected is not None:
                    if not isinstance(affected, list) or not all(isinstance(value, str) for value in affected):
                        raise FirstMateError("Affected assignments must be a list of exact IDs")
                    for identity in affected:
                        if self.store.get_assignment(identity)["feature_id"] != feature_id:
                            raise FirstMateError("Affected assignment belongs to another feature")
                if not self._quiesce(feature_id, params["reason"], affected):
                    raise DeferredOperation()
                prepared_path = self.root / "revision-plans" / (request_id + ".json")
                carry = _read_json(prepared_path)
                if carry is None:
                    carry = {}
                    if affected is not None:
                        for assignment in self.store.list_assignments(feature_id=feature_id):
                            if assignment["id"] in affected or assignment["status"] != "completed":
                                continue
                            metadata = assignment.get("metadata", {})
                            path = metadata.get("worktree_path")
                            if path:
                                if self._git(path, "status", "--porcelain"):
                                    raise FirstMateError("Cannot carry completed code evidence from a dirty worktree")
                                carry[assignment["id"]] = self._git(path, "rev-parse", "HEAD")
                    _write_json(prepared_path, carry)
                result = self.store.revise_feature(feature_id, params["goal"], revisions[request_id], request_id,
                                                  authorization_message_id=claim["id"], verified_stopped=True,
                                                  affected_assignment_ids=affected, carry_forward_evidence=carry)
                self._event(feature_id, "revision.reason", params["reason"], {}, "reason:" + request_id)
                return result
            if action == "fm_finish_feature":
                return self.store.feature_action(feature_id, "complete", request_id)
        elif job["kind"] == "worker":
            if action == "fm_outcome":
                code_revision = None
                try:
                    code_revision = self._git(job["cwd"], "rev-parse", "HEAD")
                    if params["verdict"] in {"success", "passed"} and self._git(job["cwd"], "status", "--porcelain"):
                        raise FirstMateError("Commit the finished private worktree changes before reporting success, or report the remaining work as blocked. Review evidence must identify an exact clean revision.")
                except FirstMateError:
                    if job.get("workspace_mode") == "isolated" or claim.get("metadata", {}).get("expected_code_revision"):
                        raise
                return self.store.record_outcome(claim["id"], claim["generation"], job["native_session_id"],
                                                  claim["input_revision"], params["verdict"], params["summary"], request_id,
                                                  documents=params.get("documents", []), code_revision=code_revision)
            if action == "fm_wait_for_children":
                children = [a for a in self.store.list_assignments(feature_id=feature_id)
                            if a.get("metadata", {}).get("parent_assignment_id") == claim["id"]]
                if children and all(a["status"] in TERMINAL for a in children):
                    raise FirstMateError("The children have already settled. Inspect their evidence, repair failures if appropriate, and report your own outcome instead of waiting again.")
                result = self.store.wait_for_children(claim["id"], claim["generation"], job["native_session_id"], params["summary"], request_id)
                job["waiting_children"] = params["summary"]
                self._save_job(job)
                return result
            if action == "fm_request_human":
                return self.store.request_human_gate(claim["id"], claim["generation"], job["native_session_id"], params["reason"], request_id)
            if action == "fm_handoff":
                result = self.store.begin_handoff(claim["id"], claim["generation"], request_id, params["summary"])
                job["pending_handoff"] = result
                self._save_job(job)
                return result
            if action == "fm_acknowledge_handoff":
                if not job.get("handoff_id"):
                    raise ValueError("This session is not a handoff successor")
                result = self.store.acknowledge_handoff(job["handoff_id"], job["native_session_id"],
                                                       claim["generation"], request_id)
                self._event(feature_id, "handoff.verification", params["summary"],
                            {"handoff_id": job["handoff_id"]}, "verification:" + request_id)
                return result
        elif job["kind"] == "advisor":
            if action == "fm_advice":
                return self._advice(job, params, request_id)
            if action == "fm_recovery_brief":
                parent = _read_json(self.jobs_root / str(job.get("parent_job_id")) / "job.json")
                if not parent or not job.get("recovery_mode"):
                    raise FirstMateError("This advisor does not own a recovery checkpoint")
                parent["recovery_brief"] = params["summary"]
                self._save_job(parent)
                job["advice_recorded"] = True
                self._save_job(job)
                self._event(feature_id, "recovery.checkpoint", params["summary"], {
                    "assignment_id": parent["claim"]["id"], "predecessor_session_id": parent.get("native_session_id"),
                    "advisor_session_id": job.get("native_session_id")}, "recovery-brief:" + request_id)
                return {"retained": True}
        raise ValueError("Tool is outside this execution's role and assignment scope")

    def _finish(self, job: dict, state: dict) -> None:
        directory = self._job_dir(job)
        if _locked(directory / "writer.lock"):
            return
        claim = job["claim"]
        if job["kind"] == "coordinator":
            if job.get("preempt_requested"):
                self.store.release_message(claim["id"], job["owner"], "Background update deferred for a human message", verified_stopped=True, request_id="preempt:" + job["id"])
            else:
                reply = state.get("response") or "First Mate could not complete this response. Your message and execution evidence are retained."
                if state.get("error"):
                    reply += "\n\nCoordinator needs attention: " + str(state["error"])[:700]
                self.store.finish_message(claim["id"], job["owner"], reply=reply)
            self._rotate_coordinator_if_needed(job)
        elif job["kind"] == "worker":
            if job.get("waiting_children") and not job.get("cancel_requested"):
                if not self._continue_children(job):
                    return
            elif job.get("pending_handoff"):
                if self.store.get_feature(job["feature_id"])["status"] != "cancelled" and not self._continue_handoff(job):
                    return
            elif job.get("cancel_requested"):
                assignment = self.store.get_assignment(claim["id"])
                if assignment["status"] not in TERMINAL or (assignment["status"] == "paused" and assignment.get("metadata", {}).get("human_gate")):
                    self.store.acknowledge_stopped(claim["id"], claim["generation"], "stopped:" + job["id"], status="paused")
            else:
                assignment = next(a for a in self.store.snapshot(job["feature_id"])["assignments"] if a["id"] == claim["id"])
                if assignment["status"] == "paused" and assignment.get("metadata", {}).get("human_gate"):
                    self.store.acknowledge_stopped(claim["id"], claim["generation"], "gate-stopped:" + job["id"], status="paused")
                elif assignment["status"] not in TERMINAL:
                    if assignment.get("recovery_count", 0) < 2 and not self._prepare_recovery_brief(job, state):
                        return
                    self.store.recover_assignment(claim["id"], claim["generation"],
                        "Pi stopped without a structured outcome. " + str(state.get("error") or "A clean exit is not evidence of success."),
                        "missing-outcome:" + job["id"], verified_stopped=True)
        elif job["kind"] == "advisor" and not job.get("advice_recorded"):
            self._event(job["feature_id"], "advisor.failed", "Advisor ended without an assessment", {"job_id": job["id"]}, "advisor-failed:" + job["id"])
        self._event(job["feature_id"], "execution.stopped", "Saved execution ended; history retained", {
            "job_id": job["id"], "native_session_id": job.get("native_session_id"), "error": state.get("error")}, "stopped:" + job["id"])
        _write_json(directory / "finalized.json", {"at": utc_now()})

    def _continue_children(self, job: dict) -> bool:
        feature = self.store.get_feature(job["feature_id"])
        if feature["status"] != "running":
            return False
        children = [a for a in self.store.list_assignments(feature_id=feature["id"])
                    if a.get("metadata", {}).get("parent_assignment_id") == job["claim"]["id"]]
        if not children or any(a["status"] not in TERMINAL for a in children):
            return False
        claim = {**job["claim"], "dispatch_id": "children:" + job["id"]}
        continuation = self._new_job(feature, kind="worker", claim=claim, parent_job=job,
            prompt="Resume your current assignment after delegated children settled. Inspect their evidence, repair bounded failures if needed, and report your own honest outcome. You may not advance the major stage.\nYour saved checkpoint:\n"
                   + job["waiting_children"] + "\nChild outcomes:\n" + json.dumps(children, ensure_ascii=False))
        # This is a new turn of the SAME saved executor, not a new generation.
        continuation["session_file"] = job["session_file"]
        continuation["owner"] = job["owner"]
        self._save_job(continuation)
        self._launch(continuation)
        return True

    def _prepare_recovery_brief(self, job: dict, state: dict) -> bool:
        if job.get("recovery_brief"):
            return True
        feature = self.store.get_feature(job["feature_id"])
        if job.get("recovery_job_id"):
            recovery_dir = self.jobs_root / job["recovery_job_id"]
            if not (recovery_dir / "finalized.json").exists():
                return False
            # Even when model judgment is unavailable, retain facts and make
            # uncertainty explicit instead of losing the old execution context.
            job["recovery_brief"] = "The independent recovery advisor produced no checkpoint. Inspect the retained predecessor session " + str(job.get("native_session_id")) + " and verify every side effect before continuing. Failure: " + str(state.get("error", "missing outcome"))
            self._save_job(job)
            return True
        evidence, _ = _records(self._job_dir(job) / "events.jsonl")
        evidence = [e for e in evidence if e.get("type") in {"message_end", "tool_execution_start", "tool_execution_end"}][-80:]
        advisor = self._new_job(feature, kind="advisor", claim={"id": "recovery:" + job["id"]}, parent_job=job,
            prompt="The predecessor is stopped and cannot reliably summarize. Produce a recovery brief with fm_recovery_brief. Include observed work, uncertain side effects, files/commits, verification, blockers and the exact next safe action. Distinguish evidence from inference. Do not attempt the assignment.\nAssignment:\n" + job["prompt"] + "\nRetained recent evidence:\n" + json.dumps([_ledger_event(e) for e in evidence], ensure_ascii=False))
        advisor["recovery_mode"] = True
        self._save_job(advisor)
        job["recovery_job_id"] = advisor["id"]
        self._save_job(job)
        self._launch(advisor)
        return False

    def _rotate_coordinator_if_needed(self, job: dict) -> None:
        feature = self.store.get_feature(job["feature_id"])
        context = self.context.project(feature, [job])
        if (context["status"] != "measured"
                or context["tokens"] < context["handoff_target_tokens"]
                or context["native_session_id"] != job.get("native_session_id")):
            return
        snapshot = self.store.snapshot(job["feature_id"])
        checkpoint = {"predecessor_session_id": job["native_session_id"], "created_at": utc_now(),
                      "router_state": _coordinator_state(snapshot),
                      # These are authoritative instructions, not evidence. A
                      # successor without transcript readers must retain them
                      # verbatim across coordinator rotation.
                      "human_directives": [{"id": message["id"], "text": message["text"],
                                             "created_at": message["created_at"]}
                                            for message in snapshot["messages"] if message["role"] == "user"],
                      # Short answers such as "yes" retain meaning only beside
                      # the coordinator question they answer.
                      "recent_conversation": [message for message in snapshot["messages"]
                                              if message["role"] in {"user", "assistant"}][-30:]}
        path = self.root / "checkpoints" / (job["feature_id"] + ".json")
        # Preserve the same checkpoint across a crash between rotation and job finalization.
        previous = _read_json(path)
        if not previous or previous.get("predecessor_session_id") != job["native_session_id"]:
            _write_json(path, checkpoint)
        self.store.rotate_coordinator_session(job["feature_id"], job["native_session_id"],
                                              "rotate:" + job["id"], verified_stopped=True)

    def _unknown(self, job: dict) -> None:
        if job.get("unknown_recorded"):
            return
        reason = "Supervisor disappeared without a final receipt. Dispatch will not be replayed automatically."
        self._event(job["feature_id"], "dispatch.unknown", reason, {"job_id": job["id"]}, "unknown:" + job["id"])
        if job["kind"] == "worker":
            self.store.mark_dispatch_unknown(job["claim"]["id"], job["claim"]["generation"], reason,
                                             "unknown:" + job["id"])
        elif job["kind"] == "coordinator":
            self.store.finish_message(job["claim"]["id"], job["owner"], reply=reason)
        job["unknown_recorded"] = True
        self._save_job(job)
        _write_json(self._job_dir(job) / "finalized.json", {"at": utc_now(), "unknown": True})

    def _continue_handoff(self, job: dict) -> bool:
        handoff = job["pending_handoff"]
        feature = self.store.get_feature(job["feature_id"])
        if feature["status"] in {"paused", "cancelled"}:
            return False
        claim = {**job["claim"], "dispatch_id": "handoff:" + handoff["id"]}
        successor = self._new_job(feature, kind="worker", claim=claim,
            prompt=self._worker_input(feature, claim) + "\n\nRetained predecessor checkpoint:\n" + handoff["summary"]
            + "\nInspect this evidence and workspace, then fm_acknowledge_handoff before changing anything.",
            parent_job=job, handoff_id=handoff["id"])
        self._launch(successor)
        return True

    def _watch(self, jobs: list[dict]) -> None:
        for job in jobs:
            directory = self._job_dir(job)
            if job["kind"] != "worker" or (directory / "finalized.json").exists():
                continue
            if job.get("handoff_deadline") and time.time() > job["handoff_deadline"] and not job.get("pending_handoff"):
                self._control(job, "abort", "Worker did not produce a checkpoint after the advisor's handoff deadline")
                job.pop("handoff_deadline", None)
                self._save_job(job)
            if job.get("advisor_job_id"):
                advisor_dir = self.jobs_root / job["advisor_job_id"]
                if not (advisor_dir / "finalized.json").exists():
                    continue
                if time.time() - job.get("last_assessment_epoch", time.time()) < 30:
                    continue
            state = _read_json(directory / "status.json", {})
            if state.get("ended") or not state.get("accepted"):
                continue
            events, _ = _records(directory / "events.jsonl")
            recent = events[-100:]
            observed_since = events[int(job.get("watch_cursor", 0)):]
            calls = [hashlib.sha256(json.dumps({"tool": e.get("toolName"), "args": e.get("args")}, sort_keys=True).encode()).hexdigest()
                     for e in observed_since if e.get("type") == "tool_execution_start"]
            repetition = len(calls) >= 8 and len(set(calls[-8:])) <= 2
            deltas = [e.get("assistantMessageEvent", {}).get("delta", "") for e in observed_since[-150:]
                      if e.get("type") == "message_update" and e.get("assistantMessageEvent", {}).get("type") == "text_delta"]
            repeated_text = len(deltas) >= 20 and len(set(deltas[-20:])) <= 3
            idle = time.time() - max(float(state.get("last_event_epoch", time.time())), job.get("last_assessment_epoch", 0)) > self.stall_seconds
            if not repetition and not repeated_text and not idle:
                continue
            reason = "Repeated tool calls without a changed pattern" if repetition else ("Repetitive generated text suggests a model loop" if repeated_text else "No observable Pi activity within the watchdog interval")
            round_number = int(job.get("advisor_round", 0)) + 1
            self._event(job["feature_id"], "watchdog.suspicion", reason, {"job_id": job["id"], "round": round_number}, f"watch:{job['id']}:{round_number}")
            feature = self.store.get_feature(job["feature_id"])
            advisor = self._new_job(feature, kind="advisor", claim={"id": f"advisor:{job['id']}:{round_number}"}, parent_job=job,
                                    prompt="Assignment:\n" + job["prompt"] + "\nWatchdog signal: " + reason
                                    + "\nRecent observable evidence:\n" + json.dumps([_ledger_event(e) for e in recent], ensure_ascii=False))
            job.update(advisor_job_id=advisor["id"], advisor_round=round_number, watch_cursor=len(events), last_assessment_epoch=time.time())
            self._save_job(job)
            self._launch(advisor)

    def _advice(self, job: dict, params: dict, request_id: str) -> dict:
        parent = _read_json(self.jobs_root / str(job.get("parent_job_id")) / "job.json")
        if not parent:
            raise ValueError("Advisor's target execution no longer exists")
        decision = params.get("decision")
        if decision not in {"continue", "steer", "handoff", "pause"}:
            raise ValueError("Invalid advisor decision")
        self._event(job["feature_id"], "advisor.assessment", params["reason"], {
            "job_id": job["id"], "target_job_id": parent["id"], **params}, "advice:" + request_id)
        assignment = self.store.get_assignment(parent["claim"]["id"])
        if assignment["status"] != "running":
            job["advice_recorded"] = True
            self._save_job(job)
            return {"decision": decision, "recorded": True, "applied": False, "reason": "The target execution already settled or paused"}
        if decision in {"steer", "handoff"}:
            instruction = params.get("instruction") or params["reason"]
            if decision == "handoff":
                instruction = "Stop at a safe boundary, call fm_handoff with a complete checkpoint, then end. " + instruction
                parent["handoff_deadline"] = time.time() + 90
                self._save_job(parent)
            self._control(parent, "steer", instruction)
        elif decision == "pause":
            self.store.request_human_gate(assignment["id"], assignment["generation"], assignment["native_session_id"],
                                          "Advisor intervention requires your direction: " + params["reason"], "advisor-pause:" + request_id)
            self._control(parent, "abort", params["reason"])
        job["advice_recorded"] = True
        self._save_job(job)
        return {"decision": decision, "recorded": True}

    def session(self, native_session_id: str, *, before: int | None = None, limit: int = 100) -> dict:
        jobs = self._jobs()
        ledger_records = self.store.list_session_records()
        claims = []
        for job in jobs:
            started = (self._job_dir(job) / "started.json").exists()
            if job.get("native_session_id") == native_session_id:
                claims.append(("job", job, Path(job["session_file"]).resolve(), job["feature_id"], job["kind"]))
            elif started and not job.get("native_session_id"):
                # Header discovery closes only the bind crash gap. Never let a
                # header override a different stored native identity.
                parsed = self.usage.session_usage(job.get("session_file", ""))
                if parsed.get("_identity_valid") and parsed.get("_session_id") == native_session_id:
                    claims.append(("job", job, Path(job["session_file"]).resolve(), job["feature_id"], job["kind"]))
        for row in ledger_records:
            if row.get("native_session_id") == native_session_id:
                kind = "worker" if row.get("assignment_id") else "coordinator"
                claims.append(("ledger", row, Path(row["session_file"]).resolve(), row["feature_id"], kind))
        if not claims:
            raise ValueError("Saved First Mate session was not found")

        path_features: dict[Path, set[str]] = {}
        for row in ledger_records:
            if row.get("session_file") and row.get("feature_id"):
                path_features.setdefault(Path(row["session_file"]).resolve(), set()).add(row["feature_id"])
        for job in jobs:
            if ((self._job_dir(job) / "started.json").exists() or job.get("native_session_id")) and job.get("session_file"):
                path_features.setdefault(Path(job["session_file"]).resolve(), set()).add(job["feature_id"])
        claim_paths = {claim[2] for claim in claims}
        if (len({claim[3] for claim in claims}) > 1 or len(claim_paths) > 1
                or any(len(path_features.get(path, set())) > 1 for path in claim_paths)):
            raise ValueError("Saved session identity has conflicting First Mate ownership")

        selected_source = next((claim for claim in reversed(claims) if claim[0] == "job"), claims[-1])
        source_kind, selected_record, path, feature_id, kind = selected_source
        path.relative_to((self.root / "sessions").resolve())
        rows, _ = _records(path)
        header = next((row for row in rows if row.get("type") == "session"), {})
        if header.get("id") != native_session_id:
            raise ValueError("Saved session identity does not match the retained assignment")
        messages = []
        for row in rows:
            message = row.get("message", {})
            role = message.get("role")
            if role not in {"user", "assistant", "toolResult"}:
                continue
            content = message.get("content", "")
            rendered = content if isinstance(content, str) else "\n".join(str(c.get("text", "")) for c in content if isinstance(c, dict) and c.get("type") == "text")
            messages.append({"role": role, "text": rendered, "created_at": row.get("timestamp")})
        total = len(messages)
        end = total if before is None else max(0, min(total, int(before)))
        count = max(1, min(100, int(limit)))
        start = max(0, end - count)
        selected_messages = [{**m, "index": start + index} for index, m in enumerate(messages[start:end])]
        parsed_usage = self.usage.session_usage(path, native_session_id)
        usage = self.usage.public_summary(parsed_usage)
        model_selection = self._selection(selected_record if source_kind == "job" else {"kind": kind},
                                          parsed_usage)
        return {"ok": True, "native_session_id": native_session_id, "messages": selected_messages,
                "next_before": start if start else None, "total_messages": total,
                "usage": usage, "model_selection": model_selection,
                "session": {"native_session_id": native_session_id, "feature_id": feature_id,
                            "session_file": str(path), "kind": kind, "usage": usage,
                            "model_selection": model_selection}}


def _pi_command(job: dict) -> list[str]:
    """Return the role-scoped Pi invocation for this dispatch.

    Use current in-process charters rather than persisted job text so every turn,
    including a resumed saved session created by an older service revision,
    receives the current role boundary.
    """
    charter = {"coordinator": COORDINATOR_PROMPT,
               "worker": WORKER_PROMPT,
               "advisor": ADVISOR_PROMPT}[job["kind"]]
    prompt_flag = "--system-prompt" if job["kind"] == "coordinator" else "--append-system-prompt"
    command = [job["pi_bin"], "--mode", "rpc", "--session", job["session_file"],
               "--name", "First Mate" if job["kind"] == "coordinator" else job["claim"].get("title", "First Mate advisor"),
               prompt_flag, charter, "--extension", job["extension"]]
    if job.get("model"):
        command += ["--model", job["model"]]
    if job.get("thinking"):
        command += ["--thinking", job["thinking"]]
    return command


def run_detached(directory: Path) -> int:
    """One dispatch's process owner. Never started twice for the same job."""
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = (directory / "writer.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 0
    if (directory / "started.json").exists():
        return 0
    # Read dispatch policy only after acquiring the same lock used by the
    # manager's final pre-launch refresh.
    job = _read_json(directory / "job.json")
    if not job:
        return 2
    # A second lock protects the exact Pi conversation, including across turns
    # and accidental duplicate service instances with different runtime locks.
    session_lock = Path(job["session_file"] + ".lock").open("a")
    try:
        fcntl.flock(session_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        _write_json(directory / "status.json", {"ended": True, "error": "Saved conversation already has a writer"})
        return 1
    # Pi persists an empty explicit session immediately on opening it. Creating
    # the empty file under the writer lock makes its native ID durable even if
    # authentication or the first model response fails before any assistant text.
    session_path = Path(job["session_file"])
    if not session_path.exists():
        with session_path.open("x") as empty:
            os.chmod(session_path, 0o600)
            empty.flush()
            os.fsync(empty.fileno())
    _write_json(directory / "started.json", {"pid": os.getpid(), "at": utc_now(),
                                               "extension": job.get("extension")})
    status = {"pid": os.getpid(), "started_at": utc_now(), "accepted": False,
              "ended": False, "response": "", "last_event_epoch": time.time()}
    _write_json(directory / "status.json", status)
    command = _pi_command(job)
    process = None
    event_lock = threading.Lock()
    accepted = threading.Event()
    ready = threading.Event()
    ended = threading.Event()
    stdin_lock = threading.Lock()
    try:
        stderr = (directory / "pi-stderr.log").open("ab")
        process = subprocess.Popen(command, cwd=job["cwd"], env=os.environ,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
                                   text=True, bufsize=1, start_new_session=True, pass_fds=(lock.fileno(), session_lock.fileno()))
        status["pi_pid"] = process.pid
        _write_json(directory / "status.json", status)
        def send(value: dict) -> None:
            with stdin_lock:
                if process.stdin and process.poll() is None:
                    process.stdin.write(json.dumps(value, ensure_ascii=False) + "\n")
                    process.stdin.flush()
        def consume() -> None:
            assert process.stdout is not None
            with (directory / "events.jsonl").open("a", encoding="utf-8") as output:
                os.chmod(directory / "events.jsonl", 0o600)
                for line in process.stdout:
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(event, dict):
                        continue
                    event.setdefault("id", uuid.uuid4().hex)
                    output.write(json.dumps(event, ensure_ascii=False) + "\n")
                    output.flush()
                    with event_lock:
                        status["last_event_epoch"] = time.time()
                        if event.get("type") == "response" and event.get("command") == "get_state" and event.get("success"):
                            ready.set()
                        if event.get("type") == "response" and event.get("command") == "prompt":
                            status["accepted"] = bool(event.get("success"))
                            if not event.get("success"):
                                status["error"] = event.get("error", "Pi rejected the prompt")
                                ended.set()
                            accepted.set()
                        if event.get("type") == "message_end":
                            message = event.get("message", {})
                            response = _assistant_text(message)
                            if response:
                                status["response"] = response
                            if message.get("stopReason") == "error":
                                status["error"] = message.get("errorMessage", "Model error")
                        if event.get("type") == "agent_end":
                            ended.set()
                        # Coalesce status writes; full events are retained above.
                        if event.get("type") in {"response", "message_end", "agent_end", "tool_execution_start", "tool_execution_end"}:
                            _write_json(directory / "status.json", status)
        reader = threading.Thread(target=consume, name="pi-rpc-events", daemon=True)
        reader.start()
        send({"type": "set_auto_compaction", "enabled": False, "id": "no-compaction"})
        send({"type": "get_state", "id": "initial-state"})
        if not ready.wait(30):
            raise RuntimeError("Pi did not confirm its saved session during startup")
        send({"type": "prompt", "id": "dispatch:" + job["id"], "message": job["prompt"]})
        sent_controls = set()
        abort_deadline = None
        started_epoch = time.monotonic()
        last_flush = time.monotonic()
        while process.poll() is None and not ended.is_set():
            for path in sorted((directory / "controls").glob("*.json")):
                if path.name in sent_controls:
                    continue
                control = _read_json(path, {})
                if control.get("action") == "abort":
                    send({"type": "abort", "id": path.stem})
                    abort_deadline = time.monotonic() + 10
                    status["interrupted"] = True
                elif control.get("action") == "steer":
                    send({"type": "steer", "id": path.stem, "message": control.get("text", "")})
                sent_controls.add(path.name)
                _write_json(directory / "controls-applied" / path.name, control)
            if abort_deadline and time.monotonic() >= abort_deadline:
                break
            if time.monotonic() - started_epoch > job.get("timeout_seconds", 86400):
                status["error"] = "Execution exceeded its bounded supervisor deadline"
                break
            if time.monotonic() - last_flush >= 5:
                with event_lock:
                    _write_json(directory / "status.json", status)
                last_flush = time.monotonic()
            time.sleep(0.1)
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        reader.join(timeout=3)
        status["exit_code"] = process.returncode
        if not accepted.is_set():
            status["error"] = status.get("error") or "Pi stopped before prompt acceptance was observed"
        if not ended.is_set() and not status.get("interrupted"):
            status["error"] = status.get("error") or "Pi stopped without an agent_end event"
    except Exception as exc:
        status["error"] = str(exc)[:1000]
        if process and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
    finally:
        status.update(ended=True, ended_at=utc_now())
        _write_json(directory / "status.json", status)
        session_lock.close()
        lock.close()
    return 0 if not status.get("error") else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, required=True)
    arguments = parser.parse_args()
    raise SystemExit(run_detached(arguments.runner.resolve()))
