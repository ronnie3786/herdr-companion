import Foundation
import Observation

@MainActor @Observable
final class FirstMateProjectArchiveModel: Identifiable {
    let project: FirstMateProject
    let connection: FirstMateProjectConnection
    let sessionStore = FirstMateStore()
    private(set) var sessions: [FirstMateFeature] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var supportsReview = false
    private(set) var error: String?
    @ObservationIgnored private let isCurrent: () -> Bool

    init(project: FirstMateProject, connection: FirstMateProjectConnection, isCurrent: @escaping () -> Bool) {
        self.project = project
        self.connection = connection
        self.isCurrent = isCurrent
        sessionStore.configure(client: connection.client, demo: false)
    }

    var completedSessions: [FirstMateFeature] { sessions.filter { $0.status == "completed" && !$0.isArchived } }
    var retainedCount: Int { sessions.count - completedSessions.count }
    var connectionIsCurrent: Bool { isCurrent() }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            guard isCurrent() else { throw CancellationError() }
            let capabilities = try await connection.client.fetchFirstMateCapabilities()
            let response = try await connection.client.fetchFirstMateFeatures(scope: .all)
            guard isCurrent(), response.ok else { throw CancellationError() }
            supportsReview = capabilities.ok && capabilities.supportsArchiveReview
            sessions = response.features.filter { $0.projectID == project.id }
            await sessionStore.refresh()
            guard isCurrent() else { throw CancellationError() }
            hasLoaded = true
        } catch {
            self.error = "Could not refresh this project’s sessions. \(error.localizedDescription)"
        }
    }

    func archiveModel(for feature: FirstMateFeature) -> FirstMateArchiveModel {
        FirstMateArchiveModel(feature: feature,
            readPreview: { [self] in
                guard isCurrent() else { throw CancellationError() }
                let value = try await connection.client.fetchFirstMateArchivePreview(featureID: feature.id)
                guard isCurrent(), value.ok else { throw CancellationError() }
                return value.preview
            },
            archive: { [self] request in
                guard isCurrent() else { throw CancellationError() }
                let value = try await connection.client.confirmFirstMateArchive(featureID: feature.id, request: request)
                guard isCurrent() else { throw CancellationError() }
                return value
            },
            readProgress: { [self] archiveID, after in
                guard isCurrent() else { throw CancellationError() }
                let value = try await connection.client.fetchFirstMateArchiveProgress(featureID: feature.id, archiveID: archiveID, after: after)
                guard isCurrent() else { throw CancellationError() }
                return value
            })
    }
}
