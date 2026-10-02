import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate saved project contract")
@MainActor
struct FirstMateProjectTests {
    @Test("Legacy capabilities remain decodable and do not imply project support")
    func additiveCapabilities() throws {
        let old = try JSONDecoder().decode(
            FirstMateCapabilities.self,
            from: Data(#"{"ok":true,"capabilities":["first-mate-v1"]}"#.utf8)
        )
        #expect(old.serverID == nil)
        #expect(!old.supportsProjects)
        #expect(!old.supportsDirectoryBrowser)
        let current = try JSONDecoder().decode(
            FirstMateCapabilities.self,
            from: Data(#"{"ok":true,"server_id":"synthetic-server","capabilities":["first-mate-projects-v1","directory-browser-v1"]}"#.utf8)
        )
        #expect(current.serverID == "synthetic-server")
        #expect(current.supportsProjects)
        #expect(current.supportsDirectoryBrowser)
    }

    @Test("Projects and directory pages retain ownership, revision and unavailable symlinks")
    func projectAndDirectoryPayloads() throws {
        let listing = try JSONDecoder().decode(FirstMateProjectList.self, from: Data(#"""
            {"ok":true,"server_id":"synthetic-server","projects":[
              {"id":"fmp_sample","name":"Sample app","cwd":"/workspace/sample-app","revision":3,
               "created_at":"2030-01-01T12:00:00Z","updated_at":"2030-01-02T12:00:00Z","archived_at":null}
            ]}
            """#.utf8))
        #expect(listing.serverID == "synthetic-server")
        #expect(listing.projects == [Self.project])
        #expect(try JSONDecoder().decode(FirstMateProjectList.self, from: JSONEncoder().encode(listing)) == listing)
        let page = try JSONDecoder().decode(FirstMateDirectoryList.self, from: Data(#"""
            {"ok":true,"path":"/","parent_path":null,"home_path":"/home/synthetic",
             "entries":[{"name":"Unreachable alias","path":"/Unreachable alias","resolved_path":null,
                         "is_symlink":true,"can_open":false}],"next_cursor":"opaque+page/2="}
            """#.utf8))
        #expect(page.parentPath == nil)
        #expect(page.nextCursor == "opaque+page/2=")
        #expect(page.entries.first?.resolvedPath == nil)
        #expect(page.entries.first?.canOpen == false)
        #expect(page.entries.first?.isSymlink == true)
        #expect(try JSONDecoder().decode(FirstMateDirectoryList.self, from: JSONEncoder().encode(page)) == page)
    }

    @Test("Feature project metadata is optional and participates in updates")
    func featureCompatibility() throws {
        let source = FirstMateDemo.features(step: 0)[0].feature
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        object.removeValue(forKey: "project_id")
        object.removeValue(forKey: "project_name")
        object.removeValue(forKey: "project_revision")
        let legacy = try JSONDecoder().decode(FirstMateFeature.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.projectID == nil)
        #expect(legacy.projectName == nil)
        #expect(legacy.projectRevision == nil)
        var linked = legacy
        linked.projectID = Self.project.id
        linked.projectName = Self.project.name
        linked.projectRevision = Self.project.revision
        #expect(linked != legacy)
        let decoded = try JSONDecoder().decode(FirstMateFeature.self, from: JSONEncoder().encode(linked))
        #expect(decoded == linked)
        #expect(decoded.cwd == legacy.cwd)
    }

    @Test("Demo creation snapshots the project and retains the initial direction verbatim")
    func demoCreation() async throws {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        let prompt = "  Start with SYNTH-204.\nInvestigate first; keep this wording.  "
        let accepted = await store.create(title: "Search investigation", goal: prompt, project: Self.project, requestID: "demo-project-create")
        #expect(accepted)
        let snapshot = try #require(store.snapshot)
        #expect(snapshot.feature.cwd == Self.project.cwd)
        #expect(snapshot.feature.projectID == Self.project.id)
        #expect(snapshot.feature.projectName == Self.project.name)
        #expect(snapshot.feature.projectRevision == Self.project.revision)
        #expect(snapshot.feature.goal == prompt)
        #expect(snapshot.messages.filter { $0.role == "user" }.map(\.text) == [prompt])
    }

    @Test("A lost creation response retries the same project request without sending a second message")
    func retriesAcceptedCreation() async throws {
        let client = FirstMateProjectStoreClient(project: Self.project, failFirstCreation: true)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let context = store.operationContext
        let prompt = "  Investigate the ticket.\nDo not implement yet.  "
        let first = await store.create(title: "Investigation", goal: prompt, project: Self.project, requestID: "same-request", expectedContext: context)
        #expect(!first)
        #expect(store.error != nil)
        let retry = await store.create(title: "Investigation", goal: prompt, project: Self.project, requestID: "same-request", expectedContext: context)
        #expect(retry)
        let requests = await client.creationRequests
        #expect(requests.count == 2)
        #expect(requests[0] == requests[1])
        #expect(requests.first?.goal == prompt)
        #expect(requests.first?.projectID == Self.project.id)
        #expect(requests.first?.expectedProjectRevision == Self.project.revision)
        #expect(await client.messageCount == 0)
        #expect(store.features.count == 1)
        #expect(store.snapshot?.messages.filter { $0.role == "user" }.map(\.text) == [prompt])
    }

    @Test("An in-flight creation cannot select a feature after the host changes")
    func staleHostCreation() async {
        let client = FirstMateProjectStoreClient(project: Self.project, holdCreation: true)
        let replacement = FirstMateProjectStoreClient(project: Self.project)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let context = store.operationContext
        let task = Task {
            await store.create(title: "Original host", goal: "Work only here", project: Self.project, requestID: "host-bound", expectedContext: context)
        }
        await client.waitForCreation()
        store.configure(client: replacement, demo: false)
        await client.releaseCreation()
        #expect(await task.value == false)
        #expect(store.features.isEmpty)
        #expect(store.selectedFeatureID == nil)
        #expect(await replacement.creationRequests.isEmpty)
    }

    @Test("An old companion or archived project is rejected before submitting creation")
    func rejectsUnavailableProjects() async {
        let client = FirstMateProjectStoreClient(project: Self.project, supportsProjects: false)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        #expect(!store.projectsSupported)
        #expect(await store.create(title: "Blocked", goal: "Do not send", project: Self.project, requestID: "old-server") == false)
        #expect(await client.creationRequests.isEmpty)
        store.configure(client: nil, demo: true)
        var archived = Self.project
        archived.archivedAt = "2030-01-03T12:00:00Z"
        let previousCount = store.features.count
        #expect(await store.create(title: "Archived", goal: "Do not send", project: archived, requestID: "archived-project") == false)
        #expect(store.features.count == previousCount)
    }

    private static let project = FirstMateProject(
        id: "fmp_sample", name: "Sample app", cwd: "/workspace/sample-app", revision: 3,
        createdAt: "2030-01-01T12:00:00Z", updatedAt: "2030-01-02T12:00:00Z"
    )
}

private actor FirstMateProjectStoreClient: FirstMateClient {
    private let project: FirstMateProject
    private let failFirstCreation: Bool
    private let holdCreation: Bool
    private let supportsProjects: Bool
    private var created: FirstMateSnapshot?
    private var creationContinuation: CheckedContinuation<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var startedCreation = false
    private(set) var creationRequests: [FirstMateProjectFeatureRequest] = []
    private(set) var messageCount = 0

    init(project: FirstMateProject, failFirstCreation: Bool = false, holdCreation: Bool = false, supportsProjects: Bool = true) {
        self.project = project
        self.failFirstCreation = failFirstCreation
        self.holdCreation = holdCreation
        self.supportsProjects = supportsProjects
    }

    func waitForCreation() async {
        if startedCreation { return }
        await withCheckedContinuation { readyContinuation = $0 }
    }
    func releaseCreation() { creationContinuation?.resume(); creationContinuation = nil }
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: supportsProjects ? ["first-mate-projects-v1"] : [])
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        .init(ok: true, features: created.map { [$0.feature] } ?? [])
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        guard let created else { throw APIError.invalidResponse }
        return created
    }
    func createFirstMateFeature(title: String, goal: String, projectID: String, expectedProjectRevision: Int, requestID: String) async throws -> FirstMateSnapshot {
        creationRequests.append(.init(title: title, goal: goal, projectID: projectID, expectedProjectRevision: expectedProjectRevision, requestID: requestID))
        if created == nil {
            var snapshot = FirstMateDemo.newFeature(title: title, goal: goal, cwd: project.cwd)
            snapshot.feature.projectID = projectID
            snapshot.feature.projectName = project.name
            snapshot.feature.projectRevision = expectedProjectRevision
            created = snapshot
        }
        startedCreation = true
        if holdCreation {
            await withCheckedContinuation {
                creationContinuation = $0
                readyContinuation?.resume()
                readyContinuation = nil
            }
        }
        if failFirstCreation, creationRequests.count == 1 { throw URLError(.networkConnectionLost) }
        guard let created else { throw APIError.invalidResponse }
        return created
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        messageCount += 1
        throw APIError.invalidResponse
    }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
