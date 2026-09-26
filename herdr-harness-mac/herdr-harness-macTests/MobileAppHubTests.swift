import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Synthetic hub responses only: example hosts, bundle IDs, and First Mate IDs.
enum MobileAppHubFixtures {
    static let hubURL = URL(string: "https://builds.example.invalid")!

    static func buildJSON(id: String, app: String = "Example App", bundleID: String = "org.example.app",
                          version: String = "2.4.0", build: String = "118", builtAt: String = "2026-09-25T14:00:00Z",
                          ticket: String? = "EX-42", title: String? = "Offline reading list",
                          contexts: String? = nil, expiresAt: String = "2027-09-01T00:00:00Z") -> String {
        let ticketJSON = ticket.map { "\"\($0)\"" } ?? "null"
        let titleJSON = title.map { "\"\($0)\"" } ?? "null"
        let contextsJSON = contexts.map { ",\"herdr_contexts\":\($0)" } ?? ""
        return """
        {"id":"\(id)","app":{"name":"\(app)","bundle_id":"\(bundleID)","slug":"\(bundleID)"},
         "version":"\(version)","build_number":"\(build)","built_at":"\(builtAt)","uploaded_at":"2026-09-25T15:00:00Z",
         "label":{"ticket":\(ticketJSON),"title":\(titleJSON),"notes":null},
         "source":{"machine":"build-mac","branch":"feature/ex-42-reading-list","commit":"abc1234"},
         "urls":{"page":"https://builds.example.invalid/builds/\(id)","app_page":"https://builds.example.invalid/apps/\(bundleID)",
                 "install":"itms-services://?action=download-manifest","ipa":"https://builds.example.invalid/files/\(id)/a.ipa","icon":null},
         "signing":{"method":"development","expires_at":"\(expiresAt)"}\(contextsJSON)}
        """
    }

    static func builds(_ items: [String]) throws -> [MobileAppHubBuild] {
        let data = Data("{\"builds\":[\(items.joined(separator: ","))]}".utf8)
        struct Envelope: Decodable { let builds: [MobileAppHubBuild] }
        return try MobileAppHubClient.decoder.decode(Envelope.self, from: data).builds
    }
}

