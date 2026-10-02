import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("PR Review agent catalog refresh")
@MainActor
struct PRReviewAgentCatalogRefreshTests {
    @Test("The event refresh exposes saved agent changes without resetting the open review")
    func savedCatalogRefresh() async throws {
        let client = TestPRReviewClient()
        var capabilities = try JSONDecoder().decode(PRReviewCapabilities.self, from: Data("""
            {"ok":true,"capabilities":["pr-review-v1","pr-review-agents-v1"],"available":true,"skills":[]}
            """.utf8))
        capabilities.agents = Array(AgentRoleTestFixtures.reviewRoles.prefix(1))
        client.capabilitiesResult = capabilities
        let store = PRReviewStore()
        store.configure(client: client, machineID: "synthetic-desktop", demo: false)
        store.select(PRReviewDemo.reviewID)
        await store.refresh()
        let selectedPath = try #require(store.snapshot?.files.first?.path)
        store.selectedPath = selectedPath
        store.tab = .agents
        #expect(store.reviewAgents.map(\.id) == ["pr-review-comprehensive"])

        // Agent Roles saves trigger the same full review refresh used by the
        // window's event tick, while ordinary run polling fetches only a snapshot.
        var updatedAgents = AgentRoleTestFixtures.reviewRoles
        updatedAgents[0].name = "Sample comprehensive reviewer"
        capabilities.agents = updatedAgents
        client.capabilitiesResult = capabilities
        await store.refreshSelected()
        #expect(store.reviewAgents.count == 1)
        await store.refresh()

        #expect(store.reviewAgents == updatedAgents)
        #expect(store.currentMachineID == "synthetic-desktop")
        #expect(store.selectedReviewID == PRReviewDemo.reviewID)
        #expect(store.selectedPath == selectedPath)
        #expect(store.tab == .agents)
    }
}
