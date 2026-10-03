import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate project archive selection")
@MainActor
struct FirstMateProjectArchiveTests {
    @Test("Cleanup review only offers completed sessions explicitly linked to the selected project")
    func matchesProjectIdentity() async throws {
        let client = ProjectArchiveClient()
        let model = try model(client: client, isCurrent: { true })
        await model.load()
        #expect(model.completedSessions.map(\.id) == ["completed"])
        #expect(model.retainedCount == 2)
        #expect(model.sessions.count == 3)
        #expect(model.supportsReview)
    }

    @Test("A replaced connection cannot load or submit cleanup through the previous project screen")
    func connectionFence() async throws {
        let client = ProjectArchiveClient()
        var current = true
        let model = try model(client: client, isCurrent: { current })
        await model.load()
        let feature = try #require(model.completedSessions.first)
        let archive = model.archiveModel(for: feature)
        current = false
        await archive.load()
        #expect(!archive.canConfirm)
        #expect(await client.previewRequests == 0)
        #expect(!model.connectionIsCurrent)
    }

    private func model(client: ProjectArchiveClient, isCurrent: @escaping () -> Bool) throws -> FirstMateProjectArchiveModel {
        let project = FirstMateProject(id: "project_sample", name: "Sample project", cwd: "/workspace/sample", revision: 1,
                                       createdAt: FirstMateDemo.timestamp, updatedAt: FirstMateDemo.timestamp)
        let config = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "synthetic-project-archive"))
        let connection = FirstMateProjectConnection(machineID: "sample", machineName: "Sample machine", configuration: config,
                                                    epoch: UUID(), serverID: "sample-server", client: client)
        return FirstMateProjectArchiveModel(project: project, connection: connection, isCurrent: isCurrent)
    }
}

private actor ProjectArchiveClient: FirstMateClient {
    var previewRequests = 0
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: ["first-mate-archive-review-v1", "first-mate-archive-cleanup-v1"])
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        var completed = await FirstMateArchiveReviewTests.feature
        completed.id = "completed"
        completed.cwd = "/workspace/sample"
        completed.projectID = "project_sample"
        var active = completed
        active.id = "active"
        active.status = "running"
        var archived = completed
        archived.id = "archived"
        archived.archivedAt = FirstMateDemo.timestamp
        var sameFolder = completed
        sameFolder.id = "different_project_same_folder"
        sameFolder.projectID = "project_other"
        var manual = completed
        manual.id = "manual_same_folder"
        manual.projectID = nil
        return .init(ok: true, features: [completed, active, archived, sameFolder, manual])
    }
    func fetchFirstMateArchivePreview(featureID: String) async throws -> FirstMateArchivePreviewResponse {
        previewRequests += 1
        return .init(ok: true, preview: await FirstMateArchiveReviewTests.preview)
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
