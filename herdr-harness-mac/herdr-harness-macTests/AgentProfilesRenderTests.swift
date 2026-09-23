import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Agent Profiles renders", .serialized)
@MainActor
struct AgentProfilesRenderTests {
    private static let settingsSize = CGSize(width: 685, height: 632)

    @Test("A machine's own profile renders in the Settings column")
    func rendersOwnedProfile() async throws {
        let store = await Self.demoStore(selecting: "demo1")
        let result = try await HerdrRenderHarness.render("agent-profiles-owned.png", size: Self.settingsSize) {
            AgentProfilesView(store: store)
        }
        result.expectSubstantial()
    }

    @Test("A shared profile renders with its owner and a pending suggestion")
    func rendersSharedProfile() async throws {
        let store = await Self.demoStore(selecting: "demo2")
        #expect(store.editingProfileIsShared)
        #expect(store.suggestions.count == 1)
        let result = try await HerdrRenderHarness.render("agent-profiles-shared.png", size: Self.settingsSize) {
            AgentProfilesView(store: store)
        }
        result.expectSubstantial()
    }

    @Test("Unsaved User edits render with a save state")
    func rendersUnsavedUserEdits() async throws {
        let store = await Self.demoStore(selecting: "demo1")
        store.userDraft += "\n- Loves a good checklist."
        let result = try await HerdrRenderHarness.render("agent-profiles-unsaved.png", size: Self.settingsSize) {
            AgentProfilesView(store: store, document: .user)
        }
        result.expectSubstantial()
    }

    @Test("A machine without a profile renders its empty state")
    func rendersNoProfile() async throws {
        let world = AgentProfilesDemoWorld()
        _ = try await world.mutate(
            serverID: AgentProfileFixtures.sharedServerID,
            mutation: .assign(expectedRevision: 1, ownerMachineId: nil, profileId: nil, soul: "", user: "", requestId: UUID())
        )
        let store = await Self.demoStore(selecting: "demo2", world: world)
        #expect(store.editingReference == nil)
        let result = try await HerdrRenderHarness.render("agent-profiles-none.png", size: Self.settingsSize) {
            AgentProfilesView(store: store)
        }
        result.expectSubstantial()
    }

    @Test("The wide Fleet layout renders")
    func rendersWideLayout() async throws {
        let store = await Self.demoStore(selecting: "demo2")
        let result = try await HerdrRenderHarness.render(
            "agent-profiles-wide.png",
            size: CGSize(width: 1180, height: 760)
        ) {
            AgentProfilesView(store: store)
        }
        result.expectSubstantial()
    }

    @Test("Suggested edits render as a readable diff")
    func rendersSuggestions() async throws {
        let store = await Self.demoStore(selecting: "demo2")
        let result = try await HerdrRenderHarness.render(
            "agent-profiles-suggestions.png",
            size: CGSize(width: 700, height: 620)
        ) {
            AgentProfileSuggestionsSheet(store: store)
        }
        result.expectSubstantial()
    }

    @Test("History renders revisions beside a preview")
    func rendersHistory() async throws {
        let store = await Self.demoStore(selecting: "demo1")
        await store.loadHistory()
        #expect(store.history.count == 2)
        let result = try await HerdrRenderHarness.render(
            "agent-profiles-history.png",
            size: CGSize(width: 760, height: 560)
        ) {
            AgentProfileHistorySheet(store: store)
        }
        result.expectSubstantial()
    }

    @Test("Machine-only notes and the prompt preview render")
    func rendersAdditionsAndPrompt() async throws {
        let store = await Self.demoStore(selecting: "demo2")
        store.overrideUser = "- Repositories on this machine live in ~/work."
        let additions = try await HerdrRenderHarness.render(
            "agent-profiles-additions.png",
            size: CGSize(width: 620, height: 500)
        ) {
            AgentProfileAdditionsSheet(store: store)
        }
        additions.expectSubstantial()
        let prompt = try await HerdrRenderHarness.render(
            "agent-profiles-prompt.png",
            size: CGSize(width: 700, height: 560)
        ) {
            AgentProfilePromptSheet(store: store)
        }
        prompt.expectSubstantial()
    }

    private static func demoStore(
        selecting machineID: String,
        world: AgentProfilesDemoWorld = AgentProfilesDemoWorld()
    ) async -> AgentProfilesStore {
        let store = AgentProfilesStore(
            machines: [
                HerdrMachine(id: "demo1", name: "desktop", urlString: ""),
                HerdrMachine(id: "demo2", name: "laptop", urlString: "", role: "development"),
            ],
            clients: [
                "demo1": AgentProfilesDemoClient(serverID: AgentProfileFixtures.ownerServerID, world: world),
                "demo2": AgentProfilesDemoClient(serverID: AgentProfileFixtures.sharedServerID, world: world),
            ],
            initiallySelectedMachineID: machineID
        )
        await store.load()
        return store
    }
}
