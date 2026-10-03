import SwiftUI

#if DEBUG
/// A real full-screen cover and WebSocket, backed only by the local synthetic fixture.
struct SimulatorInputUITestFixtureView: View {
    @State private var session: FirstMateSimulatorSession?
    @State private var presented = false

    var body: some View {
        Button("Open fixture simulator") { presented = true }
            .disabled(session == nil)
            .task { session = makeSession() }
            .fullScreenCover(isPresented: $presented) {
                if let session {
                    FirstMateSimulatorCoverContent(session: session) { presented = false }
                        .task { await session.run() }
                        .onDisappear { session.close() }
                }
            }
    }

    private func makeSession() -> FirstMateSimulatorSession? {
        struct Fixture: Decodable {
            let base_url: String
            let token: String
            let feature_id: String
            let build_id: String
        }
        guard let raw = ProcessInfo.processInfo.environment["HERDR_SIMULATOR_RELAY_FIXTURE"],
              let fixture = try? JSONDecoder().decode(Fixture.self, from: Data(raw.utf8)),
              let config = ServerConfiguration(urlString: fixture.base_url, token: fixture.token),
              ["localhost", "127.0.0.1"].contains(config.baseURL.host ?? "") else { return nil }
        return FirstMateSimulatorSession(
            target: .init(machineID: "fixture", featureID: fixture.feature_id, buildID: fixture.build_id),
            machineName: "Fixture", api: FirstMateSimulatorAPI(configuration: config), isDemo: false,
            hiddenPauseDelay: .zero)
    }
}
#endif
