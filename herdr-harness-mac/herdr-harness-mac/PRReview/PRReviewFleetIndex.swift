import Foundation
import Observation

struct PRReviewFleetSource: Sendable {
    let machineID: String
    let machineName: String
    let client: any PRReviewClient
}

/// What invalidates fleet requests: the ordered roster, names, authenticated
/// connections, connection generation, and demo flag. Held in memory only;
/// this value contains tokens and must never be logged or persisted.
struct PRReviewFleetIdentity: Hashable, Sendable {
    struct Machine: Hashable, Sendable {
        let id: String
        let name: String
        let urlString: String
        let token: String
    }

    let isDemo: Bool
    let generation: Int
    let machines: [Machine]
}

/// A server-local review is distinct on every owning machine, even when its
/// review ID, pull request number, or display title matches another row.
struct PRReviewFleetEntry: Identifiable, Equatable, Sendable {
    let machineID: String
    let machineName: String
    let review: PRReviewSummary

    var id: PRReviewWindowTarget {
        .init(machineID: machineID, reviewID: review.id)
    }
}

struct PRReviewFleetHostNotice: Identifiable, Equatable, Sendable {
    let machineID: String
    let machineName: String
    let message: String

    var id: String { machineID }
}

/// Combines only the PR Review rail's summaries. Detail stores and popped-out
/// windows remain single-host, and every row action uses its exact owner.
///
/// Hosts refresh independently: a failed companion keeps its last usable
/// lists alongside a notice without hiding the other machines. Replacing the
/// roster invalidates every in-flight response, including mutations, so an
/// old connection cannot repopulate a removed host or overwrite a new client.
@MainActor
@Observable
final class PRReviewFleetIndex {
    private(set) var active: [PRReviewFleetEntry] = []
    private(set) var archived: [PRReviewFleetEntry] = []
    private(set) var notices: [PRReviewFleetHostNotice] = []
    private(set) var hasLoaded = false
    private(set) var isRefreshing = false
    private(set) var sourceCount = 0

    @ObservationIgnored private var sources: [PRReviewFleetSource] = []
    @ObservationIgnored private var identity: AnyHashable?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hosts: [String: HostContent] = [:]

    private struct HostContent {
        var active: [PRReviewSummary] = []
        var archived: [PRReviewSummary] = []
        var notice: String?
        /// A list fetched before a row action cannot undo that action.
        var mutationRevision = 0
    }

    private struct FetchResult: Sendable {
        enum Outcome: Sendable {
            case success(active: [PRReviewSummary], archived: [PRReviewSummary])
            case failure(String)
            case cancelled
        }

        let machineID: String
        let outcome: Outcome
    }

    /// An unchanged identity is a no-op, even if the caller constructed fresh
    /// clients. Remaining hosts keep their lists and notices; removed hosts
    /// are dropped immediately, and labels and order follow the new roster.
    func setSources(_ sources: [PRReviewFleetSource], identity: AnyHashable) {
        guard self.identity != identity else { return }
        generation &+= 1
        self.identity = identity
        self.sources = sources
        let machineIDs = Set(sources.map(\.machineID))
        hosts = hosts.filter { machineIDs.contains($0.key) }
        sourceCount = sources.count
        isRefreshing = false
        hasLoaded = false
        publish()
    }

    /// Reads both lists on every source concurrently. Each host publishes as
    /// soon as it answers, while the combined order remains roster then server
    /// order rather than the order in which requests finish.
    func refresh() async {
        guard !Task.isCancelled, !isRefreshing else { return }
        let refreshGeneration = generation
        let refreshSources = sources
        let mutationRevisions = hosts.mapValues(\.mutationRevision)
        isRefreshing = true
        defer {
            if generation == refreshGeneration { isRefreshing = false }
        }

        await withTaskGroup(of: FetchResult.self) { group in
            for source in refreshSources {
                group.addTask { await Self.fetch(source) }
            }
            for await result in group {
                guard generation == refreshGeneration, !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                var host = hosts[result.machineID] ?? HostContent()
                guard host.mutationRevision == (mutationRevisions[result.machineID] ?? 0) else { continue }
                switch result.outcome {
                case let .success(active, archived):
                    host.active = active
                    host.archived = archived
                    host.notice = nil
                case let .failure(message):
                    host.notice = message
                case .cancelled:
                    continue
                }
                hosts[result.machineID] = host
                hasLoaded = true
                publish()
            }
        }
        if generation == refreshGeneration, !Task.isCancelled { hasLoaded = true }
    }

