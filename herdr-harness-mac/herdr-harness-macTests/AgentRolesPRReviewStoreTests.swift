import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("PR review role state")
@MainActor
struct AgentRolesPRReviewStoreTests {
    @Test("Review agents are separated from workers and can be created with copied local skills")
    func createReviewAgent() async throws {
        let client = AgentRoleTestClient(overview: AgentRoleTestFixtures.reviewOverview())
        let catalog = AgentRoleTestCatalog()
        let store = makeStore(client, catalog: catalog)
        await store.load()
        #expect(store.workerRoles.count == AgentRoleTestFixtures.roles.count)
        #expect(store.prReviewRoles.count == 2)
        #expect(store.canCreatePRReviewRole)
        store.newPRReviewRole()
        #expect(store.draft?.isPRReview == true)
        #expect(store.hasUnsavedChanges)
        store.draft?.name = "  Beacon  "
        store.draft?.group = "  Sample team  "
        store.draft?.avatar = "security"
        store.toggleSkill("skill_alpha")
        await store.save()
        let mutation = try #require(await client.recordedMutations().last)
        #expect(mutation.role?.name == "Beacon")
        #expect(mutation.role?.group == "Sample team")
        #expect(mutation.role?.reviewPrompt == "")
        #expect(mutation.role?.avatar == "security")
        #expect(mutation.role?.modelProfile == "default")
        #expect(mutation.skillBundles.map(\.id) == ["skill_alpha"])
        #expect(catalog.bundledIDs == ["skill_alpha"])
        #expect(!store.hasUnsavedChanges)
        #expect(store.supportsPRReviewAgents)
        await store.deleteRole()
        #expect(store.prReviewRoles.count == 2)
    }

    @Test("Older companions retain worker edits while rejecting review creation and edits")
    func oldCompanion() async throws {
        let client = AgentRoleTestClient(overview: AgentRoleTestFixtures.overview(
            roles: AgentRoleTestFixtures.roles + AgentRoleTestFixtures.reviewRoles))
        let store = makeStore(client)
        await store.load()
        store.newPRReviewRole()
        #expect(store.draft?.id == "first_mate")
        #expect(!store.canCreatePRReviewRole)
        #expect(store.canEdit)
        store.draft?.name = "Captain"
        await store.save()
        #expect(store.savedMessage != nil)
        store.selectRole("pr-review-comprehensive")
        #expect(!store.canEdit)
        store.draft?.reviewPrompt = "Unsaved instructions"
        await store.save()
        #expect(store.validationMessage?.contains("Update this companion") == true)
        #expect(await client.recordedMutations().count == 1)
    }

    @Test("Review validation rejects unsafe avatar tokens, long prompts, and multiline teams")
    func validation() async {
        let store = makeStore(AgentRoleTestClient(overview: AgentRoleTestFixtures.reviewOverview()))
        await store.load()
        store.newPRReviewRole()
        store.draft?.group = "One\nTwo"
        #expect(!store.canSave)
        store.draft?.group = "One\tTwo"
        #expect(!store.canSave)
        store.draft?.group = String(repeating: "é", count: 61)
        #expect(!store.canSave)
        store.draft?.group = "Sample team"
        store.draft?.reviewPrompt = String(repeating: "a", count: 32769)
        #expect(!store.canSave)
        store.draft?.reviewPrompt = ""
        store.draft?.avatar = "https://example.invalid/avatar.png"
        #expect(!store.canSave)
        store.draft?.avatar = "concurrency"
        #expect(store.canSave)
    }

    @Test("An incomplete returned review profile cannot confirm a save")
    func truncatedResponse() async {
        let client = AgentRoleTestClient(overview: AgentRoleTestFixtures.reviewOverview())
        let store = makeStore(client)
        await store.load()
        store.selectRole("sample-review-agent")
        store.draft?.reviewPrompt = "New sample instructions"
        await client.respondToMutation(with: AgentRoleTestFixtures.overview(revision: 1,
            roles: AgentRoleTestFixtures.roles + AgentRoleTestFixtures.reviewRoles,
            capabilities: ["pr-review-agents-v1"]))
        await store.save()
        #expect(store.hasUnsavedChanges)
        #expect(store.draft?.reviewPrompt == "New sample instructions")
        #expect(store.errorMessage != nil)
        #expect(store.savedMessage == nil)
    }

    @Test("Host switching refreshes review support and never carries a draft across machines")
    func switchHost() async {
        let supported = AgentRoleTestClient(overview: AgentRoleTestFixtures.reviewOverview())
        let legacy = AgentRoleTestClient(overview: AgentRoleTestFixtures.overview(machineID: "server-laptop"))
        let store = AgentRolesStore(machines: AgentRoleTestFixtures.machines,
            clients: ["desktop": supported, "laptop": legacy], catalog: AgentRoleTestCatalog())
        await store.load()
        store.newPRReviewRole()
        store.draft?.reviewPrompt = "Keep this draft on its original machine."
        await store.selectMachine("laptop")
        #expect(store.selectedMachineID == "desktop")
        #expect(store.draft?.reviewPrompt == "Keep this draft on its original machine.")
        store.discard()
        await store.selectMachine("laptop")
        #expect(!store.supportsPRReviewAgents)
        #expect(store.prReviewRoles.isEmpty)
        #expect(store.draft?.purpose == "worker")
        store.newPRReviewRole()
        #expect(!store.hasUnsavedChanges)
        await store.selectMachine("desktop")
        #expect(store.supportsPRReviewAgents)
        #expect(store.prReviewRoles.count == 2)
    }

    private func makeStore(_ client: any AgentRolesClient, catalog: AgentRoleTestCatalog? = nil) -> AgentRolesStore {
        AgentRolesStore(machines: AgentRoleTestFixtures.machines, clients: ["desktop": client],
            catalog: catalog ?? AgentRoleTestCatalog())
    }
}
