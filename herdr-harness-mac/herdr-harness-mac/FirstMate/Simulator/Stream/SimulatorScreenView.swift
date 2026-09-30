import AppKit
import QuartzCore
import SwiftUI

/// The simulator's live screen. Size it to `controller.pixelSize`'s aspect
/// ratio; rounding its corners and drawing a bezel are the caller's job.
/// Show a controller in one screen view at a time.
struct SimulatorScreenView: NSViewRepresentable {
    let controller: SimulatorStreamController
    var isInteractive = true

    func makeNSView(context: Context) -> SimulatorScreenNSView {
        SimulatorScreenNSView(controller: controller, isInteractive: isInteractive)
    }

    func updateNSView(_ view: SimulatorScreenNSView, context: Context) {
        view.controller = controller
        view.isInteractive = isInteractive
    }

    static func dismantleNSView(_ view: SimulatorScreenNSView, coordinator: ()) {
        view.detach()
    }
}

/// Hosts the controller's video layers and turns mouse, scroll and keyboard
/// input into simulator touches and HID keys. Its bounds are the displayed
/// screen (letterboxed if the caller's aspect ratio is off), in a top-left
/// coordinate space like the simulator's.
final class SimulatorScreenNSView: NSView {
    var controller: SimulatorStreamController {
        willSet {
            guard newValue !== controller else { return }
            releaseInput()
            detachRenderer()
        }
        didSet {
            guard controller !== oldValue else { return }
            attachRenderer()
        }
    }

    var isInteractive: Bool {
        didSet {
            guard isInteractive != oldValue, !isInteractive else { return }
            releaseInput()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            setTyping(false)
        }
    }

    private struct ActiveTouch {
        var point: CGPoint
        let pinch: Bool
    }

    /// AppKit keeps its geometry matched to `isFlipped`, so sublayers use the
    /// view's top-left coordinates while their contents still draw upright.
    private let rootLayer = CALayer()
    private let touchDots = [SimulatorScreenNSView.makeTouchDot(), SimulatorScreenNSView.makeTouchDot()]
    private var keyboard = SimulatorKeyboardState()
    private var touch: ActiveTouch?
    private var pendingMove: CGPoint?
    private var glide: SimulatorWheelGlide?
    private var ticker: Timer?

    init(controller: SimulatorStreamController, isInteractive: Bool) {
        self.controller = controller
        self.isInteractive = isInteractive
        super.init(frame: .zero)
        // Assigning the layer before `wantsLayer` makes this a layer-hosting
        // view: the video layers are ours, not redrawn by AppKit.
        layer = rootLayer
        wantsLayer = true
        rootLayer.masksToBounds = true
        for dot in touchDots { rootLayer.addSublayer(dot) }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Simulator screen")
        setAccessibilityHelp("Click to tap, drag to swipe, scroll to scroll. Typing goes to the simulator.")
        attachRenderer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Lets go of the simulator and the video layers; the representable's teardown.
    func detach() {
        releaseInput()
        detachRenderer()
    }

    /// SwiftUI can build a replacement view before tearing this one down;
    /// the newest view takes the layers, and the old one must not touch them.
    private var hostsRenderer: Bool { controller.renderer.layer.superlayer === rootLayer }

    private func attachRenderer() {
        let renderer = controller.renderer
        rootLayer.insertSublayer(renderer.layer, at: 0)
        renderer.hostBounds = bounds
        renderer.contentsScale = rootLayer.contentsScale
        controller.inputSink = self
    }

    private func detachRenderer() {
        if hostsRenderer { controller.renderer.layer.removeFromSuperlayer() }
        if controller.inputSink === self {
            controller.setTyping(false)
            controller.inputSink = nil
        }
    }

    private func setTyping(_ typing: Bool) {
        if controller.inputSink === self { controller.setTyping(typing) }
    }

    // MARK: Layout

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if hostsRenderer { controller.renderer.hostBounds = bounds }
    }

    override func layout() {
        super.layout()
        if hostsRenderer { controller.renderer.hostBounds = bounds }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        rootLayer.contentsScale = scale
        for dot in touchDots { dot.contentsScale = scale }
        if hostsRenderer { controller.renderer.contentsScale = scale }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        }
        if newWindow == nil {
            releaseInput()
            setTyping(false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
        viewDidChangeBackingProperties()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        // Key-ups and mouse-ups go to whatever is key now: let go before they are lost.
        releaseInput()
        setTyping(false)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        updateTyping(isFirstResponder: window?.firstResponder === self)
    }

    // MARK: Pointer

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        guard controller.acceptsInput else { return }
        endGlide()
        let location = convert(event.locationInWindow, from: nil)
        let screen = controller.renderer.displayRect
        // A click in the letterbox is not on the simulator.
        guard screen.contains(location) else { return }
        let point = SimulatorInputMath.normalized(location, in: screen)
        let pinch = event.modifierFlags.contains(.option)
        touch = ActiveTouch(point: point, pinch: pinch)
        pendingMove = nil
        controller.send(.touch(SimulatorInputMath.touch(.began, at: point, pinch: pinch)))
        showTouchDots(at: point, pinch: pinch)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var touch else { return }
        touch.point = normalizedPoint(of: event)
        self.touch = touch
        showTouchDots(at: touch.point, pinch: touch.pinch)
        // Sent on the next tick, so a fast mouse sends at most one move per frame.
        pendingMove = touch.point
        startTicker()
    }

    override func mouseUp(with event: NSEvent) {
        guard let touch else { return }
        let point = normalizedPoint(of: event)
        self.touch = nil
        pendingMove = nil
        controller.send(.touch(SimulatorInputMath.touch(.ended, at: point, pinch: touch.pinch)))
        hideTouchDots()
    }

