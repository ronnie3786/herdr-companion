import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate project state and session startup")
@MainActor
struct FirstMateProjectStateTests {
    @Test("Starting a project session submits the exact prompt once")
    func startsOneSession() async throws {
        let project = Self.project()
        let client = ProjectStateClient(projects: [project])
        let index = try await index(client)
        let model = startModel(project)
        let prompt = "  Investigate SYNTH-204.\nKeep the prompt intact; do not implement yet.  "
        model.prompt = prompt

        let started = try #require(await model.start(in: index))
        #expect(started.connection.machineID == "studio")
        #expect(started.snapshot.feature.cwd == project.cwd)
        #expect(started.snapshot.messages.filter { $0.role == "user" }.map(\.text) == [prompt])
        #expect(await client.creationRequests.count == 1)
        #expect(await client.creationRequests.first?.goal == prompt)
        #expect(await client.messageCount == 0)
        #expect(model.prompt.isEmpty)
        #expect(await model.start(in: index) == nil)
        #expect(await client.creationRequests.count == 1)
    }

    @Test("An unknown outcome replays the original project despite later catalog changes", arguments: CatalogChange.allCases)
    func retriesOriginalSnapshot(change: CatalogChange) async throws {
        let project = Self.project()
        let client = ProjectStateClient(projects: [project], loseFirstCreationResponse: true)
        let index = try await index(client)
        let model = startModel(project)
        let prompt = "  Start here.\nPreserve the original project selection.  "
        model.prompt = prompt
        #expect(await model.start(in: index) == nil)
        #expect(model.prompt == prompt)

        switch change {
        case .edited:
            await client.setProjects([Self.project(revision: 2, cwd: "/workspace/moved-app")])
        case .archived:
            var archived = Self.project(revision: 2)
            archived.archivedAt = "2030-01-03T12:00:00Z"
            await client.setProjects([archived])
        case .removed:
            await client.setProjects([])
        }
        await index.refresh()
        // Reopening the same picker row also must not create a second request.
        model.chooseProject(.init(machineID: "studio", projectID: project.id))
        #expect(model.canStart(in: index))
        #expect(model.unavailableReason(in: index) == nil)
        let result = try #require(await model.start(in: index))
        let requests = await client.creationRequests
        #expect(requests.count == 2)
        #expect(requests[0] == requests[1])
        #expect(requests.last?.expectedProjectRevision == 1)
        #expect(result.snapshot.feature.projectRevision == 1)
        #expect(result.snapshot.feature.cwd == project.cwd)
        #expect(await client.createdCount == 1)
        #expect(await client.messageCount == 0)
    }

    @Test("A rejected project revision needs an explicit successful reload before a new request")
    func revisionConflictRequiresReload() async throws {
        let project = Self.project()
        let client = ProjectStateClient(projects: [project])
        let index = try await index(client)
        let model = startModel(project)
        let prompt = model.prompt
        await client.setProjects([Self.project(revision: 2, cwd: "/workspace/updated-app")])

        #expect(await model.start(in: index) == nil)
        #expect(model.needsProjectReload)
        #expect(model.prompt == prompt)
        await index.refresh()
        #expect(!model.canStart(in: index))
        #expect(await model.start(in: index) == nil)
        #expect(await client.creationRequests.count == 1)

        await client.setOffline(true)
        await model.reloadProject(in: index)
        #expect(model.needsProjectReload)
        #expect(!model.canStart(in: index))
        await client.setOffline(false)
        await model.reloadProject(in: index)
        #expect(!model.needsProjectReload)
        #expect(model.canStart(in: index))
        let started = try #require(await model.start(in: index))
        let requests = await client.creationRequests
        #expect(requests.count == 2)
        #expect(requests[0].requestID != requests[1].requestID)
        #expect(requests.map(\.expectedProjectRevision) == [1, 2])
        #expect(started.snapshot.feature.cwd == "/workspace/updated-app")
        #expect(await client.createdCount == 1)
    }

