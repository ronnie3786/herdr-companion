import CoreGraphics
import Foundation
import SwiftUI

/// The hand-crafted morph between the HUD's resting circle and its orb with
/// the agents beneath it.
///
/// The choreography, in the expanding direction: the 20-point status circle
/// swells into the 56-point orb while rising the eight points between the two
/// centres. Its colour does not fade away but drains outward into a rim, which
/// settles onto the orb's state ring and only then hands the colour over. The
/// orb face and its glyph are revealed inside that opening rim, the small
/// satellite controls arrive last, and the agent chips unfurl beneath the orb
/// one after another, each sliding down from under it. Collapsing is not the
/// reverse film played backwards: the chips fold back up first, from the
/// bottom, and the orb contracts afterwards as the colour floods back in.
///
/// Every value is a pure function of progress so the whole thing can be unit
/// tested and rendered at fixed frames. `HerdrHudMorphStage` draws it and
/// `HerdrHudMorphTimeline` advances it.
enum HerdrHudMorph {
    /// Where each layer sits between the two states: 0 is the resting circle,
    /// 1 is the full collapsed HUD. The orb and the agents move on separate
    /// tracks so the orb can lead on the way out and trail on the way back.
    struct State: Equatable, Sendable {
        var orb: Double
        var agents: Double

        static let rest = State(orb: 0, agents: 0)
        static let full = State(orb: 1, agents: 1)
    }

    enum Direction: Equatable, Sendable {
        case expand
        case collapse
    }

    /// One layer's slot on the master timeline.
    struct Track: Sendable {
        let delay: TimeInterval
        let duration: TimeInterval
        let easing: @Sendable (Double) -> Double

        var end: TimeInterval { delay + duration }

        /// Eased progress through this track, 0 before its delay and 1 after
        /// it ends. The easing may overshoot 1 briefly by design.
        func progress(elapsed: TimeInterval) -> Double {
            guard duration > 0 else { return elapsed >= delay ? 1 : 0 }
            return easing(HerdrHudMorph.clamp((elapsed - delay) / duration))
        }
    }

    enum Easing {
        static func easeOutCubic(_ t: Double) -> Double {
            let inverse = 1 - clamp(t)
            return 1 - inverse * inverse * inverse
        }

        static func easeInOutCubic(_ t: Double) -> Double {
            let t = clamp(t)
            if t < 0.5 { return 4 * t * t * t }
            let inverse = -2 * t + 2
            return 1 - inverse * inverse * inverse / 2
        }

        /// Overshoot strength of `settle`. Peaks at about 2.7 percent, which
        /// carries the orb a point and a half past its size before it lands.
        static let settleOvershoot = 0.85

        /// An ease-out that lands with a small overshoot, so the orb reads as
        /// arriving rather than stopping.
        static func settle(_ t: Double) -> Double {
            let t = clamp(t)
            // Exact at both ends so the morph lands on the real surfaces.
            guard t > 0 else { return 0 }
            guard t < 1 else { return 1 }
            let c1 = settleOvershoot
            let c3 = c1 + 1
            let shifted = t - 1
            return 1 + c3 * shifted * shifted * shifted + c1 * shifted * shifted
        }
    }

    // MARK: Timeline

    static let expandOrb = Track(delay: 0, duration: 0.34) { Easing.settle($0) }
    static let expandAgents = Track(delay: 0.16, duration: 0.36) { Easing.easeOutCubic($0) }
    static let collapseAgents = Track(delay: 0, duration: 0.22) { Easing.easeInOutCubic($0) }
    static let collapseOrb = Track(delay: 0.12, duration: 0.30) { Easing.easeInOutCubic($0) }

    static func tracks(for direction: Direction) -> (orb: Track, agents: Track) {
        switch direction {
        case .expand: (expandOrb, expandAgents)
        case .collapse: (collapseOrb, collapseAgents)
        }
    }

    static func duration(for direction: Direction) -> TimeInterval {
        let tracks = tracks(for: direction)
        return max(tracks.orb.end, tracks.agents.end)
    }

    /// How long the AppKit panel keeps the orb's frame once the HUD starts
    /// morphing back to the circle: the whole collapse plus a margin for the
    /// view's own settle step, so the window never shrinks around a
    /// still-moving orb.
    static let restingFrameHold: Duration = .milliseconds(Int(duration(for: .collapse) * 1000) + 100)