@Suite("Mobile App Hub")
struct MobileAppHubTests {
    @Test("Hub address must be http(s) with a host; trailing slashes are dropped")
    func hubURL() {
        #expect(MobileAppHubSettings.hubURL(from: " https://builds.example.invalid:8540/ ")?.absoluteString
                == "https://builds.example.invalid:8540")
        #expect(MobileAppHubSettings.hubURL(from: "builds.example.invalid") == nil)
        #expect(MobileAppHubSettings.hubURL(from: "ftp://builds.example.invalid") == nil)
        #expect(MobileAppHubSettings.hubURL(from: "https://builds.example.invalid/?x=1") == nil)
        #expect(MobileAppHubSettings.hubURL(from: "") == nil)
    }

    @Test("Dashboard apps split on commas and whitespace, without duplicates")
    func bundleIDs() {
        #expect(MobileAppHubSettings.bundleIDs(from: "org.example.app, org.example.beta\norg.example.app")
                == ["org.example.app", "org.example.beta"])
        #expect(MobileAppHubSettings.dashboardQuery(hubURLText: "https://builds.example.invalid", bundleIDsText: " ") == nil)
        #expect(MobileAppHubSettings.dashboardQuery(hubURLText: "", bundleIDsText: "org.example.app") == nil)
    }

    @Test("Builds decode with and without First Mate links")
    func decoding() throws {
        let builds = try MobileAppHubFixtures.builds([
            MobileAppHubFixtures.buildJSON(id: "b1", contexts: #"[{"first_mate_feature_id":"fmf_one","first_mate_assignment_id":"fma_a","first_mate_role":"worker"}]"#),
            MobileAppHubFixtures.buildJSON(id: "b2", ticket: nil, title: nil),
        ])
        #expect(builds[0].assignmentIDs(featureID: "fmf_one") == ["fma_a"])
        #expect(builds[0].assignmentIDs(featureID: "fmf_other").isEmpty)
        #expect(builds[1].herdrContexts.isEmpty)
        #expect(builds[1].title == "feature/ex-42-reading-list")
        #expect(builds[0].versionLabel == "2.4.0 (118)")
        #expect(builds[0].date == ISO8601DateFormatter().date(from: "2026-09-25T14:00:00Z"))
    }

    @Test("Search matches ticket, feature, app, and version; Focus mode keeps the last day")
    func dashboardRows() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z"))
        let builds = try MobileAppHubFixtures.builds([
            MobileAppHubFixtures.buildJSON(id: "new", builtAt: "2026-09-26T09:00:00Z"),
            MobileAppHubFixtures.buildJSON(id: "old", build: "90", builtAt: "2026-09-20T09:00:00Z", ticket: "EX-7", title: "Dark mode"),
        ])
        #expect(MobileAppHubPresentation.dashboardRows(builds, query: "", focusMode: false, now: now).map(\.id) == ["new", "old"])
        #expect(MobileAppHubPresentation.dashboardRows(builds, query: "", focusMode: true, now: now).map(\.id) == ["new"])
        #expect(MobileAppHubPresentation.dashboardRows(builds, query: "ex-7", focusMode: false, now: now).map(\.id) == ["old"])
        #expect(MobileAppHubPresentation.dashboardRows(builds, query: "(90)", focusMode: false, now: now).map(\.id) == ["old"])
        #expect(MobileAppHubPresentation.dashboardTitle(builds) == "Example App builds")
        #expect(MobileAppHubPresentation.seeAllURL(builds, hubURL: MobileAppHubFixtures.hubURL).absoluteString
                == "https://builds.example.invalid/apps/org.example.app")
        let mixed = try MobileAppHubFixtures.builds([
            MobileAppHubFixtures.buildJSON(id: "a"),
            MobileAppHubFixtures.buildJSON(id: "b", app: "Other", bundleID: "org.example.other"),
        ])
        #expect(MobileAppHubPresentation.dashboardTitle(mixed) == "Builds")
        #expect(MobileAppHubPresentation.seeAllURL(mixed, hubURL: MobileAppHubFixtures.hubURL) == MobileAppHubFixtures.hubURL)
    }

    @Test("A build names the First Mate assignments that produced it, in First Mate order")
    func assignmentTitles() throws {
        let build = try #require(try MobileAppHubFixtures.builds([
            MobileAppHubFixtures.buildJSON(id: "b", contexts: #"[{"first_mate_feature_id":"fmf_one","first_mate_assignment_id":"fma_b"},{"first_mate_feature_id":"fmf_one","first_mate_assignment_id":"fma_a"},{"first_mate_feature_id":"fmf_two","first_mate_assignment_id":"fma_c"}]"#),
        ]).first)
        let assignments = [(id: "fma_a", title: "Build the list"), (id: "fma_b", title: "Polish"), (id: "fma_c", title: "Elsewhere")]
        #expect(MobileAppHubPresentation.assignmentTitles(for: build, featureID: "fmf_one", assignments: assignments)
                == ["Build the list", "Polish"])
    }
}

