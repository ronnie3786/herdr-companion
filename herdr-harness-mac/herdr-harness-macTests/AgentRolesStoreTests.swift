import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Agent Roles state")
@MainActor
struct AgentRolesStoreTests {
    @Test("Opting in preserves the distinction between inherited and empty skills")
    func inheritedAndEmpty() async throws {
        let client = AgentRoleTestClient()
        let catalog = AgentRoleTestCatalog()
        let store = makeStore(client, catalog: catalog)
        await store.load()
        #expect(store.draft?.skillIds == nil)
        #expect(!store.canChangeSkills)
        store.toggleSkill("skill_alpha")
        #expect(!store.hasUnsavedChanges)
        store.configureSelection()
        #expect(store.draft?.skillIds == [])
        #expect(store.canSave)
        await store.save()
        let mutation = try #require(await client.recordedMutations().last)
        #expect(mutation.expectedRevision == 0)
        #expect(mutation.role?.skillIds == [])
        #expect(mutation.skillBundles.isEmpty)
        #expect(!store.hasUnsavedChanges)
        #expect(store.overview?.revision == 1)
        #expect(store.savedMessage != nil)
    }

    @Test("Search and source filters limit select shown; missing selections stay removable")
    func filteredSelection() async {
        let store = makeStore(AgentRoleTestClient())
        await store.load()
        store.configureSelection()
        store.sourceFilter = "personal"
        store.search = "notes"
        store.selectShown()
        #expect(store.selectedIDs == ["skill_alpha"])
        #expect(store.selectedTokens == 90)
        store.draft?.skillIds?.append("skill_missing")
        #expect(store.missingIDs == ["skill_missing"])
        store.toggleSkill("skill_missing")
        #expect(store.missingIDs.isEmpty)
        store.copySkills(from: AgentRoleTestFixtures.roles[2])
        #expect(store.selectedIDs == ["skill_bravo"])
        store.clearSkills()
        #expect(store.draft?.skillIds == [])
    }

    @Test("Saving copies local packages and retains unavailable selected IDs")
    func localPackagesOnly() async throws {
        let client = AgentRoleTestClient()
        let catalog = AgentRoleTestCatalog()
        let store = makeStore(client, catalog: catalog)
        await store.load()
        store.configureSelection()
        store.draft?.skillIds = ["skill_alpha", "skill_missing"]
        await store.save()
        #expect(catalog.bundledIDs == ["skill_alpha"])
        let mutation = try #require(await client.recordedMutations().last)
        #expect(mutation.role?.skillIds == ["skill_alpha", "skill_missing"])
        #expect(mutation.skillBundles.map(\.id) == ["skill_alpha"])
    }

    @Test("Update Copies refreshes a saved role without requiring a profile edit")
    func refreshCopies() async throws {
        let client = AgentRoleTestClient()
        let store = makeStore(client)
        await store.load()
        store.selectRole("worker")
        #expect(!store.canSave)
        #expect(store.canUpdateCopies)
        await store.updateCopies()
        let mutation = try #require(await client.recordedMutations().last)
        #expect(mutation.role == AgentRoleTestFixtures.roles[2])
        #expect(mutation.skillBundles.map(\.id) == ["skill_bravo"])
        #expect(store.overview?.revision == 1)
        #expect(!store.hasUnsavedChanges)
    }

    @Test("Navigation never silently discards edits and discard resets new custom roles")
    func protectDrafts() async {
        let store = makeStore(AgentRoleTestClient())
        await store.load()
        store.draft?.systemPrompt = "Synthetic instructions."
        store.selectRole("worker")
        await store.selectMachine("laptop")
        #expect(store.selectedMachineID == "desktop")
        #expect(store.draft?.id == "first_mate")
        #expect(store.hasUnsavedChanges)
        store.discard()
        store.newRole()
        #expect(store.draft?.builtin == false)
        #expect(store.draft?.skillIds == [])
        #expect(store.draft?.systemPrompt == "")
        #expect(store.draft?.whenToUse == "")
        #expect(store.draft?.allowDelegation == false)
        #expect(store.roles.count == 8)
        store.discard()
        #expect(store.roles.count == 7)
        #expect(!store.hasUnsavedChanges)
    }

