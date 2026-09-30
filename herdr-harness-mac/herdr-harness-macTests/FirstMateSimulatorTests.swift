import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Synthetic companion responses in the shape of docs/first-mate/simulator-previews.md.
enum FirstMateSimulatorFixtures {
    static let baseURL = "https://companion.example.invalid"
    static let featureID = "fmf_00000000000000000000000000000001"
    static let buildID = "11111111-2222-4333-8444-555555555555"
    static let previewID = "fmsp_0123456789abcdef0123456789abcdef"

    static func status(state: String = "ready") -> String {
        """
        {"configured":true,"state":"\(state)","reason":null,"server_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
         "pinned_server_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","registration_available":true,"registration_reason":null,
         "preview_available":true,"storage":{"free_bytes":90000000000,"min_free_bytes":20000000000,"admission_allowed":true,"observed_at":"2026-09-29T10:00:00Z"},
         "toolchain":{"xcode":"26.2"},"default_device":{"device_type":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
         "device_type_name":"iPhone 17 Pro","runtime":"com.apple.CoreSimulator.SimRuntime.iOS-26-2","runtime_name":"iOS 26.2"},
         "policy":{"idle_shutdown_minutes":60,"max_running_previews":4},"running_previews":1,"checked_at":"2026-09-29T10:00:00Z"}
        """
    }

    static func preview(phase: String = "running", status: String = "ready", stream: Bool = true, step: String = "checking_stream",
                        id: String = previewID) -> String {
        """
        {"id":"\(id)","feature_id":"\(featureID)","build_id":"\(buildID)","portal_id":"99999999-8888-4777-8666-555555555555",
         "phase":"\(phase)","status":"\(status)","device":{"device_type":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
         "runtime":"com.apple.CoreSimulator.SimRuntime.iOS-26-2","device_type_name":"iPhone 17 Pro","runtime_name":"iOS 26.2"},
         "stop_reason":null,"last_active_at":"2026-09-29T10:00:00Z","created_at":"2026-09-29T09:58:00Z","updated_at":"2026-09-29T10:00:00Z",
         "udid":"ABCDEF01-2345-4789-ABCD-EF0123456789","stream_available":\(stream),
         "operation":{"id":"op-1","kind":"start","status":"running","step":"\(step)","steps":[{"name":"validating","state":"succeeded"},
           {"name":"booting","state":"succeeded"},{"name":"installing","state":"running"}],"error":null,"sequence":4,"updated_at":null,"udid":null},
         "observation":{"device_state":"Booted","viewer_count":1,"helper_ready":true,"last_frame_at":null,"observed_at":null},
         "error":null,"browser_links":{"local":null,"tailnet":"https://simportal.example.invalid:8531/d/ABCDEF01-2345-4789-ABCD-EF0123456789"},
         "idle":{"shutdown_after_minutes":60,"shutdown_at":null,"watchers":1}}
        """
    }

    static func build(id: String = buildID, status: String = "ready", launchable: Bool = true, hub: String? = nil,
                      visit: String? = "fmv_00000000000000000000000000000002", previews: String = "[]",
                      createdAt: String = "2026-09-29T09:00:00Z") -> String {
        """
        {"id":"\(id)","feature_id":"\(featureID)","server_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Receipts · Round 1",
         "checkpoint_id":"fma_00000000000000000000000000000003","checkpoint_label":"Round 1: receipt capture","stage_title":"Implementation",
         "visit_id":\(visit.map { "\"\($0)\"" } ?? "null"),"assignment_id":"fma_00000000000000000000000000000003","native_session_id":"native-1",
         "hub_build_id":\(hub.map { "\"\($0)\"" } ?? "null"),"origin":"agent","status":"\(status)","status_detail":null,
         "app":{"name":"Receipts","bundle_id":"com.example.receipts","version":"1.4","build":"212","minimum_os":"18.0"},
         "digest":"sha256:aaaa","bytes":4096,"source":{"revision":"4f1c2d9e7b3a","working_tree":"clean","configuration":"Debug","target":"Receipts"},
         "error":null,"launchable":\(launchable),"created_at":"\(createdAt)","updated_at":"\(createdAt)","previews":\(previews)}
        """
    }