@Suite("Mobile App Hub client", .serialized)
struct MobileAppHubClientTests {
    @Test("Requests carry the app and First Mate filters and decode the reply")
    func request() async throws {
        HubURLProtocol.state.withLock { $0 = .init(status: 200, body: "{\"builds\":[\(MobileAppHubFixtures.buildJSON(id: "b1"))]}") }
        let builds = try await client().builds(bundleIDs: ["org.example.app", "org.example.beta"], firstMateFeatureID: "fmf_one", limit: 5)
        #expect(builds.map(\.id) == ["b1"])
        let url = try #require(HubURLProtocol.state.withLock { $0.lastURL })
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path == "/api/v1/builds")
        #expect(items.contains(URLQueryItem(name: "bundle_id", value: "org.example.app,org.example.beta")))
        #expect(items.contains(URLQueryItem(name: "first_mate_feature", value: "fmf_one")))
        #expect(items.contains(URLQueryItem(name: "limit", value: "5")))
    }

    @Test("Server errors surface, and a feed keeps its last good builds")
    @MainActor
    func errorsKeepLastGoodBuilds() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HubURLProtocol.self]
        let feed = MobileAppHubFeed(sessionConfiguration: configuration)
        let query = MobileAppHubFeed.Query(hubURL: MobileAppHubFixtures.hubURL, firstMateFeatureID: "fmf_one")
        HubURLProtocol.state.withLock { $0 = .init(status: 200, body: "{\"builds\":[\(MobileAppHubFixtures.buildJSON(id: "b1"))]}") }
        await feed.load(query)
        #expect(feed.builds.map(\.id) == ["b1"])
        HubURLProtocol.state.withLock { $0 = .init(status: 500, body: "{}") }
        await feed.load(query)
        #expect(feed.builds.map(\.id) == ["b1"])
        #expect(feed.error != nil)
        // A different First Mate never shows the previous one's builds.
        await feed.load(MobileAppHubFeed.Query(hubURL: MobileAppHubFixtures.hubURL, firstMateFeatureID: "fmf_two"))
        #expect(feed.builds.isEmpty)
    }

    private func client() -> MobileAppHubClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HubURLProtocol.self]
        return MobileAppHubClient(baseURL: MobileAppHubFixtures.hubURL, sessionConfiguration: configuration)
    }
}

private final class HubURLProtocol: URLProtocol {
    struct State: Sendable {
        var status = 200
        var body = "{}"
        var lastURL: URL?
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.state.withLock { state -> State in
            state.lastURL = url
            return state
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Mobile App Hub renders", .serialized)
@MainActor
struct MobileAppHubRenderTests {
    @Test("Dashboard card and First Mate Overview section")
    func sections() async throws {
        let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600))
        let builds = try MobileAppHubFixtures.builds([
            MobileAppHubFixtures.buildJSON(id: "b3", build: "120", builtAt: now, ticket: "EX-44", title: "Share sheet for saved articles",
                                           contexts: #"[{"first_mate_feature_id":"fmf_demo","first_mate_assignment_id":"fma_share"}]"#),
            MobileAppHubFixtures.buildJSON(id: "b2", build: "119", builtAt: "2026-09-24T10:00:00Z",
                                           contexts: #"[{"first_mate_feature_id":"fmf_demo","first_mate_assignment_id":"fma_list"}]"#),
            MobileAppHubFixtures.buildJSON(id: "b1", version: "2.3.9", build: "101", builtAt: "2025-01-10T10:00:00Z", ticket: nil,
                                           title: "Launch screen refresh", expiresAt: "2025-06-01T00:00:00Z"),
        ])
        let query = MobileAppHubFeed.Query(hubURL: MobileAppHubFixtures.hubURL, bundleIDs: ["org.example.app"])
        let dashboard = DashboardState(defaults: UserDefaults(suiteName: "MobileAppHubRender.\(UUID())")!)
        dashboard.builds.present(builds)
        let card = try await HerdrRenderHarness.render("dashboard-builds.png", size: CGSize(width: 1100, height: 260)) {
            DashboardBuildsSection(dashboard: dashboard, query: query)
                .padding(.vertical, 20)
                .background(HerdrTheme.graphite)
                .foregroundStyle(HerdrTheme.text)
        }
        card.expectSubstantial()

        let feed = MobileAppHubFeed(builds: Array(builds.prefix(2)))
        for scheme in [ColorScheme.light, .dark] {
            let section = try await HerdrRenderHarness.render("first-mate-builds-\(scheme == .dark ? "dark" : "light").png",
                                                              size: CGSize(width: 640, height: 260)) {
                FirstMateBuildsSection(featureID: "fmf_demo",
                                       assignments: [("fma_list", "Reading list screen"), ("fma_share", "Share sheet")],
                                       feed: feed, query: MobileAppHubFeed.Query(hubURL: MobileAppHubFixtures.hubURL, firstMateFeatureID: "fmf_demo"))
                    .padding(20)
                    .background(FirstMatePalette(scheme: scheme).background)
                    .environment(\.colorScheme, scheme)
            }
            section.expectSubstantial()
        }
    }
}
