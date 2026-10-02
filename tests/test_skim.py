"""Skim v1 port: the Skim lab's conformance vectors plus repair and reject cases."""
from __future__ import annotations

import json
from pathlib import Path
import unittest

from herdr_harness import skim

VECTORS = Path(__file__).parent / "fixtures" / "first_mate_skim"


def without_text(segment: dict) -> dict:
    return {key: value for key, value in segment.items() if key != "text"}


class ConformanceVectorTests(unittest.TestCase):
    def test_every_vector_reproduces_exactly(self) -> None:
        files = sorted(path for path in VECTORS.glob("*.json") if path.name != "skim-document.schema.json")
        self.assertGreaterEqual(len(files), 6)
        for path in files:
            with self.subTest(vector=path.name):
                vector = json.loads(path.read_text(encoding="utf-8"))
                self.assertEqual(vector["segmenterVersion"], skim.SEGMENTER_VERSION)
                self.assertEqual(vector["skimVersion"], skim.SKIM_VERSION)
                source = vector["input"]
                document = skim.segment(source["reply"])
                self.assertEqual([without_text(seg) for seg in document.segments], vector["expected"]["segments"])
                self.assertEqual(skim.prompt_view(document.segments), vector["expected"]["promptView"])
                parsed, _, notes = skim.read_model_output(source["modelOutput"])
                normalized = skim.normalize(parsed, document, voice=source["voice"], notes=notes, format=source["format"])
                # Round-trip through JSON like the reference does before comparing.
                self.assertEqual(json.loads(json.dumps(normalized)), vector["expected"]["document"])

    def test_offsets_slice_the_canonical_text(self) -> None:
        for path in VECTORS.glob("*.json"):
            if path.name == "skim-document.schema.json":
                continue
            reply = json.loads(path.read_text(encoding="utf-8"))["input"]["reply"]
            document = skim.segment(reply)
            for seg in document.segments:
                runs = skim.slice_runs(document, [seg["id"]])
                self.assertEqual(runs[0]["text"], seg["text"])