    static func list(_ builds: [String]) -> String {
        "{\"ok\":true,\"feature_id\":\"\(featureID)\",\"simulator\":\(status()),\"builds\":[\(builds.joined(separator: ","))],\"selected_build_id\":null,\"generated_at\":\"2026-09-29T10:00:00Z\"}"
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}

@Suite("First Mate simulator models")
struct FirstMateSimulatorModelTests {
    @Test("Build lists decode, and only an explicit launchable opens a simulator")
    func decoding() throws {
        let list = try FirstMateSimulatorFixtures.decode(FirstMateSimulatorBuildList.self, FirstMateSimulatorFixtures.list([
            FirstMateSimulatorFixtures.build(previews: "[\(FirstMateSimulatorFixtures.preview())]"),
            FirstMateSimulatorFixtures.build(id: "22222222-2222-4333-8444-555555555555", status: "registering", launchable: false),
        ]))
        #expect(list.simulator.canWatch)
        #expect(list.simulator.policy?.idleShutdownMinutes == 60)
        #expect(list.simulator.policy?.maxRunningPreviews == 4)
        #expect(list.simulator.defaultDevice?.label == "iPhone 17 Pro · iOS 26.2")
        let first = try #require(list.builds.first)
        #expect(first.launchable)
        #expect(first.appLabel == "Receipts 1.4 (212)")
        #expect(first.activePreview?.streamAvailable == true)
        #expect(first.unavailableReason == nil)
        #expect(list.builds[1].unavailableReason == "Saving to SimPortal…")
        let missing = try FirstMateSimulatorFixtures.decode(FirstMateSimulatorBuild.self,
            #"{"id":"x","feature_id":"f","status":"somethingNew"}"#)
        #expect(!missing.launchable)
        #expect(missing.unavailableReason == "Not available (somethingNew)")
    }

    @Test("Refusals keep their code and the running previews that filled the cap")
    func errors() {
        let body = Data(#"{"ok":false,"error":{"code":"simulator_capacity","message":"2 Herdr simulators are running and in use.","details":{"running":[\#(FirstMateSimulatorFixtures.preview())]}}}"#.utf8)
        let error = FirstMateSimulatorAPI.error(status: 409, data: body)
        #expect(error.code == "simulator_capacity")
        #expect(error.running.count == 1)
        #expect(error.isDefinite)
        let missing = FirstMateSimulatorAPI.error(status: 404, data: Data("{}".utf8))
        #expect(missing.message.contains("Update the companion"))
        #expect(!FirstMateSimulatorAPI.error(status: 503, data: Data()).isDefinite)
    }

    @Test("Identifiers are plain tokens; anything else never reaches a URL")
    func identifiers() {
        #expect(FirstMateSimulatorAPI.isIdentifier(FirstMateSimulatorFixtures.previewID))
        #expect(FirstMateSimulatorAPI.isIdentifier(FirstMateSimulatorFixtures.buildID))
        #expect(!FirstMateSimulatorAPI.isIdentifier("../stream"))
        #expect(!FirstMateSimulatorAPI.isIdentifier("a b"))
        #expect(!FirstMateSimulatorAPI.isIdentifier(""))
        #expect(FirstMateSimulatorStepText.title(for: "creating_simulator") == "Creating the simulator")
        #expect(FirstMateSimulatorStepText.title(for: "new_step") == "New Step")
    }

    @Test("Idle windows read as people say them")
    func policyText() {
        #expect(FirstMateSimulatorPolicyText.duration(minutes: 60) == "an hour")
        #expect(FirstMateSimulatorPolicyText.duration(minutes: 60, short: true) == "1 hr")
        #expect(FirstMateSimulatorPolicyText.duration(minutes: 120) == "2 hours")
        #expect(FirstMateSimulatorPolicyText.duration(minutes: 90) == "90 minutes")
        #expect(FirstMateSimulatorPolicyText.duration(minutes: 20, short: true) == "20 min")
    }

    @Test("Builds merge hub builds with their simulator copies, newest first")
    func entries() throws {
        let hub = try MobileAppHubFixtures.builds([
            MobileAppHubFixtures.buildJSON(id: "hub-2", builtAt: "2026-09-29T11:00:00Z"),
            MobileAppHubFixtures.buildJSON(id: "hub-1", builtAt: "2026-09-29T08:00:00Z"),
        ])
        let simulator = try [
            FirstMateSimulatorFixtures.build(hub: "hub-2", createdAt: "2026-09-29T11:00:05Z"),
            FirstMateSimulatorFixtures.build(id: "33333333-2222-4333-8444-555555555555", createdAt: "2026-09-29T09:00:00Z"),
        ].map { try FirstMateSimulatorFixtures.decode(FirstMateSimulatorBuild.self, $0) }
        let entries = FirstMateBuildEntry.merge(hub: hub, simulator: simulator)
        #expect(entries.map(\.id) == ["hub-hub-2", "simulator-33333333-2222-4333-8444-555555555555", "hub-hub-1"])
        if case .hub(_, let linked) = entries[0] { #expect(linked?.id == FirstMateSimulatorFixtures.buildID) } else { Issue.record("expected a hub entry") }
        if case .hub(_, let linked) = entries[2] { #expect(linked == nil) } else { Issue.record("expected a hub entry") }
        #expect(FirstMateBuildEntry.merge(hub: [], simulator: []).isEmpty)
    }
}

@Suite("First Mate simulator API", .serialized)
struct FirstMateSimulatorAPITests {
    @Test("Requests use the feature's routes, carry the credential in a header, and decode replies")
    func requests() async throws {
        SimulatorURLProtocol.reset(["GET /api/v1/first-mate/features/\(FirstMateSimulatorFixtures.featureID)/simulator-builds":
                                        (200, FirstMateSimulatorFixtures.list([FirstMateSimulatorFixtures.build()])),
                                    "POST /api/v1/first-mate/features/\(FirstMateSimulatorFixtures.featureID)/simulator-builds/\(FirstMateSimulatorFixtures.buildID)/preview":
                                        (200, "{\"ok\":true,\"preview\":\(FirstMateSimulatorFixtures.preview(phase: "starting", status: "booting")),\"reused\":false,\"stopped_to_make_room\":[]}")])
        let api = SimulatorURLProtocol.api()
        let list = try await api.builds(featureID: FirstMateSimulatorFixtures.featureID)
        #expect(list.builds.count == 1)
        let opened = try await api.open(featureID: FirstMateSimulatorFixtures.featureID, buildID: FirstMateSimulatorFixtures.buildID, requestID: "request-1")
        #expect(opened.preview.phase == "starting")
        let requests = SimulatorURLProtocol.requests()
        #expect(requests.map(\.authorization) == ["Bearer synthetic-token", "Bearer synthetic-token"])
        #expect(requests.last?.body == ["request_id": "request-1"])
        let stream = try api.streamRequest(featureID: FirstMateSimulatorFixtures.featureID, previewID: FirstMateSimulatorFixtures.previewID)
        #expect(stream.url?.absoluteString == "wss://companion.example.invalid/api/v1/first-mate/features/\(FirstMateSimulatorFixtures.featureID)/simulator-previews/\(FirstMateSimulatorFixtures.previewID)/stream")
        #expect(stream.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        #expect(!(stream.url?.absoluteString.contains("token") ?? true))
        let local = FirstMateSimulatorAPI(configuration: try #require(ServerConfiguration(urlString: "http://127.0.0.1:9092", token: "t")))
        #expect(try local.streamRequest(featureID: "f", previewID: "p").url?.scheme == "ws")
        #expect(local.isLocal)
        #expect(!api.isLocal)
        await #expect(throws: FirstMateSimulatorError.self) {
            try await api.preview(featureID: FirstMateSimulatorFixtures.featureID, previewID: "../x")
        }
    }
}

@Suite("First Mate simulator window session", .serialized)
@MainActor
struct FirstMateSimulatorSessionTests {
    private let target = FirstMateSimulatorWindowTarget(machineID: "machine-1", featureID: FirstMateSimulatorFixtures.featureID,
                                                        buildID: FirstMateSimulatorFixtures.buildID)
    private var openPath: String { "POST /api/v1/first-mate/features/\(FirstMateSimulatorFixtures.featureID)/simulator-builds/\(FirstMateSimulatorFixtures.buildID)/preview" }

    @Test("Opening follows a starting simulator; the stop is explicit and replayable")
    func openAndStop() async throws {
        SimulatorURLProtocol.reset([
            openPath: (200, "{\"ok\":true,\"preview\":\(FirstMateSimulatorFixtures.preview(phase: "starting", status: "creating_simulator", stream: false)),\"reused\":false,\"stopped_to_make_room\":[\(FirstMateSimulatorFixtures.preview(id: "fmsp_00000000000000000000000000000009"))]}"),
            "POST /api/v1/first-mate/features/\(FirstMateSimulatorFixtures.featureID)/simulator-previews/\(FirstMateSimulatorFixtures.previewID)/stop":
                (200, "{\"ok\":true,\"preview\":\(FirstMateSimulatorFixtures.preview(phase: "stopping", status: "stopping", stream: false))}"),
        ])
        let session = FirstMateSimulatorSession(target: target, machineName: "Build Mac", api: SimulatorURLProtocol.api(), isDemo: false)
        await session.startAgain()
        #expect(session.phase == .starting)
        #expect(session.notice == "Shut down an idle simulator to make room.")
        #expect(session.stream == nil)
        await session.stop()
        #expect(session.phase == .stopping)
        let stops = SimulatorURLProtocol.requests().filter { $0.path.hasSuffix("/stop") }
        #expect(stops.count == 1)
        #expect(stops.first?.body?["mode"] == "shutdown")
        session.close()
    }

    @Test("A full machine is explained with the simulators that are in use")
    func capacity() async throws {
        SimulatorURLProtocol.reset([openPath: (409, #"{"ok":false,"error":{"code":"simulator_capacity","message":"2 Herdr simulators are running and in use. Stop one to open another.","details":{"running":[\#(FirstMateSimulatorFixtures.preview()),\#(FirstMateSimulatorFixtures.preview(id: "fmsp_00000000000000000000000000000008"))]}}}"#)])
        let session = FirstMateSimulatorSession(target: target, machineName: "Build Mac", api: SimulatorURLProtocol.api(), isDemo: false)
        await session.startAgain()
        #expect(session.phase == .unavailable("2 Herdr simulators are running and in use. Stop one to open another."))
        #expect(session.capacity.count == 2)
    }

    @Test("A simulator deleted in SimPortal reads as stopped, and says so")
    func deletedSimulator() async throws {
        SimulatorURLProtocol.reset([
            openPath: (200, "{\"ok\":true,\"preview\":\(FirstMateSimulatorFixtures.preview(phase: "stopped", status: "simulator_deleted", stream: false)),\"reused\":true,\"stopped_to_make_room\":[]}"),
        ])
        let session = FirstMateSimulatorSession(target: target, machineName: "Build Mac", api: SimulatorURLProtocol.api(), isDemo: false)
        await session.startAgain()
        #expect(session.phase == .stopped)
        #expect(session.simulatorDeleted)
        #expect(session.stream == nil)
        session.close()
    }

    @Test("Without a connection, or in demo mode, nothing is requested")
    func offlineAndDemo() {
        let offline = FirstMateSimulatorSession(target: target, machineName: "Build Mac", api: nil, isDemo: false)
        if case .unavailable = offline.phase {} else { Issue.record("expected unavailable") }
        let demo = FirstMateSimulatorSession(target: target, machineName: "Build Mac", api: nil, isDemo: true)
        #expect(demo.phase == .running)
        #expect(demo.demoFrame != nil)
        #expect(demo.browserURL != nil)
    }

    @Test("A hidden window pauses nothing until it has been hidden for a while")
    func hiddenWindow() async {
        let demo = FirstMateSimulatorSession(target: target, machineName: "Build Mac", api: nil, isDemo: true)
        demo.setVisible(false)
        #expect(!demo.isPausedWhileHidden)
        demo.setVisible(true)
        #expect(!demo.isPausedWhileHidden)
    }
}

/// Canned companion replies keyed by "METHOD path"; records what was sent.
private final class SimulatorURLProtocol: URLProtocol {
    struct Sent: Sendable {
        let method: String
        let path: String
        let authorization: String?
        let body: [String: String]?
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

    static func api() -> FirstMateSimulatorAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SimulatorURLProtocol.self]
        return FirstMateSimulatorAPI(configuration: ServerConfiguration(urlString: FirstMateSimulatorFixtures.baseURL, token: "synthetic-token")!,
                                     session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let method = request.httpMethod ?? "GET"
        var body: [String: String]?
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = try? JSONDecoder().decode([String: String].self, from: data)
        } else if let data = request.httpBody {
            body = try? JSONDecoder().decode([String: String].self, from: data)
        }
        let reply = Self.state.withLock { state -> (Int, String) in
            state.sent.append(Sent(method: method, path: url.path, authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
            return state.replies["\(method) \(url.path)"] ?? (404, #"{"ok":false,"error":{"code":"not_found","message":"No such route"}}"#)
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("First Mate simulator renders", .serialized)
@MainActor
struct FirstMateSimulatorRenderTests {
    private let target = FirstMateSimulatorWindowTarget(machineID: "demo", featureID: "demo-receipts", buildID: "demo-build-3")

    @Test("Window: live, starting, installing, and deleted in SimPortal")
    func window() async throws {
        let live = FirstMateSimulatorSession(target: target, machineName: "Build Mac", api: nil, isDemo: true)
        let starting = FirstMateSimulatorSession(target: target, machineName: "Build Mac", api: nil, isDemo: true)
        starting.presentDemoStarting(at: "creating_simulator")
        let installing = FirstMateSimulatorSession(target: target, machineName: "Build Mac", api: nil, isDemo: true)
        installing.presentDemoStarting(at: "installing")
        let deleted = FirstMateSimulatorSession(target: target, machineName: "Build Mac", api: nil, isDemo: true)
        deleted.presentDemoDeleted()
        #expect(deleted.simulatorDeleted)
        for (name, session) in [("live", live), ("starting", starting), ("installing", installing), ("deleted", deleted)] {
            let image = try await HerdrRenderHarness.render("first-mate-simulator-\(name).png", size: CGSize(width: 430, height: 900)) {
                ZStack {
                    HerdrDuskBackdrop()
                    FirstMateSimulatorWindowContent(session: session)
                }
                .environment(\.herdrGlassActive, true)
                .environment(\.herdrHazeActive, true)
                .foregroundStyle(HerdrTheme.text)
            }
            image.expectSubstantial()
        }
    }

    @Test("Builds section and a workflow stage with simulator checkpoints")
    func inspector() async throws {
        let feed = FirstMateSimulatorFeed(machineID: "demo", featureID: "demo-receipts", configuration: { nil })
        feed.presentDemo(visitIDs: ["demo-receipts-visit-0", "demo-receipts-visit-1", "demo-receipts-visit-2"])
        let context = FirstMateSimulatorContext(machineID: "demo", feed: feed, isDemo: true)
        let hub = try MobileAppHubFixtures.builds([MobileAppHubFixtures.buildJSON(id: "hub-1", builtAt: "2026-09-29T08:00:00Z")])
        let image = try await HerdrRenderHarness.render("first-mate-simulator-builds.png", size: CGSize(width: 380, height: 520)) {
            FirstMateBuildsSection(featureID: "demo-receipts", assignments: [("demo-receipts-crew-2", "Export sheet")],
                                   feed: MobileAppHubFeed(builds: hub),
                                   query: MobileAppHubFeed.Query(hubURL: MobileAppHubFixtures.hubURL, firstMateFeatureID: "demo-receipts"),
                                   simulator: context)
                .padding(16)
                .background(FirstMatePalette(scheme: .dark).background)
        }
        image.expectSubstantial()
        let row = try await HerdrRenderHarness.render("first-mate-simulator-workflow.png", size: CGSize(width: 380, height: 140)) {
            VStack(alignment: .leading, spacing: 10) {
                // One build in the review stage, two in implementation (a menu).
                FirstMateSimulatorVisitChip(visitID: "demo-receipts-visit-2")
                FirstMateSimulatorVisitChip(visitID: "demo-receipts-visit-1")
                FirstMateSimulatorVisitChip(visitID: "demo-receipts-visit-0")
            }
            .menuStyle(.button)
            .buttonStyle(.herdrPlain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.firstMateSimulator, context)
            .background(FirstMatePalette(scheme: .dark).background)
        }
        row.expectSubstantial()
    }
}