    @Test("Creating and deleting a custom role uses the current revision")
    func createAndDelete() async throws {
        let client = AgentRoleTestClient()
        let store = makeStore(client)
        await store.load()
        store.newRole()
        store.draft?.name = "  Release notes  "
        store.draft?.modelProfile = "planning"
        let id = try #require(store.draft?.id)
        #expect(UUID(uuidString: id) != nil)
        await store.save()
        #expect(store.draft?.name == "Release notes")
        #expect(store.draft?.modelProfile == "planning")
        await store.deleteRole()
        #expect(!store.roles.contains { $0.id == id })
        let mutations = await client.recordedMutations()
        #expect(mutations.map(\.expectedRevision) == [0, 1])
        #expect(mutations.last?.action == "delete")
        #expect(mutations.last?.roleId == id)
    }

    @Test("Recovery Advisor remains read-only and cannot save, delegate, or select skills")
    func lockedAdvisor() async {
        let client = AgentRoleTestClient()
        let store = makeStore(client)
        await store.load()
        store.selectRole("recovery_advisor")
        store.toggleSkill("skill_alpha")
        store.configureSelection()
        store.draft?.name = "Changed"
        await store.save()
        await store.deleteRole()
        #expect(!store.canEdit)
        #expect(!store.canSave)
        #expect(store.draft?.skillIds == [])
        #expect(await client.recordedMutations().isEmpty)
    }

    @Test("Conflict preserves drafts and disables save until latest roles are reloaded")
    func conflict() async {
        let client = AgentRoleTestClient()
        let store = makeStore(client)
        await store.load()
        store.draft?.systemPrompt = "My unsaved prompt."
        await client.fail(with: .server(status: 409, message: "Changed elsewhere"))
        await store.save()
        #expect(store.hasConflict)
        #expect(store.hasUnsavedChanges)
        #expect(store.draft?.systemPrompt == "My unsaved prompt.")
        #expect(!store.canSave)
        #expect(!store.isSaving)
        #expect(store.savedMessage == nil)
        #expect(store.unsavedEditsText.contains("My unsaved prompt."))
    }

    @Test("Unconfirmed saves preserve dirty state and allow a retry")
    func failedSave() async {
        let client = AgentRoleTestClient()
        let store = makeStore(client)
        await store.load()
        store.draft?.name = "Captain"
        await client.fail(with: .server(status: 503, message: "Unavailable"))
        await store.save()
        #expect(store.canSave)
        #expect(store.hasUnsavedChanges)
        #expect(store.errorMessage != nil)
        #expect(store.savedMessage == nil)
        await client.fail(with: nil)
        await store.save()
        #expect(!store.hasUnsavedChanges)
        #expect(store.draft?.name == "Captain")
    }

    @Test("Older and unreachable companions have distinct retryable states")
    func oldAndOffline() async {
        let client = AgentRoleTestClient()
        let store = makeStore(client)
        await client.fail(with: .server(status: 404, message: "Not found"))
        await store.load()
        #expect(store.status == .needsUpdate)
        await client.fail(with: .server(status: 503, message: "Offline"))
        await store.load()
        if case .unavailable = store.status {} else { Issue.record("Expected unavailable state") }
        await client.fail(with: nil)
        await store.load()
        #expect(store.status == .loaded)
    }

    @Test("Malformed success responses cannot discard or mark unsaved work as saved", arguments: ["missing", "stale", "different"])
    func malformedSuccess(_ scenario: String) async throws {
        let client = AgentRoleTestClient()
        let store = makeStore(client)
        await store.load()
        store.draft?.name = "Captain"
        let submitted = try #require(store.draft)
        let returnedRoles: [AgentRole] = switch scenario {
        case "missing": []
        case "stale": [submitted]
        default: AgentRoleTestFixtures.roles
        }
        await client.respondToMutation(with: AgentRoleTestFixtures.overview(
            revision: scenario == "stale" ? 0 : 1, roles: returnedRoles))
        await store.save()
        #expect(store.draft == submitted)
        #expect(store.hasUnsavedChanges)
        #expect(store.overview?.revision == 0)
        #expect(store.savedMessage == nil)
        #expect(store.errorMessage != nil)
    }

    @Test("Late results from the previous machine never replace the current role")
    func lateResponse() async {
        let slow = DelayedAgentRolesTestClient()
        let fast = AgentRoleTestClient(overview: AgentRoleTestFixtures.overview(machineID: "server-laptop"))
        let store = AgentRolesStore(machines: AgentRoleTestFixtures.machines,
            clients: ["desktop": slow, "laptop": fast], catalog: AgentRoleTestCatalog())
        let initial = Task { await store.load() }
        await slow.waitUntilRequested()
        await store.selectMachine("laptop")
        await slow.finish(AgentRoleTestFixtures.overview())
        await initial.value
        #expect(store.selectedMachineID == "laptop")
        #expect(store.overview?.machineId == "server-laptop")
        #expect(store.status == .loaded)
    }