    static func state(
        from start: State,
        toward target: State,
        direction: Direction,
        elapsed: TimeInterval
    ) -> State {
        let tracks = tracks(for: direction)
        return State(
            orb: lerp(start.orb, target.orb, tracks.orb.progress(elapsed: elapsed)),
            agents: lerp(start.agents, target.agents, tracks.agents.progress(elapsed: elapsed))
        )
    }

    // MARK: Geometry shared with the orb

    static let restDiameter: CGFloat = HerdrHudPlacement.ultraCompactIndicatorSize
    static let orbDiameter: CGFloat = 56
    static let stateRingInset: CGFloat = 2
    static let stateRingWidth: CGFloat = 2.5
    /// Both surfaces live in the same 88 × 72 lane. The circle rests at its
    /// centre; the orb sits at the top of the lane, eight points higher.
    static let laneCenterX: CGFloat = HerdrHudPlacement.collapsedSize.width / 2
    static let restCenterY: CGFloat = HerdrHudPlacement.collapsedSize.height / 2
    static let orbCenterY: CGFloat = orbDiameter / 2
    static var rise: CGFloat { restCenterY - orbCenterY }

    // MARK: Orb layer

    static func diameter(orb: Double) -> CGFloat {
        lerp(restDiameter, orbDiameter, orb)
    }

    /// The real orb row is drawn underneath at exactly the disc's size, so the
    /// face is always precisely what the opening rim reveals.
    static func faceScale(orb: Double) -> CGFloat {
        diameter(orb: orb) / orbDiameter
    }

    static func centerY(orb: Double) -> CGFloat {
        restCenterY - rise * CGFloat(orb)
    }

    /// The coloured rim contracts from the face's edge onto the state ring
    /// during the last stretch, letting the orb's own graphite edge emerge.
    static func ringOuterDiameter(orb: Double) -> CGFloat {
        diameter(orb: orb) - 2 * stateRingInset * CGFloat(ramp(orb, from: 0.6, to: 0.95))
    }

    /// Solid (the full radius) until a quarter of the way, then hollowing to
    /// the ring's width.
    static func ringLineWidth(orb: Double) -> CGFloat {
        let solid = ringOuterDiameter(orb: orb) / 2
        return lerp(solid, stateRingWidth, Easing.easeInOutCubic(ramp(orb, from: 0.25, to: 0.85)))
    }

    /// The tone colour hands over to the orb's real state ring at the very end.
    static func ringOpacity(orb: Double) -> Double {
        1 - ramp(orb, from: 0.86, to: 1)
    }

    /// The resting circle's one-point hairline, gone once the rim has opened.
    static func hairlineOpacity(orb: Double, resting: Double) -> Double {
        resting * (1 - ramp(orb, from: 0.25, to: 0.6))
    }

    static func faceOpacity(orb: Double) -> Double {
        ramp(orb, from: 0.05, to: 0.4)
    }

    static func glyphOpacity(orb: Double) -> Double {
        ramp(orb, from: 0.3, to: 0.75)
    }

    static func glyphScale(orb: Double) -> CGFloat {
        lerp(0.7, 1, Easing.easeOutCubic(ramp(orb, from: 0.3, to: 0.85)))
    }

    /// The small controls around the orb are the last thing to arrive.
    static func satelliteOpacity(orb: Double) -> Double {
        ramp(orb, from: 0.7, to: 1)
    }

    /// The circle's glow blooms as it wakes and is spent by the time the rim
    /// has opened; the orb's own shadow takes over underneath.
    static func bloom(orb: Double) -> Double {
        guard orb > 0, orb < 0.7 else { return 0 }
        return sin(.pi * orb / 0.7)
    }

    static let restGlowOpacity = 0.22
    static let restGlowRadius: CGFloat = 3

    static func glowOpacity(orb: Double) -> Double {
        (1 - ramp(orb, from: 0.4, to: 0.8)) * (restGlowOpacity + 0.24 * bloom(orb: orb))
    }

    static func glowRadius(orb: Double) -> CGFloat {
        restGlowRadius + 9 * CGFloat(bloom(orb: orb))
    }

