import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Pi session families")
@MainActor
struct PiSessionTreeTests {
    @Test("Cross-workspace children stay under their parent exactly once")
    func crossWorkspaceFamily() throws {
        let workspaces = try PiSessionTreeFixtures.workspaces()
        let tree = SidebarTree.build(workspaces: workspaces, query: "", collapsedWorkspaceIDs: [])
        let rows = tree.flatMap { $0.sections.flatMap(\.rows) + $0.looseRows }
        #expect(rows.map(\.id) == ["demo1|garden:p1", "demo1|garden:p2", "demo1|weather:p1", "demo1|weather:p2"])
        #expect(rows.map(\.depth) == [0, 1, 1, 2])
        #expect(rows[2].workspaceLabel == "Weather Samples")
        #expect(rows[3].workspaceLabel == "Weather Samples")
        #expect(tree.map(\.workspace.workspaceID) == ["garden"])
        #expect(Set(rows.map(\.id)).count == 4)
    }

    @Test("Collapsing a parent hides descendants without losing session counts")
    func collapseFamily() throws {
        let workspaces = try PiSessionTreeFixtures.workspaces()
        let tree = SidebarTree.build(
            workspaces: workspaces, query: "", collapsedWorkspaceIDs: [],
            collapsedSessionIDs: ["demo1|plan-session"]
        )
        #expect(tree[0].sections[0].rows.map(\.id) == ["demo1|garden:p1"])
        #expect(tree[0].sections[0].rows[0].childCount == 2)
        #expect(tree[0].sections[0].chats.count == 4)
    }

    @Test("Search finds a child by its own workspace and reveals its ancestry")
    func searchAcrossWorkspaces() throws {
        let workspaces = try PiSessionTreeFixtures.workspaces()
        let tree = SidebarTree.build(
            workspaces: workspaces, query: "Weather Samples", collapsedWorkspaceIDs: ["demo1|garden"],
            collapsedTabIDs: ["demo1|garden:t1"], collapsedSessionIDs: ["demo1|plan-session"]
        )
        let rows = tree.flatMap { $0.sections.flatMap(\.rows) }
        #expect(rows.map(\.id) == ["demo1|garden:p1", "demo1|weather:p1", "demo1|weather:p2"])
        #expect(rows.map(\.depth) == [0, 1, 2])
        #expect(tree[0].isExpanded)
        #expect(tree[0].sections[0].isExpanded)
    }

    @Test("A recent child keeps an older parent as context")
    func recencyRetainsParent() throws {
        var workspaces = try PiSessionTreeFixtures.workspaces()
        workspaces[0].panes = [try PiSessionTreeFixtures.pane("garden:p1", session: "plan-session")]
        let tree = SidebarTree.build(
            workspaces: workspaces, query: "", collapsedWorkspaceIDs: [], recency: .today
        )
        #expect(tree.first?.sections.first?.rows.first?.pane.piSemantic?.sessionID == "plan-session")
        #expect(tree.first?.sections.first?.rows.count == 3)
    }

    @Test("Missing parents and ambiguous duplicate sessions remain visible roots")
    func missingAndDuplicateParents() throws {
        var workspaces = try PiSessionTreeFixtures.workspaces()
        workspaces[0].panes.append(try PiSessionTreeFixtures.pane("garden:p3", session: "plan-session"))
        let duplicateTree = PiSessionTree(workspaces: workspaces)
        #expect(duplicateTree.parentByPaneID["demo1|weather:p1"] == nil)
        workspaces[0].panes = []
        let missingTree = SidebarTree.build(workspaces: workspaces, query: "", collapsedWorkspaceIDs: [])
        let rows = missingTree.flatMap { $0.sections.flatMap(\.rows) }
        #expect(rows.map(\.id) == ["demo1|weather:p1", "demo1|weather:p2"])
        #expect(rows.map(\.depth) == [0, 1])
    }

