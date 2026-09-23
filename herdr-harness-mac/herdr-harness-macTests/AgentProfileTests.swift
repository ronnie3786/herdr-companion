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
        var draft = AgentProfileDraft()
        draft.name = String(repeating: "n", count: AgentProfileLimits.maximumNameBytes)
        draft.reason = "Required reason"
        #expect(draft.nameIsValid)
        #expect(draft.reasonIsValid)
        draft.name += "n"
        #expect(!draft.nameIsValid)
        draft.name = "Valid"
        draft.reason = "   "
        #expect(!draft.reasonIsValid)
        draft.reason = String(repeating: "r", count: AgentProfileLimits.maximumReasonBytes + 1)
        #expect(!draft.reasonIsValid)
        draft.reason = "Valid"
        draft.soul = String(repeating: "é", count: AgentProfileLimits.maximumDocumentBytes / 2 + 1)
        #expect(!draft.documentsAreValid)
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

    @Test("Conflict preserves profile and override drafts for explicit reconciliation")
    func conflictPreservesDraft() async {
        let client = ConflictAgentProfilesClient(overview: Self.overview(machineID: "machine-a"))
        let store = AgentProfilesStore(
            machines: [HerdrMachine(id: "ui-a", name: "Build", urlString: "https://build.example.invalid")],
            clients: ["ui-a": client],
            initiallySelectedMachineID: "ui-a"
        )
        await store.load()
        #expect(store.assignmentProfileID == "00000000-0000-4000-8000-000000000001")
        await store.chooseAssignmentOwner("ui-a")
        #expect(store.assignmentProfileID == "00000000-0000-4000-8000-000000000001")
        store.draft.soul = "unsaved soul"
        store.draft.reason = "Synthetic edit reason"
        store.overrideUser = "unsaved override"

        await store.createOrUpdateProfile()

        #expect(store.draft.soul == "unsaved soul")
        #expect(store.overrideUser == "unsaved override")
        #expect(store.conflictMessage?.contains("preserved") == true)
        #expect(store.hasUnsavedChanges)
    }

    @Test("Preserved profile and binding drafts keep their original CAS revisions")
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
        store.draft.soul = "draft from revision two"
        store.draft.reason = "Keep the original profile base"
        store.overrideUser = "draft from binding four"

        await store.syncNow()
        await store.createOrUpdateProfile()
        await store.saveAssignment()

        let mutations = await client.recordedMutations()
        #expect(mutations.count == 3)
        guard case let .update(_, expectedProfileRevision, _, _, _, _, _) = mutations[1] else {
            Issue.record("Expected update mutation")
            return
        }
        guard case let .assign(expectedBindingRevision, _, _, _, _, _) = mutations[2] else {
            Issue.record("Expected assignment mutation")
            return
        }
        #expect(expectedProfileRevision == 2)
        #expect(expectedBindingRevision == 4)
    }

    @Test("Saving a profile preserves unrelated assignment edits")
    func profileSavePreservesAssignmentDraft() async {
        let overview = Self.overview(machineID: "server-a")
        let savedProfile = AgentProfile(
            id: "00000000-0000-4000-8000-000000000001",
            name: "Personal",
            revision: 3,
            soul: "saved soul",
            user: "base user",
            updatedAt: "2026-09-22T12:10:00Z",
            actor: "operator",
            reason: "Saved edit"
        )
        let response = AgentProfileMutationResponse(
            ok: true,
            profile: savedProfile,
            binding: nil,
            effective: nil,
            proposal: nil
        )
        let client = ScriptedAgentProfilesClient(overviews: [overview, overview], mutationResponse: response)
        let store = AgentProfilesStore(
            machines: [HerdrMachine(id: "a", name: "Build", urlString: "https://build.example.invalid")],
            clients: ["a": client],
            initiallySelectedMachineID: "a"
        )
        await store.load()
        store.overrideSoul = "keep this override"
        store.draft.soul = "saved soul"
        store.draft.reason = "Saved edit"

        await store.createOrUpdateProfile()

        #expect(store.overrideSoul == "keep this override")
        #expect(store.assignmentHasUnsavedChanges)

        store.draft.reason = "Restore synthetic revision"
        await store.restore(1)
        #expect(store.overrideSoul == "keep this override")
        #expect(store.assignmentHasUnsavedChanges)
        let mutations = await client.recordedMutations()
        #expect(mutations.count == 2)
        if mutations.count == 2 {
            guard case .restore = mutations[1] else {
                Issue.record("Expected restore mutation")
                return
            }
        }
    }

    @Test("A lost mutation response retries the exact request on its original target")
    func lostResponseRetriesExactly() async {
        let oldOverview = Self.overview(machineID: "server-old")
        let oldClient = ScriptedAgentProfilesClient(overviews: [oldOverview], failFirstMutation: true)
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
        store.draft.soul = "retry me"
        store.draft.reason = "Lost response regression"
        await store.createOrUpdateProfile()
        #expect(store.hasPendingMutation)

        await store.selectMachine("new")
        await store.syncNow()
        let newTargetMutations = await newClient.recordedMutations()
        #expect(newTargetMutations.isEmpty)
        await store.retryPendingMutation()

        let attempts = await oldClient.recordedMutations()
        #expect(attempts.count == 2)
        #expect(attempts.first == attempts.last)
        #expect(!store.hasPendingMutation)
    }

    @Test("Successful creation selects the returned profile")
    func creationSelectsReturnedProfile() async {
        let initial = Self.overview(machineID: "server-a")
        let created = AgentProfile(
            id: "00000000-0000-4000-8000-000000000077",
            name: "Shared",
            revision: 1,
            soul: "Shared soul",
            user: "Shared user",
            updatedAt: "2026-09-22T12:10:00Z",
            actor: "operator",
            reason: "Create shared profile"
        )
        let refreshed = Self.overview(
            machineID: "server-a",
            profileName: "Shared",
            profileRevision: 1,
            bindingRevision: 4,
            profileID: created.id
        )
        let response = AgentProfileMutationResponse(ok: true, profile: created, binding: nil, effective: nil, proposal: nil)
        let client = ScriptedAgentProfilesClient(overviews: [initial, refreshed], mutationResponse: response)
        let store = AgentProfilesStore(
            machines: [HerdrMachine(id: "a", name: "Build", urlString: "https://build.example.invalid")],
            clients: ["a": client],
            initiallySelectedMachineID: "a"
        )
        await store.load()
        store.beginCreatingProfile()
        store.draft.name = "Shared"
        store.draft.soul = "Shared soul"
        store.draft.user = "Shared user"
        store.draft.reason = "Create shared profile"

        await store.createOrUpdateProfile()

        #expect(store.selectedProfileID == created.id)
        #expect(store.selectedProfile?.name == "Shared")
    }

    @Test("A late response cannot replace a newly selected data machine")
    func lateResponseDoesNotCrossTargets() async {
        let oldClient = DeferredAgentProfilesClient()
        let newClient = ConflictAgentProfilesClient(
            overview: Self.overview(machineID: "server-new", profileName: "New target"),
            mutationError: nil
        )
        let store = AgentProfilesStore(
            machines: [
                HerdrMachine(id: "old", name: "Old", urlString: "https://old.example.invalid"),
                HerdrMachine(id: "new", name: "New", urlString: "https://new.example.invalid"),
            ],
            clients: ["old": oldClient, "new": newClient],
            initiallySelectedMachineID: "old"
        )

        let oldLoad = Task { await store.load() }
        await oldClient.waitUntilRequested()
        await store.selectMachine("new")
        await oldClient.resolve(Self.overview(machineID: "server-old", profileName: "Stale target"))
        await oldLoad.value

        #expect(store.selectedMachineID == "new")
        #expect(store.overview?.machineId == "server-new")
        #expect(store.selectedProfile?.name == "New target")
        #expect(!store.isLoading)
        #expect(!store.isLoadingHistory)
        #expect(!store.isLoadingOwnerProfiles)
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
        guard let profileID = store.selectedProfileID else {
            Issue.record("Expected selected profile")
            return
        }
        await store.selectProfile(profileID)

        #expect(store.overview != nil)
        #expect(!store.requiresServerUpgrade)
        #expect(store.errorMessage == "Revision history was pruned.")

        store.draft.reason = "Restore a retained revision"
        await store.restore(1)
        #expect(store.overview != nil)
        #expect(!store.requiresServerUpgrade)
        #expect(store.errorMessage == "Revision was pruned.")
    }

    @Test("Remote owner list comes from that configured machine")
    func remoteOwnerProfiles() async {
        let local = ConflictAgentProfilesClient(overview: Self.overview(machineID: "server-local"), mutationError: nil)
        let remoteOverview = Self.overview(machineID: "server-remote", profileName: "Remote Work")
        let remote = ConflictAgentProfilesClient(overview: remoteOverview, mutationError: nil)
        let store = AgentProfilesStore(
            machines: [
                HerdrMachine(id: "local", name: "Local", urlString: "https://local.example.invalid"),
                HerdrMachine(id: "remote", name: "Remote", urlString: "https://remote.example.invalid"),
            ],
            clients: ["local": local, "remote": remote],
            initiallySelectedMachineID: "local"
        )
        await store.load()
        store.assignmentEnabled = true
        await store.chooseAssignmentOwner("remote")

        #expect(store.ownerMachineServerID == "server-remote")
        #expect(store.ownerProfiles.map(\.name) == ["Remote Work"])
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

    fileprivate static func overview(
        machineID: String,
        profileName: String = "Personal",
        profileRevision: Int = 2,
        bindingRevision: Int = 4,
        profileID: String = "00000000-0000-4000-8000-000000000001"
    ) -> AgentProfilesOverview {
        let profile = AgentProfile(
            id: profileID,
            name: profileName,
            revision: profileRevision,
            soul: "base soul",
            user: "base user",
            updatedAt: "2026-09-22T12:00:00Z",
            actor: "operator",
            reason: "Synthetic revision"
        )
        let binding = AgentProfileBinding(
            revision: bindingRevision,
            ownerMachineId: machineID,
            profileId: profile.id,
            soul: "",
            user: "",
            updatedAt: "2026-09-22T12:00:00Z"
        )
        return AgentProfilesOverview(
            ok: true,
            capability: "agent-profiles-v1",
            machineId: machineID,
            profiles: [profile],
            binding: binding,
            effective: AgentProfileEffective(
                profile: profile,
                binding: binding,
                prompt: "Synthetic effective prompt",
                syncStatus: "current",
                lastSyncedAt: "2026-09-22T12:00:00Z",
                error: nil
            ),
            proposals: []
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