class SegmenterTests(unittest.TestCase):
    def kinds(self, text: str) -> list[str]:
        return [seg["kind"] for seg in skim.segment(text).segments]

    def test_block_kinds_and_extras(self) -> None:
        reply = "\n".join([
            "## Summary", "First paragraph", "continues here.", "",
            "- one", "- two", "  - nested under two", "",
            "```js", "const a = 1;", "", "const b = 2;", "```", "",
            "| a | b |", "|---|---|", "| 1 | 2 |", "",
            "> quoted", "> more", "", "---", "**Next steps**", "", "1. do it",
        ])
        self.assertEqual(self.kinds(reply), ["heading", "paragraph", "item", "item", "code", "table",
                                             "quote", "rule", "heading", "item"])
        segments = skim.segment(reply).segments
        self.assertEqual(segments[3]["text"], "- two\n  - nested under two")
        self.assertEqual(segments[4]["codeLines"], 3)
        self.assertEqual(segments[5]["rows"], 1)
        self.assertTrue(segments[8]["pseudo"])
        self.assertTrue(segments[9]["ordered"])
        self.assertEqual(segments[9]["section"], "s9")

    def test_crlf_is_canonicalized_and_fences_stay_with_items(self) -> None:
        document = skim.segment("Para one.\r\n\r\n- item\r\n\r\nPara two.")
        self.assertEqual(document.text, "Para one.\n\n- item\n\nPara two.")
        self.assertEqual([(s["startLine"], s["endLine"]) for s in document.segments], [(1, 1), (3, 3), (5, 5)])
        self.assertEqual(self.kinds("1. Run this:\n\n   ```bash\n   npm test\n\n   ```\n2. Next"), ["item", "item"])
        self.assertEqual(self.kinds("1. Run this:\n```bash\nnpm test\n```"), ["item", "code"])
        unterminated = skim.segment("Intro\n\n```\ncode\nmore")
        self.assertEqual(unterminated.segments[1]["endLine"], 5)

    def test_offsets_count_utf16_code_units(self) -> None:
        document = skim.segment("Ship it 🚀 now.\n\nSecond block.")
        first, second = document.segments
        # The rocket is two UTF-16 code units, matching the reference's [[0,15],[17,30]].
        self.assertEqual((first["start"], first["end"]), (0, 15))
        self.assertEqual((second["start"], second["end"]), (17, 30))
        self.assertEqual(skim.slice_runs(document, ["s2"])[0]["text"], "Second block.")

    def test_slice_runs_bridge_rules_and_split_gaps(self) -> None:
        document = skim.segment("A\n\nB\n\nX\n\n---\n\nC\n\nD")
        runs = skim.slice_runs(document, ["s5", "s1", "s2", "s6"])
        self.assertEqual([run["ids"] for run in runs], [["s1", "s2"], ["s5", "s6"]])
        self.assertEqual(runs[0]["text"], "A\n\nB")
        bridged = skim.slice_runs(document, ["s3", "s5"])
        self.assertEqual(len(bridged), 1)
        self.assertEqual(bridged[0]["text"], "X\n\n---\n\nC")

    def test_prompt_view_clips_code_but_never_paragraphs(self) -> None:
        code = "\n".join(["```", *[f"line {i}" for i in range(30)], "```"])
        view = skim.prompt_view(skim.segment(f"Words here.\n\n{code}").segments)
        self.assertIn("[s2 code, 30 lines]", view)
        self.assertIn("… (20 more lines)", view)
        self.assertTrue(view.startswith("[s1 para]\nWords here."))

    def test_segment_table_omits_text(self) -> None:
        table = skim.segment_table(skim.segment("## Title\n\nBody text.\n\n```py\nx = 1\n```"))
        self.assertEqual([row["kind"] for row in table], ["heading", "paragraph", "code"])
        self.assertTrue(all("text" not in row and "title" not in row for row in table))
        self.assertEqual(table[2]["lang"], "py")


class InlineAndMarkupTests(unittest.TestCase):
    def test_anchors_ranges_and_code_labels(self) -> None:
        tokens, _ = skim.parse_inline("It [floors `913.5`](s12) and [breaks tests](S3-s5, #s9).")
        anchors = [token for token in tokens if token["t"] == "anchor"]
        self.assertEqual([anchor["ranges"] for anchor in anchors], [[[12, 12]], [[3, 5], [9, 9]]])
        self.assertEqual(skim.plain(tokens), "It floors 913.5 and breaks tests.")
        self.assertEqual(anchors[0]["label"][1]["t"], "code")

    def test_repairs_bare_refs_emphasis_and_literal_brackets(self) -> None:
        tokens, notes = skim.parse_inline("See **this** [s4-s6] and [not a link] (s2).")
        self.assertEqual(skim.plain(tokens), "See this and [not a link].")
        self.assertIn("bare_ref", notes)
        self.assertIn("emphasis_stripped", notes)

    def test_markup_lines_lists_drawers_and_continuations(self) -> None:
        parsed, notes = skim.parse_markup("\n".join([
            "status: plan", "headline: I'd [add a cursor](s3).", "say: It loads everything,",
            "so it's slow.", "- [first](s1)", "- second", "ask: Want me to go ahead?",
            "heads-up: I didn't run it.", "drawer: The patch | code | s4-s5 | two files, 30 lines",
        ]))
        self.assertEqual(parsed["status"], "plan")
        self.assertEqual(parsed["blocks"], [{"say": "It loads everything, so it's slow."},
                                            {"list": ["[first](s1)", "second"]},
                                            {"ask": "Want me to go ahead?"}, {"heads_up": "I didn't run it."}])
        self.assertEqual(parsed["drawers"], [{"title": "The patch", "kind": "code", "refs": "s4-s5",
                                              "peek": "two files, 30 lines"}])
        self.assertEqual(notes, ["continuation"])

    def test_streaming_drops_the_unfinished_line(self) -> None:
        parsed, _ = skim.parse_markup("status: done\nheadline: All green.\nsay: Half a sent", final=False)
        self.assertEqual(parsed["headline"], "All green.")
        self.assertEqual(parsed["blocks"], [])

    def test_read_model_output_accepts_both_syntaxes_and_rejects_empty(self) -> None:
        self.assertEqual(skim.read_model_output('```json\n{"skim":1,"status":"done","headline":"x","blocks":[]}\n```')[1], "json")
        self.assertEqual(skim.read_model_output("```\nstatus: done\nheadline: x\n```")[1], "markup")
        with self.assertRaisesRegex(skim.SkimRejected, "no skim lines"):
            skim.read_model_output("   ")
        with self.assertRaises(skim.SkimRejected):
            skim.read_model_output('{"skim": 1, "status": NaN}')


