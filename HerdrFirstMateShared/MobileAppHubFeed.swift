import Foundation
import Observation

/// One section's builds, refreshed while the section is on screen.
@MainActor @Observable
final class MobileAppHubFeed {
    struct Query: Equatable, Sendable {
        var hubURL: URL
        var bundleIDs: [String] = []
        var firstMateFeatureID: String?
        var limit = 20
    }

    private(set) var builds: [MobileAppHubBuild] = []
    private(set) var error: String?
    private(set) var hasLoaded = false
    @ObservationIgnored private var loadedQuery: Query?
    @ObservationIgnored private let sessionConfiguration: URLSessionConfiguration?

    init(builds: [MobileAppHubBuild]? = nil, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.sessionConfiguration = sessionConfiguration
        if let builds {
            self.builds = builds
            hasLoaded = true
        }
    }

    /// Shows `builds` without asking a hub: demo data and render fixtures.
    func present(_ builds: [MobileAppHubBuild]) {
        self.builds = builds
        error = nil
        hasLoaded = true
    }

    func load(_ query: Query) async {
        if loadedQuery != query {
            // A different hub or filter: never show the previous one's builds.
            builds = []
            hasLoaded = false
            error = nil
        }
        let client = MobileAppHubClient(baseURL: query.hubURL, sessionConfiguration: sessionConfiguration)
        do {
            let result = try await client.builds(
                bundleIDs: query.bundleIDs, firstMateFeatureID: query.firstMateFeatureID, limit: query.limit)
            guard !Task.isCancelled else { return }
            builds = result
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            // Keep the last good list; say why it may be stale.
            self.error = error.localizedDescription
        }
        loadedQuery = query
        hasLoaded = true
    }

    /// Loads now, then every `interval` until the calling task is cancelled.
    func poll(_ query: Query, every interval: Duration = .seconds(60)) async {
        while !Task.isCancelled {
            await load(query)
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }
}

extension MobileAppHubSettings {
    static func firstMateQuery(hubURLText: String, featureID: String) -> MobileAppHubFeed.Query? {
        hubURL(from: hubURLText).map { .init(hubURL: $0, firstMateFeatureID: featureID, limit: 50) }
    }
}

enum MobileAppHubPresentation {
    /// Where "See all" goes: the one app's page, or the hub's home.
    static func seeAllURL(_ builds: [MobileAppHubBuild], hubURL: URL) -> URL {
        let pages = Set(builds.compactMap(\.urls.appPage))
        if pages.count == 1, let page = pages.first { return page }
        return hubURL
    }

    static func isFresh(_ build: MobileAppHubBuild, now: Date = .now) -> Bool {
        now.timeIntervalSince(build.date) < 24 * 3600
    }

    /// The assignment titles, in First Mate order, that produced a build.
    static func assignmentTitles(for build: MobileAppHubBuild, featureID: String,
                                 assignments: [(id: String, title: String)]) -> [String] {
        let ids = Set(build.assignmentIDs(featureID: featureID))
        return assignments.filter { ids.contains($0.id) }.map(\.title)
    }
}
