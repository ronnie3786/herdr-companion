import CoreGraphics
import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("Simulator input math")
struct SimulatorInputMathTests {
    private func close(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

    private func close(_ touch: SimulatorTouch, _ phase: SimulatorTouchPhase, x: Double, y: Double) -> Bool {
        touch.phase == phase && close(touch.x, x) && close(touch.y, y)
    }

    @Test("Points normalize to the displayed screen and clamp to it")
    func normalization() {
        let screen = CGRect(x: 10, y: 20, width: 200, height: 400)
        #expect(SimulatorInputMath.normalized(CGPoint(x: 110, y: 220), in: screen) == CGPoint(x: 0.5, y: 0.5))
        #expect(SimulatorInputMath.normalized(CGPoint(x: 10, y: 20), in: screen) == CGPoint(x: 0, y: 0))
        #expect(SimulatorInputMath.normalized(CGPoint(x: 60, y: 120), in: screen) == CGPoint(x: 0.25, y: 0.25))
        #expect(SimulatorInputMath.normalized(CGPoint(x: -50, y: 900), in: screen) == CGPoint(x: 0, y: 1))
        #expect(SimulatorInputMath.normalized(CGPoint(x: 5, y: 5), in: .zero) == CGPoint(x: 0.5, y: 0.5))
        #expect(SimulatorInputMath.clamp(.nan) == 0.5)
        #expect(SimulatorInputMath.clamp(3, 0.1, 0.9) == 0.9)
    }

    @Test("The screen aspect-fits and centers in the view, excluding the letterbox")
    func aspectFit() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let tall = SimulatorInputMath.aspectFitRect(for: CGSize(width: 1206, height: 2622), in: bounds)
        #expect(close(Double(tall.height), 400))
        #expect(close(Double(tall.width), 400 * 1206 / 2622))
        #expect(close(Double(tall.midX), 200) && close(Double(tall.midY), 200))
        let wide = SimulatorInputMath.aspectFitRect(for: CGSize(width: 2622, height: 1206), in: CGRect(x: 0, y: 0, width: 300, height: 600))
        #expect(close(Double(wide.width), 300) && close(Double(wide.minY), 300 - Double(wide.height) / 2))
        #expect(SimulatorInputMath.aspectFitRect(for: nil, in: bounds) == bounds)
        #expect(SimulatorInputMath.aspectFitRect(for: CGSize(width: 0, height: 10), in: bounds) == bounds)
        // A click at the letterbox edge maps to the screen's edge.
        #expect(SimulatorInputMath.normalized(CGPoint(x: 0, y: 200), in: tall).x == 0)
    }

    @Test("Option-drag pinches through the screen's center")
    func pinch() {
        #expect(SimulatorInputMath.mirrored(CGPoint(x: 0.2, y: 0.3)) == CGPoint(x: 0.8, y: 0.7))
        let touch = SimulatorInputMath.touch(.moved, at: CGPoint(x: 0.25, y: 0.75), pinch: true)
        #expect(touch == SimulatorTouch(phase: .moved, x: 0.25, y: 0.75, x2: 0.75, y2: 0.25))
        let single = SimulatorInputMath.touch(.began, at: CGPoint(x: 0.25, y: 0.75), pinch: false)
        #expect(single.x2 == nil && single.y2 == nil)
    }

    @Test("A glide starts at the cursor, kept away from the edges")
    func glideStart() {
        let corner = SimulatorWheelGlide(cursor: CGPoint(x: 0.02, y: 0.97), now: 0)
        #expect(corner.origin == CGPoint(x: 0.1, y: 0.8))
        #expect(corner.position == corner.origin && corner.target == corner.origin)
        let middle = SimulatorWheelGlide(cursor: CGPoint(x: 0.4, y: 0.6), now: 0)
        #expect(middle.origin == CGPoint(x: 0.4, y: 0.6))
        #expect(middle.endedIfBegun == nil)
    }

    @Test("A nudge below the start distance never puts a finger down")
    func glideNudge() {
        let size = CGSize(width: 400, height: 800)
        var glide = SimulatorWheelGlide(cursor: CGPoint(x: 0.5, y: 0.5), now: 0)
        glide.scroll(dx: 0, dy: 3, in: size, now: 0)
        #expect(glide.step(in: size, now: 0.016) == .init(touches: [], isFinished: false))
        #expect(glide.step(in: size, now: 0.2) == .init(touches: [], isFinished: true))
        #expect(!glide.hasBegun)
    }