    @Test("A replaced connection discards a late creation response and keeps the draft pinned")
    func connectionReplacement() async throws {
        let project = Self.project()
        let original = ProjectStateClient(projects: [project])
        let replacement = ProjectStateClient(projects: [project], serverID: "replacement-server")
        let index = try await index(original)
        let model = startModel(project)
        let prompt = model.prompt
        await original.holdNextCreation()
        var created: FirstMateStartedSession?
        let creating = Task { created = await model.start(in: index) }
        defer {
            creating.cancel()
            Task { await original.releaseCreation() }
        }
        try await waitUntil { await original.isHoldingCreation }
        index.activate(sources: [try source(replacement, token: "replacement-token")])
        await index.refresh()
        await original.releaseCreation()
        await creating.value
        #expect(created == nil)
        #expect(model.prompt == prompt)
        #expect(model.error != nil)
        #expect(!model.canStart(in: index))
        #expect(await model.start(in: index) == nil)
        model.chooseProject(.init(machineID: "studio", projectID: project.id))
        #expect(!model.canStart(in: index))
        #expect(await replacement.creationRequests.isEmpty)
        #expect(await original.createdCount == 1)
    }

    @Test("A live configuration change fences creation before the index roster updates")
    func liveConfigurationReplacement() async throws {
        let project = Self.project()
        let client = ProjectStateClient(projects: [project])
        let originalSource = try source(client)
        let settings = ProjectStateLiveConfiguration(originalSource.configuration)
        let index = FirstMateProjectIndex()
        index.activate(sources: [originalSource], validateConnection: { connection in
            settings.configuration == connection.configuration
        })
        await index.refresh()
        let connection = try #require(index.connection(for: "studio"))
        #expect(index.isCurrent(connection))
        let model = startModel(project)
        let prompt = model.prompt
        await client.holdNextCreation()
        var created: FirstMateStartedSession?
        let creating = Task { created = await model.start(in: index) }
        defer {
            creating.cancel()
            Task { await client.releaseCreation() }
        }
        try await waitUntil { await client.isHoldingCreation }

        // Change the app's configuration without activating or refreshing the
        // index, reproducing the gap before SwiftUI restarts its task.
        settings.configuration = try source(client, token: "replacement-token").configuration
        #expect(index.host("studio")?.canManageProjects == true)
        #expect(index.connection(for: "studio")?.configuration == originalSource.configuration)
        #expect(!index.isCurrent(connection))
        let anotherDraft = startModel(project)
        #expect(await anotherDraft.start(in: index) == nil)
        #expect(await client.creationRequests.count == 1)

        await client.releaseCreation()
        await creating.value
        #expect(created == nil)
        #expect(model.prompt == prompt)
        #expect(model.error?.contains("connection changed") == true)
        #expect(!model.canStart(in: index))
        #expect(await model.start(in: index) == nil)
        #expect(await client.creationRequests.count == 1)
        #expect(await client.createdCount == 1)
    }

    @Test("Offline cached projects remain visible while aliases deduplicate without redirecting selection")
    func offlineAliases() async throws {
        let project = Self.project()
        let primary = ProjectStateClient(projects: [project])
        let alias = ProjectStateClient(projects: [project])
        let other = ProjectStateClient(projects: [project], serverID: "other-server")
        let index = FirstMateProjectIndex()
        let sources = [try source(primary), try source(alias, id: "alias"), try source(other, id: "other")]
        index.activate(sources: sources)
        await index.refresh()
        let originalConnection = try #require(index.connection(for: "studio"))
        #expect(index.activeChoices.count == 2)
        #expect(index.host("studio")?.lastUpdated != nil)
        await primary.setOffline(true)
        await index.refresh()
        #expect(index.host("studio")?.projects == [project])
        #expect(index.host("studio")?.isReachable == false)
        #expect(index.activeChoices.count == 2)
        #expect(index.activeChoices.first { $0.host.serverID == "synthetic-server" }?.host.machineID == "alias")
        let model = startModel(project)
        #expect(!model.canStart(in: index))
        #expect(model.selectedProject?.machineID == "studio")
        #expect(index.isCurrent(originalConnection))

        index.activate(sources: Array(sources.reversed()))
        #expect(index.host("studio")?.projects == [project])
        #expect(index.host("studio")?.isReachable == false)
        #expect(index.isCurrent(originalConnection))
    }

