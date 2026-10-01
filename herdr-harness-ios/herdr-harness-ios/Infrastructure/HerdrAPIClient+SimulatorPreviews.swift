import Foundation

/// The companion's SimPortal routes (`first-mate-simulator-previews-v1`; see
/// docs/first-mate/simulator-previews.md) on this client's machine, with its
/// address, credential and session. The routes, identifier checks, timeouts
/// and error codes live in the shared `FirstMateSimulatorAPI`, which the Mac
/// uses too. The phone never contacts SimPortal: the companion holds its
/// credential and relays the stream.
///
/// - `GET  …/features/{id}/simulator-builds`
/// - `POST …/features/{id}/simulator-builds/{build}/preview`
/// - `GET  …/features/{id}/simulator-previews/{preview}`
/// - `POST …/features/{id}/simulator-previews/{preview}/stop`
/// - `GET  …/features/{id}/simulator-previews/{preview}/stream` (WebSocket)
extension HerdrAPIClient {
    /// Builds and previews use their own 20 s (reads) and 45 s (start and
    /// stop) timeouts, not the long First Mate mutation bound.
    nonisolated var simulatorPreviews: FirstMateSimulatorAPI {
        FirstMateSimulatorAPI(configuration: configuration, session: session)
    }

    func fetchSimulatorBuilds(featureID: String) async throws -> FirstMateSimulatorBuildList {
        try await simulatorPreviews.builds(featureID: featureID)
    }

    func openSimulatorPreview(featureID: String, buildID: String, requestID: String) async throws -> FirstMateSimulatorOpenResponse {
        try await simulatorPreviews.open(featureID: featureID, buildID: buildID, requestID: requestID)
    }

    func fetchSimulatorPreview(featureID: String, previewID: String) async throws -> FirstMateSimulatorPreviewDetail {
        try await simulatorPreviews.preview(featureID: featureID, previewID: previewID)
    }

    func stopSimulatorPreview(featureID: String, previewID: String, requestID: String) async throws -> FirstMateSimulatorPreviewEnvelope {
        try await simulatorPreviews.stop(featureID: featureID, previewID: previewID, requestID: requestID)
    }

    /// The stream's WebSocket upgrade, with the credential in a header (never in the URL).
    nonisolated func simulatorStreamRequest(featureID: String, previewID: String) throws -> URLRequest {
        try simulatorPreviews.streamRequest(featureID: featureID, previewID: previewID)
    }
}
