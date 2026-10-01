import CoreGraphics
import Foundation

/// Geometry shared by rendering and input: both must agree on where the
/// simulator's screen is drawn, or taps land beside what the user pointed at.
enum SimulatorInputMath {
    static func clamp(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
        guard value.isFinite else { return (lower + upper) / 2 }
        return min(max(value, lower), upper)
    }

    /// The largest rect with the stream's aspect ratio centered in `bounds`;
    /// all of `bounds` until the stream's size is known.
    static func aspectFitRect(for content: CGSize?, in bounds: CGRect) -> CGRect {
        guard let content, content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// `point` as fractions of `rect`, clamped to it. Both use a top-left origin.
    static func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: clamp(Double((point.x - rect.minX) / rect.width)),
                       y: clamp(Double((point.y - rect.minY) / rect.height)))
    }

    /// Option-drag pinches around the screen's center, like the Simulator app.
    static func mirrored(_ point: CGPoint) -> CGPoint {
        CGPoint(x: 1 - point.x, y: 1 - point.y)
    }

    static func touch(_ phase: SimulatorTouchPhase, at point: CGPoint, pinch: Bool) -> SimulatorTouch {
        SimulatorTouch(phase: phase, at: point, second: pinch ? mirrored(point) : nil)
    }
}

/// Turns wheel and trackpad scrolling into a finger drag, ported from
/// SimPortal's browser viewer. The finger glides toward where the wheel says
/// it should be, because a notched wheel jumps far enough per event that iOS
/// would not read it as a drag, and it lifts only after resting, so a scroll
/// stops where it was left. Unlike the browser, the finger goes down only
/// once the scroll has moved a few points: a touch that barely moves is a
/// tap in iOS, and nudging the trackpad should not press what is under the
/// pointer. Positions are fractions of the screen (top-left origin);
/// distances are in view points.
struct SimulatorWheelGlide: Equatable, Sendable {
    /// Farthest the finger moves per tick.
    static let stepPoints: Double = 28
    /// Quiet time after the last wheel event before the finger lifts.
    static let restInterval: TimeInterval = 0.14
    /// Points per line for wheels without precise deltas.
    static let lineHeight: Double = 18
    /// Scroll distance before the finger goes down.
    static let startDistance: Double = 6

    private(set) var position: CGPoint
    private(set) var target: CGPoint
    let origin: CGPoint
    private(set) var lastInput: TimeInterval
    /// Whether the simulator has this glide's finger down.
    private(set) var hasBegun = false

    /// Starts at the cursor, kept away from the edges so there is room to drag.
    init(cursor: CGPoint, now: TimeInterval) {
        let start = CGPoint(x: SimulatorInputMath.clamp(Double(cursor.x), 0.1, 0.9),
                            y: SimulatorInputMath.clamp(Double(cursor.y), 0.2, 0.8))
        position = start
        target = start
        origin = start
        lastInput = now
    }

    /// Lifts the finger where it is, e.g. when a click interrupts the glide;
    /// `nil` when it never went down.
    var endedIfBegun: SimulatorTouch? {
        hasBegun ? SimulatorTouch(phase: .ended, at: position) : nil
    }

    /// Moves the target by a scroll delta in points. AppKit's scrolling deltas
    /// already point the way the content should move (the opposite of a DOM
    /// wheel delta), so the finger follows them directly.
    mutating func scroll(dx: Double, dy: Double, in size: CGSize, now: TimeInterval) {
        guard size.width > 0, size.height > 0, dx.isFinite, dy.isFinite else { return }
        target.x += dx / size.width
        target.y += dy / size.height
        lastInput = now
    }

    struct Step: Equatable, Sendable {
        var touches: [SimulatorTouch]
        var isFinished: Bool
    }

    /// One tick: put the finger down once there is somewhere to go, glide
    /// toward the target, restart from the origin when out of room (carrying
    /// what is left), and lift once at rest.
    mutating func step(in size: CGSize, now: TimeInterval) -> Step {
        guard size.width > 0, size.height > 0 else { return finished }
        let dx = (target.x - position.x) * size.width
        let dy = (target.y - position.y) * size.height
        let distance = hypot(dx, dy)
        var touches: [SimulatorTouch] = []
        if !hasBegun {
            guard distance >= Self.startDistance else {
                return now - lastInput > Self.restInterval ? finished : Step(touches: [], isFinished: false)
            }
            hasBegun = true
            touches.append(SimulatorTouch(phase: .began, at: position))
        }
        if distance > 0.5 {
            let k = min(1, Self.stepPoints / distance)
            position.x += dx * k / size.width
            position.y += dy * k / size.height
            touches.append(SimulatorTouch(phase: .moved, at: position))
            if position.x < 0.03 || position.x > 0.97 || position.y < 0.05 || position.y > 0.95 {
                touches.append(SimulatorTouch(phase: .ended, at: position))
                let remaining = CGPoint(x: target.x - position.x, y: target.y - position.y)
                position = origin
                target = CGPoint(x: origin.x + remaining.x, y: origin.y + remaining.y)
                touches.append(SimulatorTouch(phase: .began, at: position))
            }
            return Step(touches: touches, isFinished: false)
        }
        if now - lastInput > Self.restInterval { return finished }
        return Step(touches: touches, isFinished: false)
    }

    private var finished: Step {
        Step(touches: endedIfBegun.map { [$0] } ?? [], isFinished: true)
    }
}