class NormalizeTests(unittest.TestCase):
    def test_links_resolve_bad_refs_repair_and_every_block_stays_reachable(self) -> None:
        reply = skim.segment("\n".join(["Para one.", "", "- a", "- b", "", "```", "x", "```", "", "Para four?"]))
        parsed, _, notes = skim.read_model_output("\n".join([
            "status: sideways", "headline: [Para](s1) done.", "say: [ghost](s40) and [range](s2-s9).",
            "drawer: Code | code | s4 | one line", "drawer: Empty | log | s99 | nothing",
        ]))
        document = skim.normalize(parsed, reply, notes=notes)
        self.assertEqual(document["status"], "answer")
        self.assertEqual([(a["id"], a["refs"]) for a in document["anchors"]],
                         [("a1", ["s1"]), ("a2", ["s2", "s3", "s4", "s5"])])
        self.assertEqual(skim.plain(document["blocks"][0]["tokens"]), "ghost and range.")
        self.assertEqual([d["refs"] for d in document["drawers"]], [["s4"]])
        self.assertEqual(document["rest"]["refs"], [])
        codes = {warning["code"] for warning in document["warnings"]}
        self.assertTrue({"status", "dead_link", "bad_ref", "drawer_empty"} <= codes)

    def test_uncovered_blocks_land_in_rest_and_unasked_questions_are_flagged(self) -> None:
        reply = skim.segment("Answer.\n\nDetail one.\n\nShould I ship it?")
        document = skim.normalize({"skim": 1, "status": "answer", "headline": "[Answer](s1).", "blocks": [],
                                   "drawers": []}, reply)
        self.assertEqual(document["rest"]["refs"], ["s2", "s3"])
        self.assertTrue(any(w["code"] == "missed_question" for w in document["warnings"]))
        self.assertLess(document["stats"]["coverage"], 0.5)

    def test_breath_tight_budget_and_shape(self) -> None:
        self.assertEqual(skim.budget(40)["max"], 30)
        self.assertEqual(skim.budget(477)["max"], 86)
        self.assertEqual(skim.budget(5000)["max"], 90)
        self.assertEqual(skim.budget(5000, "terse")["max"], 35)
        self.assertEqual(skim.budget(600, "buddy", "breath_tight")["max"], 35)
        self.assertIn("optional next-step line only when the reply explicitly contains that question or suggestion",
                      skim.shape(skim.budget(600, "buddy", "breath_tight"), "breath_tight"))

    def test_math_round_halves_round_up(self) -> None:
        self.assertEqual(skim.js_round(24.5), 25)
        self.assertEqual(skim.js_round(-2.5), -2)
        self.assertEqual(skim.js_round(0.49999999999999994), 0)

    def test_runaway_output_is_rejected(self) -> None:
        reply = skim.segment(" ".join(["word"] * 400))
        runaway = "status: done\nsay: " + " ".join(["filler"] * 200)
        parsed, _, notes = skim.read_model_output(runaway)
        with self.assertRaisesRegex(skim.SkimRejected, "ran away"):
            skim.normalize(parsed, reply, notes=notes, format="breath_tight")

    def test_breath_tight_skim_from_a_lab_style_output(self) -> None:
        reply = "\n\n".join([
            "Checkout reserves stock before charging the card.",
            "When the charge fails, nothing releases the reservation.",
            "- `reserve()` in `cart.js` holds the SKU", "- `charge()` throws on decline",
            "A rollback wrapper would release it.", "Want me to add the rollback?",
        ])
        output = "\n".join([
            "status: answer",
            "say: Checkout [reserves stock first](s1), so a [failed charge](s2) leaves the [SKU held](s3-s4).",
            "ask: Want me to [add the rollback](s5)?",
        ])
        document, normalized, syntax = skim.skim_from_output(reply=reply, output=output)
        self.assertEqual(syntax, "markup")
        self.assertEqual(normalized["format"], "breath_balanced")
        self.assertEqual([block["kind"] for block in normalized["blocks"]], ["say", "ask"])
        self.assertEqual(normalized["rest"]["refs"], ["s6"])
        self.assertEqual(len(normalized["anchors"]), 4)
        self.assertEqual(len(document.segments), 6)