    override func scrollWheel(with event: NSEvent) {
        guard isInteractive, controller.acceptsInput, touch == nil else { return super.scrollWheel(with: event) }
        // A resting or lifting trackpad reports zero deltas; no finger should go down for those.
        guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return }
        let screen = controller.renderer.displayRect
        guard screen.width > 0, screen.height > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var current = glide ?? SimulatorWheelGlide(
            cursor: SimulatorInputMath.normalized(convert(event.locationInWindow, from: nil), in: screen), now: now)
        let unit = event.hasPreciseScrollingDeltas ? 1 : SimulatorWheelGlide.lineHeight
        current.scroll(dx: Double(event.scrollingDeltaX) * unit, dy: Double(event.scrollingDeltaY) * unit,
                       in: screen.size, now: now)
        glide = current
        startTicker()
    }

    private func normalizedPoint(of event: NSEvent) -> CGPoint {
        SimulatorInputMath.normalized(convert(event.locationInWindow, from: nil), in: controller.renderer.displayRect)
    }

    private func endGlide() {
        if let ended = glide?.endedIfBegun { controller.send(.touch(ended)) }
        glide = nil
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            // Scheduled on the main run loop below.
            MainActor.assumeIsolated { self.tick() }
        }
        // Common modes keep it running while AppKit tracks a drag or scroll.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        if let point = pendingMove, let touch {
            pendingMove = nil
            controller.send(.touch(SimulatorInputMath.touch(.moved, at: point, pinch: touch.pinch)))
        }
        if var current = glide {
            let step = current.step(in: controller.renderer.displayRect.size, now: ProcessInfo.processInfo.systemUptime)
            for touch in step.touches { controller.send(.touch(touch)) }
            glide = step.isFinished ? nil : current
        }
        if pendingMove == nil, glide == nil { stopTicker() }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { isInteractive }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        updateTyping(isFirstResponder: true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        releaseInput()
        updateTyping(isFirstResponder: false)
        return true
    }

    private func updateTyping(isFirstResponder: Bool) {
        setTyping(isInteractive && isFirstResponder && window?.isKeyWindow == true)
    }

    /// Runs before the app's menus see a ⌘-key, so the simulator's shortcuts
    /// and editing combos win while typing goes to it; everything else
    /// (⌘W, ⌘Q, ⌘Tab, menu items) is left alone.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, isInteractive, window?.firstResponder === self, controller.acceptsInput else {
            return super.performKeyEquivalent(with: event)
        }
        switch SimulatorKeyboardState.keyEquivalent(keyCode: event.keyCode, modifiers: event.modifierFlags) {
        case .appShortcut:
            return super.performKeyEquivalent(with: event)
        case .button, .paste, .forward:
            perform(keyboard.keyDown(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat),
                    for: event)
            return true
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isInteractive else { return super.keyDown(with: event) }
        // Until the stream is live, typing goes nowhere rather than beeping.
        guard controller.acceptsInput else { return }
        perform(keyboard.keyDown(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat),
                for: event)
    }

    override func keyUp(with event: NSEvent) {
        let messages = keyboard.keyUp(keyCode: event.keyCode)
        guard !messages.isEmpty else { return super.keyUp(with: event) }
        for message in messages { controller.send(message) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isInteractive, controller.acceptsInput else { return super.flagsChanged(with: event) }
        for message in keyboard.flagsChanged(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            controller.send(message)
        }
    }

    private func perform(_ command: SimulatorKeyCommand, for event: NSEvent) {
        switch command {
        case .forward(let messages):
            for message in messages { controller.send(message) }
        case .button(let button):
            controller.pressButton(button)
        case .paste:
            // The text is private: it goes to the simulator and nowhere else.
            if let text = NSPasteboard.general.string(forType: .string) { controller.paste(text) }
        case .passThrough:
            super.keyDown(with: event)
        }
    }

    // MARK: Releasing input

    /// Lifts every held key and finger, so nothing stays stuck in the simulator.
    private func releaseInput() {
        for message in keyboard.releaseAll() { controller.send(message) }
        if let touch {
            controller.send(.touch(SimulatorInputMath.touch(.ended, at: touch.point, pinch: touch.pinch)))
            self.touch = nil
        }
        endGlide()
        pendingMove = nil
        hideTouchDots()
        stopTicker()
    }

    private func forgetInput() {
        _ = keyboard.releaseAll()
        touch = nil
        glide = nil
        pendingMove = nil
        hideTouchDots()
        stopTicker()
    }

    // MARK: Touch dots

    private static func makeTouchDot() -> CALayer {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
        dot.cornerRadius = 13
        dot.backgroundColor = CGColor(gray: 1, alpha: 0.32)
        dot.borderColor = CGColor(gray: 1, alpha: 0.7)
        dot.borderWidth = 1
        dot.zPosition = 1
        dot.isHidden = true
        return dot
    }

    private func showTouchDots(at point: CGPoint, pinch: Bool) {
        let screen = controller.renderer.displayRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(touchDots[0], at: point, in: screen)
        if pinch { place(touchDots[1], at: SimulatorInputMath.mirrored(point), in: screen) }
        touchDots[0].isHidden = false
        touchDots[1].isHidden = !pinch
        CATransaction.commit()
    }

    private func hideTouchDots() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in touchDots { dot.isHidden = true }
        CATransaction.commit()
    }

    private func place(_ dot: CALayer, at point: CGPoint, in screen: CGRect) {
        dot.position = CGPoint(x: screen.minX + point.x * screen.width, y: screen.minY + point.y * screen.height)
    }
}

extension SimulatorScreenNSView: SimulatorStreamInputSink {
    func streamDidReleaseInput() {
        forgetInput()
    }
}