    /// A working circle breathes. Its current breath is carried into the first
    /// stretch of the morph instead of snapping to full opacity.
    static func pulseHandoff(orb: Double, pulse: Double) -> Double {
        lerp(pulse, 1, ramp(orb, from: 0, to: 0.3))
    }

    // MARK: Agents layer

    /// Chips unfurl top-first. Because every chip shares the same progress
    /// value, running it backwards folds them up bottom-first for free.
    static func chipStagger(count: Int) -> Double {
        guard count > 1 else { return 0 }
        return min(0.12, 0.55 / Double(count - 1))
    }

    static func chipReveal(agents: Double, index: Int, count: Int) -> Double {
        let delay = Double(max(0, index)) * chipStagger(count: count)
        guard delay < 1 else { return clamp(agents) }
        return clamp((agents - delay) / (1 - delay))
    }

    static func chipOffset(reveal: Double) -> CGFloat {
        -14 * CGFloat(1 - reveal)
    }

    static func chipScale(reveal: Double) -> CGFloat {
        0.88 + 0.12 * CGFloat(reveal)
    }

    /// Chips grow from the point beneath the orb's centre, which sits in the
    /// trailing lane of the 200-point chip column.
    static let chipAnchor = UnitPoint(x: 1 - laneCenterX / HerdrHudPlacement.chipWidth, y: 0)

    /// Companion surfaces below the chips (notes, voice) fade and settle with
    /// the block rather than staggering.
    static func companionOpacity(agents: Double) -> Double {
        ramp(agents, from: 0.3, to: 1)
    }

    static func companionOffset(agents: Double) -> CGFloat {
        -10 * CGFloat(1 - agents)
    }

    // MARK: Maths

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// 0 until `from`, rising linearly to 1 at `to`.
    static func ramp(_ value: Double, from start: Double, to end: Double) -> Double {
        guard end > start else { return value >= end ? 1 : 0 }
        return clamp((value - start) / (end - start))
    }

    static func lerp(_ start: Double, _ end: Double, _ t: Double) -> Double {
        start + (end - start) * t
    }

    static func lerp(_ start: CGFloat, _ end: CGFloat, _ t: Double) -> CGFloat {
        start + (end - start) * CGFloat(t)
    }
}

/// Advances the morph. Retargeting mid-flight starts the new direction from
/// wherever each layer is, so a pointer that comes back during the collapse
/// sees the chips reverse and the orb swell again without a jump.
struct HerdrHudMorphTimeline: Equatable, Sendable {
    private(set) var start: HerdrHudMorph.State
    private(set) var target: HerdrHudMorph.State
    private(set) var direction: HerdrHudMorph.Direction
    /// `nil` while settled on the target.
    private(set) var startedAt: Date?

    static func settled(atRest: Bool) -> HerdrHudMorphTimeline {
        let state: HerdrHudMorph.State = atRest ? .rest : .full
        return HerdrHudMorphTimeline(
            start: state,
            target: state,
            direction: atRest ? .collapse : .expand,
            startedAt: nil
        )
    }

    var isAtRest: Bool { target == .rest }
    var isAnimating: Bool { startedAt != nil }
    var duration: TimeInterval { startedAt == nil ? 0 : HerdrHudMorph.duration(for: direction) }

    func state(at date: Date) -> HerdrHudMorph.State {
        guard let startedAt else { return target }
        return HerdrHudMorph.state(
            from: start,
            toward: target,
            direction: direction,
            elapsed: date.timeIntervalSince(startedAt)
        )
    }

    func isSettled(at date: Date) -> Bool {
        guard let startedAt else { return true }
        return date.timeIntervalSince(startedAt) >= duration
    }

    func remainingDuration(at date: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, duration - date.timeIntervalSince(startedAt))
    }

    mutating func retarget(toRest rest: Bool, at date: Date, animated: Bool) {
        let newTarget: HerdrHudMorph.State = rest ? .rest : .full
        let current = state(at: date)
        target = newTarget
        direction = rest ? .collapse : .expand
        if animated, current != newTarget {
            start = current
            startedAt = date
        } else {
            start = newTarget
            startedAt = nil
        }
    }
}
