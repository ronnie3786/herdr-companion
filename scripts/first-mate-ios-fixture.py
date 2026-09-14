#!/usr/bin/env python3
"""Local simulator fixture: real HTTP handler, SQLite ledger and session reader.

The runtime is deliberately incapable of launching any process. All material is
synthetic and stored below this ignored build directory. No operator config,
credential, existing session, or actual workspace is loaded.
"""
from __future__ import annotations

import argparse
import json
from http.server import ThreadingHTTPServer
from pathlib import Path
import signal
import sys
import threading
import uuid

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from herdr_harness.alerts import utc_now
from herdr_harness.events import EventBroker
from herdr_harness.first_mate_runtime import FirstMateRuntime
from herdr_harness.first_mate_store import FirstMateStore
from herdr_harness.server import HTTPValidationError, make_handler


class FixtureRuntime:
    """Reuse only the production session reader; execution is not implemented."""

    session = FirstMateRuntime.session
    _jobs = FirstMateRuntime._jobs

    def __init__(self, store, root):
        self.store = store
        self.root = root
        self.jobs_root = root / "jobs"
        self.jobs_root.mkdir(parents=True)
        (root / "sessions").mkdir()

    def capabilities(self):
        return {"available": False, "saved_sessions": True,
                "reason": "Synthetic simulator fixture. Agent execution is disabled."}

    def model_catalog(self):
        return {"models": [
            {"id": "synthetic/reasoner", "provider": "synthetic", "name": "Reasoner", "reasoning": True},
            {"id": "synthetic/quick", "provider": "synthetic", "name": "Quick", "reasoning": False}],
            "default_model": "synthetic/default", "thinking_levels": ["off", "low", "medium", "high"]}

    def action(self, feature_id, action, request_id, **kwargs):
        return self.store.feature_action(feature_id, action, request_id, **kwargs)

    def start(self):
        raise RuntimeError("This simulator fixture cannot launch agents")

    def reconcile(self):
        raise RuntimeError("This simulator fixture cannot launch agents")

    def saved_session(self, feature_id, native_id, title, count=8, kind="worker"):
        path = self.root / "sessions" / (native_id + ".jsonl")
        rows = [{"type": "session", "id": native_id, "version": 3, "timestamp": utc_now()}]
        for index in range(count):
            rows.append({"type": "message", "id": f"message-{index}", "timestamp": utc_now(), "message": {
                "role": "user" if index % 2 == 0 else "assistant",
                "content": [{"type": "text", "text": f"{title}, saved message {index + 1} of {count}. "
                    + ("Original synthetic direction: preserve every review and its producing session." if index == 0 else
                       "Synthetic verification evidence. This session was never executed by a model.")}],
            }})
        path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
        job_dir = self.jobs_root / native_id
        job_dir.mkdir()
        (job_dir / "job.json").write_text(json.dumps({"id": native_id, "native_session_id": native_id,
            "session_file": str(path), "feature_id": feature_id, "kind": kind}))
        return str(path)


class FixtureService:
    def __init__(self, root, token):
        self.root = root
        (root / "synthetic-home").mkdir(mode=0o700)
        self.environ = {"HERDR_HARNESS_API_TOKEN": token,
                        "HERDR_STATE_DIR": str(root / "state"), "HOME": str(root / "synthetic-home")}
        self.first_mate_store = FirstMateStore(root / "first-mate.sqlite3")
        self.first_mate = FixtureRuntime(self.first_mate_store, root / "runtime")
        self.broker = EventBroker()
        self.lock = threading.Lock()

    def first_mate_changed(self, feature_id):
        # A deterministic acknowledgment, never a plan, delegation, or stage approval.
        with self.lock:
            message = self.first_mate_store.claim_message(feature_id, "fixture-reply-owner")
            if message:
                self.first_mate_store.finish_message(message["id"], "fixture-reply-owner",
                    reply="I recorded your direction in the simulator fixture. No agents were launched and no next stage was approved.")
            self.broker.publish("first_mate.updated", {"feature_id": feature_id})

    def workspaces_response(self):
        return {"ok": True, "workspaces": [], "alerts": [], "starredPaneIds": [], "generatedAt": utc_now()}

    def health_response(self):
        return {"ok": True, "service": "herdr-harness", "session": "synthetic-first-mate-ios",
            "herdr": {"connected": True, "requestConnected": True, "eventsConnected": True, "socketFound": False,
                      "version": "synthetic", "protocol": 1, "lastError": None},
            "cache": {"available": True, "stale": False, "generatedAt": utc_now()},
            "alerts": {"unread": 0}, "generatedAt": utc_now()}

    def network_response(self, port, **kwargs):
        return {"ok": True, "hostname": "Simulator fixture", "displayName": "Simulator fixture", "port": port,
                "session": "synthetic-first-mate-ios", "apiBasePath": "/api/v1", "authRequired": True}

    def list_alerts(self, **kwargs):
        return {"ok": True, "alerts": [], "unreadCount": 0, "generatedAt": utc_now()}

    def record_request(self, method, segments, query, body):
        with self.lock:
            with (self.root / "requests.jsonl").open("a") as handle:
                handle.write(json.dumps({"method": method, "path": "/" + "/".join(segments), "query": query,
                                        "body": body, "at": utc_now()}) + "\n")


