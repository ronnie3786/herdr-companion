import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("Agent Profiles", .serialized)
@MainActor
struct AgentProfileTests {
    @Test("Overview decodes the complete v1 contract")
    func decodesOverview() throws {
        let overview = try JSONDecoder().decode(
            AgentProfilesOverview.self,
            from: Data(Self.overviewJSON(machineID: "machine-a").utf8)
        )

        #expect(overview.capability == "agent-profiles-v1")
        #expect(overview.machineId == "machine-a")
        #expect(overview.profiles.first?.name == "Personal")
        #expect(overview.binding.ownerMachineId == "machine-a")
        #expect(overview.effective.syncStatus == "current")
        #expect(overview.proposals.first?.baseRevision == 2)
    }

    @Test("Native validation matches server byte limits and requires reasons")
    func validatesServerLimits() {
        #expect(AgentProfileLimits.nameIsValid(String(repeating: "n", count: AgentProfileLimits.maximumNameBytes)))
        #expect(!AgentProfileLimits.nameIsValid(String(repeating: "n", count: AgentProfileLimits.maximumNameBytes + 1)))
        #expect(!AgentProfileLimits.nameIsValid("   "))
        #expect(AgentProfileLimits.reasonIsValid("Required reason"))
        #expect(!AgentProfileLimits.reasonIsValid("   "))
        #expect(!AgentProfileLimits.reasonIsValid(String(repeating: "r", count: AgentProfileLimits.maximumReasonBytes + 1)))
        #expect(AgentProfileLimits.documentIsValid(String(repeating: "d", count: AgentProfileLimits.maximumDocumentBytes)))
        #expect(!AgentProfileLimits.documentIsValid(
            String(repeating: "é", count: AgentProfileLimits.maximumDocumentBytes / 2 + 1)
        ))
    }

    @Test("Assignment mutation encodes explicit nulls when disabling")
    func encodesDisabledAssignment() throws {
        let requestID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000099"))
        let mutation = AgentProfileMutation.assign(
            expectedRevision: 4,
            ownerMachineId: nil,
            profileId: nil,
            soul: "local soul",
            user: "local user",
            requestId: requestID
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation)) as? [String: Any]
        )

        #expect(object["action"] as? String == "assign")
        #expect(object["expectedRevision"] as? Int == 4)
        #expect(object["ownerMachineId"] is NSNull)
        #expect(object["profileId"] is NSNull)
        #expect(object["soul"] as? String == "local soul")
        #expect(object["user"] as? String == "local user")
        #expect(object["request_id"] == nil)
        #expect(object["requestId"] != nil)
    }

    @Test("Client uses authenticated v1 routes and exact mutation body")
    func clientRoutes() async throws {
        AgentProfilesURLProtocol.records.withLock { $0 = [] }
        let client = try makeClient()

        _ = try await client.fetchAgentProfiles()
        _ = try await client.fetchAgentProfile(id: "00000000-0000-4000-8000-000000000001")
        let requestID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000088"))
        _ = try await client.mutateAgentProfiles(
            .sync(expectedRevision: 7, requestId: requestID)
        )

        let records = AgentProfilesURLProtocol.records.withLock { $0 }
        #expect(records.map(\.path) == [
            "/api/v1/agent-profiles",
            "/api/v1/agent-profiles/profiles/00000000-0000-4000-8000-000000000001",
            "/api/v1/agent-profiles",
        ])
        #expect(records.map(\.method) == ["GET", "GET", "POST"])
        #expect(records.allSatisfy { $0.authorization == "Bearer synthetic-token" })
        let body = try #require(records.last?.body)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(object["action"] as? String == "sync")
        #expect(object["expectedRevision"] as? Int == 7)
    }

    @Test("Conflict preserves profile and machine-only drafts for explicit reconciliation")
    func conflictPreservesDraft() async {
        let client = ConflictAgentProfilesClient(overview: Self.overview(machineID: "machine-a"))
        let store = AgentProfilesStore(
            machines: [HerdrMachine(id: "ui-a", name: "Build", urlString: "https://build.example.invalid")],
            clients: ["ui-a": client],
            initiallySelectedMachineID: "ui-a"
        )
        await store.load()
        #expect(store.soulDraft == "base soul")
        store.soulDraft = "unsaved soul"
        store.overrideUser = "unsaved override"

        await store.saveProfile()

        #expect(store.soulDraft == "unsaved soul")
        #expect(store.overrideUser == "unsaved override")
        #expect(store.conflictMessage?.contains("still here") == true)
        #expect(store.hasUnsavedChanges)
    }

    @Test("Dirty profile and machine-only drafts keep their original CAS revisions")
    func preservedDraftsKeepBaseRevisions() async throws {
        let old = Self.overview(machineID: "server-a", profileRevision: 2, bindingRevision: 4)
        let newer = Self.overview(machineID: "server-a", profileRevision: 3, bindingRevision: 5)
        let client = ScriptedAgentProfilesClient(overviews: [old, newer, newer])
        let store = AgentProfilesStore(
            machines: [HerdrMachine(id: "a", name: "Build", urlString: "https://build.example.invalid")],
            clients: ["a": client],
            initiallySelectedMachineID: "a"
        )
        await store.load()
        store.soulDraft = "draft from revision two"
        store.overrideUser = "draft from binding four"

        await store.syncNow()
        #expect(store.profileDraftIsBehindServer)
        await store.saveProfile()
        await store.saveOverrides()

        let mutations = await client.recordedMutations()
        #expect(mutations.count == 3)
        guard mutations.count == 3,
              case let .update(_, expectedProfileRevision, _, _, _, reason, _) = mutations[1],
              case let .assign(expectedBindingRevision, _, _, _, _, _) = mutations[2] else {
            Issue.record("Expected sync, update and assign mutations")
            return
        }
        #expect(expectedProfileRevision == 2)
        #expect(expectedBindingRevision == 4)
        #expect(reason == "Edited Soul")
    }

    @Test("Saving a profile keeps unsaved machine-only notes")
    func profileSavePreservesOverrideDraft() async {
        let overview = Self.overview(machineID: "server-a")
        let savedProfile = AgentProfile(
            id: "00000000-0000-4000-8000-000000000001",
            name: "Personal",
            revision: 3,
            soul: "saved soul",
            user: "base user",
            updatedAt: "2026-09-22T12:10:00Z",
            actor: "operator",
            reason: "Edited Soul"
        )
        let response = AgentProfileMutationResponse(ok: true, profile: savedProfile, binding: nil, effective: nil, proposal: nil)
        let client = ScriptedAgentProfilesClient(overviews: [overview, overview], mutationResponse: response)
        let store = AgentProfilesStore(
            machines: [HerdrMachine(id: "a", name: "Build", urlString: "https://build.example.invalid")],
            clients: ["a": client],
            initiallySelectedMachineID: "a"
        )
        await store.load()
        store.overrideSoul = "keep this override"
        store.soulDraft = "saved soul"

        await store.saveProfile()

        #expect(store.overrideSoul == "keep this override")
        #expect(store.overridesHaveUnsavedChanges)
        #expect(!store.profileHasUnsavedChanges)

        await store.restore(Self.profile(revision: 1))
        #expect(store.overrideSoul == "keep this override")
        let mutations = await client.recordedMutations()
        #expect(mutations.count == 2)
        if mutations.count == 2 {
            guard case let .restore(_, _, sourceRevision, _, _) = mutations[1] else {
                Issue.record("Expected restore mutation")
                return
            }
            #expect(sourceRevision == 1)
        }
    }

    @Test("A lost mutation response retries the exact request on its original machine")
    func lostResponseRetriesExactly() async {
        let oldClient = ScriptedAgentProfilesClient(overviews: [Self.overview(machineID: "server-old")], failFirstMutation: true)
        let newClient = ScriptedAgentProfilesClient(overviews: [Self.overview(machineID: "server-new")])
        let store = AgentProfilesStore(
            machines: [
                HerdrMachine(id: "old", name: "Old", urlString: "https://old.example.invalid"),
                HerdrMachine(id: "new", name: "New", urlString: "https://new.example.invalid"),
            ],
            clients: ["old": oldClient, "new": newClient],
            initiallySelectedMachineID: "old"
        )
        await store.load()
        store.soulDraft = "retry me"
        await store.saveProfile()
        #expect(store.hasPendingMutation)
        #expect(store.isLocked)

        store.selectMachine("new")
        await store.syncNow()
        let newTargetMutations = await newClient.recordedMutations()
        #expect(newTargetMutations.isEmpty)
        await store.retryPendingMutation()

        let attempts = await oldClient.recordedMutations()
        #expect(attempts.count == 2)
        #expect(attempts.first == attempts.last)
        #expect(!store.hasPendingMutation)
    }

    @Test("Server failures and malformed responses retain the original mutation")
    func ambiguousServerFailuresRemainPending() async {
        let errors: [APIError] = [.server(status: 500, message: "Response failed"),
                                  .server(status: 408, message: "Timed out"), .invalidResponse]
        for error in errors {
            let client = ConflictAgentProfilesClient(overview: Self.overview(machineID: "desktop"), mutationError: error)
            let store = AgentProfilesStore(
                machines: [HerdrMachine(id: "desktop", name: "Desktop", urlString: "https://desktop.example.invalid")],
                clients: ["desktop": client]
            )
            await store.load()
            store.soulDraft = "Edited"
            await store.saveProfile()
            #expect(store.hasPendingMutation)
            await store.retryPendingMutation()
            #expect(store.hasPendingMutation)
        }
    }

    @Test("A machine using another machine's profile edits it on the owner")
    func sharedProfileEditsGoToOwner() async throws {
        let shared = Self.profile(id: "00000000-0000-4000-8000-000000000077", name: "Work", revision: 5, soul: "owner soul")
        let owner = Self.overview(machineID: "server-owner", profiles: [shared], boundTo: nil)
        let consumer = Self.overview(machineID: "server-consumer", boundTo: ("server-owner", shared))
        let ownerClient = ScriptedAgentProfilesClient(overviews: [owner])
        let consumerClient = ScriptedAgentProfilesClient(overviews: [consumer])
        let store = AgentProfilesStore(
            machines: [
                HerdrMachine(id: "consumer", name: "Work Mac", urlString: "https://consumer.example.invalid"),
                HerdrMachine(id: "owner", name: "Devbox", urlString: "https://owner.example.invalid"),
            ],
            clients: ["consumer": consumerClient, "owner": ownerClient],
            initiallySelectedMachineID: "consumer"
        )
        await store.load()

        #expect(store.editingOwner?.id == "owner")
        #expect(store.editingProfileIsShared)
        #expect(store.editingProfileIsEditable)
        #expect(store.soulDraft == "owner soul")
        #expect(store.profileName(for: "consumer") == "Work")
        #expect(store.machinesUsing(try #require(store.activeReference)).map(\.id) == ["consumer"])

        store.userDraft = "shared user"
        await store.saveProfile()

        let ownerMutations = await ownerClient.recordedMutations()
        let consumerMutations = await consumerClient.recordedMutations()
        guard case let .update(profileID, expectedRevision, name, _, user, reason, _) = ownerMutations.first else {
            Issue.record("Expected the owner to receive the update")
            return
        }
        #expect(profileID == shared.id)
        #expect(expectedRevision == 5)
        #expect(name == "Work")
        #expect(user == "shared user")
        #expect(reason == "Edited User")
        guard case .sync = consumerMutations.first else {
            Issue.record("Expected the consumer to refresh its copy")
            return
        }
    }

    @Test("An offline owner leaves the last synced copy readable but not editable")
    func offlineOwnerIsReadOnly() async {
        let shared = Self.profile(id: "00000000-0000-4000-8000-000000000077", name: "Work", revision: 5, soul: "cached soul")
        let consumer = Self.overview(machineID: "server-consumer", boundTo: ("server-owner", shared))
        let store = AgentProfilesStore(
            machines: [
                HerdrMachine(id: "consumer", name: "Work Mac", urlString: "https://consumer.example.invalid"),
                HerdrMachine(id: "owner", name: "Devbox", urlString: "https://owner.example.invalid"),
            ],
            clients: [
                "consumer": ScriptedAgentProfilesClient(overviews: [consumer]),
                "owner": ScriptedAgentProfilesClient(overviews: []),
            ],
            initiallySelectedMachineID: "consumer"
        )
        await store.load()

        #expect(store.editingProfile?.soul == "cached soul")
        #expect(!store.editingProfileIsEditable)
        store.soulDraft = "edit"
        #expect(!store.canSaveProfile)
        #expect(store.editingOwnerNote?.contains("isn't reachable") == true)
        if case .unavailable = store.status(for: "owner") {} else {
            Issue.record("Expected the owner to be unavailable")
        }
    }

    @Test("Switching profiles names the owner and keeps saved machine-only notes")
    func switchingProfilesKeepsOverrides() async throws {
        let remoteWork = Self.profile(id: "00000000-0000-4000-8000-000000000077", name: "Work", revision: 2, soul: "work")
        let local = Self.overview(machineID: "server-local", bindingRevision: 6, bindingSoul: "machine note")
        let remote = Self.overview(machineID: "server-remote", profiles: [remoteWork], boundTo: nil)
        let localClient = ScriptedAgentProfilesClient(overviews: [local])
        let store = AgentProfilesStore(
            machines: [
                HerdrMachine(id: "local", name: "Studio", urlString: "https://local.example.invalid"),
                HerdrMachine(id: "remote", name: "Devbox", urlString: "https://remote.example.invalid"),
            ],
            clients: ["local": localClient, "remote": ScriptedAgentProfilesClient(overviews: [remote])],
            initiallySelectedMachineID: "local"
        )
        await store.load()
        let choice = try #require(store.profileChoices.first { $0.profile.id == remoteWork.id })
        #expect(choice.owner.id == "remote")

        await store.use(choice)

        let mutations = await localClient.recordedMutations()
        guard case let .assign(expectedRevision, ownerMachineID, profileID, soul, _, _) = mutations.first else {
            Issue.record("Expected an assignment on the selected machine")
            return
        }
        #expect(expectedRevision == 6)
        #expect(ownerMachineID == "server-remote")
        #expect(profileID == remoteWork.id)
        #expect(soul == "machine note")
    }

    @Test("Creating a profile uses it on the selected machine")
    func creationAssignsReturnedProfile() async {
        let created = Self.profile(id: "00000000-0000-4000-8000-000000000078", name: "Side projects", revision: 1, soul: "")
        let initial = Self.overview(machineID: "server-a")
        let refreshed = Self.overview(machineID: "server-a", profiles: [Self.profile(), created])
        let response = AgentProfileMutationResponse(ok: true, profile: created, binding: nil, effective: nil, proposal: nil)
        let client = ScriptedAgentProfilesClient(overviews: [initial, refreshed], mutationResponse: response)
        let store = AgentProfilesStore(
            machines: [HerdrMachine(id: "a", name: "Build", urlString: "https://build.example.invalid")],
            clients: ["a": client],
            initiallySelectedMachineID: "a"
        )
        await store.load()

        await store.createProfile(named: "  Side projects ")

        let mutations = await client.recordedMutations()
        #expect(mutations.count == 2)
        guard mutations.count == 2,
              case let .create(name, _, _, reason, _) = mutations[0],
              case let .assign(_, ownerMachineID, profileID, _, _, _) = mutations[1] else {
            Issue.record("Expected create then assign")
            return
        }
        #expect(name == "Side projects")
        #expect(AgentProfileLimits.reasonIsValid(reason))
        #expect(ownerMachineID == "server-a")
        #expect(profileID == created.id)
    }

    @Test("A slow machine cannot replace the machine the user switched to")
    func slowMachineDoesNotCrossTargets() async {
        let slowClient = DeferredAgentProfilesClient()
        let fastClient = ConflictAgentProfilesClient(
            overview: Self.overview(machineID: "server-new", profileName: "New target"),
            mutationError: nil
        )
        let store = AgentProfilesStore(
            machines: [
                HerdrMachine(id: "old", name: "Old", urlString: "https://old.example.invalid"),
                HerdrMachine(id: "new", name: "New", urlString: "https://new.example.invalid"),
            ],
            clients: ["old": slowClient, "new": fastClient],
            initiallySelectedMachineID: "old"
        )

        let load = Task { await store.load() }
        await slowClient.waitUntilRequested()
        store.selectMachine("new")
        await slowClient.resolve(Self.overview(machineID: "server-old", profileName: "Stale target"))
        await load.value

        #expect(store.selectedMachineID == "new")
        #expect(store.selectedOverview?.machineId == "server-new")
        #expect(store.editingProfile?.name == "New target")
        #expect(store.soulDraft == "base soul")
        #expect(!store.isLoading)
    }

    @Test("A missing profile history is an operation error, not an upgrade signal")
    func missingHistoryDoesNotHideEditor() async {
        let client = MissingHistoryAgentProfilesClient(overview: Self.overview(machineID: "server-a"))
        let store = AgentProfilesStore(
            machines: [HerdrMachine(id: "a", name: "Build", urlString: "https://build.example.invalid")],
            clients: ["a": client],
            initiallySelectedMachineID: "a"
        )
        await store.load()
        await store.loadHistory()

        #expect(store.selectedOverview != nil)
        #expect(store.historyError == "Revision history was pruned.")

        await store.restore(Self.profile(revision: 1))
        #expect(store.selectedOverview != nil)
        #expect(store.errorMessage == "Revision was pruned.")
    }

    @Test("A companion without Agent Profiles asks for an update")
    func missingRouteNeedsUpdate() async {
        let store = AgentProfilesStore(
            machines: [HerdrMachine(id: "a", name: "Build", urlString: "https://build.example.invalid")],
            clients: ["a": MissingRouteAgentProfilesClient()],
            initiallySelectedMachineID: "a"
        )
        await store.load()
        #expect(store.status(for: "a") == .needsUpdate)
    }

    @Test("Profile choices span machines and tuck away unused empty starters")
    func profileChoicesSpanMachines() async {
        let starter = Self.profile(id: "00000000-0000-4000-8000-000000000079", name: "Work", revision: 1, soul: "", user: "")
        let remoteWork = Self.profile(id: "00000000-0000-4000-8000-000000000077", name: "Work", revision: 2, soul: "work")
        let local = Self.overview(machineID: "server-local", profiles: [Self.profile(), starter])
        let remote = Self.overview(machineID: "server-remote", profiles: [remoteWork], boundTo: ("server-remote", remoteWork))
        let store = AgentProfilesStore(
            machines: [
                HerdrMachine(id: "local", name: "Studio", urlString: "https://local.example.invalid"),
                HerdrMachine(id: "remote", name: "Devbox", urlString: "https://remote.example.invalid"),
            ],
            clients: [
                "local": ScriptedAgentProfilesClient(overviews: [local]),
                "remote": ScriptedAgentProfilesClient(overviews: [remote]),
            ]
        )
        await store.load()

        let choices = store.profileChoices
        #expect(choices.map(\.owner.id) == ["local", "local", "remote"])
        #expect(choices.filter(\.isUnusedStarter).map(\.profile.id) == [starter.id])
        #expect(choices.last?.users.map(\.id) == ["remote"])
    }

    @Test("Suggestions for a shared profile come from and are approved on its owner")
    func sharedSuggestionsUseOwner() async throws {
        let shared = Self.profile(id: "00000000-0000-4000-8000-000000000077", name: "Work", revision: 5, soul: "owner soul")
        let proposal = AgentProfileProposal(
            id: "proposal-7", profileId: shared.id, baseRevision: 5, soul: "owner soul", user: "new user",
            reason: "Learned a preference", actor: "agent proposal", status: "pending",
            createdAt: "2026-09-23T09:00:00Z"
        )
        let owner = Self.overview(machineID: "server-owner", profiles: [shared], boundTo: nil, proposals: [proposal])
        let consumer = Self.overview(machineID: "server-consumer", boundTo: ("server-owner", shared))
        let ownerClient = ScriptedAgentProfilesClient(overviews: [owner])
        let store = AgentProfilesStore(
            machines: [
                HerdrMachine(id: "consumer", name: "Work Mac", urlString: "https://consumer.example.invalid"),
                HerdrMachine(id: "owner", name: "Devbox", urlString: "https://owner.example.invalid"),
            ],
            clients: ["consumer": ScriptedAgentProfilesClient(overviews: [consumer]), "owner": ownerClient],
            initiallySelectedMachineID: "consumer"
        )
        await store.load()

        let suggestion = try #require(store.suggestions.first)
        #expect(store.suggestions.count == 1)
        #expect(suggestion.owner.id == "owner")
        #expect(!suggestion.isOutdated)
        #expect(store.suggestions(for: "owner").count == 1)
        #expect(store.suggestionCountForProfileUsed(on: "consumer") == 1)
        #expect(store.suggestionCountForProfileUsed(on: "owner") == 0)

        await store.approve(suggestion)

        let mutations = await ownerClient.recordedMutations()
        guard case let .approve(proposalID, expectedRevision, reason, _) = mutations.first else {
            Issue.record("Expected approval on the owner")
            return
        }
        #expect(proposalID == "proposal-7")
        #expect(expectedRevision == 5)
        #expect(AgentProfileLimits.reasonIsValid(reason))
    }

    @Test("A failed sync is an error, and an unconfirmed change can be abandoned")
    func failedSyncAndStopRetrying() async {
        let client = ConflictAgentProfilesClient(
            overview: Self.overview(machineID: "server-a"),
            mutationError: .server(status: 503, message: "Remote profile owner is unavailable")
        )
        let store = AgentProfilesStore(
            machines: [HerdrMachine(id: "a", name: "Build", urlString: "https://build.example.invalid")],
            clients: ["a": client]
        )
        await store.load()

        await store.syncNow()
        #expect(!store.hasPendingMutation)
        #expect(store.errorMessage?.hasPrefix("Couldn't sync") == true)

        store.soulDraft = "edit"
        await store.saveProfile()
        #expect(store.hasPendingMutation)
        #expect(store.pendingMutationMessage?.contains("Remote profile owner is unavailable") == true)
        await store.load()
        #expect(store.hasPendingMutation)
        #expect(store.soulDraft == "edit")

        store.stopRetryingPendingMutation()
        #expect(!store.hasPendingMutation)
        #expect(store.canSaveProfile)
    }

    @Test("Copied edits include unsaved machine-only notes")
    func copiedEditsIncludeNotes() async {
        let store = AgentProfilesStore(
            machines: [HerdrMachine(id: "a", name: "Build", urlString: "https://build.example.invalid")],
            clients: ["a": ScriptedAgentProfilesClient(overviews: [Self.overview(machineID: "server-a")])]
        )
        await store.load()
        store.overrideUser = "machine note"
        #expect(store.unsavedEditsText.contains("machine note"))
        #expect(!store.unsavedEditsText.contains("base soul"))
        store.soulDraft = "new soul"
        #expect(store.unsavedEditsText.contains("new soul"))
    }

    @Test("Saving unlocks before slow machines finish reloading, without reverting the save")
    func saveUnlocksBeforeSlowReload() async {
        let saved = Self.profile(revision: 3, soul: "saved soul")
        let owner = ScriptedAgentProfilesClient(
            overviews: [Self.overview(machineID: "server-a")],
            mutationResponse: AgentProfileMutationResponse(ok: true, profile: saved, binding: nil, effective: nil, proposal: nil)
        )
        let slow = GatedAgentProfilesClient(overview: Self.overview(machineID: "server-slow", boundTo: nil))
        let store = AgentProfilesStore(
            machines: [
                HerdrMachine(id: "a", name: "Build", urlString: "https://build.example.invalid"),
                HerdrMachine(id: "slow", name: "Laptop", urlString: "https://slow.example.invalid"),
            ],
            clients: ["a": owner, "slow": slow],
            initiallySelectedMachineID: "a"
        )
        await store.load()
        store.soulDraft = "saved soul"

        let save = Task { await store.saveProfile() }
        await slow.waitUntilBlocked()

        #expect(!store.isSaving)
        #expect(!store.isLocked)
        #expect(store.soulDraft == "saved soul")
        #expect(!store.profileHasUnsavedChanges)

        await slow.release()
        await save.value
        #expect(!store.isLoading)
        #expect(store.soulDraft == "saved soul")
    }

    @Test("A create confirmed on retry is still used on its machine")
    func retriedCreateAssigns() async {
        let created = Self.profile(id: "00000000-0000-4000-8000-000000000078", name: "Side projects", revision: 1, soul: "")
        let refreshed = Self.overview(machineID: "server-a", profiles: [Self.profile(), created])
        let client = ScriptedAgentProfilesClient(
            overviews: [Self.overview(machineID: "server-a"), refreshed],
            mutationResponse: AgentProfileMutationResponse(ok: true, profile: created, binding: nil, effective: nil, proposal: nil),
            failFirstMutation: true
        )
        let store = AgentProfilesStore(
            machines: [HerdrMachine(id: "a", name: "Build", urlString: "https://build.example.invalid")],
            clients: ["a": client]
        )
        await store.load()

        await store.createProfile(named: "Side projects")
        #expect(store.hasPendingMutation)
        await store.retryPendingMutation()

        let mutations = await client.recordedMutations()
        #expect(mutations.count == 3)
        guard mutations.count == 3, case let .assign(_, _, profileID, _, _, _) = mutations[2] else {
            Issue.record("Expected create, retried create, then assign")
            return
        }
        #expect(mutations[0] == mutations[1])
        #expect(profileID == created.id)
    }

    @Test("Line diff marks removed and added lines in order")
    func lineDiff() {
        let lines = AgentProfileLineDiff.lines(from: "a\nb\nc", to: "a\nc\nd")
        #expect(lines.map(\.kind) == [.unchanged, .removed, .unchanged, .added])
        #expect(lines.map(\.text) == ["a", "b", "c", "d"])
        #expect(AgentProfileLineDiff.lines(from: "", to: "x\ny").map(\.kind) == [.added, .added])
    }

    @Test("Server timestamps parse with and without fractional seconds")
    func parsesServerDates() {
        #expect(AgentProfileDates.date(from: "2026-09-23T07:35:53.350Z") != nil)
        #expect(AgentProfileDates.date(from: "2026-09-23T07:35:53Z") != nil)
        #expect(AgentProfileDates.date(from: "not a date") == nil)
    }

    @Test("Demo profiles save on the owner and show on the machine sharing them")
    func demoWorldSharesEdits() async throws {
        let world = AgentProfilesDemoWorld()
        let machines = [
            HerdrMachine(id: "demo1", name: "desktop", urlString: ""),
            HerdrMachine(id: "demo2", name: "laptop", urlString: ""),
        ]
        let store = AgentProfilesStore(
            machines: machines,
            clients: [
                "demo1": AgentProfilesDemoClient(serverID: AgentProfileFixtures.ownerServerID, world: world),
                "demo2": AgentProfilesDemoClient(serverID: AgentProfileFixtures.sharedServerID, world: world),
            ],
            initiallySelectedMachineID: "demo2"
        )
        await store.load()
        #expect(store.editingProfile?.name == "Work")
        #expect(store.editingOwner?.id == "demo1")
        #expect(store.suggestions.count == 1)

        store.soulDraft += "\n- Keep PRs small."
        await store.saveProfile()

        let laptop = try await world.overview(serverID: AgentProfileFixtures.sharedServerID)
        #expect(laptop.effective.profile?.soul.hasSuffix("- Keep PRs small.") == true)
        #expect(!store.profileHasUnsavedChanges)
        #expect(store.suggestions.first?.isOutdated == true)
    }

    private func makeClient() throws -> HerdrAPIClient {
        let configuration = try #require(
            ServerConfiguration(urlString: "http://localhost:9092", token: "synthetic-token")
        )
        let configurationSession = URLSessionConfiguration.ephemeral
        configurationSession.protocolClasses = [AgentProfilesURLProtocol.self]
        return HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: configurationSession)
        )
    }

    fileprivate static func profile(
        id: String = "00000000-0000-4000-8000-000000000001",
        name: String = "Personal",
        revision: Int = 2,
        soul: String = "base soul",
        user: String = "base user"
    ) -> AgentProfile {
        AgentProfile(
            id: id,
            name: name,
            revision: revision,
            soul: soul,
            user: user,
            updatedAt: "2026-09-22T12:00:00Z",
            actor: "operator",
            reason: "Synthetic revision"
        )
    }

    /// A machine that owns its profiles and uses the first one.
    fileprivate static func overview(
        machineID: String,
        profileName: String = "Personal",
        profileRevision: Int = 2,
        bindingRevision: Int = 4,
        profileID: String = "00000000-0000-4000-8000-000000000001",
        profiles: [AgentProfile]? = nil,
        bindingSoul: String = "",
        proposals: [AgentProfileProposal] = []
    ) -> AgentProfilesOverview {
        let owned = profiles ?? [profile(id: profileID, name: profileName, revision: profileRevision)]
        return makeOverview(
            machineID: machineID,
            profiles: owned,
            boundTo: owned.first.map { (machineID, $0) },
            bindingRevision: bindingRevision,
            bindingSoul: bindingSoul,
            proposals: proposals
        )
    }

    /// A machine bound to an explicit profile, possibly owned elsewhere, or to none.
    fileprivate static func overview(
        machineID: String,
        profiles: [AgentProfile]? = nil,
        boundTo: (String, AgentProfile)?,
        bindingRevision: Int = 4,
        proposals: [AgentProfileProposal] = []
    ) -> AgentProfilesOverview {
        makeOverview(
            machineID: machineID,
            profiles: profiles ?? [profile()],
            boundTo: boundTo,
            bindingRevision: bindingRevision,
            bindingSoul: "",
            proposals: proposals
        )
    }

    private static func makeOverview(
        machineID: String,
        profiles: [AgentProfile],
        boundTo: (String, AgentProfile)?,
        bindingRevision: Int,
        bindingSoul: String,
        proposals: [AgentProfileProposal]
    ) -> AgentProfilesOverview {
        let binding = AgentProfileBinding(
            revision: bindingRevision,
            ownerMachineId: boundTo?.0,
            profileId: boundTo?.1.id,
            soul: bindingSoul,
            user: "",
            updatedAt: "2026-09-22T12:00:00Z"
        )
        let isRemote = boundTo.map { $0.0 != machineID } ?? false
        return AgentProfilesOverview(
            ok: true,
            capability: "agent-profiles-v1",
            machineId: machineID,
            profiles: profiles,
            binding: binding,
            effective: AgentProfileEffective(
                profile: boundTo?.1,
                binding: binding,
                prompt: "Synthetic effective prompt",
                syncStatus: boundTo == nil ? "unassigned" : (isRemote ? "current" : "local"),
                lastSyncedAt: isRemote ? "2026-09-22T12:00:00Z" : nil,
                error: nil
            ),
            proposals: proposals
        )
    }

    nonisolated fileprivate static func overviewJSON(machineID: String) -> String {
        """
        {
          "ok": true,
          "capability": "agent-profiles-v1",
          "machineId": "\(machineID)",
          "profiles": [{
            "id": "00000000-0000-4000-8000-000000000001",
            "name": "Personal", "revision": 2, "soul": "Be clear", "user": "Prefers concise replies",
            "updatedAt": "2026-09-22T12:00:00Z", "actor": "operator", "reason": "Synthetic revision"
          }],
          "binding": {
            "revision": 4, "ownerMachineId": "\(machineID)",
            "profileId": "00000000-0000-4000-8000-000000000001",
            "soul": "", "user": "", "updatedAt": "2026-09-22T12:00:00Z"
          },
          "effective": {
            "profile": null,
            "binding": {
              "revision": 4, "ownerMachineId": "\(machineID)",
              "profileId": "00000000-0000-4000-8000-000000000001",
              "soul": "", "user": "", "updatedAt": "2026-09-22T12:00:00Z"
            },
            "prompt": "Synthetic effective prompt", "syncStatus": "current",
            "lastSyncedAt": "2026-09-22T12:00:00Z", "error": null
          },
          "proposals": [{
            "id": "proposal-1", "profileId": "00000000-0000-4000-8000-000000000001",
            "baseRevision": 2, "soul": "Proposed soul", "user": "Proposed user",
            "reason": "Synthetic proposal", "actor": "agent proposal", "status": "pending",
            "createdAt": "2026-09-22T12:05:00Z"
          }]
        }
        """
    }
}

