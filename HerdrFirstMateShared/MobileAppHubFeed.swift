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
    static func dashboardQuery(hubURLText: String, bundleIDsText: String) -> MobileAppHubFeed.Query? {
        guard let hubURL = hubURL(from: hubURLText) else { return nil }
        let ids = bundleIDs(from: bundleIDsText)
        guard !ids.isEmpty else { return nil }
        return .init(hubURL: hubURL, bundleIDs: ids, limit: 40)
    }

    static func firstMateQuery(hubURLText: String, featureID: String) -> MobileAppHubFeed.Query? {
        hubURL(from: hubURLText).map { .init(hubURL: $0, firstMateFeatureID: featureID, limit: 50) }
    }
}

enum MobileAppHubPresentation {
    /// Dashboard search matches the same words a person would type for a build:
    /// ticket, feature, app, version, or branch. Focus mode keeps the last day.
    static func dashboardRows(_ builds: [MobileAppHubBuild], query: String, focusMode: Bool,
                              now: Date = .now, limit: Int = 5) -> [MobileAppHubBuild] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = builds.filter { build in
            if focusMode, now.timeIntervalSince(build.date) > 24 * 3600 { return false }
            guard !needle.isEmpty else { return true }
            return [build.label.ticket, build.label.title, build.app.name, build.versionLabel, build.source.branch]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(needle) }
        }
        return Array(filtered.prefix(limit))
    }

    /// "Doximity builds" when every build is one app, otherwise "Builds".
    static func dashboardTitle(_ builds: [MobileAppHubBuild]) -> String {
        let names = Set(builds.map(\.app.name))
        if names.count == 1, let name = names.first { return "\(name) builds" }
        return "Builds"
    }

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
