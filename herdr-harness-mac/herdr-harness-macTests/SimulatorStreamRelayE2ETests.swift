import Foundation
import Testing
@testable import herdr_harness_mac

/// The real URLSession WebSocket client through the companion's relay, against
/// scripts/simulator-preview-fixture.py (a synthetic SimPortal). Opt-in: run
/// the fixture, then pass its JSON line to the test runner:
///
///     TEST_RUNNER_HERDR_SIMULATOR_RELAY_FIXTURE='{"base_url":…}' xcodebuild test … \
///       -only-testing:herdr-harness-macTests/SimulatorStreamRelayE2ETests
@Suite("Simulator stream relay, end to end", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HERDR_SIMULATOR_RELAY_FIXTURE"] != nil))
@MainActor
struct SimulatorStreamRelayE2ETests {
    private struct Fixture: Decodable {
        let baseURL: String
        let token: String
        let featureID: String
        let previewID: String

        enum CodingKeys: String, CodingKey {
            case token
            case baseURL = "base_url"
            case featureID = "feature_id"
            case previewID = "preview_id"
        }
    }

    @Test("The companion relays a live picture and input for the preview's exact simulator")
    func relay() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["HERDR_SIMULATOR_RELAY_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(raw.utf8))
        let api = FirstMateSimulatorAPI(configuration: try #require(ServerConfiguration(urlString: fixture.baseURL, token: fixture.token)))

        let detail = try await api.preview(featureID: fixture.featureID, previewID: fixture.previewID)
        #expect(detail.preview.phase == "running")
        #expect(detail.preview.streamAvailable)
        #expect(detail.build?.checkpointLabel == "Round 1: fixture")

        let controller = SimulatorStreamController(
            requestFactory: { try api.streamRequest(featureID: fixture.featureID, previewID: fixture.previewID) },
            codec: .jpeg)
        controller.connect()
        for _ in 0..<150 where controller.framesShown == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(controller.state == .live)
        #expect(controller.framesShown > 0)
        #expect(controller.pixelSize != nil)
        controller.send(.touch(SimulatorTouch(phase: .began, x: 0.25, y: 0.5)))
        controller.send(.touch(SimulatorTouch(phase: .ended, x: 0.25, y: 0.5)))
        try await Task.sleep(for: .milliseconds(500))
        controller.disconnect()

        // A refused upgrade stops instead of retrying: an unknown preview is a 404.
        let missing = SimulatorStreamController(
            requestFactory: { try api.streamRequest(featureID: fixture.featureID, previewID: "fmsp_00000000000000000000000000000000") },
            codec: .jpeg)
        missing.connect()
        for _ in 0..<100 {
            if case .ended = missing.state { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if case .ended = missing.state {} else { Issue.record("Expected the refused stream to end, got \(missing.state)") }
        missing.disconnect()
    }
}