private actor MissingHistoryAgentProfilesClient: AgentProfilesClient {
    let overview: AgentProfilesOverview

    init(overview: AgentProfilesOverview) {
        self.overview = overview
    }

    func fetchAgentProfiles() async throws -> AgentProfilesOverview { overview }

    func fetchAgentProfile(id: String) async throws -> AgentProfileHistoryResponse {
        throw APIError.server(status: 404, message: "Revision history was pruned.")
    }

    func mutateAgentProfiles(_ mutation: AgentProfileMutation) async throws -> AgentProfileMutationResponse {
        throw APIError.server(status: 404, message: "Revision was pruned.")
    }
}

private struct MissingRouteAgentProfilesClient: AgentProfilesClient {
    func fetchAgentProfiles() async throws -> AgentProfilesOverview {
        throw APIError.server(status: 404, message: "Not found")
    }

    func fetchAgentProfile(id: String) async throws -> AgentProfileHistoryResponse {
        throw APIError.server(status: 404, message: "Not found")
    }

    func mutateAgentProfiles(_ mutation: AgentProfileMutation) async throws -> AgentProfileMutationResponse {
        throw APIError.server(status: 404, message: "Not found")
    }
}

/// Answers the first overview request, then holds later ones until released.
private actor GatedAgentProfilesClient: AgentProfilesClient {
    let overview: AgentProfilesOverview
    private var fetchCount = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(overview: AgentProfilesOverview) {
        self.overview = overview
    }

    func fetchAgentProfiles() async throws -> AgentProfilesOverview {
        fetchCount += 1
        if fetchCount > 1 {
            await withCheckedContinuation { continuation in
                gate = continuation
                let blocked = waiters
                waiters.removeAll()
                for waiter in blocked { waiter.resume() }
            }
        }
        return overview
    }

    func waitUntilBlocked() async {
        if gate != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func fetchAgentProfile(id: String) async throws -> AgentProfileHistoryResponse {
        guard let profile = overview.profiles.first else { throw APIError.invalidResponse }
        return AgentProfileHistoryResponse(ok: true, profile: profile, history: overview.profiles)
    }

    func mutateAgentProfiles(_ mutation: AgentProfileMutation) async throws -> AgentProfileMutationResponse {
        AgentProfileMutationResponse(ok: true, profile: nil, binding: nil, effective: nil, proposal: nil)
    }
}

private actor ScriptedAgentProfilesClient: AgentProfilesClient {
    private let overviews: [AgentProfilesOverview]
    private let mutationResponse: AgentProfileMutationResponse
    private var fetchIndex = 0
    private var mutations: [AgentProfileMutation] = []
    private var shouldFailMutation: Bool

    init(
        overviews: [AgentProfilesOverview],
        mutationResponse: AgentProfileMutationResponse = AgentProfileMutationResponse(
            ok: true,
            profile: nil,
            binding: nil,
            effective: nil,
            proposal: nil
        ),
        failFirstMutation: Bool = false
    ) {
        self.overviews = overviews
        self.mutationResponse = mutationResponse
        shouldFailMutation = failFirstMutation
    }

    func fetchAgentProfiles() async throws -> AgentProfilesOverview {
        guard !overviews.isEmpty else { throw APIError.invalidResponse }
        let index = min(fetchIndex, overviews.count - 1)
        fetchIndex += 1
        return overviews[index]
    }

    func fetchAgentProfile(id: String) async throws -> AgentProfileHistoryResponse {
        guard !overviews.isEmpty else { throw APIError.invalidResponse }
        let index = max(0, min(fetchIndex - 1, overviews.count - 1))
        let overview = overviews[index]
        guard let profile = overview.profiles.first else { throw APIError.invalidResponse }
        return AgentProfileHistoryResponse(ok: true, profile: profile, history: overview.profiles)
    }

    func mutateAgentProfiles(_ mutation: AgentProfileMutation) async throws -> AgentProfileMutationResponse {
        mutations.append(mutation)
        if shouldFailMutation {
            shouldFailMutation = false
            throw URLError(.networkConnectionLost)
        }
        return mutationResponse
    }

    func recordedMutations() -> [AgentProfileMutation] { mutations }
}

private actor DeferredAgentProfilesClient: AgentProfilesClient {
    private var fetchContinuation: CheckedContinuation<AgentProfilesOverview, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilRequested() async {
        if fetchContinuation != nil { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resolve(_ overview: AgentProfilesOverview) {
        fetchContinuation?.resume(returning: overview)
        fetchContinuation = nil
    }

    func fetchAgentProfiles() async throws -> AgentProfilesOverview {
        await withCheckedContinuation { continuation in
            fetchContinuation = continuation
            let waiters = requestWaiters
            requestWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func fetchAgentProfile(id: String) async throws -> AgentProfileHistoryResponse {
        throw APIError.invalidResponse
    }

    func mutateAgentProfiles(_ mutation: AgentProfileMutation) async throws -> AgentProfileMutationResponse {
        throw APIError.invalidResponse
    }
}

private actor ConflictAgentProfilesClient: AgentProfilesClient {
    let overview: AgentProfilesOverview
    let mutationError: APIError?

    init(overview: AgentProfilesOverview, mutationError: APIError? = .server(status: 409, message: "Revision conflict.")) {
        self.overview = overview
        self.mutationError = mutationError
    }

    func fetchAgentProfiles() async throws -> AgentProfilesOverview { overview }

    func fetchAgentProfile(id: String) async throws -> AgentProfileHistoryResponse {
        guard let profile = overview.profiles.first else { throw APIError.invalidResponse }
        return AgentProfileHistoryResponse(ok: true, profile: profile, history: overview.profiles)
    }

    func mutateAgentProfiles(_ mutation: AgentProfileMutation) async throws -> AgentProfileMutationResponse {
        if let mutationError { throw mutationError }
        return AgentProfileMutationResponse(ok: true, profile: nil, binding: nil, effective: nil, proposal: nil)
    }
}

private struct AgentProfilesRecordedRequest: Sendable {
    let path: String
    let method: String
    let authorization: String?
    let body: String?
}

private final class AgentProfilesURLProtocol: URLProtocol {
    static let records = Mutex<[AgentProfilesRecordedRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        let path = url.path
        let body = Self.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
        Self.records.withLock {
            $0.append(
                AgentProfilesRecordedRequest(
                    path: path,
                    method: request.httpMethod ?? "",
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    body: body
                )
            )
        }

        let payload: String
        if path.contains("/profiles/") {
            payload = """
            {
              "ok": true,
              "profile": {
                "id": "00000000-0000-4000-8000-000000000001", "name": "Personal",
                "revision": 2, "soul": "Be clear", "user": "Synthetic user",
                "updatedAt": "2026-09-22T12:00:00Z", "actor": "operator", "reason": "Synthetic revision"
              },
              "history": [{
                "id": "00000000-0000-4000-8000-000000000001", "name": "Personal",
                "revision": 2, "soul": "Be clear", "user": "Synthetic user",
                "updatedAt": "2026-09-22T12:00:00Z", "actor": "operator", "reason": "Synthetic revision"
              }]
            }
            """
        } else if request.httpMethod == "POST" {
            payload = #"{"ok":true}"#
        } else {
            payload = AgentProfileTests.overviewJSON(machineID: "machine-a")
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
