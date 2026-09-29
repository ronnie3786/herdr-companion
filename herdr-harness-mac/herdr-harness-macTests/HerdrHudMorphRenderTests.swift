import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// One fixed frame of the morph: which direction, and how far along.
struct HerdrHudMorphFrameSample: Sendable, CustomTestStringConvertible {
    let direction: HerdrHudMorph.Direction
    let index: Int
    let elapsed: TimeInterval

    var state: HerdrHudMorph.State {
        switch direction {
        case .expand:
            HerdrHudMorph.state(from: .rest, toward: .full, direction: .expand, elapsed: elapsed)
        case .collapse:
            HerdrHudMorph.state(from: .full, toward: .rest, direction: .collapse, elapsed: elapsed)
        }
    }

    var fileName: String {
        let milliseconds = Int((elapsed * 1000).rounded())
        let prefix = direction == .expand ? "expand" : "collapse"
        return String(format: "hud-morph-%@-%02d-%04dms.png", prefix, index, milliseconds)
    }

    var testDescription: String { fileName }

    /// Every 40 ms through each direction, plus the exact end frame.
    static func samples(for direction: HerdrHudMorph.Direction) -> [HerdrHudMorphFrameSample] {
        let duration = HerdrHudMorph.duration(for: direction)
        var times = stride(from: 0.0, to: duration, by: 0.04).map { $0 }
        times.append(duration)
        return times.enumerated().map { index, elapsed in
            HerdrHudMorphFrameSample(direction: direction, index: index, elapsed: elapsed)
        }
    }
}

/// Deterministic frames of the choreography, rendered through the same
/// offscreen harness as every other HUD render and written as PNGs. They are
/// the reviewable record of the morph and catch a stage that fails to lay out.
@Suite("Herdr HUD morph renders", .serialized)
@MainActor
struct HerdrHudMorphRenderTests {
    private nonisolated static let chipCount = 3
    private nonisolated static let overflow = 2
    private nonisolated static let canvasPadding: CGFloat = 24

    /// The collapsed HUD's content size for three chips and a `+2`, with room
    /// around it for shadows and the glow.
    private nonisolated static var canvasSize: CGSize {
        let content = HerdrHudPlacement.collapsedContentSize(chipCount: chipCount, overflow: overflow)
        return CGSize(width: content.width + 2 * canvasPadding, height: content.height + 2 * canvasPadding)
    }

    @Test("The resting circle renders in the morph canvas as the frame-zero reference")
    func rendersRestingReference() async throws {
        let controller = HerdrHudController(userDefaults: makeDefaults(), reduceMotionPreference: { false })
        let result = try await HerdrRenderHarness.render(
            "hud-morph-reference-resting.png",
            size: Self.canvasSize
        ) {
            HerdrHudUltraCompactIndicator(controller: controller, tone: .working)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(Self.canvasPadding)
        }
        result.expectSubstantial(minimumBytes: 500)
    }

    @Test(
        "Expanding frames render the circle swelling into the orb and the agents unfurling beneath it",
        arguments: HerdrHudMorphFrameSample.samples(for: .expand)
    )
    func rendersExpandFrame(sample: HerdrHudMorphFrameSample) async throws {
        try await renderFrame(sample)
    }

    @Test(
        "Collapsing frames render the agents folding up before the orb contracts into the circle",
        arguments: HerdrHudMorphFrameSample.samples(for: .collapse)
    )
    func rendersCollapseFrame(sample: HerdrHudMorphFrameSample) async throws {
        try await renderFrame(sample)
    }

    @Test("The settled stage is a pass-through for the ordinary orb and chips")
    func settledStageMatchesThePlainHud() async throws {
        let fixture = makeFixture()
        let stage = try await HerdrRenderHarness.render(
            "hud-morph-settled-stage.png",
            size: Self.canvasSize
        ) {
            fixture.stage(state: .full)
        }
        let plain = try await HerdrRenderHarness.render(
            "hud-morph-settled-plain.png",
            size: Self.canvasSize
        ) {
            VStack(alignment: .trailing, spacing: HerdrHudPlacement.chipSpacing) {
                fixture.orbRow(morphProgress: 1)
                fixture.chips(reveal: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(Self.canvasPadding)
        }
        stage.expectSubstantial(minimumBytes: 4_000)
        plain.expectSubstantial(minimumBytes: 4_000)
        // Same pixels within the tolerance of two independent offscreen draws.
        let stageData = try Data(contentsOf: stage.url)
        let plainData = try Data(contentsOf: plain.url)
        let ratio = Double(stageData.count) / Double(plainData.count)
        #expect(ratio > 0.9 && ratio < 1.1, "settled stage \(stageData.count) B vs plain \(plainData.count) B")
    }

    private func renderFrame(_ sample: HerdrHudMorphFrameSample) async throws {
        let fixture = makeFixture()
        let state = sample.state
        let result = try await HerdrRenderHarness.render(sample.fileName, size: Self.canvasSize) {
            fixture.stage(state: state)
        }
        // The resting end is a lone 20-point circle; everything else carries
        // at least part of the orb and chips.
        result.expectSubstantial(minimumBytes: state == .rest ? 500 : 2_000)
    }

    // MARK: Fixture

    /// A demo model, a hover-expanded controller (so the satellites are part of
    /// the picture), and three synthetic sessions plus an overflow control.
    @MainActor
    private struct Fixture {
        let model: HerdrAppModel
        let controller: HerdrHudController
        let session: HerdrHudSession
        let chips: [HerdrHudSessionChips.Chip]

        @ViewBuilder
        func orbRow(morphProgress: Double) -> some View {
            HerdrHudOrbResultRow(
                model: model,
                controller: controller,
                session: session,
                artifacts: [],
                attentionChipCount: 0,
                morphProgress: morphProgress
            )
        }

        @ViewBuilder
        func chips(reveal: Double) -> some View {
            HerdrHudSessionChipsView(
                model: model,
                session: session,
                chips: chips,
                overflow: HerdrHudMorphRenderTests.overflow,
                revealProgress: reveal
            )
        }

        @ViewBuilder
        func stage(state: HerdrHudMorph.State) -> some View {
            HerdrHudMorphStage(state: state, tone: .working) {
                orbRow(morphProgress: state.orb)
            } agents: {
                chips(reveal: state.agents)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(HerdrHudMorphRenderTests.canvasPadding)
        }
    }

    private func makeFixture() -> Fixture {
        let defaults = makeDefaults()
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(userDefaults: defaults, persistenceURL: temporaryURL(named: "hud-thread.json"))
        let controller = HerdrHudController(userDefaults: defaults, reduceMotionPreference: { false })
        controller.setUltraCompactEnabled(true)
        controller.setHoveringHud(true, region: "render")
        let chips = [
            HerdrHudSessionChips.Chip(
                id: "demo1|w1:p1", title: "Herdr Mac", status: .working, isMuted: false, since: .now,
                emoji: "🧪", activity: "Running UI tests"
            ),
            HerdrHudSessionChips.Chip(
                id: "demo2|w2:p1", title: "Launch report", status: .done, isMuted: false, since: .now,
                emoji: "📄", activity: "Release documents"
            ),
            HerdrHudSessionChips.Chip(
                id: "demo1|w3:p2", title: "Slack follow-up", status: .blocked, isMuted: false, since: .now,
                emoji: "💬", activity: "Investigating sign-in"
            ),
        ]
        return Fixture(model: model, controller: controller, session: session, chips: chips)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "HerdrHudMorphRenderTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated render defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func temporaryURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}
