import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import herdr_harness_mac

/// Wire messages built byte for byte the way SimPortal's helper writes them
/// (big-endian, type byte first). Synthetic content only.
enum SimulatorWire {
    static func u16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func u64(_ value: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8((value >> (UInt64($0) * 8)) & 0xFF) }
    }

    /// SimPortal derives the codec string from the avcC's profile bytes.
    static func codecString(for avcC: Data) -> String {
        let bytes = [UInt8](avcC)
        return String(format: "avc1.%02x%02x%02x", bytes[1], bytes[2], bytes[3])
    }

    static func config(codec: String? = nil, width: Int, height: Int, avcC: Data) -> Data {
        let codecBytes = Array((codec ?? codecString(for: avcC)).utf8)
        var bytes: [UInt8] = [0x02]
        bytes += u16(codecBytes.count)
        bytes += codecBytes
        bytes += u16(width)
        bytes += u16(height)
        bytes += [UInt8](avcC)
        return Data(bytes)
    }

    static func frame(keyframe: Bool, timestampUs: UInt64, data: Data) -> Data {
        var bytes: [UInt8] = [0x03, keyframe ? 1 : 0]
        bytes += u64(timestampUs)
        bytes += [UInt8](data)
        return Data(bytes)
    }

    static func jpeg(timestampUs: UInt64, width: Int, height: Int, data: Data) -> Data {
        var bytes: [UInt8] = [0x04]
        bytes += u64(timestampUs)
        bytes += u16(width)
        bytes += u16(height)
        bytes += [UInt8](data)
        return Data(bytes)
    }

    /// A structurally valid avcC (version 1, High profile, 4-byte NAL lengths,
    /// one SPS and one PPS) with made-up parameter sets.
    static let avcC = Data([
        0x01, 0x64, 0x0C, 0x33, 0xFF, 0xE1, 0x00, 0x04, 0x67, 0x64, 0x0C, 0x33,
        0x01, 0x00, 0x04, 0x68, 0xEE, 0x3C, 0x80,
    ])

    /// Two AVCC NAL units with 4-byte length prefixes.
    static let accessUnit = Data([0x00, 0x00, 0x00, 0x03, 0x65, 0x88, 0x84, 0x00, 0x00, 0x00, 0x02, 0x41, 0x9A])

    /// A real JPEG: `top` over `bottom`, split horizontally.
    static func jpegImage(width: Int, height: Int, top: CGColor, bottom: CGColor) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Core Graphics is y-up: the first fill is the image's bottom half.
        context.setFillColor(bottom)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(top)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func jsonObject(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

/// A scripted socket: records what the controller sends and replays what the test delivers.
final class FakeSimulatorTransport: SimulatorStreamTransport {
    private struct State {
        var sent: [String] = []
        var inbox: [Result<SimulatorStreamFrame, SimulatorStreamTransportError>] = []
        var receiver: CheckedContinuation<SimulatorStreamFrame, any Error>?
        var isOpen = false
        var isClosed = false
    }

    let openError: SimulatorStreamTransportError?
    let request: URLRequest
    private let state = Mutex(State())

    init(request: URLRequest, openError: SimulatorStreamTransportError? = nil) {
        self.request = request
        self.openError = openError
    }

    func open() async throws {
        if let openError { throw openError }
        try state.withLock { state in
            guard !state.isClosed else { throw SimulatorStreamTransportError.cancelled }
            state.isOpen = true
        }
    }

    func send(_ text: String) async throws {
        try state.withLock { state in
            guard !state.isClosed else { throw SimulatorStreamTransportError.cancelled }
            state.sent.append(text)
        }
    }

    func receive() async throws -> SimulatorStreamFrame {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<SimulatorStreamFrame, SimulatorStreamTransportError>? in
                if state.isClosed { return .failure(.cancelled) }
                if !state.inbox.isEmpty { return state.inbox.removeFirst() }
                state.receiver = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func close() {
        let receiver = state.withLock { state in
            state.isClosed = true
            defer { state.receiver = nil }
            return state.receiver
        }
        receiver?.resume(throwing: SimulatorStreamTransportError.cancelled)
    }

    // MARK: Test side

    func deliver(_ frame: SimulatorStreamFrame) {
        deliver(.success(frame))
    }

    func deliverText(_ text: String) {
        deliver(.text(text))
    }

    func serverClose(code: Int) {
        deliver(.failure(.closed(code: code)))
    }

    private func deliver(_ result: Result<SimulatorStreamFrame, SimulatorStreamTransportError>) {
        let receiver = state.withLock { state -> CheckedContinuation<SimulatorStreamFrame, any Error>? in
            guard let receiver = state.receiver else {
                state.inbox.append(result)
                return nil
            }
            state.receiver = nil
            return receiver
        }
        receiver?.resume(with: result)
    }

    var sent: [String] { state.withLock { $0.sent } }
    var isOpen: Bool { state.withLock { $0.isOpen } }
    var isClosed: Bool { state.withLock { $0.isClosed } }

    /// Sent messages' `type` fields, pings left out (they tick on their own).
    var sentTypes: [String] {
        sent.compactMap { (try? SimulatorWire.jsonObject($0))?["type"] as? String }.filter { $0 != "ping" }
    }
}

/// Hands out fake transports; each connection attempt takes the next scripted open result.
final class FakeSimulatorTransportFactory: Sendable {
    private let made = Mutex<[FakeSimulatorTransport]>([])
    private let openErrors: Mutex<[SimulatorStreamTransportError?]>

    init(openErrors: [SimulatorStreamTransportError?] = []) {
        self.openErrors = Mutex(openErrors)
    }

    var factory: SimulatorStreamTransportFactory {
        { [self] request in make(request) }
    }

    private func make(_ request: URLRequest) -> FakeSimulatorTransport {
        let error = openErrors.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        let transport = FakeSimulatorTransport(request: request, openError: error)
        made.withLock { $0.append(transport) }
        return transport
    }

    var transports: [FakeSimulatorTransport] { made.withLock { $0 } }
    var last: FakeSimulatorTransport? { transports.last }
}

/// Records reconnect delays without waiting them out.
final class SimulatorSleepRecorder: Sendable {
    private let delays = Mutex<[Duration]>([])

    var sleep: SimulatorStreamController.Sleep {
        { [self] delay in
            delays.withLock { $0.append(delay) }
            await Task.yield()
        }
    }

    var recorded: [Duration] { delays.withLock { $0 } }
}

enum SimulatorStreamWait {
    struct TimedOut: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func until(_ what: String, timeout: Duration = .seconds(3),
                      _ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw TimedOut(description: "Timed out waiting for \(what)") }
            try await clock.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
enum SimulatorStreamHarness {
    static func controller(_ factory: FakeSimulatorTransportFactory, sleeps: SimulatorSleepRecorder = SimulatorSleepRecorder(),
                           codec: SimulatorStreamCodec = .h264,
                           pingInterval: Duration = .seconds(3600)) -> SimulatorStreamController {
        SimulatorStreamController(
            requestFactory: {
                var request = URLRequest(url: URL(string: "wss://companion.example.invalid/simulators/preview-1/stream")!)
                request.setValue("Bearer example-token", forHTTPHeaderField: "Authorization")
                return request
            },
            transportFactory: factory.factory, quality: .high, codec: codec,
            pingInterval: pingInterval, openTimeout: .seconds(3600), backoffSleep: sleeps.sleep)
    }

    /// Connects and plays the server's side up to `ready`.
    static func live(_ controller: SimulatorStreamController, _ factory: FakeSimulatorTransportFactory,
                     width: Int = 100, height: Int = 200) async throws -> FakeSimulatorTransport {
        let count = factory.transports.count
        controller.connect()
        try await SimulatorStreamWait.until("hello") { factory.transports.count > count && factory.last?.sentTypes.first == "hello" }
        let transport = try #require(factory.last)
        transport.deliverText(#"{"type":"ready","width":\#(width),"height":\#(height),"codec":"\#(controller.codec.rawValue)"}"#)
        try await SimulatorStreamWait.until("live") { controller.state == .live }
        return transport
    }

    /// Everything sent after hello, pings left out.
    static func sentAfterHello(_ transport: FakeSimulatorTransport) -> [String] {
        Array(transport.sent.filter { !$0.contains(#""type":"ping""#) }.dropFirst())
    }
}
