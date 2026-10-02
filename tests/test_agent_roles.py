import base64
import concurrent.futures
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import uuid

from herdr_harness.agent_roles import AgentRoles, AgentRoleError, BUILTIN_IDS, configured_sources, skill_catalog
from herdr_harness.config import load_configuration, ConfigurationError


def custom_role(**overrides):
    return {"id": str(uuid.uuid4()), "name": "Verifier", "whenToUse": "Check a result.",
            "systemPrompt": "", "modelProfile": "execution", "skillIds": [],
            "allowDelegation": False, **overrides}


def skill_bundle(sid="skill_" + "a" * 64, text="---\nname: synthetic-skill\ndescription: Read synthetic fixtures.\n---\nBody"):
    return {"id": sid, "name": "Synthetic Skill", "description": "Read synthetic fixtures.", "source": "Personal",
            "files": [{"path": "SKILL.md", "content": base64.b64encode(text.encode()).decode()},
                      {"path": "scripts/check.sh", "content": base64.b64encode(b"#!/bin/sh\nexit 0\n").decode(), "executable": True}]}


class AgentRolesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sources = self.root / "catalog"
        self.sources.mkdir()
        self.environ = {"HERDR_FIRST_MATE_SKILL_SOURCES": json.dumps({"Synthetic": str(self.sources)})}
        self.store = AgentRoles(self.root / "state/roles.sqlite3", machine_id="synthetic", environ=self.environ)
        self.addCleanup(self.store.close)

    def save(self, role, *, bundles=None, store=None, revision=None):
        store = store or self.store
        return store.mutate({"action": "save", "role": role,
                             "expectedRevision": store.overview()["revision"] if revision is None else revision,
                             **({"skillBundles": bundles} if bundles is not None else {})})

    def skill(self, name="synthetic-skill", *, folder=None, content=None):
        directory = (folder or self.sources) / name
        directory.mkdir(parents=True)
        path = directory / "SKILL.md"
        path.write_text(content or f"---\nname: {name}\ndescription: Synthetic fixtures only.\n---\nLong body\n")
        return path

    def test_defaults_are_blank_private_and_stable(self):
        value = self.store.overview()
        self.assertEqual(value["revision"], 0)
        self.assertEqual(value["machineId"], "synthetic")
        self.assertEqual({r["id"] for r in value["roles"]}, BUILTIN_IDS)
        self.assertTrue(all(not r["systemPrompt"] for r in value["roles"]))
        for role in value["roles"]:
            self.assertEqual(role["builtin"], True)
            if role["purpose"] == "worker" and role["id"] != "recovery_advisor":
                self.assertIsNone(role["skillIds"])
                self.assertIsNone(self.store.snapshot(role["id"])["skillPaths"])
        self.assertEqual(os.stat(self.root / "state/roles.sqlite3").st_mode & 0o777, 0o600)

    def test_custom_save_defaults_empty_and_persists(self):
        role = custom_role()
        del role["skillIds"]
        del role["allowDelegation"]
        self.save(role)
        saved = self.store.snapshot(role["id"])
        self.assertEqual(saved["skillPaths"], [])
        self.assertFalse(saved["allowDelegation"])
        second = AgentRoles(self.root / "state/roles.sqlite3", environ={})
        self.addCleanup(second.close)
        self.assertEqual(second.snapshot(role["id"]), saved)

    def test_stale_revision_does_not_overwrite(self):
        role = custom_role(systemPrompt="Saved preference")
        self.save(role)
        with self.assertRaises(AgentRoleError) as caught:
            self.save({**role, "systemPrompt": "Stale draft"}, revision=0)
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(self.store.snapshot(role["id"])["systemPrompt"], "Saved preference")

    def test_competing_connections_commit_one_edit(self):
        second = AgentRoles(self.root / "state/roles.sqlite3", environ={})
        self.addCleanup(second.close)
        def mutate(store):
            try:
                self.save(custom_role(), store=store, revision=0)
                return "saved"
            except AgentRoleError as exc:
                return exc.status
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(mutate, (self.store, second)))
        self.assertCountEqual(results, ["saved", 409])

    def test_recovery_advisor_cannot_gain_skills_prompt_or_delegation(self):
        advisor = self.store.snapshot("recovery_advisor")
        self.assertEqual(advisor["skillPaths"], [])
        self.assertFalse(advisor["allowDelegation"])
        role = next(r for r in self.store.overview()["roles"] if r["id"] == "recovery_advisor")
        for update in ({"systemPrompt": "Edit"}, {"allowDelegation": True}, {"skillIds": None}, {"name": "New"}):
            with self.subTest(update=update), self.assertRaises(AgentRoleError) as caught:
                self.save({**role, **update})
            self.assertEqual(caught.exception.status, 403)
        self.assertEqual(self.store.overview()["revision"], 0)

    def test_builtins_cannot_be_deleted_custom_can(self):
        for rid in BUILTIN_IDS:
            with self.assertRaises(AgentRoleError):
                self.store.mutate({"action": "delete", "roleId": rid, "expectedRevision": 0})
        role = custom_role()
        self.save(role)
        self.store.mutate({"action": "delete", "roleId": role["id"], "expectedRevision": 1})
        with self.assertRaises(AgentRoleError) as caught:
            self.store.snapshot(role["id"])
        self.assertEqual(caught.exception.status, 404)

    def test_names_do_not_determine_identity_or_routing(self):
        role = next(r for r in self.store.overview()["roles"] if r["id"] == "worker")
        self.save({**role, "name": "First Mate"})
        self.assertEqual(self.store.snapshot("worker")["modelProfile"], "execution")
        with self.assertRaises(AgentRoleError):
            self.save({**role, "modelProfile": "architect"})
        self.assertEqual(self.store.snapshot("first_mate")["modelProfile"], "planning")
        catalog = self.store.delegation_catalog()
        self.assertNotIn("first_mate", {r["id"] for r in catalog})
        self.assertEqual(next(r for r in catalog if r["id"] == "worker")["name"], "First Mate")

    def test_validation_rejects_path_injection_invalid_ids_and_flags(self):
        cases = ({"id": "../outside"}, {"skillIds": ["/private/file"]}, {"skillIds": "all"},
                 {"skillPaths": ["/private/file"]}, {"builtin": True}, {"locked": True},
                 {"name": "  "}, {"name": "Two\nlines"}, {"allowDelegation": 1},
                 {"modelProfile": "unconfigured"}, {"systemPrompt": "x" * 32769})
        for changes in cases:
            with self.subTest(changes=changes), self.assertRaises(AgentRoleError):
                self.save(custom_role(**changes))
        self.assertEqual(self.store.overview()["revision"], 0)
        with self.assertRaises(AgentRoleError):
            self.store.mutate({"action": "save", "role": custom_role(), "expectedRevision": True})

    def test_missing_selection_is_retained_without_discovery_fallback(self):
        path = self.skill()
        sid = self.store.overview()["skills"][0]["id"]
        role = custom_role(skillIds=[sid])
        self.save(role)
        self.assertEqual(self.store.snapshot(role["id"])["skillPaths"], [str(path.resolve())])
        path.unlink()
        self.save({**role, "name": "Edited while unavailable"})
        value = self.store.snapshot(role["id"])
        self.assertEqual(value["skillIds"], [sid])
        self.assertEqual(value["skillPaths"], [])
        self.assertEqual(value["missingSkillIds"], [sid])
        with self.assertRaises(AgentRoleError):
            self.save(custom_role(skillIds=[sid]))

    def test_skill_ids_are_source_and_path_based_not_names(self):
        path = self.skill(content="---\nname: Original\ndescription: Synthetic.\n---")
        original = self.store.overview()["skills"][0]
        path.write_text("---\nname: Renamed\ndescription: Synthetic.\n---")
        renamed = self.store.overview()["skills"][0]
        self.assertEqual(original["id"], renamed["id"])
        self.assertNotEqual(original["name"], renamed["name"])
        self.skill(name="different-directory", content=path.read_text())
        items = self.store.overview()["skills"]
        self.assertEqual(len({item["id"] for item in items}), 2)

    def test_import_copies_scripts_and_private_permissions(self):
        bundle = skill_bundle()
        role = custom_role(skillIds=[bundle["id"]])
        self.save(role, bundles=[bundle])
        snapshot = self.store.snapshot(role["id"])
        path = Path(snapshot["skillPaths"][0])
        self.assertEqual(path.name, "SKILL.md")
        self.assertIn("agent-role-skills", path.parts)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual((path.parent / "scripts/check.sh").stat().st_mode & 0o777, 0o700)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(snapshot["missingSkillIds"], [])
        self.assertEqual(self.store.overview()["skills"][0]["id"], bundle["id"])

    def test_import_refresh_is_immutable_and_role_scoped(self):
        bundle = skill_bundle()
        role_a = custom_role(skillIds=[bundle["id"]])
        role_b = custom_role(skillIds=[bundle["id"]])
        self.save(role_a, bundles=[bundle])
        self.save(role_b)
        original = self.store.snapshot(role_a["id"])["skillPaths"]
        self.save(role_a, bundles=[skill_bundle(text="---\nname: synthetic-skill\ndescription: Updated fixture.\n---\nUpdated skill manifest")])
        updated = self.store.snapshot(role_a["id"])["skillPaths"]
        self.assertNotEqual(original, updated)
        self.assertEqual(self.store.snapshot(role_b["id"])["skillPaths"], original)
        self.assertTrue(Path(original[0]).is_file())
        self.assertIn("Updated skill manifest", Path(updated[0]).read_text())

    def test_missing_import_never_uses_another_catalog_entry(self):
        bundle = skill_bundle()
        role = custom_role(skillIds=[bundle["id"]])
        self.save(role, bundles=[bundle])
        path = Path(self.store.snapshot(role["id"])["skillPaths"][0])
        path.unlink()
        with mock.patch("herdr_harness.agent_roles.skill_catalog", return_value={"skills": [{"id": bundle["id"], "path": "/wrong/SKILL.md"}]}):
            snapshot = self.store.snapshot(role["id"])
        self.assertEqual(snapshot["skillPaths"], [])
        self.assertEqual(snapshot["missingSkillIds"], [bundle["id"]])

    def test_missing_copied_skills_warn_per_role_using_pinned_version(self):
        bundle = skill_bundle()
        role_a = custom_role(name="First reviewer", skillIds=[bundle["id"]])
        role_b = custom_role(name="Second reviewer", skillIds=[bundle["id"]])
        self.save(role_a, bundles=[bundle])
        old = Path(self.store.snapshot(role_a["id"])["skillPaths"][0])
        self.save(role_b, bundles=[skill_bundle(text="---\nname: synthetic-skill\ndescription: New fixture.\n---")])
        latest = Path(self.store.snapshot(role_b["id"])["skillPaths"][0])
        # Source remains available but the imported execution-host copy is missing.
        self.skill()
        old.unlink()
        warnings = self.store.overview()["warnings"]
        self.assertTrue(any("First reviewer: 1 selected skill is unavailable" in w for w in warnings))
        self.assertFalse(any("Second reviewer" in w for w in warnings))
        self.assertEqual(self.store.overview()["missingRoleSkills"], {role_a["id"]: [bundle["id"]]})
        self.assertIn(bundle["id"], {skill["id"] for skill in self.store.overview()["skills"]})
        latest.unlink()
        self.assertEqual(self.store.overview()["missingRoleSkills"],
                         {role_a["id"]: [bundle["id"]], role_b["id"]: [bundle["id"]]})
        self.assertTrue(any("Second reviewer: 1 selected skill is unavailable" in w for w in self.store.overview()["warnings"]))

    def test_update_copies_repairs_damaged_package_without_overwriting_pinned_path(self):
        bundle = skill_bundle()
        role = custom_role(skillIds=[bundle["id"]])
        self.save(role, bundles=[bundle])
        original = Path(self.store.snapshot(role["id"])["skillPaths"][0])
        original.unlink()
        self.save(role, bundles=[bundle])
        repaired = Path(self.store.snapshot(role["id"])["skillPaths"][0])
        self.assertNotEqual(original, repaired)
        self.assertTrue(repaired.is_file())
        self.assertTrue(original.parent.is_dir())
        self.assertEqual(self.store.overview()["warnings"], [])

    def test_invalid_packages_leave_revision_and_files_unchanged(self):
        for path in ("../escape", "/escape", "sub/../../escape", "sub\\escape", "a//b", "./SKILL.md", ".git/config"):
            bundle = skill_bundle()
            bundle["files"].append({"path": path, "content": ""})
            with self.subTest(path=path), self.assertRaises(AgentRoleError):
                self.save(custom_role(skillIds=[bundle["id"]]), bundles=[bundle])
        self.assertEqual(self.store.overview()["revision"], 0)
        self.assertFalse((self.root / "state/agent-role-skills").exists())

    def test_duplicate_bad_base64_missing_manifest_and_extraneous_bundles_rejected(self):
        bundle = skill_bundle()
        cases = [
            {**bundle, "files": bundle["files"] + [{"path": "skill.md", "content": ""}]},
            {**bundle, "files": [{"path": "SKILL.md", "content": "invalid@@"}]},
            {**bundle, "files": [{"path": "instructions.md", "content": ""}]},
            {**bundle, "files": bundle["files"] + [{"path": "scripts", "content": ""}]},
            {**bundle, "files": [{"path": "SKILL.md", "content": base64.b64encode(b"\xff").decode()}]},
        ]
        for invalid in cases:
            with self.subTest(invalid=invalid), self.assertRaises(AgentRoleError):
                self.save(custom_role(skillIds=[bundle["id"]]), bundles=[invalid])
        with self.assertRaises(AgentRoleError):
            self.save(custom_role(), bundles=[bundle])
        with self.assertRaises(AgentRoleError):
            self.save(custom_role(skillIds=[bundle["id"]]), bundles=[bundle, bundle])

    def test_malformed_unicode_and_action_are_validation_errors(self):
        with self.assertRaises(AgentRoleError):
            self.store.mutate({"action": [], "expectedRevision": 0})
        bundle = skill_bundle()
        for invalid in ({**bundle, "name": "\ud800"},
                        {**bundle, "files": [{"path": "\ud800", "content": ""}]}):
            with self.assertRaises(AgentRoleError):
                self.save(custom_role(skillIds=[bundle["id"]]), bundles=[invalid])

    def test_manifest_metadata_overrides_bundle_labels(self):
        bundle = skill_bundle()
        self.save(custom_role(skillIds=[bundle["id"]]), bundles=[{**bundle, "name": "Incorrect label", "description": "Wrong"}])
        value = self.store.overview()["skills"][0]
        self.assertEqual(value["name"], "synthetic-skill")
        self.assertEqual(value["description"], "Read synthetic fixtures.")

    def test_missing_manifest_name_preserves_original_identity_after_copy(self):
        for header in ("description: Synthetic fixture.", "name:\ndescription: Synthetic fixture."):
            bundle = skill_bundle(text="---\n" + header + "\n---\nBody")
            bundle["name"] = "original-folder"
            role = custom_role(skillIds=[bundle["id"]])
            self.save(role, bundles=[bundle])
            path = Path(self.store.snapshot(role["id"])["skillPaths"][0])
            self.assertIn('name: "original-folder"', path.read_text())
            self.assertEqual(self.store.overview()["skills"][0]["name"], "original-folder")
        with self.assertRaises(AgentRoleError):
            self.save(custom_role(skillIds=[bundle["id"]]), bundles=[skill_bundle(text="---\nname: invalid\n---")])

    def test_multiline_and_quoted_manifest_metadata(self):
        from herdr_harness.agent_roles import _metadata
        for scalar, expected in ((">-\n  First line.\n  Second line.", "First line. Second line."),
                                 ("|\n  First line.\n  Second line.", "First line.\nSecond line."),
                                 ('"First line.\n  Second line."', "First line. Second line."),
                                 ("First line.\n  Second line. # comment", "First line. Second line.")):
            self.assertEqual(_metadata("---\ndescription: " + scalar + "\n---", "fallback"), ("fallback", expected))

    def test_duplicate_skill_names_rejected_before_install(self):
        bundles = [skill_bundle(), skill_bundle(sid="skill_" + "b" * 64)]
        with self.assertRaises(AgentRoleError) as caught:
            self.save(custom_role(skillIds=[b["id"] for b in bundles]), bundles=bundles)
        self.assertIn("duplicate names", str(caught.exception))
        self.assertFalse((self.root / "state/agent-role-skills").exists())

    def test_bundle_size_and_file_count_limits(self):
        bundle = skill_bundle()
        for files in ([{"path": "SKILL.md", "content": base64.b64encode(b"x" * (2 * 1024 * 1024 + 1)).decode()}],
                      [{"path": f"file-{i}", "content": ""} for i in range(1001)]):
            with self.assertRaises(AgentRoleError):
                self.save(custom_role(skillIds=[bundle["id"]]), bundles=[{**bundle, "files": files}])

    def test_total_bundle_bytes_are_bounded(self):
        bundle = skill_bundle()
        files = [{"path": "SKILL.md", "content": ""}]
        files += [{"path": f"file-{i}", "content": base64.b64encode(b"x" * (2 * 1024 * 1024)).decode()} for i in range(4)]
        files.append({"path": "overflow", "content": "eA=="})
        with self.assertRaises(AgentRoleError):
            self.save(custom_role(skillIds=[bundle["id"]]), bundles=[{**bundle, "files": files}])

    def test_conflict_does_not_install_packages(self):
        self.save(custom_role())
        bundle = skill_bundle()
        with self.assertRaises(AgentRoleError) as caught:
            self.save(custom_role(skillIds=[bundle["id"]]), bundles=[bundle], revision=0)
        self.assertEqual(caught.exception.status, 409)
        self.assertFalse((self.root / "state/agent-role-skills").exists())


class SkillCatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_nested_symlink_entries_duplicates_and_cycles(self):
        actual = self.root / "actual"
        skill = actual / "group/skill"
        skill.mkdir(parents=True)
        (skill / "SKILL.md").write_text("---\nname: Synthetic\ndescription: >-\n  A multiline\n  description.\n---\nBody")
        alias = self.root / "aliases"
        alias.mkdir()
        (alias / "linked-skill").symlink_to(skill, target_is_directory=True)
        (actual / "cycle").symlink_to(actual, target_is_directory=True)
        value = skill_catalog({"One": alias, "Two": actual, "Missing": self.root / "missing"})
        self.assertEqual(len(value["skills"]), 1)
        self.assertEqual(value["skills"][0]["description"], "A multiline description.")
        self.assertEqual(value["skills"][0]["path"], str((skill / "SKILL.md").resolve()))
        self.assertGreater(value["skills"][0]["estimatedTokens"], 0)
        self.assertFalse(next(s for s in value["sources"] if s["name"] == "Missing")["available"])
        self.assertEqual(len(value["warnings"]), 1)

    def test_hardlinked_files_deduplicate(self):
        for name in ("a", "b"):
            (self.root / name).mkdir()
        (self.root / "a/SKILL.md").write_text("---\nname: Synthetic\ndescription: Synthetic fixture.\n---")
        os.link(self.root / "a/SKILL.md", self.root / "b/SKILL.md")
        self.assertEqual(len(skill_catalog({"Local": self.root})["skills"]), 1)

    def test_scan_is_bounded(self):
        directory = self.root / "a/b/c"
        directory.mkdir(parents=True)
        (directory / "SKILL.md").write_text("Synthetic")
        with mock.patch("herdr_harness.agent_roles.MAX_SCAN_DEPTH", 1):
            value = skill_catalog({"Local": self.root})
        self.assertEqual(value["skills"], [])
        self.assertIn("scan limit", value["warnings"][0])
        with mock.patch("herdr_harness.agent_roles.MAX_SCAN_ENTRIES", 1):
            self.assertTrue(skill_catalog({"Local": self.root})["warnings"])

    def test_no_home_never_discovers_operator_skills(self):
        self.assertEqual(configured_sources({}), {})
        self.assertEqual(configured_sources({"HOME": str(self.root), "HERDR_FIRST_MATE_SKILL_SOURCES": "{}"}), {})
        paths = configured_sources({"HOME": str(self.root)})
        self.assertEqual(set(paths.values()), {self.root / ".pi/agent/skills", self.root / ".agents/skills"})

    def test_configuration_normalizes_paths_and_respects_environment(self):
        path = self.root / "config.toml"
        path.write_text('[first_mate]\nskill_sources = {Personal = "~/.pi/agent/skills", Project = "project/skills"}\n')
        config = load_configuration(path, environ={"HOME": str(self.root)})
        self.assertEqual(json.loads(config.environ["HERDR_FIRST_MATE_SKILL_SOURCES"]),
                         {"Personal": str(self.root / ".pi/agent/skills"), "Project": str(self.root.resolve() / "project/skills")})
        override = load_configuration(path, environ={"HERDR_FIRST_MATE_SKILL_SOURCES": "{}"})
        self.assertEqual(override.environ["HERDR_FIRST_MATE_SKILL_SOURCES"], "{}")
        path.write_text('[first_mate]\nskill_sources = {}\n')
        self.assertEqual(load_configuration(path, environ={}).environ["HERDR_FIRST_MATE_SKILL_SOURCES"], "{}")
        path.write_text('[first_mate]\nskill_sources = {Bad = 4}\n')
        with self.assertRaises(ConfigurationError):
            load_configuration(path, environ={})

    def test_invalid_source_environment_rejected(self):
        for value in ("[]", "bad-json", '{"Test":"relative"}', '{"Test":"~/skills"}', '{"Test":4}'):
            with self.subTest(value=value), self.assertRaises(AgentRoleError):
                configured_sources({"HERDR_FIRST_MATE_SKILL_SOURCES": value})


if __name__ == "__main__":
    unittest.main()
