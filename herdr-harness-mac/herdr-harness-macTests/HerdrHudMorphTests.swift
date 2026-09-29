import CoreGraphics
import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD morph choreography")
struct HerdrHudMorphTests {
    @Test("The morph starts exactly on the resting circle and lands exactly on the full HUD")
    func endpointsAreExact() {
        let expandDuration = HerdrHudMorph.duration(for: .expand)
        let collapseDuration = HerdrHudMorph.duration(for: .collapse)
        #expect(HerdrHudMorph.state(from: .rest, toward: .full, direction: .expand, elapsed: 0) == .rest)
        #expect(HerdrHudMorph.state(from: .rest, toward: .full, direction: .expand, elapsed: expandDuration) == .full)
        #expect(HerdrHudMorph.state(from: .full, toward: .rest, direction: .collapse, elapsed: 0) == .full)
        #expect(HerdrHudMorph.state(from: .full, toward: .rest, direction: .collapse, elapsed: collapseDuration) == .rest)

        // The two ends are the two real surfaces: a 20-point circle centred in
        // the lane, and the 56-point orb at the top of it, eight points higher.
        #expect(HerdrHudMorph.diameter(orb: 0) == HerdrHudPlacement.ultraCompactIndicatorSize)
        #expect(HerdrHudMorph.diameter(orb: 1) == HerdrHudMorph.orbDiameter)
        #expect(HerdrHudMorph.faceScale(orb: 1) == 1)
        #expect(HerdrHudMorph.faceOpacity(orb: 0) == 0)
        #expect(HerdrHudMorph.faceOpacity(orb: 1) == 1)
        #expect(HerdrHudMorph.centerY(orb: 0) == HerdrHudPlacement.collapsedSize.height / 2)
        #expect(HerdrHudMorph.centerY(orb: 1) == HerdrHudMorph.orbDiameter / 2)
        #expect(HerdrHudMorph.rise == 8)
        #expect(HerdrHudMorph.laneCenterX == HerdrHudPlacement.orbLeadingInset + HerdrHudMorph.orbDiameter / 2)
    }

    @Test("Expanding, the orb leads and the agents follow; collapsing, the agents fold first")
    func layersAreChoreographedInOrder() {
        let early = HerdrHudMorph.state(from: .rest, toward: .full, direction: .expand, elapsed: 0.12)
        #expect(early.orb > 0.3)
        #expect(early.agents == 0)
        let late = HerdrHudMorph.state(from: .rest, toward: .full, direction: .expand, elapsed: 0.3)
        #expect(late.orb > 0.95)
        #expect(late.agents > 0)
        #expect(late.agents < 1)

        let foldingEarly = HerdrHudMorph.state(from: .full, toward: .rest, direction: .collapse, elapsed: 0.08)
        #expect(foldingEarly.orb == 1)
        #expect(foldingEarly.agents < 1)
        let foldingLate = HerdrHudMorph.state(from: .full, toward: .rest, direction: .collapse, elapsed: 0.25)
        #expect(foldingLate.agents == 0)
        #expect(foldingLate.orb > 0)
        #expect(foldingLate.orb < 1)
    }

    @Test("The orb settles with a small overshoot and never dips below its start")
    func settleOvershootIsSubtle() {
        var peak = 0.0
        for step in 0...200 {
            let value = HerdrHudMorph.Easing.settle(Double(step) / 200)
            #expect(value >= 0)
            peak = max(peak, value)
        }
        #expect(peak > 1.01)
        #expect(peak < 1.04)
        #expect(HerdrHudMorph.Easing.settle(0) == 0)
        #expect(HerdrHudMorph.Easing.settle(1) == 1)
        #expect(HerdrHudMorph.Easing.easeOutCubic(1) == 1)
        #expect(HerdrHudMorph.Easing.easeInOutCubic(0) == 0)
        #expect(HerdrHudMorph.Easing.easeInOutCubic(1) == 1)
        #expect(HerdrHudMorph.Easing.easeInOutCubic(0.5) == 0.5)
    }

