import Foundation
import Observation

/// Shared, machine/review/document-scoped state for downloaded PR Review
/// documents.
///
/// The main rail, each popped-out review window, and each retained document
/// window can all display or download the same review document, so download
/// phases and cache protection cannot live in one presentation store:
///
/// - A download started in a document window publishes `.ready` back to the
///   Context rail that offered Open and Reveal in Finder, and that rail sees
///   the status without retargeting the document window's transport.
/// - Cache protection is owned by window-lifetime leases instead of one
///   store's private set, so opening a second document at the retention limit
///   cannot evict a file another window is still displaying.
///
/// Phases are retained after a window closes so the originating rail can still
/// reveal a cached file. `cleanup(additionallyProtecting:)` forgets a ready
/// phase whose cached file retention removes, so a row never advertises a file
/// that is gone.
@MainActor
@Observable
final class PRReviewDocumentResources {
    /// The immutable identity of one downloaded document. Titles, filenames,
    /// and pull request numbers are presentation, not identity.
    struct Scope: Hashable, Sendable {
        let machineID: String
        let reviewID: String
        let documentID: String
    }

    let cache: PRReviewDocumentCache

    @ObservationIgnored private var leases: [URL: Int] = [:]

    /// Tracked so a Context rail observing `PRReviewStore.documentPhases`
    /// re-renders when any window publishes a phase for its review.
    private(set) var phases: [Scope: PRReviewStore.PRReviewDocumentPhase] = [:]

    init(cache: PRReviewDocumentCache = PRReviewDocumentCache()) {
        self.cache = cache
    }

    func scope(machineID: String, reviewID: String, documentID: String) -> Scope {
        Scope(machineID: machineID, reviewID: reviewID, documentID: documentID)
    }

    func phase(for scope: Scope) -> PRReviewStore.PRReviewDocumentPhase {
        phases[scope] ?? .idle
    }

    /// The phases one presentation store shows, keyed by document id for the
    /// Context rail. Scoping by machine and review keeps two hosts that both
    /// call a review `prr_1` from sharing any download state.
    func phases(machineID: String, reviewID: String) -> [String: PRReviewStore.PRReviewDocumentPhase] {
        var result: [String: PRReviewStore.PRReviewDocumentPhase] = [:]
        for (scope, phase) in phases where scope.machineID == machineID && scope.reviewID == reviewID {
            result[scope.documentID] = phase
        }
        return result
    }

    func setPhase(_ phase: PRReviewStore.PRReviewDocumentPhase, for scope: Scope) {
        phases[scope] = phase
    }

    /// The URLs a displayed document window currently protects from cleanup.
    var protectedURLs: Set<URL> {
        Set(leases.keys)
    }

    func acquireLease(for url: URL) {
        leases[url.standardizedFileURL, default: 0] += 1
    }

    func releaseLease(for url: URL) {
        let key = url.standardizedFileURL
        guard let count = leases[key] else { return }
        if count <= 1 {
            leases[key] = nil
        } else {
            leases[key] = count - 1
        }
    }

    /// Runs retention cleanup while protecting every displayed file plus any
    /// destination a caller just installed but has not leased yet.
    @discardableResult
    func cleanup(additionallyProtecting additionalURLs: Set<URL> = []) throws -> PRReviewDocumentCache.CleanupReport {
        let protected = protectedURLs.union(additionalURLs.map(\.standardizedFileURL))
        let report = try cache.cleanup(protecting: protected)
        forgetEvictedPhases(removedPaths: Set(report.removedPaths))
        return report
    }

    private func forgetEvictedPhases(removedPaths: Set<String>) {
        guard !removedPaths.isEmpty else { return }
        let evicted = phases.compactMap { entry -> Scope? in
            guard case let .ready(url) = entry.value,
                  removedPaths.contains(url.standardizedFileURL.path)
            else { return nil }
            return entry.key
        }
        for scope in evicted {
            phases[scope] = nil
        }
    }
}

/// A window-lifetime cache protection for one displayed document.
///
/// Acquisition and release are reference counted inside
/// `PRReviewDocumentResources`, so two windows showing the same cached file
/// release independently and only the last release makes it evictable again.
@MainActor
final class PRReviewDocumentLease {
    let url: URL
    private var onRelease: (() -> Void)?

    init(url: URL, onRelease: @escaping () -> Void) {
        self.url = url
        self.onRelease = onRelease
    }

    func release() {
        onRelease?()
        onRelease = nil
    }
}