def seed(service):
    store, runtime = service.first_mate_store, service.first_mate
    cwd = service.root / "sample-project"
    cwd.mkdir()
    (cwd / "README.md").write_text("# Synthetic simulator project\nNo application source or real work exists here.\n")
    feature = store.create_feature({"title": "Keep review evidence together", "goal": "Keep every workflow step, document, and independent agent connected to one feature. Start with a plan.", "cwd": str(cwd), "request_id": "seed-feature", "work_item_id": "DEMO-104"})
    fid = feature["id"]
    coordinator_owner = "fixture-coordinator"
    message = store.claim_message(fid, coordinator_owner)
    first_session = runtime.saved_session(fid, "fixture-first-mate-1", "First Mate predecessor", 112, "coordinator")
    store.bind_coordinator_session(fid, coordinator_owner, "fixture-first-mate-1", first_session)
    store.finish_message(message["id"], coordinator_owner, "I will bring each completed step back to you. You can inspect its agents and documents at any time.")

    def visit(stage, title, direction=None):
        if direction:
            authorization = store.append_human_message(fid, direction, "authorize-" + stage)
            claim = store.claim_message(fid, coordinator_owner)
            assert claim["id"] == authorization["id"]
            store.finish_message(claim["id"], coordinator_owner, "Your direction authorizes " + title.lower() + ".")
        else:
            authorization = message
        return store.start_visit(fid, stage, title, "visit-" + stage, 1, authorization["id"])

    def drain_updates():
        while (pending := store.claim_message(fid, coordinator_owner)) is not None:
            store.finish_message(pending["id"], coordinator_owner)

    def agent(visit_id, key, title, role, documents, *, handoff=False, count=8):
        assignment = store.create_assignment(visit_id, {"title": title, "role": role, "prompt": "Synthetic verification only: " + title, "request_id": key})
        owner = "fixture-owner-" + key
        claim = store.claim_assignment(assignment["id"], owner)
        native_id = "fixture-" + key
        session_file = runtime.saved_session(fid, native_id, title, count)
        assignment = store.bind_session(assignment["id"], claim["generation"], owner, native_id, session_file)
        if handoff:
            record = store.begin_handoff(assignment["id"], 1, "handoff-" + key,
                "# Saved handoff\n\nThe evidence lookup is implemented. Continue with the exact session links, then report the focused verification results.\n\nSynthetic fixture checkpoint.")
            successor = "fixture-" + key + "-successor"
            successor_file = runtime.saved_session(fid, successor, title + " successor", 12)
            assignment = store.bind_handoff_successor(record["id"], successor, successor_file, owner + "-successor", "bind-" + key, verified_predecessor_stopped=True)
            assignment = store.acknowledge_handoff(record["id"], successor, assignment["generation"], "ack-" + key)
        store.record_outcome(assignment["id"], assignment["generation"], assignment["native_session_id"], 1,
            "passed", title + " completed with retained evidence.", "outcome-" + key,
            documents=[{"title": name, "content": "# " + name + "\n\n" + text + "\n\n## Provenance\n\nThis document belongs to " + title + ". Its exact producing session remains available.\n\nSynthetic simulator evidence."} for name, text in documents])
        return assignment

    planning = visit("plan", "Planning")
    agent(planning["id"], "planner", "Explore evidence discovery", "Planner", [("Planning findings.md", "Group documents with their workflow step and producing agent.")])
    architect = agent(planning["id"], "architect", "Review session ownership", "Architect", [
        ("Architecture review.md", "Keep the native session identity immutable when a worker hands off."),
        ("Ownership map.md", "Feature → workflow step → assignment → native session → document.")], count=235)
    store.complete_visit(planning["id"], "The plan and architecture review are ready. Two agents attached three documents.", "Implement the durable links after you review the plan.", "complete-plan")
    drain_updates()
    implementation = visit("implement", "Implementation", "The plan looks good. Implement the durable links.")
    builder = agent(implementation["id"], "builder", "Implement durable evidence links", "Implementation", [("Implementation verification.md", "The synthetic focused checks pass. Handoff continuity retains the previous session.")], handoff=True)
    store.complete_visit(implementation["id"], "Implementation is complete. The successor verified its handoff and the earlier session remains available.", "Run the independent reviews.", "complete-implement")
    drain_updates()
    review = visit("review", "Independent review", "Run the seven independent reviews.")
    roles = ["Correctness", "Architecture", "Concurrency", "Security", "Test coverage", "Performance", "User experience"]
    for index, role in enumerate(roles):
        agent(review["id"], "review-" + str(index), role + " review", role, [(role + " findings.md", role + " checks passed against the same synthetic input revision.")], count=8 + index)
    store.complete_visit(review["id"], "All seven reviewers have reported. Their findings and saved sessions are attached to Independent review.", "Inspect the evidence, then tell me which step you want next.", "complete-review")
    drain_updates()
    store.rotate_coordinator_session(fid, "fixture-first-mate-1", "rotate-coordinator", verified_stopped=True)
    coordinator_update = store.append_human_message(fid, "Keep everything ready for my review.", "hold-for-human")
    store.claim_message(fid, coordinator_owner)
    store.bind_coordinator_session(fid, coordinator_owner, "fixture-first-mate-2", runtime.saved_session(fid, "fixture-first-mate-2", "First Mate", 10, "coordinator"))
    store.finish_message(coordinator_update["id"], coordinator_owner, "The feature is ready for your direction. No next step will begin until you ask.")
    return {"feature_id": fid, "cwd": str(cwd), "architecture_session_id": architect["native_session_id"],
            "builder_assignment_id": builder["id"], "planning_visit_id": planning["id"], "review_visit_id": review["id"]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9196)
    parser.add_argument("--output", type=Path, default=REPO / "build" / "first-mate-ios")
    parser.add_argument("--seed-only", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    root = args.output.resolve() / ("fixture-" + uuid.uuid4().hex[:12])
    root.mkdir(mode=0o700)
    token = "synthetic-first-mate-ios-token"
    service = FixtureService(root, token)
    metadata = seed(service)
    base_handler = make_handler(service)

    class RecordingHandler(base_handler):
        def _route(self, method, segments, query, body):
            service.record_request(method, segments, query, body)
            tail = segments[2:]
            read_routes = {("health",), ("network",), ("workspaces",), ("alerts",), ("events",)}
            if tail[:1] != ["first-mate"] and not (method == "GET" and tuple(tail) in read_routes):
                raise HTTPValidationError("This endpoint is outside the simulator fixture", code="not_found", status=404)
            return super()._route(method, segments, query, body)

    server = None if args.seed_only else ThreadingHTTPServer(("127.0.0.1", args.port), RecordingHandler)
    if server:
        server.daemon_threads = True
    manifest = {**metadata, "root": str(root), "token": token,
                "url": "http://localhost:" + str(server.server_port if server else args.port),
                "execution": "disabled; deterministic fixture only", "requests": str(root / "requests.jsonl")}
    (args.output / "fixture-current.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest), flush=True)
    if args.seed_only:
        print(json.dumps({"features": len(service.first_mate_store.list_features()),
                          "session_messages": service.first_mate.session(metadata["architecture_session_id"])["total_messages"]}), flush=True)
        service.first_mate_store.close()
        return
    def stop(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        service.first_mate_store.close()


if __name__ == "__main__":
    main()
