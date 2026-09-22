import Foundation
import Observation

struct FirstMateGitCatalogIdentity: Equatable, Sendable {
    let machineID: String
    let featureID: String
    let configuration: ServerConfiguration?
    let configurationRevision: Int

    init(machineID: String, featureID: String, configuration: ServerConfiguration? = nil, configurationRevision: Int = 0) {
        self.machineID = machineID
        self.featureID = featureID
        self.configuration = configuration
        self.configurationRevision = configurationRevision
    }
}

@MainActor @Observable
final class FirstMateGitCatalog {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case unsupported
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var workspaces: [FirstMateGitWorkspace] = []
    private(set) var featureTitle: String?
    private(set) var selectedWorkspaceID: String
    private(set) var identity: FirstMateGitCatalogIdentity?
    let pinnedWorkspaceID: String?

    private let initialWorkspaceID: String
    private var requestGeneration = 0

    init(pinnedWorkspaceID: String? = nil, initialWorkspaceID: String = "project") {
        self.pinnedWorkspaceID = pinnedWorkspaceID
        self.initialWorkspaceID = initialWorkspaceID
        selectedWorkspaceID = pinnedWorkspaceID ?? initialWorkspaceID
    }

    var isPinned: Bool { pinnedWorkspaceID != nil }

    var selectedWorkspace: FirstMateGitWorkspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    func selectWorkspace(id: String) {
        guard pinnedWorkspaceID == nil else { return }
        selectedWorkspaceID = id
    }

    func reset() {
        requestGeneration &+= 1
        identity = nil
        phase = .idle
        workspaces = []
        featureTitle = nil
        selectedWorkspaceID = pinnedWorkspaceID ?? initialWorkspaceID
    }

    func load(
        machineID: String,
        featureID: String,
        client: (any FirstMateGitClient)?,
        demo: Bool,
        demoFeatureTitle: String = "Demo feature",
        configuration: ServerConfiguration? = nil,
        configurationRevision: Int = 0
    ) async {
        requestGeneration &+= 1
        let request = requestGeneration
        let requestedIdentity = FirstMateGitCatalogIdentity(
            machineID: machineID, featureID: featureID,
            configuration: configuration, configurationRevision: configurationRevision
        )
        let changedTarget = identity?.machineID != machineID || identity?.featureID != featureID
        let changedConnection = identity != requestedIdentity
        identity = requestedIdentity
        // Keep a ready workbench mounted across same-target catalog refreshes.
        // A changed feature or API configuration must hide the old host's data.
        if changedConnection || phase != .ready { phase = .loading }
        if changedConnection {
            workspaces = []
            featureTitle = nil
        }
        if changedTarget {
            selectedWorkspaceID = pinnedWorkspaceID ?? initialWorkspaceID
        }

        if demo {
            guard requestIsCurrent(request, identity: requestedIdentity) else { return }
            workspaces = FirstMateGitDemo.workspaces
            featureTitle = demoFeatureTitle
            phase = .ready
            return
        }

        guard let client else {
            guard requestIsCurrent(request, identity: requestedIdentity) else { return }
            workspaces = []
            featureTitle = nil
            phase = .failed("This feature’s owning machine is not configured.")
            return
        }

        let capabilities: FirstMateCapabilities
        do {
            capabilities = try await client.fetchFirstMateCapabilities()
            try Task.checkCancellation()
            guard requestIsCurrent(request, identity: requestedIdentity) else { return }
        } catch is CancellationError {
            return
        } catch APIError.server(let status, _) where status == 404 {
            guard requestIsCurrent(request, identity: requestedIdentity) else { return }
            workspaces = []
            featureTitle = nil
            phase = .unsupported
            return
        } catch {
            guard requestIsCurrent(request, identity: requestedIdentity) else { return }
            workspaces = []
            featureTitle = nil
            phase = .failed(error.localizedDescription)
            return
        }

        guard capabilities.ok,
              capabilities.capabilities.contains("first-mate-git-v1") else {
            workspaces = []
            featureTitle = nil
            phase = .unsupported
            return
        }

        do {
            // New Git endpoints are contacted only after the capability gate.
            async let catalog = client.fetchFirstMateGitWorkspaces(featureID: featureID)
            async let snapshot = client.fetchFirstMateFeature(featureID)
            let (workspaceResponse, featureSnapshot) = try await (catalog, snapshot)
            try Task.checkCancellation()
            guard requestIsCurrent(request, identity: requestedIdentity) else { return }
            guard workspaceResponse.ok else { throw APIError.invalidResponse }
            workspaces = workspaceResponse.workspaces
            featureTitle = featureSnapshot.feature.title
            // Same-target refreshes preserve an exact worker selection. A
            // missing row stays unavailable with its ID unchanged; no row is
            // silently substituted for project or another worker.
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            guard requestIsCurrent(request, identity: requestedIdentity) else { return }
            workspaces = []
            featureTitle = nil
            phase = .failed(error.localizedDescription)
        }
    }

    private func requestIsCurrent(
        _ request: Int,
        identity requestedIdentity: FirstMateGitCatalogIdentity
    ) -> Bool {
        !Task.isCancelled && request == requestGeneration && identity == requestedIdentity
    }
}