    @Test("The finger goes down, then moves at most 28 points per tick toward the target")
    func glideStepCap() {
        let size = CGSize(width: 400, height: 800)
        var glide = SimulatorWheelGlide(cursor: CGPoint(x: 0.5, y: 0.5), now: 0)
        glide.scroll(dx: 0, dy: 100, in: size, now: 0)
        let first = glide.step(in: size, now: 0.016)
        #expect(first.touches.count == 2)
        #expect(close(first.touches[0], .began, x: 0.5, y: 0.5))
        #expect(close(first.touches[1], .moved, x: 0.5, y: 0.5 + 28.0 / 800))

        var y = 0.5 + 28.0 / 800
        var now = 0.016
        for expectedStep in [28.0, 28.0, 16.0] {
            now += 0.016
            let step = glide.step(in: size, now: now)
            y += expectedStep / 800
            #expect(step.touches.count == 1)
            #expect(close(step.touches[0], .moved, x: 0.5, y: y))
            #expect(!step.isFinished)
        }
        #expect(close(y, 0.5 + 100.0 / 800))
        // At the target but the wheel was used recently: hold still.
        #expect(glide.step(in: size, now: 0.1) == .init(touches: [], isFinished: false))
        // After resting, lift where it stopped.
        let lift = glide.step(in: size, now: 0.2)
        #expect(lift.isFinished)
        #expect(lift.touches.count == 1 && close(lift.touches[0], .ended, x: 0.5, y: 0.625))
    }

    @Test("Diagonal steps are capped by distance, not per axis")
    func glideDiagonal() {
        let size = CGSize(width: 100, height: 100)
        var glide = SimulatorWheelGlide(cursor: CGPoint(x: 0.5, y: 0.5), now: 0)
        glide.scroll(dx: -30, dy: -40, in: size, now: 0)
        let step = glide.step(in: size, now: 0.016)
        // 50 points away along (-3, -4): 28 points is (-16.8, -22.4).
        #expect(close(step.touches[1], .moved, x: 0.5 - 0.168, y: 0.5 - 0.224))
    }

    @Test("Out of room, the finger lifts and restarts at its origin carrying the rest")
    func glideEdgeRestart() {
        let size = CGSize(width: 100, height: 100)
        var glide = SimulatorWheelGlide(cursor: CGPoint(x: 0.5, y: 0.5), now: 0)
        glide.scroll(dx: 0, dy: 60, in: size, now: 0)
        let first = glide.step(in: size, now: 0.016)
        #expect(close(first.touches[0], .began, x: 0.5, y: 0.5))
        #expect(close(first.touches[1], .moved, x: 0.5, y: 0.78))

        // 32 points remain; 28 of them go past the bottom edge band (0.95).
        let edge = glide.step(in: size, now: 0.032)
        #expect(edge.touches.count == 3)
        #expect(close(edge.touches[0], .moved, x: 0.5, y: 1))
        #expect(close(edge.touches[1], .ended, x: 0.5, y: 1))
        #expect(close(edge.touches[2], .began, x: 0.5, y: 0.5))
        #expect(close(Double(glide.position.y), 0.5) && close(Double(glide.target.y), 0.54))

        let rest = glide.step(in: size, now: 0.048)
        #expect(rest.touches.count == 1 && close(rest.touches[0], .moved, x: 0.5, y: 0.54))
        let lift = glide.step(in: size, now: 0.5)
        #expect(lift.isFinished && close(lift.touches[0], .ended, x: 0.5, y: 0.54))
    }

    @Test("More scrolling while gliding extends the target and delays the lift")
    func glideKeepsGoing() {
        let size = CGSize(width: 200, height: 200)
        var glide = SimulatorWheelGlide(cursor: CGPoint(x: 0.5, y: 0.5), now: 0)
        glide.scroll(dx: 10, dy: 0, in: size, now: 0)
        _ = glide.step(in: size, now: 0.016)
        #expect(glide.step(in: size, now: 0.1).touches.isEmpty)
        glide.scroll(dx: 10, dy: 0, in: size, now: 0.12)
        let step = glide.step(in: size, now: 0.2)
        #expect(close(step.touches[0], .moved, x: 0.6, y: 0.5))
        #expect(glide.step(in: size, now: 0.25) == .init(touches: [], isFinished: false))
        #expect(glide.step(in: size, now: 0.3).isFinished)
        #expect(glide.endedIfBegun.map { close($0, .ended, x: 0.6, y: 0.5) } == true)
    }
}