class FollowupGroundingTests(unittest.TestCase):
    def test_malformed_saved_skims_fall_back_without_breaking_history_reads(self):
        for document in ({"blocks": ["stray"]}, {"blocks": "stray"},
                         {"blocks": [{"kind": "ask", "tokens": None}]}):
            self.assertIsNone(skim.ground_followups(document, "A result."))

    def test_status_warning_or_planned_work_cannot_become_an_invented_offer(self):
        for reply in ("The cleanup is running. I will stage the changes when tests pass.",
                      "Some suites were not included in this run.",
                      "Do not ask: Want me to deploy it?", "```text\nWant me to deploy it?\n```"):
            output = "status: answer\nsay: [The update](s1) is available.\nask: Want me to [deploy it](s1)?"
            _, result, _ = skim.skim_from_output(reply=reply, output=output)
            self.assertEqual([b["kind"] for b in result["blocks"]], ["say"])
            self.assertEqual(len(result["anchors"]), 1)

    def test_explicit_question_or_suggestion_is_preserved_verbatim(self):
        for ask in ("Want me to add the rollback?", "Which option do you prefer?", "I recommend reviewing the diff next."):
            reply = "The change is ready.\n\n" + ask
            _, result, _ = skim.skim_from_output(reply=reply, output="status: done\nsay: [The change is ready](s1).\nask: " + ask)
            self.assertEqual([b["kind"] for b in result["blocks"]], ["say", "ask"])

    def test_followup_cannot_add_scope_to_an_existing_question(self):
        _, result, _ = skim.skim_from_output(reply="Want me to review the diff?", output="status: answer\nsay: A [review is proposed](s1).\nask: Want me to review and merge the diff?")
        self.assertEqual([b["kind"] for b in result["blocks"]], ["say"])


class PromptTests(unittest.TestCase):
    def test_packaged_prompt_fills_every_placeholder(self) -> None:
        prompt = skim.prompt_for("Why is export slow?", "It loads every row.\n\nWant me to stream it?")
        self.assertNotIn("{{", prompt.system)
        self.assertIn("## Optional reply options", prompt.system)
        self.assertIn("one or two sentences of at most 30 words", prompt.system)
        self.assertTrue(prompt.user.startswith("QUESTION (what the user asked the agent):\nWhy is export slow?\n\n"))
        self.assertIn("REPLY (the agent's full reply: 2 blocks, 9 words):\n[s1 para]\nIt loads every row.", prompt.user)

    def test_missing_question_is_marked(self) -> None:
        prompt = skim.prompt_for("   ", "Done.")
        self.assertIn("\n(not provided)\n", prompt.user)


if __name__ == "__main__":
    unittest.main()
