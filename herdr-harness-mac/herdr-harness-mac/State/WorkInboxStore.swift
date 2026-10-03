import Foundation
import Observation

/// In-memory transport identity. Never log or persist it because the connection
/// includes credentials. The inbox covers the configured primary companion.
struct WorkInboxConnectionIdentity: Equatable, Sendable {
    let machineID: String?
    let generation: Int
    let isDemo: Bool
    let connection: ActiveServerConnection?
}

@MainActor
@Observable
final class WorkInboxStore {
    private(set) var response = WorkInboxResponse.empty
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    private(set) var lastUpdated: Date?
    private(set) var reviewRequestsUpdatedAt: Date?
    private(set) var jiraTicketsUpdatedAt: Date?
    private(set) var transportError: String?
    @ObservationIgnored private var identity: WorkInboxConnectionIdentity?
    @ObservationIgnored private var requestID: UUID?

    var totalCount: Int {
        response.reviewRequests.items.count + response.jiraTickets.items.count
    }

    var hasError: Bool {
        transportError != nil || response.reviewRequests.error != nil || response.jiraTickets.error != nil
    }

    func error(for provider: WorkInboxProvider) -> String? {
        let providerError = switch provider {
        case .github: response.reviewRequests.error
        case .jira: response.jiraTickets.error
        }
        return providerError ?? transportError
    }

    /// Reconcile while hidden too, so a changed primary, credential or demo
    /// session cannot retain or publish the previous account's requests.
    func configure(identity: WorkInboxConnectionIdentity) {
        guard self.identity != identity else { return }
        self.identity = identity
        requestID = nil
        response = .empty
        isRefreshing = false
        hasLoaded = false
        lastUpdated = nil
        reviewRequestsUpdatedAt = nil
        jiraTicketsUpdatedAt = nil
        transportError = nil
    }

    func refresh(
        for identity: WorkInboxConnectionIdentity,
        using load: () async throws -> WorkInboxResponse
    ) async {
        guard self.identity == identity, !Task.isCancelled, !isRefreshing else { return }
        let request = UUID()
        requestID = request
        isRefreshing = true
        defer {
            if requestID == request { isRefreshing = false; requestID = nil }
        }

        do {
            var received = try await load().prioritizingActiveJiraStatuses()
            guard !Task.isCancelled, self.identity == identity, requestID == request else { return }
            let now = Date.now
            if received.reviewRequests.ok, received.reviewRequests.error == nil {
                reviewRequestsUpdatedAt = now
            } else {
                received.reviewRequests.items = response.reviewRequests.items
                received.reviewRequests.error = received.reviewRequests.error ?? "GitHub requests could not be refreshed."
            }
            if received.jiraTickets.ok, received.jiraTickets.error == nil {
                jiraTicketsUpdatedAt = now
            } else {
                received.jiraTickets.items = response.jiraTickets.items
                received.jiraTickets.error = received.jiraTickets.error ?? "Jira tickets could not be refreshed."
            }
            response = received
            transportError = nil
            lastUpdated = now
            hasLoaded = true
        } catch {
            guard !Task.isCancelled, !HerdrCancellation.isCancellation(error),
                  self.identity == identity, requestID == request else { return }
            transportError = error.localizedDescription
            hasLoaded = true
        }
    }
}
