import AppKit
import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("PR Review agent selection") @MainActor
struct PRReviewAgentSelectionTests {
    @Test("New reviews default to Comprehensive and saved choices are host scoped")
    func defaultsAndPersistence() {
        let agents = PRReviewAgentDemo.agents
        #expect(PRReviewAgentSelection.initialSelection(agents: agents, saved: nil) == ["pr-review-comprehensive"])
        #expect(PRReviewAgentSelection.initialSelection(agents: agents, saved: []) == [])
        #expect(PRReviewAgentSelection.initialSelection(agents: agents, saved: ["missing", "catalog-data"]) == ["catalog-data"])
        let name = "review-agents-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        PRReviewStartSheet.saveSelection(["catalog-data"], machineID: "desktop", defaults: defaults)
        #expect(PRReviewStartSheet.loadSelection(machineID: "desktop", defaults: defaults) == ["catalog-data"])
        #expect(PRReviewStartSheet.loadSelection(machineID: "laptop", defaults: defaults).isEmpty)
    }

    @Test("Selecting a partially selected team selects all, then clears just the team")
    func teamSelection() {
        let team: Set<String> = ["catalog-data", "catalog-interface"]
        let first = PRReviewAgentSelection.toggling(team, in: ["pr-review-comprehensive", "catalog-data"])
        #expect(first == team.union(["pr-review-comprehensive"]))
        #expect(PRReviewAgentSelection.toggling(team, in: first) == ["pr-review-comprehensive"])
        #expect(PRReviewAgentSelection.groups(PRReviewAgentDemo.agents).map(\.name) == ["", "Catalog team"])
    }

    @Test("Legacy snapshots have no consolidation and new runs preserve profile identity")
    func decoding() throws {
        let legacyJSON = #"{"ok":true,"review":{"id":"prr_legacy","status":"ready"},"runs":[{"id":"prun_legacy","review_id":"prr_legacy","skill_id":"comprehensive-pr-review","skill_title":"Comprehensive review","state":"finished"}]}"#
        let legacy = try JSONDecoder().decode(PRReviewSnapshot.self, from: Data(legacyJSON.utf8))
        #expect(legacy.consolidation == nil)
        #expect(legacy.runs.count == 1)
        #expect(legacy.runs.allSatisfy { $0.agentID == nil })
        let snapshot = PRReviewAgentDemo.snapshot()
        let roundTrip = try JSONDecoder().decode(PRReviewSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(roundTrip == snapshot)
        #expect(roundTrip.runs.first?.agentAvatar == "review")
    }

    @Test("Preparing reviews keep queued membership before commit identities exist")
    func preparingConsolidation() throws {
        let json = #"{"generation":1,"state":"waiting","base_sha":null,"head_sha":null,"input_run_ids":["prun_queued"]}"#
        let value = try JSONDecoder().decode(PRReviewConsolidation.self, from: Data(json.utf8))
        #expect(value.baseSHA.isEmpty && value.headSHA.isEmpty)
        #expect(value.inputRunIDs == ["prun_queued"])
        #expect(value.documentIDs.isEmpty)
    }

    @Test("Report links accept only bounded document identities")
    func documentLinks() {
        #expect(PRReviewHTMLDocument.linkedDocumentID(URL(string: "herdr-pr-review-document:prdoc_synthetic")!) == "prdoc_synthetic")
        for value in ["herdr-pr-review-document://other/prdoc_test", "herdr-pr-review-document:prdoc_../secret", "herdr-pr-review-document:prdoc_a?token=test", "https://example.invalid/prdoc_test"] {
            #expect(PRReviewHTMLDocument.linkedDocumentID(URL(string: value)!) == nil)
        }
    }
}

@Suite("PR Review agent rendering", .serialized) @MainActor
struct PRReviewAgentRenderTests {
    @Test("Start sheet keeps the URL entry and team actions visible", arguments: [false, true])
    func startSheet(large: Bool) async throws {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "synthetic", demo: true)
        store.pendingURL = "https://github.com/example-owner/garden-planner/pull/42"
        let result = try await HerdrRenderHarness.render("pr-review-start-agents-\(large ? "large" : "normal").png", size: CGSize(width: 620, height: 780)) {
            PRReviewStartSheet(store: store, dismiss: {})
                .environment(\.herdrFontScale, large ? .xxxLarge : .medium)
                .environment(\.herdrGlassActive, true)
                .environment(\.herdrHazeActive, true)
        }
        result.expectSubstantial()
    }

    @Test("A partial consolidated report offers visible links and names incomplete coverage")
    func partialReport() async throws {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "synthetic", demo: true)
        var snapshot = PRReviewAgentDemo.snapshot()
        snapshot.runs[1].state = .finished
        snapshot.consolidation?.state = "finished"
        snapshot.consolidation?.incompleteRunIDs = [snapshot.runs[2].id]
        snapshot.consolidation?.documentIDs = [snapshot.documents[1].id]
        snapshot.documents[1].title = "Consolidated review"
        store.snapshot = snapshot
        let result = try await HerdrRenderHarness.render("pr-review-agents-report.png", size: CGSize(width: 1020, height: 780)) {
            PRReviewAgentsView(store: store, canControl: true)
                .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
                .environment(\.herdrGlassActive, true)
                .environment(\.herdrHazeActive, true)
        }
        result.expectSubstantial()
    }

    @Test("Agent picker renders grouped selected profiles")
    func picker() async throws {
        let result = try await HerdrRenderHarness.render("pr-review-agent-picker.png", size: CGSize(width: 620, height: 620)) {
            PRReviewAgentPicker(agents: PRReviewAgentDemo.agents, selection: .constant(["pr-review-comprehensive", "catalog-data"]))
                .padding(24)
                .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
                .environment(\.herdrGlassActive, true)
                .environment(\.herdrHazeActive, true)
        }
        result.expectSubstantial()
    }

    @Test("Agents and waiting consolidator render on glass and opaque backgrounds", arguments: [true, false])
    func agents(glass: Bool) async throws {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "synthetic", demo: true)
        store.snapshot = PRReviewAgentDemo.snapshot()
        let result = try await HerdrRenderHarness.render("pr-review-agents-\(glass ? "glass" : "opaque").png", size: CGSize(width: 1020, height: 780)) {
            PRReviewAgentsView(store: store, canControl: true)
                .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
                .environment(\.herdrGlassActive, glass)
                .environment(\.herdrHazeActive, glass)
        }
        result.expectSubstantial()
        #expect(store.currentAgentRuns.count == 3)
        store.snapshot?.review.headSHA = "new-head"
        #expect(store.currentAgentRuns.isEmpty)
    }
}
