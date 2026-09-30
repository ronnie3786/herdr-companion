import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import herdr_harness_mac

@Suite("Simulator screen view", .serialized)
@MainActor
struct SimulatorScreenViewTests {
    /// An offscreen window whose unflipped content view hosts the screen view.
    private func host(_ controller: SimulatorStreamController, size: NSSize) -> (NSWindow, NSView, SimulatorScreenNSView) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        window.contentView = content
        let view = SimulatorScreenNSView(controller: controller, isInteractive: true)
        view.frame = content.bounds
        content.addSubview(view)
        window.displayIfNeeded()
        return (window, content, view)
    }

    /// `point` is in window coordinates (bottom-left origin).
    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ window: NSWindow,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func key(_ type: NSEvent.EventType, _ keyCode: Int, _ window: NSWindow,
                     flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: UInt16(keyCode)))
    }

    private func touches(_ transport: FakeSimulatorTransport) throws -> [SimulatorTouch] {
        try SimulatorStreamHarness.sentAfterHello(transport).compactMap { text -> SimulatorTouch? in
            let object = try SimulatorWire.jsonObject(text)
            guard object["type"] as? String == "touch", let phase = (object["phase"] as? String).flatMap(SimulatorTouchPhase.init(rawValue:)),
                  let x = object["x"] as? Double, let y = object["y"] as? Double else { return nil }
            return SimulatorTouch(phase: phase, x: x, y: y, x2: object["x2"] as? Double, y2: object["y2"] as? Double)
        }
    }

    /// Touches compared to within rounding: 1 - 0.7 is not exactly 0.3.
    private func matches(_ actual: [SimulatorTouch], _ expected: [SimulatorTouch]) -> Bool {
        func close(_ a: Double?, _ b: Double?) -> Bool {
            switch (a, b) {
            case (nil, nil): true
            case (let a?, let b?): abs(a - b) < 1e-9
            default: false
            }
        }
        return actual.count == expected.count && zip(actual, expected).allSatisfy { a, b in
            a.phase == b.phase && close(a.x, b.x) && close(a.y, b.y) && close(a.x2, b.x2) && close(a.y2, b.y2)
        }
    }

    @Test("The screen aspect-fits inside the view, and the video layers follow it")
    func geometry() {
        let controller = SimulatorStreamHarness.controller(FakeSimulatorTransportFactory())
        let view = SimulatorScreenNSView(controller: controller, isInteractive: true)
        view.setFrameSize(NSSize(width: 300, height: 300))
        controller.renderer.contentPixelSize = CGSize(width: 100, height: 200)
        let screen = CGRect(x: 75, y: 0, width: 150, height: 300)
        #expect(controller.renderer.displayRect == screen)
        #expect(controller.renderer.layer.frame == screen)
        #expect(controller.renderer.videoLayer.frame == CGRect(origin: .zero, size: screen.size))
        #expect(controller.renderer.layer.superlayer === view.layer)
        #expect(view.accessibilityLabel() == "Simulator screen")
        #expect(view.accessibilityRole() == .image)

        view.detach()
        #expect(controller.renderer.layer.superlayer == nil)
    }

    @Test("A JPEG frame is drawn upright, inside the letterboxed screen")
    func jpegRendersUpright() async throws {
        let controller = SimulatorStreamHarness.controller(FakeSimulatorTransportFactory(), codec: .jpeg)
        let (window, content, view) = host(controller, size: NSSize(width: 200, height: 200))
        controller.renderer.contentPixelSize = CGSize(width: 60, height: 100)
        let jpeg = try SimulatorWire.jpegImage(width: 60, height: 100, top: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                                               bottom: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        controller.renderer.showJPEG(SimulatorJPEGFrame(timestampUs: 0, width: 60, height: 100, data: jpeg))
        try await SimulatorStreamWait.until("the frame") { controller.framesShown == 1 }
        #expect(controller.renderer.videoLayer.isHidden)

        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try #require(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // The content view is unflipped, so its layer renders the way the screen shows it.
        try #require(content.layer).render(in: bitmap)
        let pixels = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        // Memory row 0 is the top of the image.
        func pixel(x: Int, y: Int) -> (red: UInt8, blue: UInt8) {
            let offset = y * 800 + x * 4
            return (pixels[offset], pixels[offset + 2])
        }
        let top = pixel(x: 100, y: 20)
        let bottom = pixel(x: 100, y: 180)
        let letterbox = pixel(x: 10, y: 100)
        #expect(top.red > 200 && top.blue < 60, "top \(top)")
        #expect(bottom.blue > 200 && bottom.red < 60, "bottom \(bottom)")
        #expect(letterbox.red < 60 && letterbox.blue < 60, "letterbox \(letterbox)")
        #expect(view.window === window)
    }

    @Test("A replacement view takes the layers; tearing down the old one leaves them alone")
    func replacementView() {
        let controller = SimulatorStreamHarness.controller(FakeSimulatorTransportFactory())
        let old = SimulatorScreenNSView(controller: controller, isInteractive: true)
        old.setFrameSize(NSSize(width: 100, height: 100))
        let replacement = SimulatorScreenNSView(controller: controller, isInteractive: true)
        replacement.setFrameSize(NSSize(width: 300, height: 300))
        #expect(controller.renderer.layer.superlayer === replacement.layer)
        #expect(controller.inputSink === replacement)

        old.setFrameSize(NSSize(width: 50, height: 50))
        old.detach()
        #expect(controller.renderer.layer.superlayer === replacement.layer)
        #expect(controller.inputSink === replacement)
        #expect(controller.renderer.hostBounds == CGRect(x: 0, y: 0, width: 300, height: 300))
    }

    @Test("Clicks and drags become normalized touches; drags coalesce, the letterbox is ignored")
    func clicks() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory)
        let transport = try await SimulatorStreamHarness.live(controller, factory, width: 100, height: 200)
        let (window, _, view) = host(controller, size: NSSize(width: 300, height: 300))
        #expect(controller.renderer.displayRect == CGRect(x: 75, y: 0, width: 150, height: 300))

        // Window points are bottom-up; the view is top-down.
        view.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 150, y: 225), window))
        view.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 187.5, y: 150), window))
        view.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 225, y: 75), window))
        try await SimulatorStreamWait.until("the move") { (try? touches(transport).count) == 2 }
        view.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 400, y: 75), window))
        #expect(window.firstResponder === view)

        // Option-drag pinches around the center.
        view.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 150, y: 150), window, flags: .option))
        view.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 180, y: 150), window, flags: .option))
        try await SimulatorStreamWait.until("the pinch move") { (try? touches(transport).count) == 5 }
        view.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 180, y: 150), window, flags: .option))

        // The letterbox, and buttons other than the left one, are not the simulator.
        view.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 10, y: 150), window))
        view.rightMouseDown(with: try mouse(.rightMouseDown, NSPoint(x: 150, y: 150), window))
        try await Task.sleep(for: .milliseconds(40))

        let sent = try touches(transport)
        #expect(matches(sent, [
            SimulatorTouch(phase: .began, x: 0.5, y: 0.25),
            SimulatorTouch(phase: .moved, x: 1, y: 0.75),
            SimulatorTouch(phase: .ended, x: 1, y: 0.75),
            SimulatorTouch(phase: .began, x: 0.5, y: 0.5, x2: 0.5, y2: 0.5),
            SimulatorTouch(phase: .moved, x: 0.7, y: 0.5, x2: 0.3, y2: 0.5),
            SimulatorTouch(phase: .ended, x: 0.7, y: 0.5, x2: 0.3, y2: 0.5),
        ]), "\(sent)")
        controller.disconnect()
    }

    @Test("Losing focus lifts a finger that is still down")
    func resignEndsTouch() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory)
        let transport = try await SimulatorStreamHarness.live(controller, factory, width: 100, height: 100)
        let (window, _, view) = host(controller, size: NSSize(width: 100, height: 100))
        view.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 25, y: 75), window))
        window.makeFirstResponder(nil)
        try await SimulatorStreamWait.until("the lift") { (try? touches(transport).count) == 2 }
        #expect(try touches(transport) == [
            SimulatorTouch(phase: .began, x: 0.25, y: 0.25),
            SimulatorTouch(phase: .ended, x: 0.25, y: 0.25),
        ])
        controller.disconnect()
    }

    @Test("Keys, modifiers and ⌘-shortcuts reach the simulator; app shortcuts do not, and focus loss lifts held keys")
    func keyboard() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory)
        let transport = try await SimulatorStreamHarness.live(controller, factory)
        let (window, _, view) = host(controller, size: NSSize(width: 100, height: 200))
        #expect(window.makeFirstResponder(view))

        view.keyDown(with: try key(.keyDown, kVK_ANSI_A, window))
        view.keyUp(with: try key(.keyUp, kVK_ANSI_A, window))
        let shift = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: true))
        shift.type = .flagsChanged
        shift.flags = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x02)
        view.flagsChanged(with: try #require(NSEvent(cgEvent: shift)))
        #expect(view.performKeyEquivalent(with: try key(.keyDown, kVK_ANSI_H, window, flags: [.command, .shift])))
        #expect(!view.performKeyEquivalent(with: try key(.keyDown, kVK_ANSI_W, window, flags: .command)))
        window.makeFirstResponder(nil)

        let expected: [SimulatorClientMessage] = [
            .key(usage: 0x04, phase: .down), .key(usage: 0x04, phase: .up), .key(usage: 0xE1, phase: .down),
            .button(.home), .key(usage: 0xE1, phase: .up),
        ]
        try await SimulatorStreamWait.until("keys") { SimulatorStreamHarness.sentAfterHello(transport).count >= expected.count }
        #expect(SimulatorStreamHarness.sentAfterHello(transport) == expected.map(\.json))
        controller.disconnect()
    }

    @Test("Scrolling becomes a gliding finger that lifts after resting")
    func scrolling() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory)
        let transport = try await SimulatorStreamHarness.live(controller, factory)
        // Keep the window: leaving it releases input, glides included.
        let (window, _, view) = host(controller, size: NSSize(width: 100, height: 200))
        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -20, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
        try await SimulatorStreamWait.until("the lift") { (try? touches(transport).last?.phase) == .ended }
        let phases = try touches(transport).map(\.phase)
        #expect(phases.first == .began)
        #expect(phases.contains(.moved))
        #expect(view.window === window)
        controller.disconnect()
    }

    @Test("A non-interactive screen ignores the pointer and gives up focus")
    func nonInteractive() async throws {
        let factory = FakeSimulatorTransportFactory()
        let controller = SimulatorStreamHarness.controller(factory)
        _ = try await SimulatorStreamHarness.live(controller, factory)
        let (window, _, view) = host(controller, size: NSSize(width: 100, height: 200))
        #expect(window.makeFirstResponder(view))
        view.isInteractive = false
        #expect(window.firstResponder !== view)
        #expect(!view.acceptsFirstResponder)
        #expect(view.hitTest(NSPoint(x: 50, y: 50)) == nil)
        view.isInteractive = true
        #expect(view.hitTest(NSPoint(x: 50, y: 50)) === view)
        controller.disconnect()
    }
}