    @Test("UTF-8 limits prevent rejected saves without truncating text")
    func validation() async {
        let store = makeStore(AgentRoleTestClient())
        await store.load()
        store.draft?.name = String(repeating: "é", count: 61)
        #expect(!store.canSave)
        #expect(store.validationMessage != nil)
        #expect(store.draft?.name.count == 61)
        store.draft?.name = "Planner"
        store.draft?.whenToUse = String(repeating: "a", count: 4097)
        #expect(!store.canSave)
    }

    @Test("A newly added machine becomes available without reopening Settings")
    func addedConnection() async throws {
        let store = AgentRolesStore(machines: [], clients: [:], catalog: AgentRoleTestCatalog())
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "sample"))
        let client = AgentRoleTestClient()
        store.refreshConnections(machines: AgentRoleTestFixtures.machines,
            configurations: ["desktop": configuration], clients: ["desktop": client])
        await store.loadIfNeeded()
        #expect(store.selectedMachineID == "desktop")
        #expect(store.status == .loaded)
        #expect(store.draft?.id == "first_mate")
    }

    @Test("Fixing saved credentials replaces an unavailable connection on reload")
    func fixedConnection() async throws {
        let oldConfiguration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "old-sample"))
        let newConfiguration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "new-sample"))
        let oldClient = AgentRoleTestClient()
        await oldClient.fail(with: .server(status: 401, message: "Invalid sample credential"))
        let store = AgentRolesStore(machines: AgentRoleTestFixtures.machines, clients: ["desktop": oldClient],
            catalog: AgentRoleTestCatalog(), configurations: ["desktop": oldConfiguration])
        await store.load()
        if case .unavailable = store.status {} else { Issue.record("Expected unavailable connection") }
        store.refreshConnections(machines: AgentRoleTestFixtures.machines,
            configurations: ["desktop": newConfiguration], clients: ["desktop": AgentRoleTestClient()])
        await store.loadIfNeeded()
        #expect(store.status == .loaded)
        #expect(!store.requiresConnectionReload)
    }

    @Test("A replaced or removed execution connection preserves drafts and blocks cross-host saves", arguments: [false, true])
    func changedConnectionPreservesDraft(removed: Bool) async throws {
        let oldConfiguration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "sample"))
        let newConfiguration = try #require(ServerConfiguration(urlString: "http://localhost:9093", token: "sample"))
        let oldClient = AgentRoleTestClient()
        let newClient = AgentRoleTestClient(overview: AgentRoleTestFixtures.overview(machineID: "server-replacement"))
        let store = AgentRolesStore(machines: AgentRoleTestFixtures.machines, clients: ["desktop": oldClient],
            catalog: AgentRoleTestCatalog(), configurations: ["desktop": oldConfiguration])
        await store.load()
        store.draft?.systemPrompt = "Keep these private draft instructions."
        let machineID = removed ? "laptop" : "desktop"
        store.refreshConnections(machines: removed ? Array(AgentRoleTestFixtures.machines.suffix(1)) : AgentRoleTestFixtures.machines,
            configurations: [machineID: newConfiguration], clients: [machineID: newClient])
        await store.save()
        await store.load()
        #expect(store.requiresConnectionReload)
        #expect(store.hasUnsavedChanges)
        #expect(!store.canSave)
        #expect(store.draft?.systemPrompt == "Keep these private draft instructions.")
        #expect(store.overview?.machineId == "server-desktop")
        #expect(store.unsavedEditsText.contains("Keep these private draft instructions."))
        #expect(store.errorMessage != nil)
        #expect(await oldClient.recordedMutations().isEmpty)
        #expect(await newClient.recordedMutations().isEmpty)
        store.discard()
        await store.selectMachine(machineID)
        #expect(store.status == .loaded)
        #expect(store.overview?.machineId == "server-replacement")
        #expect(!store.requiresConnectionReload)
        #expect(!store.hasUnsavedChanges)
    }

    private func makeStore(_ client: any AgentRolesClient, catalog: AgentRoleTestCatalog? = nil) -> AgentRolesStore {
        AgentRolesStore(machines: AgentRoleTestFixtures.machines, clients: ["desktop": client], catalog: catalog ?? AgentRoleTestCatalog())
    }
}
