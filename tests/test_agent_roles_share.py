import base64
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import uuid

from herdr_harness import agent_roles_share as share
from herdr_harness.agent_roles import AgentRoles, AgentRoleError, PR_REVIEW_BUILTIN_ID

# Assembled at runtime so the repository privacy scan never sees a key header literal.
KEY_HEADER = "-----BEGIN " + "PRIVATE KEY-----"


def bundle(sid="skill_" + "a" * 64, name="synthetic-skill", body="Body", script=b"#!/bin/sh\nexit 0\n", source="agents"):
    text = f"---\nname: {name}\ndescription: Read synthetic fixtures.\n---\n{body}"
    return {"id": sid, "name": name, "description": "Read synthetic fixtures.", "source": source,
            "files": [{"path": "SKILL.md", "content": base64.b64encode(text.encode()).decode()},
                      {"path": "scripts/check.sh", "content": base64.b64encode(script).decode(), "executable": True}]}


def worker(**overrides):
    return {"id": str(uuid.uuid4()), "name": "Synthetic verifier", "whenToUse": "Check a synthetic result.",
            "systemPrompt": "Be precise.", "modelProfile": "execution", "skillIds": [], "allowDelegation": False,
            **overrides}


def reviewer(**overrides):
    return {"id": str(uuid.uuid4()), "name": "Synthetic reviewer", "whenToUse": "", "systemPrompt": "",
            "modelProfile": "default", "skillIds": [], "allowDelegation": False, "purpose": "pr_review",
            "reviewPrompt": "Review the sample change.\n\nPull request: {url}", "group": "Sample team",
            "avatar": "security", **overrides}


class AgentRolesShareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = self.store("exporter")
        self.target = self.store("importer")

    def store(self, machine, environ=None):
        root = Path(self.temp.name) / machine
        value = AgentRoles(root / "agent-roles.sqlite3", machine_id=machine, environ=environ or {})
        self.addCleanup(value.close)
        return value

    def save(self, store, role, bundles=()):
        revision = store.overview()["revision"]
        return store.mutate({"action": "save", "expectedRevision": revision, "role": role,
                             "skillBundles": list(bundles)})

    def plan(self, store, document, local=None):
        result, changed = share.import_document(store, {"document": document, "dryRun": True,
                                                        "localSkills": {} if local is None else local})
        self.assertFalse(changed)
        return result

    def commit(self, store, document, role_ids=None, replace=(), plan=None, local=None):
        plan = plan or self.plan(store, document, local)
        ids = role_ids if role_ids is not None else [row["id"] for row in plan["roles"] if row["selectedByDefault"]]
        return share.import_document(store, {"document": document, "dryRun": False, "planDigest": plan["planDigest"],
                                             "expectedRevision": plan["revision"], "roleIds": ids,
                                             "replaceRoleIds": list(replace),
                                             "localSkills": {} if local is None else local})

    def exported(self, store=None, role_ids=None):
        return share.export_document(store or self.source, role_ids)["document"]

    def package_dirs(self, store):
        root = store._package_root
        return sorted(path.name for path in root.iterdir()) if root.exists() else []

    def test_export_shares_customized_roles_with_their_stored_skills_and_nothing_private(self):
        skill = bundle()
        role = worker(skillIds=[skill["id"]])
        review = reviewer()
        self.save(self.source, role, [skill])
        self.save(self.source, review)
        result = share.export_document(self.source)
        document = result["document"]
        self.assertEqual((document["format"], document["version"]), ("herdr-agent-roles", 1))
        self.assertEqual([item["id"] for item in document["roles"]], [role["id"], review["id"]])
        self.assertEqual(document["roles"][1]["group"], "Sample team")
        self.assertNotIn("teamId", document["roles"][1])
        self.assertEqual(document["skills"][0]["id"], skill["id"])
        files = {item["path"]: item for item in document["skills"][0]["files"]}
        self.assertEqual(base64.b64decode(files["scripts/check.sh"]["content"]), b"#!/bin/sh\nexit 0\n")
        self.assertTrue(files["scripts/check.sh"]["executable"])
        self.assertEqual(document["roles"][0]["skillContent"], {skill["id"]: document["skills"][0]["contentHash"]})
        raw = json.dumps(document)
        for private in ("exporter", "machineId", "revision", self.temp.name, "agent-role-skills", "teamId"):
            self.assertNotIn(private, raw)
        self.assertEqual(result["summary"], {"roles": 2, "skills": 1, "files": 2,
                                             "bytes": sum(len(base64.b64decode(item["content"])) for item in files.values())})

    def test_untouched_builtins_and_recovery_are_never_shared(self):
        preview = share.export_preview(self.source)
        rows = {row["id"]: row for row in preview["roles"]}
        self.assertNotIn("recovery_advisor", rows)
        self.assertFalse(rows["planner"]["shareable"])
        self.assertEqual(rows["planner"]["note"], "Default — nothing to share")
        self.assertTrue(rows["planner"]["automaticSkills"])
        with self.assertRaises(AgentRoleError):
            share.export_document(self.source)
        with self.assertRaises(AgentRoleError):
            share.export_document(self.source, ["planner"])
        planner = next(role for role in self.source.overview()["roles"] if role["id"] == "planner")
        self.save(self.source, {**planner, "systemPrompt": "Plan in small steps."})
        preview = {row["id"]: row for row in share.export_preview(self.source)["roles"]}
        self.assertTrue(preview["planner"]["shareable"])
        self.assertEqual([role["id"] for role in self.exported()["roles"]], ["planner"])

    def test_export_ships_each_roles_own_copy_not_the_latest_upload(self):
        first, second = bundle(body="Version one"), bundle(body="Version two")
        one, two = worker(skillIds=[first["id"]]), worker(skillIds=[first["id"]], name="Second verifier")
        self.save(self.source, one, [first])
        self.save(self.source, two, [second])
        document = self.exported()
        versions = {role["id"]: role["skillContent"][first["id"]] for role in document["roles"]}
        self.assertNotEqual(versions[one["id"]], versions[two["id"]])
        self.assertEqual(len(document["skills"]), 2)
        texts = {entry["contentHash"]: base64.b64decode(next(f["content"] for f in entry["files"] if f["path"] == "SKILL.md"))
                 for entry in document["skills"]}
        self.assertIn(b"Version one", texts[versions[one["id"]]])

    def test_preview_counts_skill_files_without_reading_contents(self):
        skill = bundle()
        role = worker(skillIds=[skill["id"]])
        self.save(self.source, role, [skill])
        row = next(row for row in share.export_preview(self.source)["roles"] if row["id"] == role["id"])
        self.assertEqual(row["skills"], [{"id": skill["id"], "name": "synthetic-skill", "included": True,
                                          "files": 2, "bytes": row["skills"][0]["bytes"], "executable": 1}])

    def test_private_keys_block_export_without_echoing_the_key(self):
        self.save(self.source, worker(systemPrompt="Use this:\n" + KEY_HEADER + "\nabc"))
        with self.assertRaises(AgentRoleError) as caught:
            share.export_document(self.source)
        self.assertEqual(caught.exception.code, "agent_roles_export_blocked")
        self.assertNotIn("BEGIN", str(caught.exception))
        other = self.store("second-exporter")
        skill = bundle(script=(KEY_HEADER + "\n").encode())
        self.save(other, worker(skillIds=[skill["id"]]), [skill])
        with self.assertRaises(AgentRoleError) as caught:
            share.export_document(other)
        self.assertIn("scripts/check.sh", str(caught.exception))

    def test_round_trip_creates_roles_skills_and_team_in_one_revision(self):
        skill = bundle()
        role, review = worker(skillIds=[skill["id"]]), reviewer(skillIds=[skill["id"]])
        self.save(self.source, role, [skill])
        self.save(self.source, review)
        document = self.exported()
        before = self.target.overview()["revision"]
        with mock.patch.object(share, "install_bundle", wraps=share.install_bundle) as install:
            plan = self.plan(self.target, document)
            install.assert_not_called()
        self.assertEqual(self.target.overview()["revision"], before)
        self.assertEqual(self.package_dirs(self.target), [])
        rows = {row["id"]: row for row in plan["roles"]}
        self.assertEqual({row["action"] for row in rows.values()}, {"create"})
        self.assertTrue(all(row["selectedByDefault"] for row in rows.values()))
        self.assertEqual(rows[review["id"]]["team"], {"name": "Sample team", "status": "creates"})
        self.assertEqual(rows[review["id"]]["role"]["teamId"], "")
        self.assertEqual([item["outcome"] for item in rows[role["id"]]["skills"]], ["included"])
        self.assertEqual(plan["skills"][0]["executableFiles"], 1)
        self.assertIn("Read synthetic fixtures.", plan["skills"][0]["skillText"])
        result, changed = self.commit(self.target, document, plan=plan)
        self.assertTrue(changed)
        self.assertEqual(result["imported"], {"created": 2, "updated": 0, "unchanged": 0})
        overview = result["overview"]
        self.assertEqual(overview["revision"], before + 1)
        saved = {item["id"]: item for item in overview["roles"]}
        self.assertEqual(saved[role["id"]]["systemPrompt"], "Be precise.")
        self.assertEqual(saved[review["id"]]["group"], "Sample team")
        self.assertEqual([team["name"] for team in overview["teams"]], ["Sample team"])
        snapshot = self.target.snapshot(role["id"])
        self.assertEqual(snapshot["missingSkillIds"], [])
        self.assertIn("Read synthetic fixtures.", Path(snapshot["skillPaths"][0]).read_text())
        script = Path(snapshot["skillPaths"][0]).parent / "scripts/check.sh"
        self.assertTrue(os.stat(script).st_mode & 0o100)
        self.assertEqual(self.target.snapshot(review["id"])["skillPaths"], snapshot["skillPaths"])

    def test_identical_reimport_is_unchanged_and_writes_nothing(self):
        skill = bundle()
        role = worker(skillIds=[skill["id"]])
        self.save(self.source, role, [skill])
        document = self.exported()
        self.commit(self.target, document)
        revision = self.target.overview()["revision"]
        plan = self.plan(self.target, document)
        self.assertEqual([row["action"] for row in plan["roles"]], ["unchanged"])
        self.assertEqual([item["outcome"] for item in plan["roles"][0]["skills"]], ["present"])
        result, changed = self.commit(self.target, document, role_ids=[role["id"]], plan=plan)
        self.assertFalse(changed)
        self.assertEqual(result["imported"], {"created": 0, "updated": 0, "unchanged": 1})
        self.assertEqual(self.target.overview()["revision"], revision)

    def test_updates_need_explicit_replacement_and_show_what_changes(self):
        role = worker()
        self.save(self.source, role)
        self.commit(self.target, self.exported())
        self.save(self.target, {**role, "systemPrompt": "My own edit."})
        self.save(self.source, {**role, "name": "Renamed verifier", "systemPrompt": "Sender edit."})
        document = self.exported()
        plan = self.plan(self.target, document)
        row = plan["roles"][0]
        self.assertEqual(row["action"], "update")
        self.assertFalse(row["selectedByDefault"])
        self.assertEqual(row["changes"], ["Name", "System prompt"])
        self.assertEqual(row["current"]["systemPrompt"], "My own edit.")
        with self.assertRaises(AgentRoleError):
            self.commit(self.target, document, role_ids=[role["id"]], plan=plan)
        result, changed = self.commit(self.target, document, role_ids=[role["id"]], replace=[role["id"]], plan=plan)
        self.assertTrue(changed)
        self.assertEqual(result["imported"]["updated"], 1)
        saved = next(item for item in self.target.overview()["roles"] if item["id"] == role["id"])
        self.assertEqual((saved["name"], saved["systemPrompt"]), ("Renamed verifier", "Sender edit."))

    def test_customized_builtin_replaces_only_untouched_builtins_by_default(self):
        planner = next(role for role in self.source.overview()["roles"] if role["id"] == "planner")
        self.save(self.source, {**planner, "systemPrompt": "Plan in small steps."})
        document = self.exported()
        row = self.plan(self.target, document)["roles"][0]
        self.assertEqual((row["action"], row["selectedByDefault"]), ("update", True))
        self.assertEqual(row["role"]["modelProfile"], "planning")
        own = next(role for role in self.target.overview()["roles"] if role["id"] == "planner")
        self.save(self.target, {**own, "whenToUse": "My planning notes."})
        row = self.plan(self.target, document)["roles"][0]
        self.assertEqual((row["action"], row["selectedByDefault"]), ("update", False))
        self.assertEqual(row["changes"], ["When to use", "System prompt"])

    def test_skill_changes_reach_an_existing_role_without_replacing_other_copies(self):
        skill = bundle()
        role = worker(skillIds=[skill["id"]])
        self.save(self.source, role, [skill])
        self.commit(self.target, self.exported())
        neighbor = worker(name="Neighbor", skillIds=[skill["id"]])
        self.save(self.target, neighbor)
        neighbor_path = self.target.snapshot(neighbor["id"])["skillPaths"]
        updated = bundle(body="Improved body")
        self.save(self.source, role, [updated])
        document = self.exported()
        plan = self.plan(self.target, document)
        row = plan["roles"][0]
        self.assertEqual((row["action"], row["changes"]), ("update", ["Skills"]))
        self.assertEqual([item["outcome"] for item in row["skills"]], ["separate"])
        derived = row["skills"][0]["id"]
        self.assertEqual(derived, share.derived_skill_id(skill["id"], document["skills"][0]["contentHash"]))
        self.commit(self.target, document, role_ids=[role["id"]], replace=[role["id"]], plan=plan)
        self.assertIn("Improved body", Path(self.target.snapshot(role["id"])["skillPaths"][0]).read_text())
        self.assertEqual(self.target.snapshot(neighbor["id"])["skillPaths"], neighbor_path)
        state = self.target._state()
        self.assertNotEqual(state["packages"][skill["id"]]["digest"], state["packages"][derived]["digest"])
        again = self.plan(self.target, document)
        self.assertEqual(again["roles"][0]["action"], "unchanged")

    def test_a_different_skill_with_the_same_id_is_kept_separate(self):
        mine = bundle(name="my-own-skill", body="Mine")
        self.save(self.target, worker(name="Mine", skillIds=[mine["id"]]), [mine])
        mine_digest = self.target._state()["packages"][mine["id"]]["digest"]
        theirs = bundle(body="Theirs")
        role = worker(skillIds=[theirs["id"]])
        self.save(self.source, role, [theirs])
        plan = self.plan(self.target, self.exported())
        self.assertEqual(plan["roles"][0]["skills"][0]["outcome"], "separate")
        self.assertIn("kept separate", " ".join(plan["roles"][0]["notes"]))
        self.commit(self.target, self.exported())
        self.assertEqual(self.target._state()["packages"][mine["id"]]["digest"], mine_digest)
        self.assertNotIn(mine["id"], self.target.snapshot(role["id"])["skillPaths"][0])
        self.assertIn("Theirs", Path(self.target.snapshot(role["id"])["skillPaths"][0]).read_text())

    def test_identical_skill_already_present_is_reused(self):
        skill = bundle()
        self.save(self.target, worker(name="Mine", skillIds=[skill["id"]]), [skill])
        packages = self.package_dirs(self.target)
        role = worker(skillIds=[skill["id"]])
        self.save(self.source, role, [skill])
        plan = self.plan(self.target, self.exported())
        self.assertEqual(plan["roles"][0]["skills"][0], {"id": skill["id"], "sourceId": skill["id"],
                                                         "name": "synthetic-skill", "outcome": "present"})
        self.commit(self.target, self.exported())
        self.assertEqual(self.package_dirs(self.target), packages)

    def test_name_only_references_use_matching_skills_or_are_left_out(self):
        folder = Path(self.temp.name) / "host-skills" / "shared"
        folder.mkdir(parents=True)
        (folder / "SKILL.md").write_text("---\nname: host-skill\ndescription: Synthetic host skill.\n---\n")
        target = self.store("host", environ={"HERDR_FIRST_MATE_SKILL_SOURCES": json.dumps(
            {"Shared": str(folder.parent)})})
        host_id = target.overview()["skills"][0]["id"]
        unknown = "skill_" + "c" * 64
        role = worker(skillIds=[host_id, unknown])
        document = {"format": "herdr-agent-roles", "version": 1, "roles": [{**role, "builtin": False}],
                    "skills": [{"id": host_id, "name": "host-skill", "description": "", "source": "Shared"},
                               {"id": unknown, "name": "missing-skill", "description": "", "source": "agents"}]}
        row = self.plan(target, document)["roles"][0]
        self.assertEqual([(item["name"], item["outcome"]) for item in row["skills"]],
                         [("host-skill", "available"), ("missing-skill", "missing")])
        self.assertEqual(row["role"]["skillIds"], [host_id])
        self.assertFalse(row["selectedByDefault"])
        self.assertIn("Imports without: missing-skill.", row["notes"])

    def test_rows_that_cannot_be_imported_explain_why(self):
        existing = reviewer()
        self.save(self.target, existing)
        document = {"format": "herdr-agent-roles", "version": 1, "roles": [
            {"id": "recovery_advisor", "name": "Recovery"},
            {**worker(id=existing["id"])},
            {**worker(), "id": "NOT-A-UUID"},
            {**worker(), "name": "Look\u200balike"},
            {**reviewer(), "avatar": "future-avatar"},
            {**worker(), "purpose": "pr_review", "id": "planner"},
        ]}
        rows = self.plan(self.target, document)["roles"]
        self.assertEqual([row["action"] for row in rows], ["skip", "invalid", "invalid", "invalid", "create", "invalid"])
        self.assertEqual(rows[0]["reason"], "Recovery Advisor is managed by each computer.")
        self.assertIn("different kind of role", rows[1]["reason"])
        self.assertIn("invisible", rows[3]["reason"])
        self.assertEqual(rows[4]["role"]["avatar"], "review")
        self.assertTrue(rows[4]["notes"])
        with self.assertRaises(AgentRoleError):
            self.commit(self.target, document, role_ids=["recovery_advisor"])

    def test_team_names_join_existing_teams_ignoring_case(self):
        self.save(self.target, reviewer(group="sample TEAM", name="Theirs"))
        team = self.target.overview()["teams"][0]
        review = reviewer()
        self.save(self.source, review)
        plan = self.plan(self.target, self.exported())
        self.assertEqual(plan["roles"][0]["team"], {"name": "sample TEAM", "status": "joins"})
        self.commit(self.target, self.exported())
        saved = next(item for item in self.target.overview()["roles"] if item["id"] == review["id"])
        self.assertEqual((saved["teamId"], saved["group"]), (team["id"], "sample TEAM"))
        self.assertEqual(len(self.target.overview()["teams"]), 1)

    def test_commit_rejects_stale_revisions_and_changed_plans(self):
        self.save(self.source, worker())
        document = self.exported()
        plan = self.plan(self.target, document)
        self.save(self.target, worker(name="Concurrent"))
        with self.assertRaises(AgentRoleError) as caught:
            self.commit(self.target, document, plan=plan)
        self.assertEqual((caught.exception.status, caught.exception.code), (409, "agent_role_conflict"))
        plan = self.plan(self.target, document)
        with self.assertRaises(AgentRoleError) as caught:
            self.commit(self.target, document, plan={**plan, "planDigest": "0" * 64})
        self.assertEqual((caught.exception.status, caught.exception.code), (409, "import_plan_changed"))
        self.assertNotIn(document["roles"][0]["id"], {role["id"] for role in self.target.overview()["roles"]})

    def test_role_capacity_is_checked_for_the_selection(self):
        document = {"format": "herdr-agent-roles", "version": 1, "roles": [worker(), worker()]}
        capacity = len(self.target.overview()["roles"]) + 1
        with mock.patch.object(share, "MAX_ROLES", capacity):
            plan = self.plan(self.target, document)
            self.assertIn("room for 1 more roles", " ".join(plan["warnings"]))
            with self.assertRaises(AgentRoleError):
                self.commit(self.target, document, plan=plan)
            _, changed = self.commit(self.target, document, role_ids=[plan["roles"][0]["id"]], plan=plan)
            self.assertTrue(changed)

    def test_documents_are_validated_before_planning(self):
        skill = bundle()
        self.save(self.source, worker(skillIds=[skill["id"]]), [skill])
        good = self.exported()
        cases = {
            "format": {**good, "format": "other"},
            "version": {**good, "version": 2},
            "boolean version": {**good, "version": True},
            "no roles": {**good, "roles": []},
            "checksum": {**good, "skills": [{**good["skills"][0], "contentHash": "f" * 64}]},
            "hidden file": {**good, "skills": [{**good["skills"][0], "files": good["skills"][0]["files"]
                                                + [{"path": ".env", "content": ""}]}]},
            "format character path": {**good, "skills": [{**good["skills"][0], "files": good["skills"][0]["files"]
                                                          + [{"path": "notes\u202e.md", "content": ""}]}]},
        }
        for name, document in cases.items():
            with self.subTest(name), self.assertRaises(AgentRoleError) as caught:
                self.plan(self.target, document)
            self.assertEqual(caught.exception.code, "invalid_agent_roles_document")
        with self.assertRaises(AgentRoleError):
            self.plan(self.target, {**good, "version": 2})
        future = {**good, "note": "Shared", "roles": [{**good["roles"][0], "futureField": 1}]}
        plan = self.plan(self.target, future)
        self.assertIn("note", plan["warnings"][0])
        self.assertIn("roles.futureField", plan["warnings"][0])
        self.assertEqual(plan["roles"][0]["action"], "create")

    def test_oversized_exports_fail_closed(self):
        skill = bundle()
        self.save(self.source, worker(skillIds=[skill["id"]]), [skill])
        with mock.patch.object(share, "MAX_BUNDLE_BYTES", 10):
            with self.assertRaises(AgentRoleError) as caught:
                share.export_document(self.source)
        self.assertEqual((caught.exception.status, caught.exception.code), (413, "agent_roles_export_too_large"))
        self.assertIn("synthetic-skill", str(caught.exception))

    def test_the_importing_macs_own_copies_decide_whether_a_skill_id_is_reused(self):
        skill = bundle()
        role = worker(skillIds=[skill["id"]])
        self.save(self.source, role, [skill])
        document = self.exported()
        shared = document["skills"][0]["contentHash"]
        derived = share.derived_skill_id(skill["id"], shared)
        cases = {"no local copy": ({}, skill["id"], "included"),
                 "identical local copy": ({skill["id"]: shared}, skill["id"], "included"),
                 "different local copy": ({skill["id"]: "e" * 64}, derived, "separate"),
                 "older client": (None, derived, "separate")}
        for name, (local, expected, outcome) in cases.items():
            with self.subTest(name):
                body = {"document": document, "dryRun": True}
                if local is not None:
                    body["localSkills"] = local
                plan, _ = share.import_document(self.target, body)
                self.assertEqual([(item["id"], item["outcome"]) for item in plan["roles"][0]["skills"]],
                                 [(expected, outcome)])
        plan = self.plan(self.target, document, local={})
        with self.assertRaises(AgentRoleError) as caught:
            self.commit(self.target, document, plan=plan, local={skill["id"]: "e" * 64})
        self.assertEqual(caught.exception.code, "import_plan_changed")
        with self.assertRaises(AgentRoleError):
            self.plan(self.target, document, local={"not-a-skill": "e" * 64})

    def test_roles_creating_the_same_new_team_all_report_creates(self):
        first, second = reviewer(name="First"), reviewer(name="Second")
        self.save(self.source, first)
        self.save(self.source, second)
        plan = self.plan(self.target, self.exported())
        self.assertEqual([row["team"] for row in plan["roles"]], [{"name": "Sample team", "status": "creates"}] * 2)
        self.assertEqual([row["role"]["teamId"] for row in plan["roles"]], ["", ""])
        self.assertEqual(plan["teams"], [{"name": "Sample team", "status": "creates"}])
        result, _ = self.commit(self.target, self.exported(), plan=plan)
        teams = result["overview"]["teams"]
        self.assertEqual(len(teams), 1)
        saved = {role["id"]: role for role in result["overview"]["roles"]}
        self.assertEqual({saved[first["id"]]["teamId"], saved[second["id"]]["teamId"]}, {teams[0]["id"]})

    def test_rows_that_cannot_be_imported_claim_no_skills_or_teams(self):
        skill = bundle()
        document = {"format": "herdr-agent-roles", "version": 1, "roles": [
            {**reviewer(name="Broken", group="Ghost team"), "skillIds": None},
            {**reviewer(name="Fine", group="ghost TEAM"), "skillIds": [skill["id"]]}],
            "skills": [{key: skill[key] for key in ("id", "name", "description", "source", "files")}]}
        plan = self.plan(self.target, document)
        self.assertEqual([row["action"] for row in plan["roles"]], ["invalid", "create"])
        self.assertEqual(plan["roles"][1]["team"], {"name": "ghost TEAM", "status": "creates"})
        self.assertEqual([item["usedBy"] for item in plan["skills"]], [[plan["roles"][1]["id"]]])
        self.assertEqual(plan["roles"][1]["skills"][0]["outcome"], "included")

    def test_malformed_values_become_invalid_rows_instead_of_errors(self):
        document = {"format": "herdr-agent-roles", "version": 1, "roles": [
            worker(skillIds=[1]), worker(purpose=["worker"]), worker(name=5), reviewer(group=5),
            worker(whenToUse={"text": 1}), worker(skillIds=["skill_" + "a" * 64], skillContent={"x": 1}),
            worker(allowDelegation="yes"), worker(modelProfile=["execution"])]}
        rows = self.plan(self.target, document)["roles"]
        self.assertEqual({row["action"] for row in rows}, {"invalid"})
        self.assertTrue(all(row["reason"] for row in rows))

    def test_text_that_isnt_valid_unicode_is_rejected(self):
        document = {"format": "herdr-agent-roles", "version": 1, "roles": [worker(name="Bad \ud800 name")]}
        with self.assertRaises(AgentRoleError) as caught:
            self.plan(self.target, document)
        self.assertEqual(caught.exception.code, "invalid_agent_roles_document")

    def test_other_private_key_formats_block_export(self):
        self.save(self.source, reviewer(reviewPrompt="-----BEGIN " + "PGP PRIVATE KEY BLOCK-----\nabc"))
        with self.assertRaises(AgentRoleError) as caught:
            share.export_document(self.source)
        self.assertIn("review prompt", str(caught.exception))
        other = self.store("putty-exporter")
        skill = bundle(script=("PuTTY-User-Key-File-" + "3: ssh-ed25519\n").encode())
        self.save(other, worker(skillIds=[skill["id"]]), [skill])
        with self.assertRaises(AgentRoleError) as caught:
            share.export_document(other)
        self.assertEqual(caught.exception.code, "agent_roles_export_blocked")

    def test_hidden_formatting_in_prompts_is_flagged_and_left_unselected(self):
        document = {"format": "herdr-agent-roles", "version": 1,
                    "roles": [worker(systemPrompt="Visible \u202e hidden"), worker(name="Plain")]}
        rows = self.plan(self.target, document)["roles"]
        self.assertEqual([row["selectedByDefault"] for row in rows], [False, True])
        self.assertIn("hidden formatting", rows[0]["notes"][0])

    def test_unknown_file_fields_are_ignored_with_a_warning(self):
        skill = bundle()
        self.save(self.source, worker(skillIds=[skill["id"]]), [skill])
        document = self.exported()
        entry = document["skills"][0]
        document["skills"][0] = {**entry, "files": [{**item, "size": 1} for item in entry["files"]]}
        plan = self.plan(self.target, document)
        self.assertIn("skills.files.size", plan["warnings"][0])
        self.assertEqual(plan["roles"][0]["action"], "create")

    def test_export_of_a_role_that_no_longer_exists_is_a_bad_request(self):
        with self.assertRaises(AgentRoleError) as caught:
            share.export_document(self.source, [str(uuid.uuid4())])
        self.assertEqual((caught.exception.status, caught.exception.code), (400, "invalid_agent_role"))

    def test_a_name_only_reference_never_borrows_another_roles_copy(self):
        folder = Path(self.temp.name) / "exporter-host" / "shared"
        folder.mkdir(parents=True)
        (folder / "SKILL.md").write_text("---\nname: host-skill\ndescription: Synthetic host skill.\n---\n")
        source = self.store("host-exporter", environ={"HERDR_FIRST_MATE_SKILL_SOURCES": json.dumps(
            {"Shared": str(folder.parent)})})
        sid = source.overview()["skills"][0]["id"]
        uses_host, uses_copy = worker(name="Host user", skillIds=[sid]), worker(name="Copy user", skillIds=[sid])
        self.save(source, uses_host)
        self.save(source, uses_copy, [bundle(sid=sid, name="host-skill", body="Stored copy")])
        document = self.exported(source)
        roles = {role["id"]: role for role in document["roles"]}
        self.assertEqual(roles[uses_host["id"]]["skillContent"], {})
        self.assertIn(sid, roles[uses_copy["id"]]["skillContent"])
        rows = {row["id"]: row for row in self.plan(self.target, document)["roles"]}
        self.assertEqual([item["outcome"] for item in rows[uses_host["id"]]["skills"]], ["missing"])
        self.assertEqual([item["outcome"] for item in rows[uses_copy["id"]]["skills"]], ["included"])

    def test_a_failed_install_rolls_back_the_whole_import(self):
        first, second = bundle(), bundle(sid="skill_" + "b" * 64, name="second-skill")
        self.save(self.source, worker(name="One", skillIds=[first["id"]]), [first])
        self.save(self.source, worker(name="Two", skillIds=[second["id"]]), [second])
        document = self.exported()
        calls = []

        def flaky(root, entry, *, error):
            calls.append(entry)
            if len(calls) == 2:
                raise error("Synthetic install failure", status=500)
            return share.install_bundle(root, entry, error=error)

        with mock.patch.object(share, "install_bundle", side_effect=flaky):
            with self.assertRaises(AgentRoleError):
                self.commit(self.target, document)
        overview = self.target.overview()
        self.assertEqual(overview["revision"], 0)
        self.assertFalse({role["id"] for role in document["roles"]} & {role["id"] for role in overview["roles"]})
        self.assertEqual(self.target._state()["packages"], {})

    def test_a_skill_folder_change_without_a_revision_bump_is_a_changed_plan(self):
        folder = Path(self.temp.name) / "target-host"
        folder.mkdir()
        target = self.store("folder-host", environ={"HERDR_FIRST_MATE_SKILL_SOURCES": json.dumps({"Shared": str(folder)})})
        sid = "skill-" + __import__("hashlib").sha256(
            ("source-" + __import__("hashlib").sha256(b"Shared").hexdigest()[:24] + "\0" + "late/SKILL.md").encode()
        ).hexdigest()
        document = {"format": "herdr-agent-roles", "version": 1, "roles": [worker(skillIds=[sid], skillContent={})],
                    "skills": [{"id": sid, "name": "late-skill", "description": "", "source": "Shared"}]}
        plan = self.plan(target, document)
        self.assertEqual(plan["roles"][0]["skills"][0]["outcome"], "missing")
        (folder / "late").mkdir()
        (folder / "late" / "SKILL.md").write_text("---\nname: late-skill\ndescription: Arrives later.\n---\n")
        with self.assertRaises(AgentRoleError) as caught:
            self.commit(target, document, role_ids=[plan["roles"][0]["id"]], plan=plan)
        self.assertEqual(caught.exception.code, "import_plan_changed")
        self.assertEqual(self.plan(target, document)["roles"][0]["skills"][0]["outcome"], "available")

    def test_a_mac_copy_missing_only_the_stored_name_line_counts_as_the_same_skill(self):
        raw_text = "---\ndescription: Read synthetic fixtures.\n---\nBody"
        nameless = {**bundle(name="nameless-skill"), "files": [
            {"path": "SKILL.md", "content": base64.b64encode(raw_text.encode()).decode()}]}
        self.save(self.source, worker(skillIds=[nameless["id"]]), [nameless])
        document = self.exported()
        stored = base64.b64decode(document["skills"][0]["files"][0]["content"]).decode()
        self.assertIn('name: "nameless-skill"', stored)
        raw_hash = share.content_hash([("SKILL.md", raw_text.encode(), False)])
        plan = self.plan(self.target, document, local={nameless["id"]: raw_hash})
        self.assertEqual([(item["id"], item["outcome"]) for item in plan["roles"][0]["skills"]],
                         [(nameless["id"], "included")])

    def test_emoji_names_round_trip_but_invisible_characters_block_export(self):
        skill = bundle(name="dashboards")
        text = "---\nname: dashboards\ndescription: Builds dashboards \U0001f9d1\u200d\U0001f4bb fast.\n---\nBody"
        skill["files"][0]["content"] = base64.b64encode(text.encode()).decode()
        coder = worker(name="\U0001f9d1\u200d\U0001f4bb Coder", skillIds=[skill["id"]])
        self.save(self.source, coder, [skill])
        plan = self.plan(self.target, self.exported())
        self.assertEqual((plan["roles"][0]["action"], plan["roles"][0]["selectedByDefault"]), ("create", True))
        disguised = worker(name="Coder\u200b")
        self.save(self.source, disguised)
        row = next(row for row in share.export_preview(self.source)["roles"] if row["id"] == disguised["id"])
        self.assertEqual((row["shareable"], row["note"]), (False, share._UNSAFE_NOTE))
        with self.assertRaises(AgentRoleError) as caught:
            share.export_document(self.source, [disguised["id"]])
        self.assertEqual(caught.exception.code, "agent_roles_export_blocked")

    def test_long_skill_previews_say_they_are_partial(self):
        text = "---\nname: long-skill\ndescription: Long synthetic text.\n---\n" + "é" * 40000
        skill = bundle(name="long-skill")
        skill["files"][0]["content"] = base64.b64encode(text.encode()).decode()
        self.save(self.source, worker(skillIds=[skill["id"]]), [skill])
        row = self.plan(self.target, self.exported())["skills"][0]
        self.assertTrue(row["skillTextTruncated"])
        self.assertLessEqual(len(row["skillText"].encode("utf-8")), share.MAX_SKILL_TEXT)
        self.assertNotIn("�", row["skillText"])

    def test_hidden_text_in_skill_files_is_flagged_and_left_unselected(self):
        text = "---\nname: quiet-skill\ndescription: Looks harmless.\n---\nRead the file.\U000e0049\U000e0047\u202e"
        skill = bundle(name="quiet-skill")
        skill["files"][0]["content"] = base64.b64encode(text.encode()).decode()
        self.save(self.source, worker(skillIds=[skill["id"]]), [skill])
        plan = self.plan(self.target, self.exported())
        row = plan["roles"][0]
        self.assertFalse(row["selectedByDefault"])
        self.assertIn("Skill ‘quiet-skill’ contains hidden formatting characters", " ".join(row["notes"]))
        self.assertTrue(plan["skills"][0]["hiddenText"])

    def test_kept_separate_skills_say_why(self):
        theirs = bundle(body="Theirs")
        role = worker(skillIds=[theirs["id"]])
        self.save(self.source, role, [theirs])
        document = self.exported()
        by_mac = self.plan(self.target, document, local={theirs["id"]: "e" * 64})["skills"][0]
        self.assertEqual((by_mac["outcome"], by_mac["separateReason"]), ("separate", "mac"))
        mine = bundle(body="Mine")
        self.save(self.target, worker(name="Mine", skillIds=[mine["id"]]), [mine])
        by_computer = self.plan(self.target, document)["skills"][0]
        self.assertEqual(by_computer["separateReason"], "computer")
        other = worker(name="Second", skillIds=[theirs["id"]])
        self.save(self.source, other, [bundle(body="Another version")])
        fresh = self.store("fresh-target")
        rows = self.plan(fresh, self.exported())["skills"]
        self.assertEqual(sorted((row["outcome"], row.get("separateReason")) for row in rows),
                         [("included", None), ("separate", "file")])


if __name__ == "__main__":
    unittest.main()
