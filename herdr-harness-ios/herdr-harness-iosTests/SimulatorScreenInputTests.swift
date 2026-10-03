import SwiftUI
import Testing
import UIKit
@testable import herdr_harness_ios

@Suite("iPad simulator input", .serialized)
@MainActor
struct SimulatorScreenInputTests {
    @Test("The live cover routes screen touches through its overlays")
    func liveCoverHitTesting() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SimulatorInputURLProtocol.self]
        let api = FirstMateSimulatorAPI(
            configuration: ServerConfiguration(urlString: "https://companion.example.invalid", token: "synthetic-token")!,
            session: URLSession(configuration: configuration))
        let factory = FakeSimulatorTransportFactory()
        let session = FirstMateSimulatorSession(
            target: .init(machineID: "fixture", featureID: "feature", buildID: "build"),
            machineName: "Fixture", api: api, isDemo: false, transportFactory: factory.factory)
        let follow = Task { await session.run() }
        defer { follow.cancel(); session.close() }
        try await SimulatorStreamWait.until("stream hello") { factory.last?.sentTypes.first == "hello" }
        let transport = try #require(factory.last)
        transport.deliverText(#"{"type":"ready","width":402,"height":874,"codec":"h264"}"#)
        try await SimulatorStreamWait.until("live") { session.stream?.acceptsInput == true }

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let host = UIHostingController(rootView: FirstMateSimulatorCoverContent(session: session)
            .environment(\.horizontalSizeClass, .regular))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let screen = try #require(findScreen(in: host.view))
        #expect(screen.bounds.width > 100)
        let center = CGPoint(x: screen.bounds.midX, y: screen.bounds.midY)
        let point = screen.convert(center, to: window)
        let hit = window.hitTest(point, with: nil)
        #expect(hit === screen, "Expected simulator screen, got \(String(describing: hit))")
    }

    @Test("Native touches send a complete tap")
    func nativeTouches() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory)
        let transport = try await SimulatorStreamHarness.live(controller, factory, width: 100, height: 200)
        defer { controller.disconnect() }
        let view = SimulatorScreenUIView(controller: controller, isInteractive: true)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        view.layoutIfNeeded()
        let touch = SimulatorInputTouch(point: CGPoint(x: 150, y: 75))
        view.touchesBegan([touch], with: nil)
        view.touchesEnded([touch], with: nil)
        try await SimulatorStreamWait.until("tap") { transport.sentTypes.count >= 3 }
        let messages = try SimulatorStreamHarness.sentAfterHello(transport).map(SimulatorWire.jsonObject)
        #expect(messages.compactMap { $0["phase"] as? String } == ["began", "ended"])
        #expect(messages.allSatisfy { ($0["x"] as? Double) == 0.5 && ($0["y"] as? Double) == 0.25 })
    }

    @Test("A swipe ending before the next display tick sends its final move before lifting")
    func fastSwipe() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory)
        let transport = try await SimulatorStreamHarness.live(controller, factory, width: 100, height: 200)
        defer { controller.disconnect() }
        let view = SimulatorScreenUIView(controller: controller, isInteractive: true)
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 200)
        view.layoutIfNeeded()
        let touch = SimulatorInputTouch(point: CGPoint(x: 50, y: 150))
        view.touchesBegan([touch], with: nil)
        touch.point = CGPoint(x: 50, y: 50)
        view.touchesMoved([touch], with: nil)
        view.touchesEnded([touch], with: nil)
        try await SimulatorStreamWait.until("swipe") { transport.sentTypes.count >= 4 }
        let messages = try SimulatorStreamHarness.sentAfterHello(transport).map(SimulatorWire.jsonObject)
        #expect(messages.compactMap { $0["phase"] as? String } == ["began", "moved", "ended"])
        #expect(messages.compactMap { $0["y"] as? Double } == [0.75, 0.25, 0.25])
    }

    @Test("Backgrounding pauses immediately; a preview opened while hidden connects on return")
    func backgroundResume() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SimulatorInputURLProtocol.self]
        let api = FirstMateSimulatorAPI(
            configuration: ServerConfiguration(urlString: "https://companion.example.invalid", token: "synthetic-token")!,
            session: URLSession(configuration: configuration))
        let factory = FakeSimulatorTransportFactory()
        let session = FirstMateSimulatorSession(
            target: .init(machineID: "fixture", featureID: "feature", buildID: "build"),
            machineName: "Fixture", api: api, isDemo: false, transportFactory: factory.factory,
            hiddenPauseDelay: .zero)
        session.setVisible(false)
        let follow = Task { await session.run() }
        defer { follow.cancel(); session.close() }
        try await SimulatorStreamWait.until("hidden preview") { session.stream != nil }
        #expect(session.isPausedWhileHidden)
        #expect(factory.transports.isEmpty)
        session.setVisible(true)
        try await SimulatorStreamWait.until("connected on return") { factory.last?.sentTypes.first == "hello" }
        let first = try #require(factory.last)
        first.deliverText(#"{"type":"ready","width":100,"height":200,"codec":"h264"}"#)
        try await SimulatorStreamWait.until("live") { session.stream?.acceptsInput == true }
        session.setVisible(false)
        #expect(first.isClosed)
        #expect(session.stream?.state == .paused)
        session.setVisible(true)
        try await SimulatorStreamWait.until("fresh connection") { factory.transports.count == 2 }
        #expect(!session.isPausedWhileHidden)
    }

    private func findScreen(in view: UIView) -> SimulatorScreenUIView? {
        if let screen = view as? SimulatorScreenUIView { return screen }
        for child in view.subviews { if let found = findScreen(in: child) { return found } }
        return nil
    }
}
