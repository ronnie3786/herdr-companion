import Foundation
import Synchronization
import Testing
@testable import herdr_harness_ios

/// Synthetic hub and companion replies only: example hosts, bundle IDs and First Mate IDs.
private enum BuildsFixtures {
    static let hubURL = URL(string: "https://builds.example.invalid")!
    static let companionURL = "https://companion.example.invalid"
    static let featureID = "fmf_00000000000000000000000000000001"

    static func hubBuild(id: String, builtAt: String, install: String? = "itms-services://?action=download-manifest&url=https://builds.example.invalid/install/x/manifest.plist",
                         icon: String = "null") -> String {
        let installJSON = install.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(id)","app":{"name":"Receipts","bundle_id":"com.example.receipts","slug":"com.example.receipts"},
         "version":"2.4","build_number":"118","built_at":"\(builtAt)","uploaded_at":"\(builtAt)",
         "label":{"ticket":"EX-1","title":"Month export","notes":null},"source":{"machine":"build-mac","branch":"feature/ex-1"},
         "urls":{"page":"https://builds.example.invalid/builds/\(id)","app_page":null,"install":\(installJSON),
                 "ipa":"https://builds.example.invalid/files/\(id)/a.ipa","icon":\(icon)},
         "signing":{"method":"development","expires_at":"2099-01-01T00:00:00Z"},
         "herdr_contexts":[{"first_mate_feature_id":"\(featureID)","first_mate_assignment_id":"fma_tester"}]}
        """
    }

    static func hubBuilds(_ items: [String]) throws -> [MobileAppHubBuild] {
        struct Envelope: Decodable { let builds: [MobileAppHubBuild] }
        return try MobileAppHubClient.decoder.decode(Envelope.self, from: Data("{\"builds\":[\(items.joined(separator: ","))]}".utf8)).builds
    }

    static func simulatorBuild(id: String, hub: String? = nil, createdAt: String, visit: String = "fmv_qa",
                               launchable: Bool = true) -> FirstMateSimulatorBuild {
        FirstMateSimulatorBuild(id: id, featureID: featureID, name: "Receipts", checkpointID: id, checkpointLabel: "Checkpoint \(id)",
                                stageTitle: "QA", visitID: visit, assignmentID: "fma_tester", hubBuildID: hub, status: "ready",
                                launchable: launchable, createdAt: createdAt)
    }

    static func simulatorList(_ builds: [String] = []) -> String {
        """
        {"ok":true,"feature_id":"\(featureID)","simulator":{"configured":true,"state":"ready","registration_available":true,
         "preview_available":true,"policy":{"idle_shutdown_minutes":60,"max_running_previews":4},"running_previews":0},
         "builds":[\(builds.joined(separator: ","))],"selected_build_id":null}
        """
    }
}

@Suite("First Mate Builds on iOS")
struct FirstMateBuildsModelTests {
    @Test("The hub address must be http(s) with a host, no query; trailing slashes are dropped")
    func hubAddress() {
        #expect(MobileAppHubSettings.hubURL(from: " https://builds.example.invalid:8540/ ")?.absoluteString
                == "https://builds.example.invalid:8540")
        #expect(MobileAppHubSettings.hubURL(from: "https://builds.example.invalid/hub//")?.absoluteString
                == "https://builds.example.invalid/hub")
        #expect(MobileAppHubSettings.hubURL(from: "http://builds.example.invalid") != nil)
        #expect(MobileAppHubSettings.hubURL(from: "builds.example.invalid") == nil)
        #expect(MobileAppHubSettings.hubURL(from: "ftp://builds.example.invalid") == nil)
        #expect(MobileAppHubSettings.hubURL(from: "https://builds.example.invalid/?x=1") == nil)
        #expect(MobileAppHubSettings.hubURL(from: "https://builds.example.invalid/#top") == nil)
        #expect(MobileAppHubSettings.hubURL(from: "") == nil)
        #expect(MobileAppHubSettings.hubURLKey == "herdr.builds.hubURL")
        #expect(MobileAppHubSettings.firstMateQuery(hubURLText: "", featureID: "f") == nil)
        #expect(MobileAppHubSettings.firstMateQuery(hubURLText: "https://builds.example.invalid/", featureID: "f")
                == .init(hubURL: BuildsFixtures.hubURL, firstMateFeatureID: "f", limit: 50))
    }

    @Test("Hub builds keep their itms-services install link; any other install link is dropped")
    func installLinks() throws {
        let builds = try BuildsFixtures.hubBuilds([
            BuildsFixtures.hubBuild(id: "b1", builtAt: "2026-09-30T10:00:00Z"),
            BuildsFixtures.hubBuild(id: "b2", builtAt: "2026-09-30T09:00:00Z", install: "https://elsewhere.example.invalid/x"),
            BuildsFixtures.hubBuild(id: "b3", builtAt: "2026-09-30T08:00:00Z", install: nil),
        ])
        #expect(builds[0].urls.install?.scheme == "itms-services")
        #expect(builds[0].urls.ipa?.lastPathComponent == "a.ipa")
        #expect(builds[1].urls.install == nil)
        #expect(builds[2].urls.install == nil)
        #expect(builds[0].assignmentIDs(featureID: BuildsFixtures.featureID) == ["fma_tester"])
    }

    @Test("Hub builds pair with the simulator copy that names them; checkpoints stand alone; newest first")
    func merge() throws {
        let hub = try BuildsFixtures.hubBuilds([
            BuildsFixtures.hubBuild(id: "hub-new", builtAt: "2026-09-30T10:00:00Z"),
            BuildsFixtures.hubBuild(id: "hub-old", builtAt: "2026-09-30T07:00:00Z"),
        ])
        let simulator = [
            BuildsFixtures.simulatorBuild(id: "copy", hub: "hub-new", createdAt: "2026-09-30T10:01:00Z"),
            BuildsFixtures.simulatorBuild(id: "checkpoint", createdAt: "2026-09-30T08:30:00Z"),
            BuildsFixtures.simulatorBuild(id: "orphan-copy", hub: "hub-gone", createdAt: "2026-09-30T06:00:00Z"),
        ]
        let entries = FirstMateBuildEntry.merge(hub: hub, simulator: simulator)
        #expect(entries.map(\.id) == ["hub-hub-new", "simulator-checkpoint", "hub-hub-old", "simulator-orphan-copy"])
        if case .hub(_, let copy) = entries[0] { #expect(copy?.id == "copy") } else { Issue.record("expected a hub entry") }
        if case .hub(_, let copy) = entries[2] { #expect(copy == nil) } else { Issue.record("expected a hub entry") }
        // Without a hub address the card shows only the simulator builds, the copy included.
        #expect(FirstMateBuildEntry.merge(hub: [], simulator: simulator).count == 3)
    }

    @Test("Demo builds: Receipt export pairs a hub build with its copy; Review search's simulator is running")
    @MainActor
    func demo() throws {
        let receipts = try #require(FirstMateDemo.chatWindowFeatures().first { $0.feature.id == "demo-receipts" })
        let content = try #require(FirstMateBuildsDemo.content(for: receipts, machineName: "desktop"))
        #expect(content.hub.count == 2)
        #expect(content.simulator.count == 2)
        let entries = FirstMateBuildEntry.merge(hub: content.hub, simulator: content.simulator)
        #expect(entries.count == 3)
        #expect(entries.first?.id == "hub-demo-hub-receipts-118")
        #expect(content.hub.allSatisfy { $0.urls.install?.scheme == "itms-services" && $0.source.machine == "desktop" })
        let qa = try #require(receipts.visits.last { $0.stageKey == "proof" })
        #expect(content.simulator.allSatisfy { $0.visitID == qa.id && $0.launchable && $0.activePreview == nil })
        #expect(MobileAppHubPresentation.assignmentTitles(
            for: content.hub[0], featureID: receipts.feature.id,
            assignments: receipts.assignments.map { ($0.id, $0.title) }) == ["Device QA"])

        let search = try #require(FirstMateDemo.chatWindowFeatures().first { $0.feature.id == "demo-search" })
        let searchContent = try #require(FirstMateBuildsDemo.content(for: search, machineName: "desktop"))
        #expect(searchContent.simulator.first?.activePreview?.phase == "running")
        #expect(searchContent.simulator.first?.hubBuildID == searchContent.hub.first?.id)
        #expect(FirstMateBuildsDemo.screenKind(for: try #require(searchContent.simulator.first)) == .reviews)

        let other = try #require(FirstMateDemo.chatWindowFeatures().first { $0.feature.id == "demo-widgets" })
        #expect(FirstMateBuildsDemo.content(for: other, machineName: "desktop") == nil)
    }
}

@Suite("First Mate Builds feed and simulator routes on iOS", .serialized)
@MainActor
struct FirstMateBuildsFeedTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BuildsURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client() -> HerdrAPIClient {
        HerdrAPIClient(configuration: ServerConfiguration(urlString: BuildsFixtures.companionURL, token: "synthetic-token")!,
                       session: session())
    }

    @Test("The client's simulator routes use its address, credential and session; the stream upgrades to wss")
    func clientRoutes() async throws {
        BuildsURLProtocol.reset([
            "GET /api/v1/first-mate/features/\(BuildsFixtures.featureID)/simulator-builds": (200, BuildsFixtures.simulatorList()),
        ])
        let client = client()
        let list = try await client.fetchSimulatorBuilds(featureID: BuildsFixtures.featureID)
        #expect(list.simulator.canWatch)
        let sent = BuildsURLProtocol.requests()
        #expect(sent.map(\.path) == ["/api/v1/first-mate/features/\(BuildsFixtures.featureID)/simulator-builds"])
        #expect(sent.first?.authorization == "Bearer synthetic-token")
        #expect(sent.first?.timeout == 20)

        let stream = try client.simulatorStreamRequest(featureID: BuildsFixtures.featureID, previewID: "fmsp_0123456789abcdef")
        #expect(stream.url?.scheme == "wss")
        #expect(stream.url?.path == "/api/v1/first-mate/features/\(BuildsFixtures.featureID)/simulator-previews/fmsp_0123456789abcdef/stream")
        #expect(stream.url?.query == nil)
        #expect(stream.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        #expect(throws: FirstMateSimulatorError.self) {
            try client.simulatorStreamRequest(featureID: "../x", previewID: "p")
        }
    }

    @Test("Several watchers share one schedule: the hub loads once a minute, at once for a new address")
    func dedupedRefresh() async throws {
        BuildsURLProtocol.reset([
            "GET /api/v1/builds": (200, "{\"builds\":[\(BuildsFixtures.hubBuild(id: "b1", builtAt: "2026-09-30T10:00:00Z"))]}"),
            "GET /api/v1/first-mate/features/\(BuildsFixtures.featureID)/simulator-builds":
                (200, BuildsFixtures.simulatorList()),
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BuildsURLProtocol.self]
        let client = client()
        let simulator = FirstMateSimulatorFeed(machineID: "machine-1", featureID: BuildsFixtures.featureID, api: { client.simulatorPreviews })
        let feed = FirstMateBuildsFeed(target: FirstMateFeatureTarget(machineID: "machine-1", featureID: BuildsFixtures.featureID),
                                       hub: MobileAppHubFeed(sessionConfiguration: configuration), simulator: simulator)
        let query = MobileAppHubFeed.Query(hubURL: BuildsFixtures.hubURL, firstMateFeatureID: BuildsFixtures.featureID, limit: 50)
        let start = ContinuousClock.now
        async let first: Void = feed.refreshDue(hubQuery: query, now: start)
        async let second: Void = feed.refreshDue(hubQuery: query, now: start)
        _ = await (first, second)
        #expect(feed.hub.builds.map(\.id) == ["b1"])
        #expect(BuildsURLProtocol.requests().filter { $0.path == "/api/v1/builds" }.count == 1)
        #expect(BuildsURLProtocol.requests().filter { $0.path.hasSuffix("/simulator-builds") }.count == 1)
        let hubRequest = try #require(BuildsURLProtocol.requests().first { $0.path == "/api/v1/builds" })
        #expect(hubRequest.query?.contains("first_mate_feature=\(BuildsFixtures.featureID)") == true)
        #expect(hubRequest.query?.contains("limit=50") == true)

        await feed.refreshDue(hubQuery: query, now: start + .seconds(30))
        #expect(BuildsURLProtocol.requests().filter { $0.path == "/api/v1/builds" }.count == 1)
        await feed.refreshDue(hubQuery: query, now: start + .seconds(61))
        #expect(BuildsURLProtocol.requests().filter { $0.path == "/api/v1/builds" }.count == 2)
        let other = MobileAppHubFeed.Query(hubURL: URL(string: "https://hub2.example.invalid")!, firstMateFeatureID: BuildsFixtures.featureID, limit: 50)
        await feed.refreshDue(hubQuery: other, now: start + .seconds(62))
        #expect(BuildsURLProtocol.requests().filter { $0.path == "/api/v1/builds" }.count == 3)
        // No hub address: only the simulator feed is asked, when it is due.
        BuildsURLProtocol.reset(["GET /api/v1/first-mate/features/\(BuildsFixtures.featureID)/simulator-builds": (200, BuildsFixtures.simulatorList())])
        feed.refreshSimulatorSoon()
        await feed.refreshDue(hubQuery: nil)
        #expect(BuildsURLProtocol.requests().map(\.path) == ["/api/v1/first-mate/features/\(BuildsFixtures.featureID)/simulator-builds"])
    }

    @Test("Demo feeds fetch nothing")
    func demoFeed() async throws {
        BuildsURLProtocol.reset([:])
        let receipts = try #require(FirstMateDemo.chatWindowFeatures().first { $0.feature.id == "demo-receipts" })
        let content = try #require(FirstMateBuildsDemo.content(for: receipts, machineName: "desktop"))
        let client = client()
        let feed = FirstMateBuildsFeed(target: FirstMateFeatureTarget(machineID: "demo1", featureID: "demo-receipts"),
                                       simulator: FirstMateSimulatorFeed(machineID: "demo1", featureID: "demo-receipts", api: { client.simulatorPreviews }))
        feed.presentDemo(content)
        await feed.refreshDue(hubQuery: .init(hubURL: BuildsFixtures.hubURL, firstMateFeatureID: "demo-receipts"))
        #expect(feed.isDemo)
        #expect(feed.hub.builds.count == 2)
        #expect(feed.simulator.builds(forVisit: content.simulator[0].visitID ?? "").count == 2)
        #expect(BuildsURLProtocol.requests().isEmpty)
    }

    @Test("The demo simulator boots, runs, stops and starts again without a companion")
    func demoSession() throws {
        let search = try #require(FirstMateDemo.chatWindowFeatures().first { $0.feature.id == "demo-search" })
        let build = try #require(FirstMateBuildsDemo.content(for: search, machineName: "desktop")?.simulator.first)
        let session = FirstMateSimulatorSession(
            target: FirstMateSimulatorWindowTarget(machineID: "demo1", featureID: "demo-search", buildID: build.id),
            machineName: "desktop", api: nil, isDemo: true)
        session.presentDemo(build: build, feature: nil, screen: nil, startingAt: "booting")
        #expect(session.phase == .starting)
        #expect(session.demoFrame == nil)
        #expect(session.build?.id == build.id)
        session.presentDemoStarting(at: "installing")
        #expect(session.demoFrame != nil)
        session.presentDemoRunning()
        #expect(session.phase == .running)
        #expect(session.browserURL?.host == "simportal.example.invalid")
    }

    @Test("Stop and Start Again in demo mode")
    func demoStopStart() async throws {
        let session = FirstMateSimulatorSession(
            target: FirstMateSimulatorWindowTarget(machineID: "demo1", featureID: "demo-receipts", buildID: "demo-build-3"),
            machineName: "desktop", api: nil, isDemo: true)
        #expect(session.phase == .running)
        await session.stop()
        #expect(session.phase == .stopped)
        #expect(session.preview?.stopReason == "user")
        #expect(!session.simulatorDeleted)
        await session.startAgain()
        #expect(session.phase == .running)
        #expect(session.demoFrame != nil)
    }
}

/// Canned replies keyed by "METHOD path"; records what was sent.
private final class BuildsURLProtocol: URLProtocol {
    struct Sent: Sendable {
        let method: String
        let path: String
        let query: String?
        let authorization: String?
        let timeout: TimeInterval
    }

    struct State: Sendable {
        var replies: [String: (Int, String)] = [:]
        var sent: [Sent] = []
    }

    static let state = Mutex(State())

    static func reset(_ replies: [String: (Int, String)]) {
        state.withLock { $0 = State(replies: replies) }
    }

    static func requests() -> [Sent] { state.withLock { $0.sent } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let method = request.httpMethod ?? "GET"
        let reply = Self.state.withLock { state -> (Int, String) in
            state.sent.append(Sent(method: method, path: url.path, query: url.query,
                                   authorization: request.value(forHTTPHeaderField: "Authorization"),
                                   timeout: request.timeoutInterval))
            return state.replies["\(method) \(url.path)"] ?? (404, #"{"ok":false,"error":{"code":"not_found","message":"No such route"}}"#)
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