    @Test("An in-flight project list cannot overwrite a newer write on either alias")
    func writeWinsOverOlderReads() async throws {
        let project = Self.project()
        let primary = ProjectStateClient(projects: [project])
        let alias = ProjectStateClient(projects: [project])
        let index = FirstMateProjectIndex()
        index.activate(sources: [try source(primary), try source(alias, id: "alias")])
        await index.refresh()
        let connection = try #require(index.connection(for: "studio"))
        await primary.holdNextList()
        await alias.holdNextList()
        let refreshing = Task { await index.refresh() }
        defer {
            refreshing.cancel()
            Task { await primary.releaseList(); await alias.releaseList() }
        }
        try await waitUntil {
            let primaryHeld = await primary.isHoldingList
            let aliasHeld = await alias.isHoldingList
            return primaryHeld && aliasHeld
        }
        let updated = Self.project(revision: 2, cwd: "/workspace/updated-app")
        index.receive(updated, from: connection)
        await primary.releaseList()
        await alias.releaseList()
        await refreshing.value
        #expect(index.host("studio")?.projects == [updated])
        #expect(index.host("alias")?.projects == [updated])
        #expect(!index.isRefreshing)
    }

    @Test("Conflicting server identities reject catalog results and fence old connections")
    func inconsistentServerIdentity() async throws {
        let project = Self.project()
        let client = ProjectStateClient(projects: [project])
        let index = try await index(client)
        let connection = try #require(index.connection(for: "studio"))
        await client.setListServerID("different-server")
        await client.setProjects([Self.project(revision: 8, cwd: "/workspace/wrong-server")])
        await index.refresh()
        #expect(index.host("studio")?.projects == [project])
        #expect(index.host("studio")?.serverID == "synthetic-server")
        #expect(index.host("studio")?.canManageProjects == false)
        #expect(index.host("studio")?.error != nil)
        #expect(!index.isCurrent(connection))
        index.receive(Self.project(revision: 9), from: connection)
        #expect(index.host("studio")?.projects == [project])

        await client.setListServerID("synthetic-server")
        await client.setProjects([project])
        await index.refresh()
        #expect(index.host("studio")?.canManageProjects == true)
        #expect(index.host("studio")?.error == nil)
        #expect(!index.isCurrent(connection))
    }

    enum CatalogChange: CaseIterable, Sendable {
        case edited, archived, removed
    }

    private static func project(revision: Int = 1, cwd: String = "/workspace/sample-app") -> FirstMateProject {
        .init(id: "fmp_sample", name: "Sample app", cwd: cwd, revision: revision,
              createdAt: "2030-01-01T12:00:00Z", updatedAt: "2030-01-02T12:00:00Z")
    }

    private func startModel(_ project: FirstMateProject) -> FirstMateStartSessionModel {
        let model = FirstMateStartSessionModel()
        model.chooseProject(.init(machineID: "studio", projectID: project.id))
        model.prompt = "Investigate the synthetic ticket."
        return model
    }

    private func index(_ client: ProjectStateClient) async throws -> FirstMateProjectIndex {
        let index = FirstMateProjectIndex()
        index.activate(sources: [try source(client)])
        await index.refresh()
        return index
    }

