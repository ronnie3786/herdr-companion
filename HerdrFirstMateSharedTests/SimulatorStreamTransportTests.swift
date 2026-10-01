import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

/// The URLSession transport without a network: the sandbox forbids listening
/// sockets, so only the paths that never dial are exercised here.
@Suite("Simulator stream transport")
struct SimulatorStreamTransportTests {
    private let request = URLRequest(url: URL(string: "wss://companion.example.invalid/simulators/preview-1/stream")!)

    @Test("A closed transport never dials, and every call fails as cancelled")
    func closedBeforeOpen() async {
        let transport = URLSessionSimulatorStreamTransport.factory(request)
        transport.close()
        transport.close()
        await #expect(throws: SimulatorStreamTransportError.cancelled) { try await transport.open() }
        await #expect(throws: SimulatorStreamTransportError.cancelled) { try await transport.send("{}") }
        await #expect(throws: SimulatorStreamTransportError.cancelled) { _ = try await transport.receive() }
    }

    @Test("Nothing is sent or received before the upgrade completes")
    func notOpenYet() async {
        let transport = URLSessionSimulatorStreamTransport(request: request)
        await #expect(throws: SimulatorStreamTransportError.cancelled) { try await transport.send("{}") }
        await #expect(throws: SimulatorStreamTransportError.cancelled) { _ = try await transport.receive() }
        transport.close()
    }

    @Test("Messages up to a large keyframe fit")
    func messageSize() {
        #expect(URLSessionSimulatorStreamTransport.maximumMessageSize >= 32 * 1024 * 1024)
        #expect(URLSessionSimulatorStreamTransport.maximumMessageSize >= SimulatorBinaryMessage.maximumSize)
    }
}
