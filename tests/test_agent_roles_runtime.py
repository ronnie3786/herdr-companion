"""Role dispatch contracts use synthetic private state and no model calls."""
import copy
import base64
import hashlib
from pathlib import Path
import tempfile
import unittest
import uuid
from types import SimpleNamespace
from unittest.mock import patch

from herdr_harness.first_mate_runtime import FirstMateRuntime, _pi_command, _read_json, _validate_role_pi
from herdr_harness.first_mate_store import FirstMateStore, FirstMateError


class RoleFixtures:
    def __init__(self):
        self.roles = {
            key: {"id": key, "name": key, "systemPrompt": "", "whenToUse": "",
                  "allowDelegation": key != "recovery_advisor", "revision": 0,
                  "modelProfile": profile, "skillPaths": None, "skillIds": None}
            for key, profile in (("first_mate", "planning"), ("second_mate", "planning"),
                                 ("worker", "execution"), ("planner", "planning"),
                                 ("architect", "architect"), ("research_scout", "research_scout"),
                                 ("recovery_advisor", "execution"), ("custom-review", "execution"))
        }
        self.roles["recovery_advisor"]["skillPaths"] = []

    def snapshot(self, role_id):
        from herdr_harness.agent_roles import AgentRoleError
        if role_id not in self.roles:
            raise AgentRoleError("Unknown role")
        return copy.deepcopy(self.roles[role_id])

    def delegation_catalog(self):
        return [{key: role[key] for key in ("id", "name", "whenToUse", "modelProfile")}
                for role in self.roles.values()
                if role["id"] not in {"first_mate", "second_mate", "recovery_advisor"}]


class AgentRoleRuntimeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.roles = RoleFixtures()
        self.store = FirstMateStore(":memory:")
        self.addCleanup(self.store.close)
        self.runtime = FirstMateRuntime(self.store, environ={}, runtime_root=self.root / "runs",
                                        agent_roles=self.roles)
        self.feature = self.store.create_feature({"title": "Synthetic feature", "goal": "Inspect",
                                                 "cwd": str(self.root), "request_id": "create"})

    def command_job(self, **overrides):
        return {"kind": "worker", "pi_bin": "pi", "session_file": str(self.root / "session.jsonl"),
                "extension": "synthetic-extension.ts", "claim": {"title": "Inspect"}, **overrides}

    def test_strict_allowlist_and_empty_selection_disable_discovery(self):
        skill = self.root / "SKILL.md"
        skill.write_text("---\nname: synthetic\ndescription: Inspect synthetic files\n---\n")
        for paths, expected in (([str(skill), str(skill), str(self.root / "missing")], [str(skill)]), ([], [])):
            job = self.command_job(agent_role_snapshot={"skillPaths": paths})
            command = _pi_command(job)
            self.assertEqual(command.count("--no-skills"), 1)
            self.assertEqual([command[index + 1] for index, value in enumerate(command) if value == "--skill"], expected)
        self.assertNotIn("--no-skills", _pi_command(self.command_job(agent_role_snapshot={"skillPaths": None})))
        self.assertNotIn("--no-skills", _pi_command(self.command_job()))

    def test_role_prompt_and_catalog_stay_out_of_process_arguments(self):
        job = self.command_job(agent_role_snapshot={"systemPrompt": "Synthetic private role preferences"},
                               agent_role_catalog=[{"id": "review", "whenToUse": "Inspect synthetic changes"}],
                               agent_profile_snapshot={"prompt": "Synthetic profile preferences"})
        command = _pi_command(job)
        self.assertNotIn("Synthetic private", " ".join(command))
        prompt = Path(command[command.index("--append-system-prompt") + 1]).read_text()
        self.assertIn("Synthetic private role preferences", prompt)
        self.assertIn("Synthetic profile preferences", prompt)
        self.assertIn("agent_role_id", prompt)
        self.assertIn("human gates", prompt)
        self.assertEqual((self.root / "profile-charter.md").stat().st_mode & 0o777, 0o600)

    def test_recovery_keeps_system_boundary_even_with_modified_snapshot(self):
        skill = self.root / "SKILL.md"
        skill.write_text("Synthetic skill")
        command = _pi_command(self.command_job(kind="advisor", recovery_mode=True,
            agent_role_snapshot={"skillPaths": [str(skill)], "systemPrompt": "SHOULD NOT APPEAR"}))
        self.assertIn("--no-skills", command)
        self.assertIn("--no-extensions", command)
        self.assertNotIn("--skill", command)
        prompt = Path(command[command.index("--append-system-prompt") + 1]).read_text()
        self.assertNotIn("SHOULD NOT APPEAR", prompt)

    def test_custom_role_resolves_exact_id_and_freezes_replayed_delegation(self):
        params = {"agent_role_id": "custom-review", "title": "Inspect", "role": "A display label", "prompt": "Review"}
        first = self.runtime._role_parameters(self.feature, params, "request-one")
        self.assertEqual(first["model_profile"], "execution")
        self.roles.roles["custom-review"]["modelProfile"] = "architect"
        self.assertEqual(self.runtime._role_parameters(self.feature, params, "request-one"), first)
        retained = _read_json(self.runtime.root / "role-plans" / (first["agent_role_snapshot_key"] + ".json"))
        self.assertEqual(retained["snapshot"]["modelProfile"], "execution")
        with self.assertRaises(FirstMateError):
            self.runtime._role_parameters(self.feature, {**params, "agent_role_id": "worker"}, "request-one")
        with self.assertRaises(FirstMateError):
            self.runtime._role_parameters(self.feature, {**params, "model_profile": "execution"}, "request-two")
        with self.assertRaises(FirstMateError):
            self.runtime._role_parameters(self.feature, {**params, "agent_role_id": "first_mate"}, "request-three")
        with self.assertRaises(FirstMateError):
            self.runtime._role_parameters(self.feature, {**params, "agent_role_id": "A display label"}, "request-four")

    def test_unreadable_role_plan_never_reselects_current_configuration(self):
        params = {"agent_role_id": "custom-review"}
        selected = self.runtime._role_parameters(self.feature, params, "request")
        path = self.runtime.root / "role-plans" / (selected["agent_role_snapshot_key"] + ".json")
        for contents in ("broken", "[]", "{}"):
            path.write_text(contents)
            with self.assertRaises(FirstMateError):
                self.runtime._role_parameters(self.feature, params, "request")
            self.assertEqual(path.read_text(), contents)

    def test_strict_roles_require_supported_pi_before_any_prompt(self):
        job = self.command_job(agent_role_snapshot={"skillPaths": []})
        for version in ("0.87.1", "0.88.0", "1.0.0", "v1.0.1"):
            with patch("herdr_harness.first_mate_runtime.subprocess.run",
                       return_value=SimpleNamespace(stdout=version, returncode=0)):
                _validate_role_pi(job)
        for version in ("0.87.0", "0.84.2", "unknown", ""):
            with patch("herdr_harness.first_mate_runtime.subprocess.run",
                       return_value=SimpleNamespace(stdout=version, returncode=0)):
                with self.assertRaises(RuntimeError):
                    _validate_role_pi(job)
        with patch("herdr_harness.first_mate_runtime.subprocess.run") as version:
            _validate_role_pi(self.command_job())
            _validate_role_pi(self.command_job(kind="advisor", recovery_mode=True,
                                              agent_role_snapshot={"skillPaths": []}))
            version.assert_not_called()

    def test_builtin_mapping_and_conversation_snapshot_pinning(self):
        claim = self.store.claim_message(self.feature["id"], self.runtime.owner)
        first = self.runtime._new_job(self.feature, kind="coordinator", prompt="Route", claim=claim)
        self.assertEqual(first["agent_role_snapshot"]["id"], "second_mate")
        self.runtime._bind(first, "synthetic-coordinator", first["session_file"])
        self.store.finish_message(claim["id"], self.runtime.owner, "Ready")
        self.roles.roles["second_mate"]["systemPrompt"] = "New preference"
        self.store.append_human_message(self.feature["id"], "Continue", "next")
        next_claim = self.store.claim_message(self.feature["id"], self.runtime.owner)
        second = self.runtime._new_job(self.feature, kind="coordinator", prompt="Continue", claim=next_claim)
        self.assertEqual(second["agent_role_snapshot"]["systemPrompt"], "")
        for kind, profile, lead, expected in (("worker", "execution", False, "worker"),
                ("worker", "planning", False, "planner"), ("worker", "architect", False, "architect"),
                ("worker", "research_scout", False, "research_scout"),
                ("advisor", "execution", False, "recovery_advisor"),
                ("coordinator", "coordinator", True, "first_mate")):
            job = {"kind": kind, "feature_id": "synthetic-other", "claim": {}, "lead": lead,
                   "session_file": "other-session", "model_selection": {"profile": profile}}
            self.runtime._pin_agent_role(job)
            self.assertEqual(job["agent_role_snapshot"]["id"], expected)

    def test_delegation_is_enforced_before_any_worker_or_lead_action(self):
        job = {"agent_role_snapshot": {"allowDelegation": False}}
        for action in ("fm_delegate", "fm_relay", "fm_create_feature"):
            with self.assertRaises(FirstMateError) as raised:
                self.runtime._tool(job, action, {}, "request")
            self.assertEqual(raised.exception.code, "role_delegation_disabled")

    def test_copied_custom_role_flows_through_delegation_restart_and_pi_launch(self):
        from herdr_harness.agent_roles import AgentRoles
        roles_path = self.root / "roles.sqlite3"
        role_store = AgentRoles(roles_path)
        role_id, skill_id = str(uuid.uuid4()), "skill_" + hashlib.sha256(b"synthetic-skill").hexdigest()
        role = {"id": role_id, "name": "Synthetic reviewer", "builtin": False, "locked": False,
                "systemPrompt": "Check the documented acceptance criteria.", "whenToUse": "Review a finished patch.",
                "modelProfile": "execution", "allowDelegation": False, "skillIds": [skill_id]}
        role_store.mutate({"action": "save", "expectedRevision": 0, "role": role,
            "skillBundles": [{"id": skill_id, "name": "synthetic-review", "description": "Inspect a patch.",
                "source": "synthetic", "files": [{"path": "SKILL.md", "content": base64.b64encode(
                    b"---\nname: synthetic-review\ndescription: Inspect a patch.\n---\nRead references/checklist.md\n").decode()},
                    {"path": "references/checklist.md", "content": base64.b64encode(b"Verify acceptance criteria.").decode()}]}]})
        role_store.close()
        # Restart recovers configuration and installed packages from private state.
        role_store = AgentRoles(roles_path)
        self.addCleanup(role_store.close)
        self.runtime.agent_roles = role_store
        human = self.store.claim_message(self.feature["id"], self.runtime.owner)
        coordinator = self.runtime._new_job(self.feature, kind="coordinator", prompt="Route", claim=human)
        self.runtime._bind(coordinator, "synthetic-coordinator", coordinator["session_file"])
        self.runtime._tool(coordinator, "fm_begin_stage", {"stage_key": "implementation", "title": "Inspect"}, "begin")
        delegated = self.runtime._tool(coordinator, "fm_delegate", {
            "title": "Review patch", "role": "A freeform label", "prompt": "Inspect synthetic evidence",
            "agent_role_id": role_id, "workspace_mode": "read_only"}, "delegate")
        self.assertEqual(delegated["metadata"]["agent_role_id"], role_id)
        self.assertEqual(delegated["metadata"]["model_profile"], "execution")
        self.assertNotIn("systemPrompt", delegated["metadata"])
        # Deleting the role cannot break already accepted assignments.
        role_store.mutate({"action": "delete", "roleId": role_id, "expectedRevision": 1})
        claim = self.store.claim_assignment(delegated["id"], self.runtime.owner)
        worker = self.runtime._new_job(self.feature, kind="worker", prompt="Inspect", claim=claim)
        command = _pi_command(worker)
        copied = Path(command[command.index("--skill") + 1])
        self.assertEqual((copied.parent / "references/checklist.md").read_text(), "Verify acceptance criteria.")
        self.assertIn("--no-skills", command)
        charter = Path(command[command.index("--append-system-prompt") + 1]).read_text()
        self.assertIn("Check the documented acceptance criteria.", charter)
        self.assertFalse(worker["agent_role_snapshot"]["allowDelegation"])


if __name__ == "__main__":
    unittest.main()
