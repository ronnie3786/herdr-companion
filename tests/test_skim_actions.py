import unittest

from herdr_harness import skim


REPLY = "I found the missing recovery step.\n\nReply with recover it and I will restore the saved checkpoint.\n\nWant me to revise the plan instead?\n\n```text\nDelete everything\n```\n\n> Proceed with the quoted example."


class SkimActionTests(unittest.TestCase):
    def normalize(self, options, ask=True):
        output = "status: answer\nsay: I found [the missing recovery step](s1).\n"
        if ask:
            output += "ask: Reply with [recover it](s2) and I will restore the saved checkpoint.\n"
        output += "\n".join("action: " + option for option in options)
        return skim.skim_from_output(reply=REPLY, output=output)[1]

    def test_exact_offered_phrase_and_explanation_are_separate_from_summary(self):
        result = self.normalize(["recover it | Ask the agent to restore the saved checkpoint. | s2"])
        self.assertEqual(result["actions"], [{"id": "r1", "label": "recover it",
            "explanation": "Ask the agent to restore the saved checkpoint.", "refs": ["s2"]}])
        self.assertEqual(result["stats"]["skimWords"], 17)

    def test_unsupported_followup_also_removes_its_reply_options(self):
        output = "status: done\nsay: [The change](s1) is done.\nask: Want me to deploy it?\naction: Deploy it | Ask the agent to deploy the change. | s1"
        _, result, _ = skim.skim_from_output(reply="The change is done and the tests passed.", output=output)
        self.assertEqual(result["actions"], [])
        self.assertEqual([block["kind"] for block in result["blocks"]], ["say"])

    def test_actions_cannot_cite_unrelated_prose_beside_a_real_question(self):
        reply = "The deployment remains unauthorized.\n\nWant me to explain the test results?"
        output = "status: answer\nsay: [The tests](s2) are ready.\nask: Want me to explain the test results?\naction: Deploy now | Ask the agent to deploy the application. | s1\naction: Explain the tests | Ask the agent to explain the test results. | s2"
        _, result, _ = skim.skim_from_output(reply=reply, output=output)
        self.assertEqual([action["label"] for action in result["actions"]], ["Explain the tests"])

    def test_no_next_step_means_no_actions(self):
        result = self.normalize(["Proceed | Ask the agent to continue. | s1"], ask=False)
        self.assertEqual(result["actions"], [])
        self.assertTrue(skim.has_content(result))

    def test_malformed_options_do_not_remove_the_summary_or_good_option(self):
        result = self.normalize([
            "Please recover the saved checkpoint immediately | Too many label words. | s2",
            "Recover | | s2", "Recover | Missing block. | s99",
            "Delete everything | This is a code sample, not an offer. | s4",
            "Proceed | This is quoted material. | s5",
            "[Recover](s2) | Markdown is not a label. | s2",
            "recover it | Ask the agent to restore the saved checkpoint. | s2",
            "RECOVER IT | A duplicate. | s2",
        ])
        self.assertEqual([a["label"] for a in result["actions"]], ["recover it"])
        self.assertEqual(result["anchors"][0]["refs"], ["s1"])

    def test_maximum_three_distinct_options(self):
        result = self.normalize([f"Option {n} | Ask for the offered option. | s2" for n in range(5)])
        self.assertEqual(len(result["actions"]), 3)

    def test_legacy_documents_have_no_new_required_field(self):
        self.assertNotIn("actions", self.normalize([]))

    def test_new_budget_adds_twenty_percent_without_changing_legacy_format(self):
        for size in (80, 180, 600, 10000):
            old = skim.budget(size, format="breath_tight")
            new = skim.budget(size, format="breath_balanced")
            self.assertEqual(new["max"], round(old["max"] * 1.2))
        self.assertEqual(skim.budget(600, format="breath_balanced")["max"], 42)

    def test_prompt_keeps_omission_source_grounding_and_exact_send_contract(self):
        prompt = skim.prompt_for(None, REPLY)
        for policy in ("Most replies need NO options", "1 to 5 words", "EXACT reply", "one short sentence", "Never invent follow-up work"):
            self.assertIn(policy, prompt.system)
