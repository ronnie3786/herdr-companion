import CoreGraphics
import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("Simulator stream controller", .serialized)
@MainActor
struct SimulatorStreamControllerTests {
    private let hello = #"{"codec":"h264","focus":false,"observe":true,"quality":"high","type":"hello"}"#
    private let jpegHello = #"{"codec":"jpeg","focus":false,"observe":true,"quality":"high","type":"hello"}"#

    @Test("Connecting sends hello first, then follows the server from waiting to live")
    func helloAndStates() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory)
        #expect(controller.state == .idle)
        controller.connect()
        #expect(controller.state == .connecting)
        try await SimulatorStreamWait.until("hello") { factory.last?.sent.isEmpty == false }
        let transport = try #require(factory.last)
        #expect(transport.sent.first == hello)
        #expect(transport.request.value(forHTTPHeaderField: "Authorization") == "Bearer example-token")
        #expect(controller.state == .connecting)
        #expect(!controller.acceptsInput)

        transport.deliverText(#"{"type":"device","device":{"udid":"u-1","name":"Example Phone","state":"Shutdown"}}"#)
        transport.deliverText(#"{"type":"state","state":"Booting"}"#)
        try await SimulatorStreamWait.until("waiting") { controller.state == .waitingForDevice(state: "Booting") }
        #expect(controller.device?.name == "Example Phone")
        #expect(!controller.acceptsInput)

        transport.deliverText(#"{"type":"ready","width":603,"height":1311,"codec":"h264"}"#)
        try await SimulatorStreamWait.until("live") { controller.state == .live }
        #expect(controller.pixelSize == CGSize(width: 603, height: 1311))
        #expect(controller.renderer.contentPixelSize == CGSize(width: 603, height: 1311))
        #expect(controller.acceptsInput)

        transport.deliverText(#"{"type":"viewers","count":2}"#)
        transport.deliverText(#"{"type":"notice","level":"info","message":"Recording started"}"#)
        transport.deliverText(#"{"type":"surface","width":1311,"height":603}"#)
        transport.deliverText(#"{"type":"activity","source":"agent","action":"tap","x":0.5,"y":0.25}"#)
        transport.deliverText(#"{"type":"something-new","value":1}"#)
        transport.deliver(.binary(Data([0x09, 0x01])))
        try await SimulatorStreamWait.until("activity") { controller.lastAgentActivity != nil }
        #expect(controller.viewerCount == 2)
        #expect(controller.lastNotice == "Recording started")
        #expect(controller.pixelSize == CGSize(width: 1311, height: 603))
        #expect(controller.lastAgentActivity?.action == SimulatorAgentAction(source: "agent", action: "tap", point: CGPoint(x: 0.5, y: 0.25)))
        #expect(controller.state == .live)

        let ping = try #require(transport.sent.first { $0.contains(#""type":"ping""#) })
        let t = try #require(try SimulatorWire.jsonObject(ping)["t"] as? Double)
        transport.deliverText(#"{"type":"pong","t":\#(t)}"#)
        try await SimulatorStreamWait.until("round trip") { controller.rttMilliseconds != nil }
        #expect((controller.rttMilliseconds ?? -1) >= 0)

        transport.deliverText(#"{"type":"ended","reason":"simulator shut down"}"#)
        try await SimulatorStreamWait.until("shut down") { controller.state == .waitingForDevice(state: "Shutdown") }
        #expect(!controller.acceptsInput)
        transport.deliverText(#"{"type":"ready","width":603,"height":1311,"codec":"h264"}"#)
        try await SimulatorStreamWait.until("live again") { controller.state == .live }
        transport.deliverText(#"{"type":"ended","reason":"helper exited (1)"}"#)
        try await SimulatorStreamWait.until("restarting") { controller.state == .waitingForDevice(state: "Restarting") }

        controller.disconnect()
        #expect(controller.state == .idle)
        #expect(transport.isClosed)
        #expect(factory.transports.count == 1)
    }

    @Test("Input goes out in order, and only while live")
    func inputOrder() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory)
        controller.send(.text("too early"))
        let transport = try await SimulatorStreamHarness.live(controller, factory)

        let inputs: [SimulatorClientMessage] = [
            .touch(SimulatorTouch(phase: .began, x: 0.25, y: 0.5)),
            .touch(SimulatorTouch(phase: .moved, x: 0.3, y: 0.55)),
            .touch(SimulatorTouch(phase: .ended, x: 0.35, y: 0.6)),
            .key(usage: 0xE1, phase: .down),
            .key(usage: 0x04, phase: .down),
            .key(usage: 0x04, phase: .up),
            .key(usage: 0xE1, phase: .up),
            .button(.home),
            .text("Hello"),
        ]
        for message in inputs { controller.send(message) }
        controller.pressButton(.lock)
        controller.paste("clipboard text")
        controller.paste("")
        controller.paste(String(repeating: "x", count: SimulatorClientMessage.maximumTextLength + 1))
        controller.send(.text(""))
        controller.setQuality(.low)
        controller.setQuality(.low)
        let expected = (inputs + [.button(.lock), .paste("clipboard text"), .quality(.low)]).map(\.json)
        try await SimulatorStreamWait.until("inputs") { SimulatorStreamHarness.sentAfterHello(transport).count >= expected.count }
        #expect(SimulatorStreamHarness.sentAfterHello(transport) == expected)
        #expect(controller.quality == .low)
        #expect(controller.lastNotice == "That's too much text to paste into the simulator at once.")
        #expect(!transport.sent.contains { $0.contains("too early") })

        controller.disconnect()
        controller.send(.text("too late"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!transport.sent.contains { $0.contains("too late") })
    }

    @Test("Reconnects back off from 0.5 s to 8 s, and start over after a frame is shown")
    func backoff() async throws {
        let failures = [SimulatorStreamTransportError?](repeating: .handshakeRejected(status: 503), count: 6)
        let factory = FakeSimulatorTransportFactory(openErrors: failures + [nil])
        let sleeps = SimulatorSleepRecorder()
        let controller = SimulatorStreamHarness.controller(factory, sleeps: sleeps, codec: .jpeg)
        controller.connect()
        try await SimulatorStreamWait.until("seventh attempt") {
            factory.transports.count == 7 && factory.last?.sent.first == jpegHello
        }
        #expect(sleeps.recorded == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8)])
        #expect(controller.state == .reconnecting(attempt: 6, delay: .seconds(8)))
        #expect(SimulatorStreamController.backoff(forAttempt: 40) == .seconds(8))

        // `ready` alone is not a shown frame, so the next wait keeps growing.
        let seventh = try #require(factory.last)
        seventh.deliverText(#"{"type":"ready","width":40,"height":80,"codec":"jpeg"}"#)
        try await SimulatorStreamWait.until("live") { controller.state == .live }
        seventh.serverClose(code: 1006)
        try await SimulatorStreamWait.until("eighth attempt") { factory.transports.count == 8 && factory.last?.sent.isEmpty == false }
        #expect(sleeps.recorded.last == .seconds(8))

        let eighth = try #require(factory.last)
        let image = try SimulatorWire.jpegImage(width: 40, height: 80, top: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                                                bottom: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        eighth.deliver(.binary(SimulatorWire.jpeg(timestampUs: 1, width: 40, height: 80, data: image)))
        try await SimulatorStreamWait.until("a shown frame") { controller.framesShown == 1 }
        #expect(controller.state == .live)
        #expect(controller.pixelSize == CGSize(width: 40, height: 80))
        eighth.serverClose(code: 1001)
        try await SimulatorStreamWait.until("ninth attempt") { factory.transports.count == 9 && factory.last?.sent.isEmpty == false }
        #expect(sleeps.recorded.last == .milliseconds(500))
        #expect(seventh.isClosed && eighth.isClosed)
        controller.disconnect()
    }

    @Test("A preview that is gone, or refused credentials, end the stream without retrying",
          arguments: [(404, "This preview is no longer running"), (409, "This preview is no longer running"),
                      (410, "This preview is no longer running"), (401, "The companion rejected the stream credentials"),
                      (403, "The companion rejected the stream credentials")])
    func terminalHandshake(status: Int, reason: String) async throws {
        let factory = FakeSimulatorTransportFactory(openErrors: [.handshakeRejected(status: status)])
        let sleeps = SimulatorSleepRecorder()
        let controller = SimulatorStreamHarness.controller(factory, sleeps: sleeps)
        controller.connect()
        try await SimulatorStreamWait.until("ended") { controller.state == .ended(reason: reason) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(factory.transports.count == 1)
        #expect(sleeps.recorded.isEmpty)
        #expect(controller.state == .ended(reason: reason))

        // Connecting again is the caller's explicit choice.
        controller.connect()
        try await SimulatorStreamWait.until("second attempt") { factory.transports.count == 2 }
        controller.disconnect()
    }

    @Test("SimPortal closing with 4004 (simulator not found) ends the stream; other closes reconnect")
    func closeCodes() async throws {
        let factory = FakeSimulatorTransportFactory()
        let sleeps = SimulatorSleepRecorder()
        let controller = SimulatorStreamHarness.controller(factory, sleeps: sleeps)
        let first = try await SimulatorStreamHarness.live(controller, factory)
        first.serverClose(code: 1011)
        try await SimulatorStreamWait.until("reconnect") { factory.transports.count == 2 && factory.last?.sent.isEmpty == false }
        let second = try #require(factory.last)
        second.deliverText(#"{"type":"error","message":"No simulator matches that name"}"#)
        second.serverClose(code: 4004)
        try await SimulatorStreamWait.until("ended") { controller.state == .ended(reason: "This preview is no longer running") }
        #expect(controller.lastNotice == "No simulator matches that name")
        try await Task.sleep(for: .milliseconds(30))
        #expect(factory.transports.count == 2)
        #expect(sleeps.recorded == [.milliseconds(500)])
    }

    @Test("Pause closes the socket without reconnecting; resume reconnects with hello")
    func pauseAndResume() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory)
        let first = try await SimulatorStreamHarness.live(controller, factory)
        controller.pause()
        #expect(controller.state == .paused)
        #expect(first.isClosed)
        #expect(!controller.acceptsInput)
        controller.send(.text("while paused"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(factory.transports.count == 1)
        #expect(controller.state == .paused)

        controller.resume()
        #expect(controller.state == .connecting)
        try await SimulatorStreamWait.until("hello again") { factory.transports.count == 2 && factory.last?.sent.first == hello }
        #expect(!(factory.last?.sent.contains { $0.contains("while paused") } ?? true))

        controller.disconnect()
        #expect(controller.state == .idle)
        controller.pause()
        controller.resume()
        #expect(controller.state == .idle)
        #expect(factory.transports.count == 2)
    }

    @Test("Disconnecting while waiting to reconnect stops for good")
    func disconnectDuringBackoff() async throws {
        let factory = FakeSimulatorTransportFactory(openErrors: [.failed("offline")])
        let controller = SimulatorStreamController(
            requestFactory: { URLRequest(url: URL(string: "wss://companion.example.invalid/stream")!) },
            transportFactory: factory.factory, openTimeout: .seconds(3600),
            backoffSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        controller.connect()
        try await SimulatorStreamWait.until("backing off") { controller.state == .reconnecting(attempt: 1, delay: .milliseconds(500)) }
        controller.disconnect()
        #expect(controller.state == .idle)
        try await Task.sleep(for: .milliseconds(30))
        #expect(factory.transports.count == 1)
        #expect(controller.state == .idle)
    }

    @Test("Four decode failures switch to JPEG, and reconnects keep JPEG")
    func jpegFallback() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory)
        let transport = try await SimulatorStreamHarness.live(controller, factory)
        for _ in 0..<3 { controller.renderer.reportDecodeFailure() }
        try await SimulatorStreamWait.until("keyframe requests") {
            SimulatorStreamHarness.sentAfterHello(transport).filter { $0 == SimulatorClientMessage.keyframe.json }.count == 3
        }
        #expect(controller.codec == .h264)

        controller.renderer.reportDecodeFailure()
        try await SimulatorStreamWait.until("JPEG hello") { transport.sent.last == jpegHello }
        #expect(controller.codec == .jpeg)
        #expect(controller.renderer.codec == .jpeg)
        #expect(controller.lastNotice != nil)
        // Late failures from the old decoder change nothing.
        controller.renderer.reportDecodeFailure()
        try await Task.sleep(for: .milliseconds(20))
        #expect(SimulatorStreamHarness.sentAfterHello(transport).count == 4)

        transport.serverClose(code: 1006)
        try await SimulatorStreamWait.until("reconnect") { factory.transports.count == 2 && factory.last?.sent.isEmpty == false }
        #expect(factory.last?.sent.first == jpegHello)
        controller.disconnect()
    }

    @Test("A request factory can end the stream, and only WebSocket addresses are dialed")
    func requestFactoryStops() async throws {
        let factory = FakeSimulatorTransportFactory()
        let ended = SimulatorStreamController(
            requestFactory: { throw SimulatorStreamStop.ended(reason: "The preview was deleted") },
            transportFactory: factory.factory)
        ended.connect()
        try await SimulatorStreamWait.until("ended") { ended.state == .ended(reason: "The preview was deleted") }

        let web = SimulatorStreamController(
            requestFactory: { URLRequest(url: URL(string: "https://companion.example.invalid/stream")!) },
            transportFactory: factory.factory)
        web.connect()
        try await SimulatorStreamWait.until("failed") { if case .failed = web.state { true } else { false } }
        #expect(factory.transports.isEmpty)
    }

    @Test("Three ping intervals without a message count as a dead connection")
    func deadConnection() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory, pingInterval: .milliseconds(40))
        controller.connect()
        try await SimulatorStreamWait.until("a second connection") { factory.transports.count >= 2 }
        let first = factory.transports[0]
        #expect(first.isClosed)
        #expect(first.sent.filter { $0.contains(#""type":"ping""#) }.count >= 2)
        controller.disconnect()
    }

    @MainActor
    private final class ResetCounter: SimulatorStreamInputSink {
        var resets = 0
        func streamDidReleaseInput() { resets += 1 }
    }

    @Test("A dropped connection tells the screen view to forget held input")
    func inputResetOnDrop() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory)
        let sink = ResetCounter()
        controller.inputSink = sink
        let transport = try await SimulatorStreamHarness.live(controller, factory)
        transport.deliverText(#"{"type":"ended","reason":"idle"}"#)
        try await SimulatorStreamWait.until("helper restart reset") { sink.resets == 1 }
        transport.serverClose(code: 1006)
        try await SimulatorStreamWait.until("drop reset") { sink.resets == 2 }
        controller.disconnect()
    }
}
