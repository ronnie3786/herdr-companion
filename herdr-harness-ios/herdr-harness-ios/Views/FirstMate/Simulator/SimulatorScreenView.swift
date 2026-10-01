import QuartzCore
import SwiftUI
import UIKit

/// The simulator's live screen on iPad and iPhone. Size it to the stream's
/// aspect ratio; rounding its corners and drawing a bezel are the caller's
/// job. Show a controller in one screen view at a time (a layer has one
/// superlayer).
struct SimulatorScreenView: UIViewRepresentable {
    let controller: SimulatorStreamController
    var isInteractive = true

    func makeUIView(context: Context) -> SimulatorScreenUIView {
        SimulatorScreenUIView(controller: controller, isInteractive: isInteractive)
    }

    func updateUIView(_ view: SimulatorScreenUIView, context: Context) {
        view.controller = controller
        view.isInteractive = isInteractive
    }

    static func dismantleUIView(_ view: SimulatorScreenUIView, coordinator: ()) {
        view.detach()
    }
}

/// Hosts the controller's video layers and turns touches into simulator
/// touches (one finger, or two for a pinch or rotate) and hardware-keyboard
/// presses into HID keys. Positions use the shared `SimulatorInputMath`, so
/// taps land where the picture is drawn; touches in the letterbox are ignored.
final class SimulatorScreenUIView: UIView {
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
            if isFirstResponder { _ = resignFirstResponder() }
        }
    }

    /// The fingers this view is driving: one, or two for a pinch.
    private var primary: UITouch?
    private var secondary: UITouch?
    private var pendingMove = false
    private var displayLink: CADisplayLink?
    /// Held hardware keys (HID usages), most recent last.
    private var heldKeys: [Int] = []
    private let touchDots = [SimulatorScreenUIView.makeTouchDot(), SimulatorScreenUIView.makeTouchDot()]

    init(controller: SimulatorStreamController, isInteractive: Bool) {
        self.controller = controller
        self.isInteractive = isInteractive
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        isMultipleTouchEnabled = true
        for dot in touchDots { layer.addSublayer(dot) }
        isAccessibilityElement = true
        accessibilityTraits = [.image, .allowsDirectInteraction]
        accessibilityLabel = "Simulator screen"
        accessibilityHint = "Touches go to the simulator. A hardware keyboard types into it."
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
    private var hostsRenderer: Bool { controller.renderer.layer.superlayer === layer }

    private func attachRenderer() {
        let renderer = controller.renderer
        layer.insertSublayer(renderer.layer, at: 0)
        renderer.hostBounds = bounds
        renderer.contentsScale = traitCollection.displayScale
        controller.inputSink = self
    }

    private func detachRenderer() {
        if hostsRenderer { controller.renderer.layer.removeFromSuperlayer() }
        if controller.inputSink === self { controller.inputSink = nil }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if hostsRenderer { controller.renderer.hostBounds = bounds }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scale = traitCollection.displayScale
        for dot in touchDots { dot.contentsScale = scale }
        if hostsRenderer { controller.renderer.contentsScale = scale }
        if window == nil { releaseInput() }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isInteractive else { return super.touchesBegan(touches, with: event) }
        if !isFirstResponder { becomeFirstResponder() }
        guard controller.acceptsInput else { return }
        let screen = controller.renderer.displayRect
        for touch in touches {
            if primary == nil {
                // A touch in the letterbox is not on the simulator.
                guard screen.contains(touch.location(in: self)) else { continue }
                primary = touch
                send(.began)
            } else if secondary == nil {
                // A second finger turns the drag into a two-finger gesture:
                // lift the one finger, then put both down together.
                send(.ended)
                secondary = touch
                send(.began)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isTracking(touches) else { return super.touchesMoved(touches, with: event) }
        updateTouchDots()
        // Sent on the next frame, so a 120 Hz display sends at most 60 moves a second.
        pendingMove = true
        startDisplayLink()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isTracking(touches) else { return super.touchesEnded(touches, with: event) }
        finishGesture(.ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isTracking(touches) else { return super.touchesCancelled(touches, with: event) }
        finishGesture(.cancelled)
    }

    private func isTracking(_ touches: Set<UITouch>) -> Bool {
        touches.contains { $0 === primary || $0 === secondary }
    }

    /// Any tracked finger lifting ends the whole gesture; a finger left on the
    /// glass is ignored until every finger is up and a new touch begins.
    private func finishGesture(_ phase: SimulatorTouchPhase) {
        pendingMove = false
        send(phase)
        primary = nil
        secondary = nil
        hideTouchDots()
        stopDisplayLink()
    }

    private var points: (CGPoint, CGPoint?)? {
        guard let primary else { return nil }
        let screen = controller.renderer.displayRect
        return (SimulatorInputMath.normalized(primary.location(in: self), in: screen),
                secondary.map { SimulatorInputMath.normalized($0.location(in: self), in: screen) })
    }

    private func send(_ phase: SimulatorTouchPhase) {
        guard let points else { return }
        controller.send(.touch(SimulatorTouch(phase: phase, at: points.0, second: points.1)))
        if phase == .began || phase == .moved { updateTouchDots() }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tick() {
        guard pendingMove else { return stopDisplayLink() }
        pendingMove = false
        send(.moved)
    }

    /// Breaks the display link's strong reference to the view.
    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var view: SimulatorScreenUIView?
        init(_ view: SimulatorScreenUIView) { self.view = view }
        // The link runs on the main run loop.
        @objc func tick() { view?.tick() }
    }

    // MARK: Hardware keyboard

    override var canBecomeFirstResponder: Bool { isInteractive }

    override func resignFirstResponder() -> Bool {
        releaseKeys()
        return super.resignFirstResponder()
    }

    /// UIKit reports keys by USB HID usage (page 0x07), the numbers SimPortal
    /// hands to the simulator, so the simulator's own keyboard layout decides
    /// the character, as with SimPortal's browser viewer.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isInteractive, controller.acceptsInput else { return super.pressesBegan(presses, with: event) }
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let usage = Self.usage(of: press) else {
                unhandled.insert(press)
                continue
            }
            if !heldKeys.contains(usage) {
                heldKeys.append(usage)
                controller.send(.key(usage: usage, phase: .down))
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = keysUp(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = keysUp(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func keysUp(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let usage = Self.usage(of: press), let index = heldKeys.firstIndex(of: usage) else {
                unhandled.insert(press)
                continue
            }
            heldKeys.remove(at: index)
            controller.send(.key(usage: usage, phase: .up))
        }
        return unhandled
    }

    static func usage(of press: UIPress) -> Int? {
        guard let key = press.key else { return nil }
        let usage = key.keyCode.rawValue
        // Keyboard page usages: letters through the right GUI key.
        return (0x04...0xE7).contains(usage) ? usage : nil
    }

    // MARK: Releasing input

    /// Lifts every held key and finger, so nothing stays stuck in the simulator.
    private func releaseInput() {
        releaseKeys()
        if primary != nil { finishGesture(.cancelled) }
        stopDisplayLink()
    }

    private func releaseKeys() {
        for usage in heldKeys.reversed() { controller.send(.key(usage: usage, phase: .up)) }
        heldKeys = []
    }

    /// The server already released everything: forget it without sending.
    private func forgetInput() {
        heldKeys = []
        primary = nil
        secondary = nil
        pendingMove = false
        hideTouchDots()
        stopDisplayLink()
    }

    // MARK: Touch dots

    private static func makeTouchDot() -> CALayer {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
        dot.cornerRadius = 15
        dot.backgroundColor = UIColor(white: 1, alpha: 0.32).cgColor
        dot.borderColor = UIColor(white: 1, alpha: 0.7).cgColor
        dot.borderWidth = 1
        dot.zPosition = 1
        dot.isHidden = true
        return dot
    }

    private func updateTouchDots() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let tracked = [primary, secondary]
        for (dot, touch) in zip(touchDots, tracked) {
            if let touch {
                let screen = controller.renderer.displayRect
                let point = SimulatorInputMath.normalized(touch.location(in: self), in: screen)
                dot.position = CGPoint(x: screen.minX + point.x * screen.width, y: screen.minY + point.y * screen.height)
                dot.isHidden = false
            } else {
                dot.isHidden = true
            }
        }
        CATransaction.commit()
    }

    private func hideTouchDots() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in touchDots { dot.isHidden = true }
        CATransaction.commit()
    }
}

extension SimulatorScreenUIView: SimulatorStreamInputSink {
    func streamDidReleaseInput() {
        forgetInput()
    }
}