    /// Archives only the target's companion and reconciles that row from the
    /// returned snapshot. No other host is polled or mutated as a side effect.
    /// Callers must also forget this Mac's saved walkthrough progress after a
    /// successful archive; use HerdrShellState.archivePRReviewFromFleet in the shell.
    func archive(_ target: PRReviewWindowTarget, archived: Bool) async throws {
        guard let source = sources.first(where: { $0.machineID == target.machineID }) else {
            throw APIError.invalidResponse
        }
        let capturedGeneration = generation
        let value = try await source.client.archivePRReview(
            id: target.reviewID,
            archived: archived,
            requestID: UUID().uuidString
        )
        try receive(value, for: target, generation: capturedGeneration)
    }

    /// Refreshes only the target review on its own machine, never whichever
    /// host the detail store or the rail currently selects.
    func refreshReview(_ target: PRReviewWindowTarget) async throws {
        guard let source = sources.first(where: { $0.machineID == target.machineID }) else {
            throw APIError.invalidResponse
        }
        let capturedGeneration = generation
        let value = try await source.client.refreshPRReview(id: target.reviewID, requestID: UUID().uuidString)
        try receive(value, for: target, generation: capturedGeneration)
    }

    func entry(for target: PRReviewWindowTarget) -> PRReviewFleetEntry? {
        active.first { $0.id == target } ?? archived.first { $0.id == target }
    }

    func contains(_ target: PRReviewWindowTarget) -> Bool {
        entry(for: target) != nil
    }

    nonisolated private static func fetch(_ source: PRReviewFleetSource) async -> FetchResult {
        let outcome: FetchResult.Outcome
        do {
            async let active = source.client.prReviews(scope: "active")
            async let archived = source.client.prReviews(scope: "archived")
            outcome = try await .success(active: active, archived: archived)
        } catch {
            if HerdrCancellation.isCancellation(error) {
                outcome = .cancelled
            } else if case APIError.server(let status, _) = error, status == 404 || status == 501 {
                outcome = .failure("Update this machine's companion for PR Review (pr-review-v1).")
            } else {
                outcome = .failure(error.localizedDescription)
            }
        }
        return FetchResult(machineID: source.machineID, outcome: outcome)
    }

    private func receive(_ value: PRReviewSnapshot, for target: PRReviewWindowTarget, generation: Int) throws {
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        guard value.ok, value.review.id == target.reviewID else { throw APIError.invalidResponse }
        var host = hosts[target.machineID] ?? HostContent()
        let previous = (host.active + host.archived).first { $0.id == target.reviewID }
        guard value.review.revision >= (previous?.revision ?? 0) else { return }
        host.mutationRevision &+= 1
        let review = value.review.retainingNewerViewerState(from: previous)
        if review.archivedAt == nil {
            host.archived.removeAll { $0.id == target.reviewID }
            Self.replace(review, in: &host.active)
        } else {
            host.active.removeAll { $0.id == target.reviewID }
            Self.replace(review, in: &host.archived)
        }
        hosts[target.machineID] = host
        publish()
    }

    private static func replace(_ review: PRReviewSummary, in reviews: inout [PRReviewSummary]) {
        if let index = reviews.firstIndex(where: { $0.id == review.id }) {
            reviews[index] = review
        } else {
            reviews.insert(review, at: 0)
        }
    }

    /// Unchanged polls write nothing to the observed lists, avoiding needless
    /// rail rerenders. Cache keys never depend on a machine's display name.
    private func publish() {
        var nextActive: [PRReviewFleetEntry] = []
        var nextArchived: [PRReviewFleetEntry] = []
        var nextNotices: [PRReviewFleetHostNotice] = []
        for source in sources {
            guard let host = hosts[source.machineID] else { continue }
            nextActive += host.active.map {
                .init(machineID: source.machineID, machineName: source.machineName, review: $0)
            }
            nextArchived += host.archived.map {
                .init(machineID: source.machineID, machineName: source.machineName, review: $0)
            }
            if let message = host.notice {
                nextNotices.append(.init(machineID: source.machineID, machineName: source.machineName, message: message))
            }
        }
        if active != nextActive { active = nextActive }
        if archived != nextArchived { archived = nextArchived }
        if notices != nextNotices { notices = nextNotices }
    }
}
