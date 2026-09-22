import unittest

from herdr_harness import chat_tab_color_cli as helper


PRIMARY = "ui_11111111-1111-4111-8111-111111111111"
SECONDARY = "ui_22222222-2222-4222-8222-222222222222"


def entry(client_id, *, color=None, label=None, status="assigned", stale=False):
    return {
        "clientId": client_id,
        "color": color,
        "label": label,
        "status": status,
        "updatedAt": "2030-01-01T00:00:00Z",
        "lastSeenAt": "2030-01-01T00:00:00Z",
        "stale": stale,
    }


def row(identifier, entries=None, *, kind="pane"):
    document = {
        "kind": kind,
        "id": identifier,
        "title": identifier,
        "updatedAt": "2030-01-01T00:00:00Z",
        "status": "live",
        "target": {"kind": kind, "paneId": identifier},
        "matchEvidence": [],
        "openModes": ["chat"],
    }
    if entries is not None:
        document["chatTabColors"] = entries
    return document


class ChatTabColorCLITests(unittest.TestCase):
    def test_choices_and_capability_are_the_shared_contract(self):
        self.assertEqual(
            helper.CHAT_TAB_COLOR_CHOICES,
            ("lavender", "iris", "rose", "clay", "sage", "slate", "none"),
        )
        self.assertEqual(helper.GROUP_BY_CHOICES, ("color", "label"))
        self.assertEqual(helper.GROUPING_SCOPE, "page")
        self.assertTrue(
            helper.supports_chat_tab_colors(["agent-control-v1", "chat-tab-colors-v1"])
        )
        self.assertFalse(helper.supports_chat_tab_colors(["agent-control-v1"]))
        self.assertFalse(helper.supports_chat_tab_colors(None))

    def test_color_request_detection_and_query_parameters_preserve_values(self):
        self.assertFalse(helper.is_color_requested())
        self.assertTrue(helper.is_color_requested(color="none"))
        self.assertTrue(helper.is_color_requested(color_label=""))
        self.assertTrue(helper.is_color_requested(color_client=PRIMARY))
        self.assertTrue(helper.is_color_requested(group_by="label"))
        self.assertEqual(
            helper.color_query_parameters(
                color="sage",
                color_label="Synthesé ✦ Planning",
                color_client=PRIMARY,
            ),
            {
                "color": "sage",
                "colorLabel": "Synthesé ✦ Planning",
                "colorClientId": PRIMARY,
            },
        )
        self.assertEqual(helper.color_query_parameters(color=None), {})
        self.assertEqual(
            helper.color_query_parameters(color_client=PRIMARY.upper()),
            {"colorClientId": PRIMARY},
        )
        # Values the contract rejects are forwarded unchanged for the server.
        self.assertEqual(
            helper.color_query_parameters(color_client="not-a-client"),
            {"colorClientId": "not-a-client"},
        )

    def test_label_grouping_merges_colors_within_one_publisher_only(self):
        results = [
            row("w1:p1", [entry(PRIMARY, color="sage", label="  Synthetic   Release Group ")]),
            row("w1:p2", [entry(PRIMARY, color="iris", label="synthetic   release group")]),
            row("w1:p3", [entry(SECONDARY, color="sage", label="Synthetic   Release Group")]),
        ]
        groups = helper.group_results(results, group_by="label")
        self.assertEqual(
            [
                (group["clientId"], group["status"], group["key"], group["color"])
                for group in groups
            ],
            [
                (PRIMARY, "assigned", "synthetic   release group", None),
                (SECONDARY, "assigned", "synthetic   release group", None),
            ],
        )
        primary, secondary = groups
        self.assertEqual(primary["colors"], ["iris", "sage"])
        self.assertEqual(primary["count"], 2)
        self.assertEqual(secondary["count"], 1)
        # The first member's display label is retained; nothing merges publishers.
        self.assertEqual(primary["label"], "  Synthetic   Release Group ")
        self.assertEqual(primary["scope"], "page")
        self.assertEqual(
            [member["result"]["id"] for member in primary["members"]],
            ["w1:p1", "w1:p2"],
        )
        self.assertEqual(
            [member["chatTabColor"]["color"] for member in primary["members"]],
            ["sage", "iris"],
        )

    def test_color_grouping_separates_duplicate_labels_by_publisher(self):
        results = [
            row("w1:p1", [entry(PRIMARY, color="sage", label="Release")]),
            row("w1:p2", [entry(SECONDARY, color="sage", label="Release")]),
            row("w1:p3", [entry(PRIMARY, color="iris", label="Release")]),
        ]
        groups = helper.group_results(results, group_by="color")
        self.assertEqual(
            [(group["clientId"], group["key"], group["count"]) for group in groups],
            [(PRIMARY, "iris", 1), (PRIMARY, "sage", 1), (SECONDARY, "sage", 1)],
        )
        self.assertEqual(groups[1]["color"], "sage")
        self.assertEqual(groups[1]["colors"], ["sage"])
        self.assertEqual(groups[0]["members"][0]["result"]["id"], "w1:p3")

    def test_unassigned_unavailable_and_not_applicable_stay_distinct(self):
        results = [
            row("w1:p1", [entry(PRIMARY, status="unassigned")]),
            row("w1:p2", [entry(PRIMARY, status="unavailable")]),
            row("w1:p3", []),
            row("saved-1", None, kind="hud-chat"),
        ]
        groups = helper.group_results(results, group_by="color")
        self.assertEqual(
            [
                (group["status"], group["key"], group["clientId"], group["count"])
                for group in groups
            ],
            [
                ("unassigned", "none", PRIMARY, 1),
                ("unavailable", "unavailable", None, 1),
                ("unavailable", "unavailable", PRIMARY, 1),
                ("notApplicable", None, None, 1),
            ],
        )
        self.assertEqual(groups[0]["members"][0]["result"]["id"], "w1:p1")
        self.assertIsNone(groups[3]["members"][0]["chatTabColor"])
        self.assertEqual(groups[3]["members"][0]["result"]["target"]["kind"], "hud-chat")

    def test_color_none_never_matches_unavailable_or_unknown(self):
        results = [
            row("w1:p1", [entry(PRIMARY, status="unassigned")]),
            row("w1:p2", [entry(PRIMARY, status="unavailable")]),
            row("w1:p3", [entry(PRIMARY, color="iris", label="Release")]),
        ]
        groups = helper.group_results(results, group_by="color", color="none")
        self.assertEqual(
            [(group["status"], group["key"], group["count"]) for group in groups],
            [("unassigned", "none", 1)],
        )
        self.assertEqual(groups[0]["members"][0]["result"]["id"], "w1:p1")

    def test_predicates_match_one_entry_before_grouping(self):
        results = [
            row(
                "w1:p1",
                [
                    entry(PRIMARY, color="sage", label="Release"),
                    entry(SECONDARY, color="iris", label="Release"),
                ],
            ),
            row("w1:p2", [entry(PRIMARY, color="iris", label="Release")]),
        ]
        groups = helper.group_results(
            results, group_by="label", color="sage", color_client=PRIMARY
        )
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]["clientId"], PRIMARY)
        self.assertEqual(groups[0]["colors"], ["sage"])
        self.assertEqual(groups[0]["count"], 1)
        self.assertEqual(
            groups[0]["members"][0]["chatTabColor"]["color"], "sage"
        )

    def test_unicode_labels_normalize_and_stale_flags_survive(self):
        results = [
            row("w1:p1", [entry(PRIMARY, color="iris", label="Synthesé ✦ Planning")]),
            row("w1:p2", [entry(PRIMARY, color="iris", label="  SYNTHESÉ ✦ PLANNING  ", stale=True)]),
            row("w1:p3", [entry(PRIMARY, color="rose", label="Synthesé ✦ Planning")]),
        ]
        groups = helper.group_results(results, group_by="label")
        self.assertEqual(len(groups), 1)
        group = groups[0]
        self.assertEqual(group["key"], "synthesé ✦ planning")
        self.assertEqual(group["colors"], ["iris", "rose"])
        self.assertEqual(group["count"], 3)
        self.assertTrue(group["stale"])
        self.assertTrue(group["members"][1]["chatTabColor"]["stale"])
        self.assertFalse(group["members"][0]["chatTabColor"]["stale"])
        self.assertEqual(group["members"][0]["result"]["target"]["paneId"], "w1:p1")

    def test_mixed_case_client_filter_matches_its_entries(self):
        results = [row("w1:p1", [entry(PRIMARY, color="sage", label="Release")])]
        groups = helper.group_results(
            results, group_by="color", color_client=PRIMARY.upper()
        )
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]["clientId"], PRIMARY)
        self.assertEqual(groups[0]["count"], 1)

    def test_empty_results_and_unknown_group_by(self):
        self.assertEqual(helper.group_results([], group_by="color"), [])
        self.assertEqual(helper.group_results(None, group_by="label"), [])
        with self.assertRaises(ValueError):
            helper.group_results([], group_by="workspace")


if __name__ == "__main__":
    unittest.main()
