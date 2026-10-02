import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Agent Roles renders", .serialized)
@MainActor
struct AgentRolesRenderTests {
    private static let settingsSize = CGSize(width: 685, height: 632)

    @Test("Role profile renders in the existing Settings column")
    func profile() async throws {
        let store = await makeStore()
        let result = try await HerdrRenderHarness.render("agent-roles-profile.png", size: Self.settingsSize) {
            AgentRolesView(store: store)
        }
        result.expectSubstantial()
    }

    @Test("Strict selection renders tiles and unavailable local skills at narrow width")
    func skillTiles() async throws {
        let store = await makeStore()
        store.configureSelection()
        store.draft?.skillIds = ["skill_alpha", "skill_missing"]
        let result = try await HerdrRenderHarness.render("agent-roles-skills.png", size: Self.settingsSize) {
            AgentRolesView(store: store, initialTab: .skills)
        }
        result.expectSubstantial()
    }

    @Test("Wide layout preserves the alphabetical tile grid and role rail")
    func wideSkills() async throws {
        let store = await makeStore()
        store.selectRole("worker")
        let result = try await HerdrRenderHarness.render("agent-roles-skills-wide.png", size: CGSize(width: 1120, height: 820)) {
            AgentRolesView(store: store, initialTab: .skills)
        }
        result.expectSubstantial()
    }

    @Test("Inherited roles explain automatic discovery before selecting skills")
    func inheritedSkills() async throws {
        let store = await makeStore()
        let result = try await HerdrRenderHarness.render("agent-roles-inherited.png", size: Self.settingsSize) {
            AgentRolesView(store: store, initialTab: .skills)
        }
        result.expectSubstantial()
    }

    @Test("Recovery remains visibly locked")
    func recovery() async throws {
        let store = await makeStore()
        store.selectRole("recovery_advisor")
        let result = try await HerdrRenderHarness.render("agent-roles-recovery.png", size: Self.settingsSize) {
            AgentRolesView(store: store)
        }
        result.expectSubstantial()
    }

    @Test("Offline and update-needed states render clear actions")
    func connectionStates() async throws {
        let client = AgentRoleTestClient()
        let store = await makeStore(client: client)
        await client.fail(with: .server(status: 404, message: "Not found"))
        await store.load()
        let old = try await HerdrRenderHarness.render("agent-roles-needs-update.png", size: Self.settingsSize) {
            AgentRolesView(store: store)
        }
        old.expectSubstantial()
        await client.fail(with: .server(status: 503, message: "The sample server is offline."))
        await store.load()
        let offline = try await HerdrRenderHarness.render("agent-roles-offline.png", size: Self.settingsSize) {
            AgentRolesView(store: store)
        }
        offline.expectSubstantial()
    }

    @Test("Source folders render with editable configuration and access status")
    func sources() async throws {
        let catalog = AgentRoleTestCatalog()
        catalog.issues = [.init(kind: .linkedFolderAccess, sourceName: "Personal",
            path: "/example/linked-skills", skillNames: ["Atlas", "Compass"])]
        let result = try await HerdrRenderHarness.render("agent-roles-sources.png", size: CGSize(width: 600, height: 580)) {
            AgentRoleSourcesSheet(catalog: catalog)
        }
        result.expectSubstantial()
    }

    @Test("PR review agents stay collapsed while editing First Mate roles")
    func reviewSectionCollapsed() async throws {
        let store = await makeStore(client: AgentRoleTestClient(overview: AgentRoleTestFixtures.reviewOverview()))
        let result = try await HerdrRenderHarness.render("agent-roles-review-collapsed.png", size: Self.settingsSize) {
            AgentRolesView(store: store)
        }
        result.expectSubstantial()
    }

    @Test("The Comprehensive profile shows the blank prompt fallback and safe avatar choices")
    func reviewProfile() async throws {
        let store = await makeStore(client: AgentRoleTestClient(overview: AgentRoleTestFixtures.reviewOverview()))
        store.selectRole("pr-review-comprehensive")
        let result = try await HerdrRenderHarness.render("agent-roles-review-profile.png", size: Self.settingsSize) {
            ZStack {
                HerdrDuskBackdrop()
                AgentRolesView(store: store)
            }
            .environment(\.herdrGlassActive, true)
            .environment(\.herdrHazeActive, true)
        }
        result.expectSubstantial()
    }

    @Test("Review profiles remain usable at large type with glass disabled")
    func reviewProfileLarge() async throws {
        let store = await makeStore(client: AgentRoleTestClient(overview: AgentRoleTestFixtures.reviewOverview()))
        store.selectRole("sample-review-agent")
        let result = try await HerdrRenderHarness.render("agent-roles-review-profile-large.png", size: CGSize(width: 820, height: 780)) {
            AgentRolesView(store: store)
                .environment(\.herdrFontScale, .xxxLarge)
                .environment(\.herdrGlassActive, false)
                .environment(\.herdrHazeActive, false)
        }
        result.expectSubstantial()
    }

    @Test("PR review agents reuse the local skill catalog and package selection")
    func reviewSkills() async throws {
        let store = await makeStore(client: AgentRoleTestClient(overview: AgentRoleTestFixtures.reviewOverview()))
        store.selectRole("sample-review-agent")
        let result = try await HerdrRenderHarness.render("agent-roles-review-skills.png", size: Self.settingsSize) {
            AgentRolesView(store: store, initialTab: .skills)
        }
        result.expectSubstantial()
    }

    private func makeStore(client: AgentRoleTestClient = AgentRoleTestClient()) async -> AgentRolesStore {
        let store = AgentRolesStore(machines: AgentRoleTestFixtures.machines,
            clients: ["desktop": client], catalog: AgentRoleTestCatalog())
        await store.load()
        return store
    }
}