    @Test("Cycles and self-parenting are detached without losing descendants")
    func malformedLinks() throws {
        var workspaces = try PiSessionTreeFixtures.workspaces()
        workspaces[0].panes = [
            try PiSessionTreeFixtures.pane("garden:p1", session: "a", parent: "b"),
            try PiSessionTreeFixtures.pane("garden:p2", session: "b", parent: "a"),
            try PiSessionTreeFixtures.pane("garden:p3", session: "c", parent: "a"),
            try PiSessionTreeFixtures.pane("garden:p4", session: "self", parent: "self"),
        ]
        let sessions = PiSessionTree(workspaces: workspaces)
        #expect(sessions.parentByPaneID["demo1|garden:p1"] == nil)
        #expect(sessions.parentByPaneID["demo1|garden:p2"] == nil)
        #expect(sessions.parentByPaneID["demo1|garden:p3"] == "demo1|garden:p1")
        #expect(sessions.parentByPaneID["demo1|garden:p4"] == nil)
        let rows = sessions.rows(roots: sessions.roots(in: Set(sessions.panesByID.keys)), includedIDs: Set(sessions.panesByID.keys), collapsedSessionIDs: [])
        #expect(Set(rows.map(\.id)).count == 6)
    }

    @Test("Identical Pi IDs on different machines do not cross-link")
    func machineIsolation() throws {
        let workspaces = try PiSessionTreeFixtures.workspaces()
        let machines = workspaces + workspaces.map { $0.stamped(machineID: "demo2") }
        let tree = PiSessionTree(workspaces: machines)
        #expect(tree.parentByPaneID["demo1|weather:p1"] == "demo1|garden:p1")
        #expect(tree.parentByPaneID["demo2|weather:p1"] == "demo2|garden:p1")
    }

    @Test("Reveal opens the parent workspace and persisted session disclosure")
    func revealAndPersist() throws {
        let suiteName = "PiSessionTreeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        model.workspaces = try PiSessionTreeFixtures.workspaces()
        let parent = try #require(model.pane(id: "demo1|garden:p1"))
        model.toggleSidebarSession(parent)
        #expect(model.collapsedSidebarSessionIDs.contains("demo1|plan-session"))
        let reloaded = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        #expect(reloaded.collapsedSidebarSessionIDs == ["demo1|plan-session"])
        model.collapsedSidebarWorkspaceIDs = ["demo1|garden", "demo1|weather"]
        model.collapsedSidebarTabIDs = ["demo1|garden:t1"]
        #expect(model.revealPaneInSidebar(id: "demo1|weather:p2"))
        #expect(model.collapsedSidebarSessionIDs.isEmpty)
        #expect(model.collapsedSidebarWorkspaceIDs.isEmpty)
        #expect(model.collapsedSidebarTabIDs.isEmpty)
        #expect(defaults.stringArray(forKey: "herdr.sidebar.collapsedSessions") == [])
    }

    @Test("Reparenting refreshes the sidebar even without a fleet revision")
    func reparentingInvalidatesSnapshot() throws {
        var workspaces = try PiSessionTreeFixtures.workspaces()
        let before = HerdrSidebarView.statusDigest(workspaces)
        workspaces[1].panes[0] = try PiSessionTreeFixtures.pane(
            "weather:p1", session: "weather-session", parent: "colors-session",
            title: "Check rainfall for the garden", recent: true
        )
        #expect(HerdrSidebarView.statusDigest(workspaces) != before)
        #expect(PiSessionTree(workspaces: workspaces).parentByPaneID["demo1|weather:p1"] == "demo1|garden:p2")
    }

    @Test("The optional wire field round-trips and older servers remain compatible")
    func decodingCompatibility() throws {
        let capability = try JSONDecoder().decode(PiSemanticCapability.self, from: Data(#"{"session_id":"child","parent_session_id":"parent"}"#.utf8))
        #expect(capability.parentSessionID == "parent")
        let roundTrip = try JSONDecoder().decode(PiSemanticCapability.self, from: JSONEncoder().encode(capability))
        #expect(roundTrip == capability)
        let legacy = try JSONDecoder().decode(PiSemanticCapability.self, from: Data(#"{"session_id":"root"}"#.utf8))
        #expect(legacy.parentSessionID == nil)
    }
}
