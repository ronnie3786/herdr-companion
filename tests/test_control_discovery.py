import copy
import threading
import unittest
from unittest.mock import patch

from herdr_harness import hud_chats
from herdr_harness.control_discovery import DiscoveryService
from herdr_harness.control_validation import ControlError
from herdr_harness.service import HerdrService


CURRENT_SESSION_ID = "11111111-1111-4111-8111-111111111111"
SECOND_SESSION_ID = "22222222-2222-4222-8222-222222222222"
OLD_SESSION_ID = "33333333-3333-4333-8333-333333333333"


class FakeFirstMateStore:
    def list_features(self):
        return [
            {
                "id": "fmf_1",
                "title": "Deliver navigation",
                "goal": "Add exact navigation",
                "cwd": "/synthetic/project",
                "status": "awaiting_direction",
                "updated_at": "2026-09-16T10:00:00Z",
                "work_item_id": "work-control-7",
            }
        ]

    def snapshot(self, feature_id):
        return {"feature": next(item for item in self.list_features() if item["id"] == feature_id)}


class FakeActiveWork:
    def board_projection(self):
        return {
            "items": [
                {
                    "id": "work-control-7",
                    "jira_links": [{"issue_key": "CONTROL-7"}],
                    "pi_sessions": [
                        {
                            "id": "session_internal_1",
                            "external_id": "source-current",
                            "machine_id": "work-mac",
                            "workspace_id": "w1",
                            "pane_id": "p1",
                            "native_session_id": CURRENT_SESSION_ID,
                        }
                    ],
                    "stages": [],
                },
                {
                    "id": "work-control-8",
                    "jira_links": [{"issue_key": "CONTROL-8"}],
                    "pi_sessions": [],
                    "stages": [
                        {
                            "pi_sessions": [
                                {
                                    "id": "session_internal_2",
                                    "external_id": SECOND_SESSION_ID,
                                    "machine_id": "other-machine-alias",
                                    "workspace_id": "different-workspace",
                                    "pane_id": "different-pane",
                                    "native_session_id": "",
                                }
                            ]
                        }
                    ],
                },
            ]
        }


class FakePanesSeen:
    def lifecycle_map(self):
        return {}


class FakeDiscoverySource:
    def __init__(self):
        self.agent_runs = object()
        self.panes_seen = FakePanesSeen()
        self.first_mate_store = FakeFirstMateStore()
        self.active_work = FakeActiveWork()
        self.snapshot = {
            "workspaces": [{"workspace_id": "w1", "label": "Synthetic Project", "cwd": "/synthetic/project"}],
            "tabs": [{"tab_id": "t1", "workspace_id": "w1", "label": "Implementation"}],
            "panes": [
                {
                    "pane_id": "p1",
                    "terminal_id": "term-new",
                    "workspace_id": "w1",
                    "tab_id": "t1",
                    "label": "Backend worker",
                    "agent_status": "working",
                    "last_activity_at": "2026-09-16T12:00:00Z",
                    "pi_semantic": {"connected": True, "session_id": CURRENT_SESSION_ID},
                },
                {
                    "pane_id": "p2",
                    "terminal_id": "term-2",
                    "workspace_id": "w1",
                    "tab_id": "t1",
                    "label": "Boundary check",
                    "agent_status": "idle",
                    "last_activity_at": "2026-09-16T11:00:00Z",
                    "pi_semantic": {"connected": True, "session_id": SECOND_SESSION_ID},
                },
            ],
        }

    def snapshot_response(self):
        return {
            "ok": True,
            "snapshot": self.snapshot,
            "generatedAt": "2026-09-16T12:00:01Z",
        }

    def refresh_snapshot(self, force=False):
        return self.snapshot

    def pi_snapshot_response(self, pane_id):
        text = "Implement CONTROL-7 safely" if pane_id == "p1" else "Unrelated CONTROL-70 only"
        return {"ok": True, "snapshot": {"entries": [{"message": {"role": "user", "content": text}}]}}


class ControlDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.source = FakeDiscoverySource()
        self.discovery = DiscoveryService(self.source, "srv_11111111-1111-4111-8111-111111111111")
        self.hud_patch = patch(
            "herdr_harness.hud_chats.catalog",
            return_value={
                "ok": True,
                "chats": [
                    {
                        "id": "agr_000000000001",
                        "title": "Saved design chat",
                        "updatedAt": "2026-09-15T09:00:00Z",
                        "status": "completed",
                        "sessionId": "saved-session",
                    }
                ],
                "nextOffset": None,
            },
        )
        self.hud_catalog = self.hud_patch.start()
        self.addCleanup(self.hud_patch.stop)

    def test_discovery_projects_lifecycle_without_changing_raw_snapshot_response(self):
        raw = {
            "workspaces": [{"workspace_id": "w1", "label": "Synthetic Project"}],
            "tabs": [{"tab_id": "t1", "workspace_id": "w1", "label": "Implementation"}],
            "panes": [
                {
                    "pane_id": "p1",
                    "workspace_id": "w1",
                    "tab_id": "t1",
                    "agent_status": "working",
                }
            ],
        }
        service = object.__new__(HerdrService)
        service._lock = threading.RLock()
        service._cached_snapshot = lambda: (raw, "2026-09-16T11:59:00Z")
        service.pi_semantic = type(
            "Semantic", (), {"enrich_snapshot": staticmethod(copy.deepcopy)}
        )()
        service.panes_seen = type(
            "Seen",
            (),
            {
                "lifecycle_map": staticmethod(
                    lambda: {
                        "p1": {
                            "firstSeenAt": "2026-09-16T10:00:00Z",
                            "lastActivityAt": "2026-09-16T11:58:00Z",
                            "workingSince": "2026-09-16T11:30:00Z",
                        }
                    }
                )
            },
        )()
        service._pane_lifecycle = type(
            "Lifecycle", (), {"enrich": staticmethod(lambda pane: None)}
        )()
        service.session_labels = type(
            "Labels", (), {"label_for": staticmethod(lambda pane_id: {})}
        )()
        service.agent_activity = type(
            "Activity", (), {"session_activity": staticmethod(lambda pane_id, status: None)}
        )()
        service._agent_runs = object()
        service._first_mate_store = FakeFirstMateStore()
        service.active_work = FakeActiveWork()

        response = service.snapshot_response()
        self.assertEqual(response["generatedAt"], "2026-09-16T11:59:00Z")
        self.assertEqual(response["snapshot"], raw)

        discovery = DiscoveryService(service, self.discovery.server_id)
        result = discovery.search(
            kind="all", query="", ticket="", sort="updated", limit=100, offset=0
        )
        pane = next(item for item in result["results"] if item["kind"] == "pane")
        self.assertEqual(pane["updatedAt"], "2026-09-16T11:58:00Z")
        self.assertEqual(service.snapshot_response()["snapshot"], raw)

    def test_searches_live_pi_saved_hud_and_first_mate_with_explicit_archive_gap(self):
        result = self.discovery.search(
            kind="all", query="", ticket="CONTROL-7", sort="relevance", limit=100, offset=0
        )
        identities = {(item["kind"], item["id"]) for item in result["results"]}
        self.assertIn(("pane", "p1"), identities)
        self.assertIn(("first-mate", "fmf_1"), identities)
        self.assertNotIn(("pane", "p2"), identities)
        self.assertTrue(result["coverage"]["currentPiText"]["searched"])
        self.assertTrue(result["coverage"]["linkedTickets"]["searched"])
        self.assertEqual(result["generatedAt"], "2026-09-16T12:00:01Z")
        pane = next(item for item in result["results"] if item["id"] == "p1")
        self.assertEqual(pane["target"]["sessionId"], CURRENT_SESSION_ID)
        self.assertEqual(pane["updatedAt"], "2026-09-16T12:00:00Z")
        self.assertFalse(result["coverage"]["historicalPiArchives"]["searched"])
        self.assertIn("not indexed", result["coverage"]["historicalPiArchives"]["reason"])

        saved = self.discovery.search(
            kind="chats", query="Saved design", ticket="", sort="updated", limit=10, offset=0
        )
        self.assertEqual(saved["results"][0]["kind"], "hud-chat")
        self.assertEqual(saved["results"][0]["target"]["hudChatId"], "agr_000000000001")

    def test_unknown_snapshot_timestamp_is_not_reported_as_fresh(self):
        self.source.snapshot_response = lambda: {
            "ok": True,
            "snapshot": self.source.snapshot,
            "generatedAt": "not-a-timestamp",
        }

        result = self.discovery.search(
            kind="all", query="", ticket="", sort="updated", limit=100, offset=0
        )

        self.assertEqual(result["generatedAt"], "")
        self.assertEqual(result["coverage"]["liveTopology"]["freshness"], "unknown")
        self.assertNotIn("generatedAt", result["coverage"]["liveTopology"])

    def test_ticket_matching_uses_exact_boundaries_and_stored_links(self):
        result = self.discovery.search(
            kind="chats", query="", ticket="CONTROL-7", sort="updated", limit=100, offset=0
        )
        self.assertNotIn("p2", [item["id"] for item in result["results"]])
        linked = next(item for item in result["results"] if item["id"] == "p1")
        self.assertIn("linkedTicket", {item["field"] for item in linked["matchEvidence"]})

    def test_hud_catalog_is_query_aware_and_exact_inspect_is_not_catalog_bounded(self):
        old_chat = {
            "id": "agr_000000000099",
            "title": "Old saved chat",
            "updatedAt": "2025-01-01T00:00:00Z",
            "status": "completed",
            "sessionId": "saved-old-session",
        }

        def catalog_for_query(
            _manager, query, _offset, *, ticket="", include_match_evidence=False
        ):
            chat = dict(old_chat)
            if include_match_evidence:
                chat["matchEvidence"] = [
                    {
                        "field": "prompt",
                        "excerpt": "An actual older turn references CONTROL-OLD safely",
                    }
                ]
            return {
                "ok": True,
                "chats": [chat] if ticket == "CONTROL-OLD" else [],
                "nextOffset": None,
            }

        self.hud_catalog.side_effect = catalog_for_query

        def old_history(_manager, _identifier, offset):
            turn = {
                "id": old_chat["id"],
                "label": "Old saved chat",
                "sessionId": "saved-old-session",
                "status": "completed",
                "finishedAt": "2025-01-01T00:00:00Z",
                "prompt": "No ticket in the first history page",
            }
            if offset == 50:
                turn = {**turn, "id": "agr_000000000100", "prompt": "CONTROL-OLD"}
            return {
                "ok": True,
                "rootRunId": old_chat["id"],
                "turns": [turn],
                "nextOffset": 50 if offset == 0 else None,
            }

        with patch("herdr_harness.hud_chats.history", side_effect=old_history):
            result = self.discovery.search(
                kind="chats", query="", ticket="CONTROL-OLD", sort="updated", limit=10, offset=0
            )
            self.assertEqual([item["id"] for item in result["results"]], [old_chat["id"]])
            inspected = self.discovery.inspect({"kind": "hud-chat", "hudChatId": old_chat["id"]})
            self.assertEqual(inspected["target"]["sessionId"], "saved-old-session")
        self.hud_catalog.assert_any_call(
            self.source.agent_runs,
            "",
            0,
            ticket="CONTROL-OLD",
            include_match_evidence=True,
        )

    def test_hud_discovery_does_not_echo_ticket_filter_as_searchable_evidence(self):
        self.hud_catalog.return_value = {
            "ok": True,
            "chats": [
                {
                    "id": "agr_000000000070",
                    "title": "Boundary-only saved chat",
                    "updatedAt": "2026-01-01T00:00:00Z",
                    "status": "completed",
                    "matchEvidence": [
                        {"field": "prompt", "excerpt": "Investigate CONTROL-70 only"}
                    ],
                }
            ],
            "nextOffset": None,
        }
        with patch(
            "herdr_harness.hud_chats.history",
            return_value={
                "ok": True,
                "rootRunId": "agr_000000000070",
                "turns": [{"prompt": "Investigate CONTROL-70 only"}],
                "nextOffset": None,
            },
        ):
            result = self.discovery.search(
                kind="chats", query="", ticket="CONTROL-7", sort="updated", limit=100, offset=0
            )
        self.assertNotIn("agr_000000000070", [item["id"] for item in result["results"]])

    def test_ticket_links_use_conversation_identity_not_recycled_or_cross_machine_panes(self):
        self.source.active_work = type(
            "Associations",
            (),
            {
                "board_projection": staticmethod(
                    lambda: {
                        "items": [
                            {
                                "id": "work-stale",
                                "jira_links": [{"issue_key": "CONTROL-STALE"}],
                                "pi_sessions": [
                                    {
                                        "id": "session_internal_stale",
                                        "external_id": "source-stale",
                                        "machine_id": "work-mac",
                                        "workspace_id": "w1",
                                        "pane_id": "p1",
                                        "native_session_id": OLD_SESSION_ID,
                                    }
                                ],
                                "stages": [],
                            },
                            {
                                "id": "work-cross-machine",
                                "jira_links": [{"issue_key": "CONTROL-CROSS"}],
                                "pi_sessions": [
                                    {
                                        "id": "session_internal_cross",
                                        "external_id": "legacy:w1:p1",
                                        "machine_id": "other-machine",
                                        "workspace_id": "w1",
                                        "pane_id": "p1",
                                        "native_session_id": "",
                                    }
                                ],
                                "stages": [],
                            },
                            {
                                "id": "work-guid",
                                "jira_links": [{"issue_key": "CONTROL-GUID"}],
                                "pi_sessions": [
                                    {
                                        "id": "session_internal_guid",
                                        "external_id": "source-current",
                                        "machine_id": "renamed-machine-alias",
                                        "workspace_id": "old-workspace",
                                        "pane_id": "old-pane",
                                        "native_session_id": CURRENT_SESSION_ID,
                                    }
                                ],
                                "stages": [],
                            },
                        ]
                    }
                )
            },
        )()

        stale = self.discovery.search(
            kind="chats", query="", ticket="CONTROL-STALE", sort="updated", limit=100, offset=0
        )
        cross_machine = self.discovery.search(
            kind="chats", query="", ticket="CONTROL-CROSS", sort="updated", limit=100, offset=0
        )
        exact_guid = self.discovery.search(
            kind="chats", query="", ticket="CONTROL-GUID", sort="updated", limit=100, offset=0
        )

        self.assertNotIn("p1", [item["id"] for item in stale["results"]])
        self.assertNotIn("p1", [item["id"] for item in cross_machine["results"]])
        self.assertEqual([item["id"] for item in exact_guid["results"]], ["p1"])
        self.assertTrue(cross_machine["coverage"]["linkedTickets"]["truncated"])
        self.assertEqual(
            cross_machine["coverage"]["linkedTickets"]["unverifiableLegacyAssociations"], 1
        )

    def test_valid_native_uuid_in_external_id_links_globally(self):
        result = self.discovery.search(
            kind="chats", query="", ticket="CONTROL-8", sort="updated", limit=100, offset=0
        )
        self.assertEqual([item["id"] for item in result["results"]], ["p2"])
        self.assertEqual(
            {item["field"] for item in result["results"][0]["matchEvidence"]},
            {"linkedTicket"},
        )

    def test_inspect_returns_exact_result_and_rejects_reused_pane_identity(self):
        target = {
            "kind": "pane",
            "serverId": self.discovery.server_id,
            "workspaceId": "w1",
            "tabId": "t1",
            "paneId": "p1",
            "terminalId": "term-new",
            "sessionId": CURRENT_SESSION_ID,
        }
        result = self.discovery.inspect(target)
        self.assertEqual(result["target"], target)
        stale = {**target, "terminalId": "term-old"}
        with self.assertRaises(ControlError) as raised:
            self.discovery.inspect(stale)
        self.assertEqual(raised.exception.code, "stale_target")
        feature = self.discovery.inspect({"kind": "first-mate", "featureId": "fmf_1"})
        self.assertEqual(feature["target"]["featureId"], "fmf_1")
        with self.assertRaises(ControlError):
            self.discovery.inspect({"kind": "unknown", "paneId": "p1"})