    @Test("Colour drains from the solid disc into a rim that lands on the orb's own state ring")
    func rimSettlesOntoTheStateRing() {
        // Solid at rest and through the first quarter: the stroke spans the radius.
        #expect(HerdrHudMorph.ringLineWidth(orb: 0) >= HerdrHudMorph.diameter(orb: 0) / 2)
        #expect(HerdrHudMorph.ringLineWidth(orb: 0.2) >= HerdrHudMorph.ringOuterDiameter(orb: 0.2) / 2)
        // Exactly the state ring's geometry at the end.
        #expect(HerdrHudMorph.ringOuterDiameter(orb: 1) == HerdrHudMorph.orbDiameter - 2 * HerdrHudMorph.stateRingInset)
        #expect(HerdrHudMorph.ringLineWidth(orb: 1) == HerdrHudMorph.stateRingWidth)
        // The rim hugs the face's edge until it settles inward.
        #expect(HerdrHudMorph.ringOuterDiameter(orb: 0.5) == HerdrHudMorph.diameter(orb: 0.5))
        // Visible through most of the morph, then handed over to the real ring.
        #expect(HerdrHudMorph.ringOpacity(orb: 0.8) == 1)
        #expect(HerdrHudMorph.ringOpacity(orb: 1) == 0)

        // The opening inside the rim only ever grows: the disc stays solid while
        // it swells, then hollows without ever closing back up.
        var previousOpening: CGFloat = -1
        for step in 0...50 {
            let orb = Double(step) / 50
            let opening = HerdrHudMorph.ringOuterDiameter(orb: orb) / 2 - HerdrHudMorph.ringLineWidth(orb: orb)
            #expect(opening >= previousOpening - 0.0001, "the opening never shrinks (orb \(orb))")
            previousOpening = max(previousOpening, opening)
        }
        #expect(previousOpening > 20, "the rim ends up open almost to the ring")
    }

    @Test("The face, glyph, and satellites surface in that order inside the opening rim")
    func faceGlyphAndSatellitesSurfaceInOrder() {
        #expect(HerdrHudMorph.faceOpacity(orb: 0.3) > 0)
        #expect(HerdrHudMorph.glyphOpacity(orb: 0.3) == 0)
        #expect(HerdrHudMorph.glyphOpacity(orb: 0.5) > 0)
        #expect(HerdrHudMorph.satelliteOpacity(orb: 0.5) == 0)
        #expect(HerdrHudMorph.satelliteOpacity(orb: 0.85) > 0)
        #expect(HerdrHudMorph.satelliteOpacity(orb: 1) == 1)
        #expect(HerdrHudMorph.glyphOpacity(orb: 1) == 1)
        #expect(HerdrHudMorph.glyphScale(orb: 0) == 0.7)
        #expect(HerdrHudMorph.glyphScale(orb: 1) == 1)
        #expect(HerdrHudMorph.hairlineOpacity(orb: 0, resting: 0.55) == 0.55)
        #expect(HerdrHudMorph.hairlineOpacity(orb: 1, resting: 0.55) == 0)
    }

    @Test("The glow blooms as the circle wakes and is spent before the orb lands")
    func glowBloomsThenExtinguishes() {
        #expect(HerdrHudMorph.glowOpacity(orb: 0) == HerdrHudMorph.restGlowOpacity)
        #expect(HerdrHudMorph.glowRadius(orb: 0) == HerdrHudMorph.restGlowRadius)
        #expect(HerdrHudMorph.glowRadius(orb: 0.35) > HerdrHudMorph.glowRadius(orb: 0))
        #expect(HerdrHudMorph.glowOpacity(orb: 0.35) > HerdrHudMorph.glowOpacity(orb: 0))
        #expect(HerdrHudMorph.glowOpacity(orb: 1) == 0)
        #expect(HerdrHudMorph.bloom(orb: 0.7) == 0)
        #expect(HerdrHudMorph.bloom(orb: 1) == 0)
    }

    @Test("A working circle's breath is carried into the morph rather than snapped")
    func pulseHandsOff() {
        #expect(HerdrHudMorph.pulseHandoff(orb: 0, pulse: 0.5) == 0.5)
        #expect(HerdrHudMorph.pulseHandoff(orb: 0.15, pulse: 0.5) == 0.75)
        #expect(HerdrHudMorph.pulseHandoff(orb: 0.3, pulse: 0.5) == 1)
        #expect(HerdrHudMorph.pulseHandoff(orb: 1, pulse: 0.5) == 1)
    }

