"""Transactional membership and generation fences for saved PR reviewers.

These rows supplement the existing run ledger, preserving the skills API.
Only the current membership can publish the current consolidated report.
"""
from __future__ import annotations

import json
from typing import Any

AGENT_SCHEMA = """
CREATE TABLE IF NOT EXISTS prr_agent_runs(run_id TEXT PRIMARY KEY REFERENCES prr_skill_runs(id),agent_id TEXT,kind TEXT NOT NULL,generation INTEGER NOT NULL,snapshot_json TEXT NOT NULL,metadata_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS prr_consolidations(review_id TEXT PRIMARY KEY REFERENCES prr_reviews(id),payload_json TEXT NOT NULL);
"""
TERMINAL_REVIEW_STATES = frozenset({"finished", "failed", "ended"})
SCOPE_FIELDS = ("id", "url", "owner", "repo", "number", "title", "body", "checkout_path", "base_sha", "head_sha", "merge_base_sha")


class ReviewAgentStore:
    def _agent_run_fields(self, run: dict) -> dict:
        row = self._db.execute("SELECT * FROM prr_agent_runs WHERE run_id=?", (run["id"],)).fetchone()
        if row is None:
            return run
        role = json.loads(row["snapshot_json"])
        return {**run, "agent_id": row["agent_id"], "agent_name": role["name"], "agent_avatar": role.get("avatar", "review"),
                "kind": row["kind"], "review_generation": row["generation"], **json.loads(row["metadata_json"])}

    def agent_run_snapshot(self, review_id: str, run_id: str) -> dict:
        with self._lock:
            self.run(review_id, run_id)
            row = self._db.execute("SELECT snapshot_json FROM prr_agent_runs WHERE run_id=?", (run_id,)).fetchone()
            return json.loads(row[0]) if row else {}

    def update_agent_run_metadata(self, review_id: str, run_id: str, **values: Any) -> dict:
        from .pr_review_store import _json
        with self._transaction():
            self.run(review_id, run_id)
            row = self._db.execute("SELECT metadata_json FROM prr_agent_runs WHERE run_id=?", (run_id,)).fetchone()
            metadata = {**json.loads(row[0]), **values}
            self._db.execute("UPDATE prr_agent_runs SET metadata_json=? WHERE run_id=?", (_json(metadata), run_id))
            return self.run(review_id, run_id)

    def _consolidation(self, review_id: str) -> dict | None:
        row = self._db.execute("SELECT payload_json FROM prr_consolidations WHERE review_id=?", (review_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def consolidation(self, review_id: str) -> dict | None:
        with self._lock:
            value = self._consolidation(review_id)
            if value is not None:
                value.pop("members", None)
            return value

    def _save_consolidation(self, review_id: str, value: dict) -> None:
        from .pr_review_store import _json
        self._db.execute("INSERT INTO prr_consolidations VALUES(?,?) ON CONFLICT(review_id) DO UPDATE SET payload_json=excluded.payload_json",
                         (review_id, _json(value)))

    def _insert_agent_run(self, review_id: str, snapshot: dict, kind: str, generation: int, actor: str = "", **metadata) -> dict:
        from .pr_review_store import _id, _json, _now
        run_id = _id("prun")
        review = self.get_review(review_id, True)
        snapshot = {**snapshot, "reviewScope": {key: review.get(key) for key in SCOPE_FIELDS}}
        metadata["merge_base_sha"] = review.get("merge_base_sha")
        agent_id = snapshot["id"] if kind == "reviewer" else None
        # skill_id stays a string for legacy decoders. It is never inserted in
        # the legacy skill catalog, and the runtime dispatches by kind.
        self._db.execute("INSERT INTO prr_skill_runs(id,review_id,skill_id,skill_title,state,launch,actor,created_at) VALUES(?,?,?,?,?,?,?,?)",
                         (run_id, review_id, agent_id or "pr-review-consolidator", snapshot["name"], "queued", "none", actor, _now()))
        self._db.execute("INSERT INTO prr_agent_runs VALUES(?,?,?,?,?,?)",
                         (run_id, agent_id, kind, generation, _json(snapshot), _json(metadata)))
        self._event(review_id, "run.queued", "Review agent queued", {"run_id": run_id, "kind": kind})
        return self.run(review_id, run_id)

    def queue_agent_runs(self, review_id: str, snapshots: list[dict], request_id: str, actor: str = "") -> list[dict]:
        from .pr_review_store import PRReviewError
        payload = {"agent_ids": [role["id"] for role in snapshots], "actor": actor}
        with self._transaction():
            cached = self._receipt("agent-runs:" + review_id, request_id, payload)
            if cached is not None:
                return [self.run(review_id, run["id"]) for run in cached]
            review = self.get_review(review_id)
            if review.get("archived_at"):
                raise PRReviewError("Review is archived", code="review_archived")
            previous = self._consolidation(review_id) or {}
            members = dict(previous.get("members", {}))
            for role in snapshots:
                existing = members.get(role["id"])
                if existing and self.run(review_id, existing)["state"] not in TERMINAL_REVIEW_STATES:
                    raise PRReviewError("A selected review agent is already running", code="review_agent_busy")
            generation = previous.get("generation", 0) + 1
            created = []
            for role in snapshots:
                run = self._insert_agent_run(review_id, role, "reviewer", generation, actor,
                    base_sha=review.get("base_sha"), head_sha=review.get("head_sha"), document_ids=[])
                members[role["id"]] = run["id"]
                created.append(run)
            value = {"generation": generation, "base_sha": review.get("base_sha"), "head_sha": review.get("head_sha"),
                     "members": members, "input_run_ids": list(members.values()), "state": "waiting", "run_id": None,
                     "document_ids": [], "incomplete_run_ids": [], "error": None}
            self._save_consolidation(review_id, value)
            self._touch(review_id)
            return self._save("agent-runs:" + review_id, request_id, payload, created)

    def _agent_preparation_finished(self, review_id: str, previous: dict, values: dict) -> None:
        """Called in complete_preparation's transaction, never after publication."""
        value = self._consolidation(review_id)
        if value is None:
            return
        shas = (values.get("base_sha"), values.get("head_sha"))
        if shas == (value.get("base_sha"), value.get("head_sha")):
            return
        value.update(base_sha=shas[0], head_sha=shas[1], run_id=None, document_ids=[], incomplete_run_ids=[])
        if previous.get("head_sha") is not None:
            value.update(generation=value["generation"] + 1, state="failed",
                         incomplete_run_ids=list(value["input_run_ids"]),
                         error="The pull request changed. Rerun the selected reviewers for this revision.")
        else:
            from .pr_review_store import _json
            scope = {key: {**previous, **values}.get(key) for key in SCOPE_FIELDS}
            # The very first preparation pins every already-selected reviewer
            # atomically with the published PR revision, before launch threads.
            for run_id in value["input_run_ids"]:
                row = self._db.execute("SELECT snapshot_json,metadata_json FROM prr_agent_runs WHERE run_id=?", (run_id,)).fetchone()
                role, metadata = json.loads(row[0]), json.loads(row[1])
                if metadata.get("head_sha") is None:
                    role["reviewScope"] = scope
                    metadata.update(base_sha=shas[0], head_sha=shas[1], merge_base_sha=values.get("merge_base_sha"))
                    self._db.execute("UPDATE prr_agent_runs SET snapshot_json=?,metadata_json=? WHERE run_id=?", (_json(role), _json(metadata), run_id))
        self._save_consolidation(review_id, value)

    def claim_consolidation(self, review_id: str) -> dict | None:
        """Claim once after all current members settle, including failed members."""
        with self._transaction():
            review = self.get_review(review_id)
            value = self._consolidation(review_id)
            if (value is None or value["state"] != "waiting" or review.get("archived_at") or review["status"] != "ready"
                    or not value["input_run_ids"]):
                return None
            if (value["base_sha"], value["head_sha"]) != (review["base_sha"], review["head_sha"]):
                return None
            runs = [self.run(review_id, run_id) for run_id in value["input_run_ids"]]
            if any(run["state"] not in TERMINAL_REVIEW_STATES for run in runs):
                return None
            incomplete = [run["id"] for run in runs if run["state"] != "finished" or not run.get("document_ids")
                          or (run.get("base_sha"), run.get("head_sha")) != (value["base_sha"], value["head_sha"])]
            snapshot = {"id": "pr-review-consolidator", "name": "Consolidated review", "avatar": "review", "purpose": "pr_review",
                        "modelProfile": "default", "skillIds": [], "skillPaths": [], "missingSkillIds": [], "reviewPrompt": ""}
            run = self._insert_agent_run(review_id, snapshot, "consolidator", value["generation"],
                base_sha=value["base_sha"], head_sha=value["head_sha"], input_run_ids=value["input_run_ids"],
                incomplete_run_ids=incomplete, document_ids=[])
            value.update(state="running", run_id=run["id"], incomplete_run_ids=incomplete)
            self._save_consolidation(review_id, value)
            self._touch(review_id)
            return run

    def settle_consolidation(self, review_id: str, run_id: str) -> bool:
        """An old worker can retain history but cannot publish a newer result."""
        with self._transaction():
            value = self._consolidation(review_id)
            run = self.run(review_id, run_id)
            review = self.get_review(review_id)
            if (value is None or value["state"] != "running" or run["state"] not in TERMINAL_REVIEW_STATES or value["run_id"] != run_id
                    or value["generation"] != run["review_generation"]
                    or value["input_run_ids"] != run.get("input_run_ids")
                    or (review["base_sha"], review["head_sha"]) != (run.get("base_sha"), run.get("head_sha"))):
                return False
            value.update(state="finished" if run["state"] == "finished" else "failed",
                         document_ids=run.get("document_ids", []), error=run.get("error"))
            self._save_consolidation(review_id, value)
            self._touch(review_id)
            return True