class HudCatalogTests(unittest.TestCase):
    def test_exact_ticket_filter_searches_all_turns_and_returns_real_evidence(self):
        manager = type("Manager", (), {"_lock": threading.RLock()})()
        members = [
            {
                "id": f"agr_{index:012x}",
                "hudSequence": index,
                "createdAt": f"2026-01-01T00:{index:02d}:00Z",
                "finishedAt": f"2026-01-01T00:{index:02d}:30Z",
                "status": "completed",
                "label": "Saved thread",
                "prompt": "Investigate CONTROL-70",
                "response": "No exact target yet",
                "sessionId": "saved-session",
            }
            for index in range(50)
        ]
        with patch("herdr_harness.hud_chats.all_threads", return_value={members[0]["id"]: members}):
            boundary = hud_chats.catalog(manager, ticket="CONTROL-7")
        self.assertEqual(boundary["chats"], [])

        members.append(
            {
                **members[-1],
                "id": "agr_000000000050",
                "hudSequence": 50,
                "createdAt": "2026-01-01T01:00:00Z",
                "finishedAt": "2026-01-01T01:00:30Z",
                "prompt": "The genuine old turn references CONTROL-7",
                "response": "Preserve the genuine phrase match",
            }
        )
        with patch("herdr_harness.hud_chats.all_threads", return_value={members[0]["id"]: members}):
            matched = hud_chats.catalog(
                manager,
                "genuine phrase",
                ticket="CONTROL-7",
                include_match_evidence=True,
            )
        self.assertEqual([chat["id"] for chat in matched["chats"]], [members[0]["id"]])
        excerpts = " ".join(
            evidence["excerpt"] for evidence in matched["chats"][0]["matchEvidence"]
        )
        self.assertIn("CONTROL-7", excerpts)
        self.assertIn("genuine phrase", excerpts)
        self.assertNotEqual(excerpts, "CONTROL-7 genuine phrase")
