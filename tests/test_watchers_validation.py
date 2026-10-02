from copy import deepcopy
import unittest

from herdr_harness.watchers.assets import CHARACTERS, INSTRUMENTS
from herdr_harness.watchers.errors import WatchersError
from herdr_harness.watchers.validation import (
    example, schema, summary_text, summary_tokens, validate_definition,
    validate_script_body, validate_summary,
)


def definition():
    return example()["definition"]


class WatchersValidationTests(unittest.TestCase):
    def test_synthetic_example_canonical_defaults_do_not_mutate_input(self):
        original = definition()
        expected = deepcopy(original)
        result = validate_definition(original, machine_id="workstation")
        self.assertEqual(original, expected)
        self.assertEqual(result["machine"], "workstation")
        self.assertEqual(result["kind"], "script")
        self.assertEqual(result["state"], "draft")
        self.assertIn(result["avatar"], INSTRUMENTS)
        self.assertEqual(result["steps"][0]["interpreter"], "/bin/bash")
        self.assertEqual(result["steps"][0]["timeout_seconds"], 3600)
        self.assertEqual(result["warnings"], [])
        self.assertTrue(result["summary_text"].startswith("Every 15 min"))
        self.assertEqual(validate_definition(result, machine_id="workstation"), result)

    def test_machine_mismatch_is_rejected(self):
        value = definition()
        value["machine"] = "another-machine"
        with self.assertRaises(WatchersError) as caught:
            validate_definition(value, machine_id="workstation")
        self.assertEqual(caught.exception.code, "machine_mismatch")

    def test_all_four_step_kinds_are_valid_even_when_not_executable(self):
        value = definition()
        value["steps"].insert(1, {"id": "fresh", "kind": "gate", "rule": {"kind": "new_items", "from": "check", "key": "id", "version": "version"}})
        value["steps"].insert(2, {"id": "read", "kind": "agent", "model": "openai-codex/gpt-6-sol", "skill": "review", "instructions": "Summarize the synthetic changes."})
        value["steps"][-1]["to"].append({"kind": "slack", "target": "#example-updates"})
        value["steps"][-1]["to"].append({"kind": "notify"})
        value["summary"] = "{time}, {agent:Sol} runs {skill:review} on {script:check.sh}, then posts to {slack:#example-updates}."
        result = validate_definition(value)
        self.assertEqual(result["kind"], "hybrid")
        self.assertIn(result["avatar"], CHARACTERS)
        self.assertEqual(result["warnings"], [])
        self.assertEqual(result["steps"][2]["mode"], "ask")

    def test_delivery_does_not_count_as_a_script(self):
        value = definition()
        value["steps"][0] = {"id": "read", "kind": "agent", "model": "example/reader", "instructions": "Read the synthetic report."}
        value["summary"] = "{time}, {agent:reader} writes to the {inbox:Watcher inbox}."
        value["avatar"] = "terminal"
        result = validate_definition(value)
        self.assertEqual(result["kind"], "agent")
        self.assertIn(result["avatar"], CHARACTERS)

    def test_step_ids_unique_and_gate_sources_must_be_earlier(self):
        value = definition()
        value["steps"].append(deepcopy(value["steps"][0]))
        with self.assertRaises(WatchersError):
            validate_definition(value)
        value = definition()
        value["steps"].insert(0, {"id": "fresh", "kind": "gate", "rule": {"kind": "changed", "from": "check"}})
        with self.assertRaises(WatchersError):
            validate_definition(value)

    def test_script_filename_paths_and_timeout_limits(self):
        for file in ("../secret", "/tmp/check.sh", "nested/check.sh", ".", "..", "check\x00.sh", "definition.json", "Definition.JSON"):
            with self.subTest(file=file), self.assertRaises(WatchersError):
                value = definition()
                value["steps"][0]["file"] = file
                validate_definition(value)
        for timeout in (0, 21601, True, "3600"):
            with self.subTest(timeout=timeout), self.assertRaises(WatchersError):
                value = definition()
                value["steps"][0]["timeout_seconds"] = timeout
                validate_definition(value)
        value = definition()
        value["steps"][0]["timeout_seconds"] = 21600
        self.assertEqual(validate_definition(value)["steps"][0]["timeout_seconds"], 21600)

    def test_files_and_step_ids_cannot_collide_on_case_insensitive_hosts(self):
        value = definition()
        duplicate = deepcopy(value["steps"][0])
        duplicate.update(id="another", file="Check.sh")
        value["steps"].append(duplicate)
        with self.assertRaises(WatchersError):
            validate_definition(value)
        duplicate.update(id="CHECK", file="another.sh")
        with self.assertRaises(WatchersError):
            validate_definition(value)

    def test_script_body_limit_counts_utf8_bytes(self):
        self.assertEqual(validate_script_body("x" * 262144), "x" * 262144)
        for value in ("x" * 262145, "é" * 131073, "a\x00b", 12):
            with self.assertRaises(WatchersError):
                validate_script_body(value)

    def test_interpreters_are_executables_not_shell_commands(self):
        value = definition()
        value["steps"][0]["interpreter"] = "python"
        self.assertEqual(validate_definition(value)["steps"][0]["interpreter"], "/usr/bin/python3")
        for interpreter in ("bash -c", "relative/python", "/usr/../bin/bash", "/bin/bash\n"):
            value["steps"][0]["interpreter"] = interpreter
            with self.subTest(interpreter=interpreter), self.assertRaises(WatchersError):
                validate_definition(value)

    def test_summary_requires_time_and_disallows_nesting(self):
        for value in ("Every hour", "{time:hour}", "{time} {gh:has {repo:nesting}}", "{time} {gh:missing", "{time} stray}"):
            with self.subTest(value=value), self.assertRaises(WatchersError):
                validate_summary(value, [])

    def test_unknown_and_mismatched_tokens_become_plain_text(self):
        value = definition()
        raw = "{time}, I run {script:missing.sh} for {unknown:a report}, then {agent:Sol}."
        value["summary"] = raw
        result = validate_definition(value)
        self.assertEqual(result["summary"], raw)
        self.assertEqual([item["code"] for item in result["warnings"]], ["chip_step_mismatch", "unknown_chip", "chip_step_mismatch"])
        self.assertEqual([item["chip"] for item in result["summary_tokens"] if item["kind"] == "chip"], ["time"])
        self.assertEqual(result["summary_text"], "Every 15 min, I run missing.sh for a report, then Sol.")

    def test_nine_chips_and_punctuation_remain_in_order(self):
        steps = [
            {"kind": "script", "file": "check.sh"},
            {"kind": "agent", "model": "example/gpt-6-sol", "skill": "review"},
            {"kind": "deliver", "to": [{"kind": "slack", "target": "#updates"}]},
        ]
        raw = "{time}, {gh:PRs}; {script:check.sh}. {agent:Sol} {skill:review} {slack:#updates} {inbox:results} {repo:example} {pc:Desktop}!"
        tokens = summary_tokens(raw, steps, "every hour")
        self.assertEqual(len([item for item in tokens if item["kind"] == "chip"]), 9)
        self.assertEqual(tokens[1], {"kind": "text", "text": ", "})
        self.assertEqual(tokens[-1], {"kind": "text", "text": "!"})
        self.assertEqual(summary_text("First sentence. {time}.", [], "every hour"), "First sentence. Every hour.")

    def test_declared_agent_display_name_is_authoritative(self):
        steps = [{"kind": "agent", "model": "example/gpt-6-sol", "display_name": "Reviewer"}]
        self.assertEqual(validate_summary("{time}, {agent:Reviewer} checks.", steps), [])
        self.assertEqual(validate_summary("{time}, {agent:Sol} checks.", steps)[0]["code"], "chip_step_mismatch")

    def test_metadata_and_cronboard_source_survive_normalization(self):
        value = definition()
        value.update(id="wat_example", revision=3, state="paused", builder_session_id="example-builder", created_by="agent:watcher-builder", activated_by="user", activated_via="cli", created_at="2026-10-01T00:00:00Z", updated_at="2026-10-02T00:00:00Z", source={"kind": "cronboard", "job_id": "example-job"})
        result = validate_definition(value)
        for key in ("id", "revision", "state", "builder_session_id", "created_by", "activated_by", "activated_via", "created_at", "updated_at", "source"):
            self.assertEqual(result[key], value[key])

    def test_schema_exposes_assets_all_kinds_and_agent_workflow(self):
        result = schema()
        self.assertEqual(len(result["assets"]["characters"]), 20)
        self.assertEqual(len(result["assets"]["instruments"]), 8)
        self.assertEqual(len(result["assets"]["chips"]), 9)
        self.assertEqual(len(result["properties"]["schedule"]["oneOf"]), 4)
        self.assertEqual(len(result["properties"]["steps"]["items"]["oneOf"]), 4)
        self.assertEqual(result["workflow"][-1], "Ask the person to activate")
        self.assertEqual(set(example()["scripts"]), {"check"})

    def test_edit_draft_metadata_requires_a_valid_target_and_revision_together(self):
        value = definition()
        value.update(edit_target_id="wat_target", edit_target_revision=4)
        normalized = validate_definition(value)
        self.assertEqual(normalized["edit_target_id"], "wat_target")
        self.assertEqual(normalized["edit_target_revision"], 4)
        for metadata in ({"edit_target_id": "wat_target"}, {"edit_target_revision": 1}, {"edit_target_id": "../target", "edit_target_revision": 1}, {"edit_target_id": "wat_target", "edit_target_revision": True}, {"edit_target_id": "wat_target", "edit_target_revision": 0}):
            with self.subTest(metadata=metadata), self.assertRaises(WatchersError):
                validate_definition({**definition(), **metadata})
        self.assertEqual(schema()["dependentRequired"]["edit_target_id"], ["edit_target_revision"])

    def test_bad_payloads_fail_with_domain_errors(self):
        cases = [None, {}, {**definition(), "surprise": True}, {**definition(), "steps": []}, {**definition(), "steps": [{"id": "oops", "kind": []}]}, {**definition(), "timezone": "Fake/Place"}, {**definition(), "overlap": "queue"}, {**definition(), "avatar": "missing"}]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(WatchersError):
                validate_definition(value)


if __name__ == "__main__":
    unittest.main()