    private func source(_ client: ProjectStateClient, id: String = "studio", token: String = "synthetic-token") throws -> FirstMateFleetSource {
        let url = "https://\(id).example.invalid"
        return .init(machine: .init(id: id, name: "Synthetic \(id)", urlString: url),
                     configuration: try #require(ServerConfiguration(urlString: url, token: token)), client: client)
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw ProjectStateGateError.timedOut
    }
}

private enum ProjectStateGateError: Error { case timedOut }

@MainActor
private final class ProjectStateLiveConfiguration {
    var configuration: ServerConfiguration
    init(_ configuration: ServerConfiguration) { self.configuration = configuration }
}

private actor ProjectStateClient: FirstMateClient {
    private var projects: [FirstMateProject]
    private let serverID: String
    private var listServerID: String
    private var offline = false
    private let loseFirstCreationResponse: Bool
    private var receipts: [String: (FirstMateProjectFeatureRequest, FirstMateSnapshot)] = [:]
    private var shouldHoldList = false
    private var shouldHoldCreation = false
    private var listContinuation: CheckedContinuation<FirstMateProjectList, Never>?
    private var capturedList: FirstMateProjectList?
    private var creationContinuation: CheckedContinuation<Void, Never>?
    private(set) var creationRequests: [FirstMateProjectFeatureRequest] = []
    private(set) var messageCount = 0
    var createdCount: Int { receipts.count }
    var isHoldingList: Bool { listContinuation != nil }
    var isHoldingCreation: Bool { creationContinuation != nil }

    init(projects: [FirstMateProject], serverID: String = "synthetic-server", loseFirstCreationResponse: Bool = false) {
        self.projects = projects
        self.serverID = serverID
        self.listServerID = serverID
        self.loseFirstCreationResponse = loseFirstCreationResponse
    }

    func setProjects(_ value: [FirstMateProject]) { projects = value }
    func setOffline(_ value: Bool) { offline = value }
    func setListServerID(_ value: String) { listServerID = value }
    func holdNextList() { shouldHoldList = true }
    func holdNextCreation() { shouldHoldCreation = true }
    func releaseCreation() { creationContinuation?.resume(); creationContinuation = nil }
    func releaseList() {
        if let capturedList { listContinuation?.resume(returning: capturedList) }
        listContinuation = nil
        capturedList = nil
    }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        if offline { throw URLError(.notConnectedToInternet) }
        return .init(ok: true, capabilities: ["first-mate-projects-v1", "directory-browser-v1"], serverID: serverID)
    }
    func fetchFirstMateProjects(scope: FirstMateFeatureScope) async throws -> FirstMateProjectList {
        let response = FirstMateProjectList(ok: true, serverID: listServerID, projects: projects)
        if shouldHoldList {
            shouldHoldList = false
            capturedList = response
            return await withCheckedContinuation { listContinuation = $0 }
        }
        return response
    }
    func createFirstMateFeature(title: String, goal: String, projectID: String, expectedProjectRevision: Int, requestID: String) async throws -> FirstMateSnapshot {
        let request = FirstMateProjectFeatureRequest(title: title, goal: goal, projectID: projectID,
                                                    expectedProjectRevision: expectedProjectRevision, requestID: requestID)
        creationRequests.append(request)
        if let (original, value) = receipts[requestID] {
            guard original == request else { throw APIError.server(status: 409, message: "Request identity conflicts") }
            return value
        }
        guard let project = projects.first(where: { $0.id == projectID }),
              project.revision == expectedProjectRevision, !project.isArchived else {
            throw APIError.server(status: 409, message: "Project revision changed. Reload the project before starting.")
        }
        var value = FirstMateDemo.newFeature(title: title, goal: goal, cwd: project.cwd)
        value.feature.projectID = project.id
        value.feature.projectName = project.name
        value.feature.projectRevision = project.revision
        receipts[requestID] = (request, value)
        if shouldHoldCreation {
            shouldHoldCreation = false
            await withCheckedContinuation { creationContinuation = $0 }
        }
        if loseFirstCreationResponse, creationRequests.count == 1 { throw URLError(.networkConnectionLost) }
        return value
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        .init(ok: true, features: receipts.values.map { $0.1.feature })
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        guard let value = receipts.values.first(where: { $0.1.feature.id == id })?.1 else { throw APIError.invalidResponse }
        return value
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        FirstMateDemo.newFeature(title: title, goal: goal, cwd: cwd)
    }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        messageCount += 1
        throw APIError.invalidResponse
    }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
