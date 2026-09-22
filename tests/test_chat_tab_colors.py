import copy
import json
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from herdr_harness import chat_tab_colors
from herdr_harness.control_store import ControlStore
from herdr_harness.control_validation import ControlError


FIXTURE_PATH = Path(__file__).parent / "fixtures" / "chat-tab-colors-v1.json"
FIXED_TIME = 1893456000.0


class StepClock:
    def __init__(self, value=FIXED_TIME):
        self.value = value

    def __call__(self):
        return self.value


def publication_body(fixture, key, *, server_id):
    return {**copy.deepcopy(fixture["publications"][key]), "serverId": server_id}


class ChatTabColorContractTests(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        self.clock = StepClock()
        self.store = ControlStore(":memory:", clock=self.clock)
        self.addCleanup(self.store.close)
        self.server_id = self.store.server_id

    def publish(self, key, *, store=None, server_id=None, **overrides):
        store = store or self.store
        client_key = "secondary" if key == "disabled" else key
        body = publication_body(self.fixture, key, server_id=server_id or self.server_id)
        body.update(overrides)
        return store.publish_chat_tab_colors(
            client_id=self.fixture["clients"][client_key]["clientId"],
            publisher_token=body["publisherToken"],
            payload=chat_tab_colors.publication_payload(body),
        )

    def test_fixture_pins_the_documented_contract_shape(self):
        self.assertEqual(self.fixture["capability"], "chat-tab-colors-v1")
        self.assertEqual(tuple(self.fixture["palette"]), chat_tab_colors.CHAT_TAB_PALETTE)
        self.assertEqual(self.fixture["staleAfterSeconds"], chat_tab_colors.CHAT_TAB_STALE_SECONDS)
        self.assertEqual(self.fixture["unassignedColor"], chat_tab_colors.CHAT_TAB_COLOR_NONE)
        for client in self.fixture["clients"].values():
            self.assertEqual(uuid.UUID(client["clientId"][3:]).version, 4)
            self.assertEqual(len(client["publisherToken"]), 64)
        # The issue's example label and machine details must not become fixtures.
        text = FIXTURE_PATH.read_text(encoding="utf-8")
        self.assertNotIn("PR Review", text)
        for key in ("primary", "secondary", "disabled"):
            payload = chat_tab_colors.publication_payload(
                publication_body(self.fixture, key, server_id=self.fixture["serverId"])
            )
            self.assertEqual(payload["serverId"], self.fixture["serverId"])
            self.assertNotIn("publisherToken", payload)

    def test_publication_validation_accepts_fixture_and_rejects_invalid_fields(self):
        base = publication_body(self.fixture, "primary", server_id=self.server_id)
        entry = {"workspaceId": "w1", "tabId": "w1:t1", "color": "sage", "label": "Synthetic Group"}

        with patch.object(chat_tab_colors, "MAX_CHAT_TAB_ENTRIES", 1):
            with self.assertRaises(ControlError) as too_many:
                chat_tab_colors.publication_payload(
                    {**base, "tabs": [entry, {**entry, "tabId": "w1:t2"}]}
                )
            self.assertEqual(too_many.exception.code, "publication_too_large")

        with patch.object(chat_tab_colors, "MAX_CHAT_TAB_PUBLICATION_BYTES", 120):
            with self.assertRaises(ControlError) as too_large:
                chat_tab_colors.publication_payload(base)
            self.assertEqual(too_large.exception.code, "body_too_large")

        invalid_cases = [
            ({**base, "tabs": [entry, entry]}, "duplicate"),
            ({**base, "unexpected": True}, "unsupported field"),
            ({**base, "tabs": [{**entry, "color": "purple"}]}, "palette"),
            ({**base, "tabs": [{**entry, "color": None}]}, "requires"),
            ({**base, "tabs": [{**entry, "label": None}]}, "effective label"),
            ({**base, "tabs": [{**entry, "label": "   "}]}, "blank"),
            ({**base, "tabs": [{**entry, "label": "two\nlines"}]}, "control"),
            ({**base, "tabs": [{**entry, "label": "spoof\u202e"}]}, "control"),
            ({**base, "tabs": [{**entry, "tabId": "bad/id"}]}, "invalid"),
            ({**base, "tabs": [{**entry, "workspaceId": ""}]}, "invalid"),
            ({**base, "platform": "MacOS!"}, "platform"),
            ({**base, "revision": 0}, "revision"),
            ({**base, "revision": True}, "revision"),
            ({**base, "enabled": "yes"}, "enabled"),
            ({**base, "enabled": False}, "disabled publication"),
            ({**base, "clientName": " "}, "clientName"),
            ({**base, "serverId": ""}, "serverId"),
            ({**base, "tabs": {}}, "tabs"),
        ]
        for body, expected in invalid_cases:
            with self.subTest(expected=expected), self.assertRaises(ControlError) as raised:
                chat_tab_colors.publication_payload(body)
            self.assertIn(expected, str(raised.exception))

    def test_mixed_topology_publication_matches_the_server_contract(self):
        topology = self.fixture["topologies"]["mixed"]
        empty_identities = [
            pane
            for workspace in topology
            for pane in workspace.get("panes", [])
            if pane.get("tab_id") == ""
        ]
        self.assertTrue(
            empty_identities,
            "the mixed topology fixture must contain a pane without a tab identity",
        )

        body = publication_body(self.fixture, "mixedTopology", server_id=self.server_id)
        payload = chat_tab_colors.publication_payload(body)
        self.assertEqual(
            [tab["tabId"] for tab in payload["tabs"]],
            ["ws_mixed_alpha:t1", "ws_mixed_alpha:t2"],
        )
        assigned = payload["tabs"][0]
        self.assertEqual(assigned["color"], "sage")
        self.assertEqual(assigned["label"], "Synthetic Release Group")
        self.assertIsNone(payload["tabs"][1]["color"])
        self.assertIsNone(payload["tabs"][1]["label"])

        # The identity a tab-less pane would produce is rejected wholesale,
        # which is why the Mac publisher must never emit it.
        with self.assertRaises(ControlError) as raised:
            chat_tab_colors.publication_payload(
                {
                    **body,
                    "tabs": [
                        {
                            "workspaceId": "ws_mixed_beta",
                            "tabId": "",
                            "color": None,
                            "label": None,
                        }
                    ],
                }
            )
        self.assertIn("invalid", str(raised.exception))

    def test_unicode_labels_survive_grapheme_differences(self):
        family = "\U0001F468\u200D\U0001F469\u200D\U0001F467\u200D\U0001F466"
        label = family * 128
        self.assertEqual(len(label), 896)
        self.assertEqual(chat_tab_colors.tab_label("  " + label + "  "), label)
        with self.assertRaises(ControlError):
            chat_tab_colors.tab_label("x" * (chat_tab_colors.MAX_CHAT_TAB_LABEL_CODEPOINTS + 1))
        with patch.object(chat_tab_colors, "MAX_CHAT_TAB_LABEL_BYTES", 4):
            with self.assertRaises(ControlError):
                chat_tab_colors.tab_label("abcd\u00e9")

    def test_projection_matches_exact_identity_and_fixture_expectations(self):
        first = self.publish("primary")
        second = self.publish("secondary")
        publications = self.store.chat_tab_color_publications()
        self.assertEqual(len(publications), 2)
        self.assertEqual(chat_tab_colors.sources_response(publications), self.fixture["expected"]["sources"])

        tabs = [
            {"workspace_id": "ws_synthetic_alpha", "tab_id": "ws_synthetic_alpha:t1"},
            {"workspace_id": "ws_synthetic_alpha", "tab_id": "ws_synthetic_alpha:t2"},
            {"workspace_id": "ws_synthetic_beta", "tab_id": "ws_synthetic_beta:t1"},
            {"workspace_id": "ws_synthetic_beta", "tab_id": "ws_synthetic_beta:t2"},
            {"workspace_id": "ws_synthetic_gamma", "tab_id": "ws_synthetic_gamma:t1"},
        ]
        snapshot = {"tabs": tabs}
        chat_tab_colors.project_snapshot(snapshot, publications)
        for tab in snapshot["tabs"]:
            key = tab["tab_id"]
            if key in self.fixture["expected"]["tabs"]:
                self.assertEqual(tab["chatTabColors"], self.fixture["expected"]["tabs"][key], key)
            else:
                self.assertEqual(
                    [entry["status"] for entry in tab["chatTabColors"]],
                    ["unavailable", "unavailable"],
                    key,
                )
        # A published (workspace, tab) pair never leaks onto another workspace.
        mismatched = {"tabs": [{"workspace_id": "other", "tab_id": "ws_synthetic_alpha:t1"}]}
        chat_tab_colors.project_snapshot(mismatched, publications)
        self.assertEqual(
            [entry["status"] for entry in mismatched["tabs"][0]["chatTabColors"]],
            ["unavailable", "unavailable"],
        )
        self.assertEqual(first["revision"], 7)
        self.assertEqual(second["revision"], 3)

    def test_projection_without_publishers_keeps_the_snapshot_unchanged(self):
        snapshot = {"tabs": [{"workspace_id": "w1", "tab_id": "w1:t1"}]}
        original = copy.deepcopy(snapshot)
        self.assertEqual(chat_tab_colors.project_snapshot(snapshot, []), snapshot)
        self.assertEqual(snapshot, original)
        self.assertEqual(chat_tab_colors.sources_response([]), [])

    def test_projection_with_known_publishers_reports_empty_arrays(self):
        snapshot = {"tabs": [{"workspace_id": "w1", "tab_id": "w1:t1"}]}
        chat_tab_colors.project_snapshot(snapshot, [], include_empty=True)
        self.assertEqual(snapshot["tabs"][0]["chatTabColors"], [])

    def test_revision_heartbeat_conflict_lower_and_server_binding(self):
        first = self.publish("primary")
        self.assertEqual(first["updatedAt"], self.fixture["expected"]["publishedAt"])
        self.assertEqual(first["lastSeenAt"], self.fixture["expected"]["publishedAt"])

        self.clock.value += 20
        heartbeat = self.publish("primary")
        self.assertEqual(heartbeat["updatedAt"], first["updatedAt"])
        self.assertEqual(heartbeat["lastSeenAt"], self.fixture["expected"]["heartbeatAt"])
        self.assertEqual(heartbeat["revision"], first["revision"])

        conflicting = publication_body(self.fixture, "primary", server_id=self.server_id)
        conflicting["tabs"] = [
            {"workspaceId": "ws_synthetic_alpha", "tabId": "ws_synthetic_alpha:t1", "color": "rose", "label": "Other"}
        ]
        with self.assertRaises(ControlError) as conflict:
            self.store.publish_chat_tab_colors(
                client_id=self.fixture["clients"]["primary"]["clientId"],
                publisher_token=conflicting["publisherToken"],
                payload=chat_tab_colors.publication_payload(conflicting),
            )
        self.assertEqual(conflict.exception.code, "publication_conflict")

        with self.assertRaises(ControlError) as older:
            self.publish("primary", revision=6)
        self.assertEqual(older.exception.code, "stale_publication_revision")
        unchanged = self.store.chat_tab_color_publications()[0]
        self.assertEqual(unchanged["revision"], first["revision"])
        self.assertEqual(len(unchanged["tabs"]), 4)

        with self.assertRaises(ControlError) as wrong_server:
            self.publish("primary", server_id=self.fixture["secondServerId"], revision=99)
        self.assertEqual(wrong_server.exception.code, "stale_target")

        with self.assertRaises(ControlError) as spoofed:
            self.publish("primary", publisherToken="f" * 64, revision=99)
        self.assertEqual(spoofed.exception.code, "publisher_unauthorized")

        with patch("herdr_harness.control_store.MAX_CHAT_TAB_PUBLISHERS", 1):
            with self.assertRaises(ControlError) as capacity:
                self.store.publish_chat_tab_colors(
                    client_id=self.fixture["clients"]["secondary"]["clientId"],
                    publisher_token=self.fixture["publications"]["secondary"]["publisherToken"],
                    payload=chat_tab_colors.publication_payload(
                        publication_body(self.fixture, "secondary", server_id=self.server_id)
                    ),
                )
            self.assertEqual(capacity.exception.code, "publisher_capacity")

    def test_disabled_publication_clears_values_but_keeps_the_binding(self):
        first = self.publish("primary")
        self.assertEqual(first["revision"], 7)
        self.clock.value += 10
        disabled_body = {
            **publication_body(self.fixture, "primary", server_id=self.server_id),
            "enabled": False,
            "revision": 8,
            "tabs": [],
        }
        disabled = self.store.publish_chat_tab_colors(
            client_id=self.fixture["clients"]["primary"]["clientId"],
            publisher_token=disabled_body["publisherToken"],
            payload=chat_tab_colors.publication_payload(disabled_body),
        )
        self.assertFalse(disabled["enabled"])
        self.assertEqual(disabled["tabs"], [])

        snapshot = {"tabs": [{"workspace_id": "ws_synthetic_alpha", "tab_id": "ws_synthetic_alpha:t1"}]}
        chat_tab_colors.project_snapshot(snapshot, self.store.chat_tab_color_publications())
        entry = snapshot["tabs"][0]["chatTabColors"][0]
        self.assertEqual(entry["clientId"], self.fixture["clients"]["primary"]["clientId"])
        self.assertEqual(entry["status"], "unavailable")
        self.assertIsNone(entry["color"])
        self.assertIsNone(entry["label"])

        delayed = publication_body(self.fixture, "primary", server_id=self.server_id)
        with self.assertRaises(ControlError) as stale:
            self.store.publish_chat_tab_colors(
                client_id=self.fixture["clients"]["primary"]["clientId"],
                publisher_token=delayed["publisherToken"],
                payload=chat_tab_colors.publication_payload(delayed),
            )
        self.assertEqual(stale.exception.code, "stale_publication_revision")
        restored = self.store.chat_tab_color_publications()[0]
        self.assertFalse(restored["enabled"])
        self.assertEqual(restored["tabs"], [])

        self.clock.value += 10
        reenabled = self.publish("primary", revision=9)
        self.assertTrue(reenabled["enabled"])
        self.assertEqual(len(reenabled["tabs"]), 4)
        self.assertEqual(reenabled["lastSeenAt"], "2030-01-01T00:00:20Z")

    def test_staleness_is_marked_after_sixty_unconfirmed_seconds(self):
        self.publish("primary")
        just_fresh = self.store.chat_tab_color_publications()[0]
        self.assertFalse(just_fresh["stale"])
        self.clock.value += chat_tab_colors.CHAT_TAB_STALE_SECONDS
        boundary = self.store.chat_tab_color_publications()[0]
        self.assertFalse(boundary["stale"])
        self.clock.value += 0.5
        stale = self.store.chat_tab_color_publications()[0]
        self.assertTrue(stale["stale"])
        self.assertEqual(stale["updatedAt"], self.fixture["expected"]["publishedAt"])

    def test_entry_matching_requires_one_same_publisher_entry(self):
        first = self.publish("primary")
        second = self.publish("secondary")
        index = chat_tab_colors.publication_index(self.store.chat_tab_color_publications())
        entries = chat_tab_colors.entries_for_tab(
            index, "ws_synthetic_alpha", "ws_synthetic_alpha:t1"
        )
        primary = self.fixture["clients"]["primary"]["clientId"]
        secondary = self.fixture["clients"]["secondary"]["clientId"]
        self.assertTrue(
            chat_tab_colors.entries_match(
                entries,
                color="sage",
                color_label="  synthetic release group ",
                color_client_id=primary,
            )
        )
        self.assertFalse(
            chat_tab_colors.entries_match(
                entries, color="sage", color_label="Synthetic Release Group", color_client_id=secondary
            )
        )
        self.assertTrue(
            chat_tab_colors.entries_match(entries, color="rose", color_client_id=secondary)
        )

        unavailable = chat_tab_colors.entries_for_tab(
            index, "ws_synthetic_alpha", "ws_synthetic_alpha:t2"
        )
        self.assertFalse(
            chat_tab_colors.entries_match(
                unavailable, color=None, color_label=None, color_client_id=secondary
            )
        )
        self.assertFalse(chat_tab_colors.entries_match(unavailable, color=chat_tab_colors.CHAT_TAB_COLOR_NONE))

        unassigned = chat_tab_colors.entries_for_tab(
            index, "ws_synthetic_beta", "ws_synthetic_beta:t2"
        )
        self.assertTrue(
            chat_tab_colors.entries_match(unassigned, color=chat_tab_colors.CHAT_TAB_COLOR_NONE)
        )
        self.assertTrue(
            chat_tab_colors.entries_match(unassigned, color=chat_tab_colors.CHAT_TAB_COLOR_NONE, color_client_id=primary)
        )
        self.assertTrue(first["stale"] is False and second["stale"] is False)

    def test_relay_catalog_and_search_text_helpers(self):
        descriptor = {"id": "chat.tab-color", "title": "Set tab color", "enabled": True}
        other = {"id": "ui.open", "title": "Open", "enabled": True}
        catalog = chat_tab_colors.disable_relay_actions([descriptor, other])
        self.assertEqual(catalog[1], other)
        self.assertFalse(catalog[0]["enabled"])
        self.assertIn("read-only", catalog[0]["disabledReason"])
        self.assertIsNotNone(chat_tab_colors.disabled_action_reason("chat.tab-color"))
        self.assertIsNone(chat_tab_colors.disabled_action_reason("ui.open"))

        entries = self.fixture["expected"]["tabs"]["ws_synthetic_alpha:t1"]
        self.assertEqual(
            chat_tab_colors.searchable_colors(entries),
            {"tabColor": "sage rose", "tabColorLabel": "Synthetic Release Group"},
        )
        self.assertEqual(chat_tab_colors.searchable_colors(None), {"tabColor": "", "tabColorLabel": ""})