    @Test("Chips unfurl top-first, all arrive together, and the same curve folds them back bottom-first")
    func chipStaggerOrders() {
        let count = 4
        for step in 1..<20 {
            let agents = Double(step) / 20
            let reveals = (0..<count).map { HerdrHudMorph.chipReveal(agents: agents, index: $0, count: count) }
            for index in 1..<count {
                #expect(reveals[index] <= reveals[index - 1], "row \(index) never leads row \(index - 1)")
            }
        }
        #expect((0..<count).allSatisfy { HerdrHudMorph.chipReveal(agents: 1, index: $0, count: count) == 1 })
        #expect((0..<count).allSatisfy { HerdrHudMorph.chipReveal(agents: 0, index: $0, count: count) == 0 })
        // Folding back (agents falling from 1) the bottom row reaches 0 first.
        #expect(HerdrHudMorph.chipReveal(agents: 0.3, index: 3, count: count) == 0)
        #expect(HerdrHudMorph.chipReveal(agents: 0.3, index: 0, count: count) > 0)
        // Long stacks cap the stagger so the last row has started by the midpoint.
        #expect(HerdrHudMorph.chipReveal(agents: 0.6, index: 11, count: 12) > 0)
        #expect(HerdrHudMorph.chipStagger(count: 1) == 0)
        #expect(HerdrHudMorph.chipStagger(count: 4) == 0.12)
        #expect(HerdrHudMorph.chipReveal(agents: 0.5, index: 0, count: 1) == 0.5)

        #expect(HerdrHudMorph.chipOffset(reveal: 1) == 0)
        #expect(HerdrHudMorph.chipScale(reveal: 1) == 1)
        #expect(HerdrHudMorph.chipOffset(reveal: 0) < 0)
        #expect(HerdrHudMorph.chipScale(reveal: 0) < 1)
        #expect(HerdrHudMorph.companionOpacity(agents: 1) == 1)
        #expect(HerdrHudMorph.companionOffset(agents: 1) == 0)
        #expect(HerdrHudMorph.companionOpacity(agents: 0) == 0)
    }

    @Test("The panel frame hold outlasts the collapse, and both directions stay brisk")
    func frameHoldCoversTheCollapse() {
        let collapse = HerdrHudMorph.duration(for: .collapse)
        let expand = HerdrHudMorph.duration(for: .expand)
        #expect(HerdrHudMorph.restingFrameHold >= .milliseconds(Int(collapse * 1000)))
        #expect(HerdrHudMorph.restingFrameHold < .seconds(1))
        #expect(expand < 0.6)
        #expect(collapse < expand)
    }

    @Test("The timeline advances from rest to full and reports when it has settled")
    func timelineRunsToCompletion() {
        var timeline = HerdrHudMorphTimeline.settled(atRest: true)
        #expect(timeline.isAtRest)
        #expect(!timeline.isAnimating)

        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        timeline.retarget(toRest: false, at: start, animated: true)
        #expect(timeline.isAnimating)
        #expect(!timeline.isAtRest)
        #expect(timeline.state(at: start) == .rest)
        let mid = timeline.state(at: start.addingTimeInterval(0.2))
        #expect(mid.orb > 0.5)
        #expect(mid.agents > 0)
        #expect(mid.agents < 1)
        #expect(!timeline.isSettled(at: start.addingTimeInterval(0.3)))

        let expand = HerdrHudMorph.duration(for: .expand)
        // A hair past the end: `Date` arithmetic is not exact to the last bit.
        let end = start.addingTimeInterval(expand + 0.001)
        #expect(timeline.state(at: end) == .full)
        #expect(timeline.isSettled(at: end))
        #expect(abs(timeline.remainingDuration(at: start.addingTimeInterval(0.12)) - (expand - 0.12)) < 0.000001)
        #expect(timeline.remainingDuration(at: end.addingTimeInterval(1)) == 0)
    }

    @Test("Retargeting mid-flight continues from where each layer is, without a jump")
    func retargetingIsContinuous() {
        var timeline = HerdrHudMorphTimeline.settled(atRest: true)
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        timeline.retarget(toRest: false, at: start, animated: true)
        let interruption = start.addingTimeInterval(0.25)
        let before = timeline.state(at: interruption)
        #expect(before != .rest)
        #expect(before != .full)

        timeline.retarget(toRest: true, at: interruption, animated: true)
        #expect(timeline.isAtRest)
        #expect(timeline.direction == .collapse)
        #expect(timeline.state(at: interruption) == before)
        let end = interruption.addingTimeInterval(HerdrHudMorph.duration(for: .collapse) + 0.001)
        #expect(timeline.state(at: end) == .rest)

        // Asking for the state it already holds settles at once.
        var settled = HerdrHudMorphTimeline.settled(atRest: false)
        settled.retarget(toRest: false, at: start, animated: true)
        #expect(!settled.isAnimating)
    }

    @Test("Reduce Motion snaps the timeline to its target")
    func reduceMotionSnaps() {
        var timeline = HerdrHudMorphTimeline.settled(atRest: true)
        let now = Date()
        timeline.retarget(toRest: false, at: now, animated: false)
        #expect(!timeline.isAnimating)
        #expect(timeline.state(at: now) == .full)
        #expect(timeline.remainingDuration(at: now) == 0)
        timeline.retarget(toRest: true, at: now, animated: false)
        #expect(timeline.isAtRest)
        #expect(timeline.state(at: now) == .rest)
    }
}
