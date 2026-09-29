import SwiftUI
import UIKit
import XCTest
@testable import herdr_harness_ios

/// Native renders of skims in First Mate and HUD chats, and of the excerpt
/// sheet. Every reply, skim, and path is synthetic. PNGs land in
/// /tmp/herdr-ios-skim-render (printed as HERDR_IOS_SKIM_RENDER_DIR).
@MainActor
final class IOSSkimRenderTests: XCTestCase {
    private let harness = IOSNativeRenderHarness()
    private let width: CGFloat = 390

    private func bubble(_ message: FirstMateMessage, state: SkimReadingState = SkimReadingState()) -> some View {
        FirstMateChatBubble(row: .init(message: message, speaker: .firstMate, isFirstInGroup: true, isLastInGroup: true),
            snapshot: FirstMateSnapshot(feature: ChatFixtures.feature(message.featureID)), maximumWidth: 350,
            skimState: state, catalog: .init(entries: []), sendReply: { _ in }, presentationChanged: { _, _ in })
            .herdrFirstMateChrome()
    }

    func testFirstMateSkimRowShowsSentenceCaveatChipNextStepAndFooter() async throws {
        for dynamicType in [IOSNativeRenderHarness.DynamicTypeFixture.defaultSize, .accessibility3] {
            let message = SkimFixture.checkoutMessage(skim: SkimFixture.checkoutSkim())
            let render = await harness.render(
                bubble(message).padding(20),
                width: width,
                dynamicType: dynamicType
            )
            try save(render, name: "first-mate-skim-\(dynamicType.name)")
            let context = "First Mate skim, \(dynamicType.name)"

            XCTAssertTrue(render.drewHierarchy, context)
            let sentence = try XCTUnwrap(render.element(identifier: "skim-sentence"), context)
            let caveat = try XCTUnwrap(render.element(identifier: "skim-caveat-0"), context)
            let chip = try XCTUnwrap(render.element(identifier: "skim-rest-chip"), context)
            let next = try XCTUnwrap(render.element(identifier: "skim-next-step-0"), context)
            let toggle = try XCTUnwrap(render.element(identifier: "skim-toggle"), context)
            XCTAssertEqual(chip.label, "Rest of the original", context)
            XCTAssertEqual(toggle.label, "Full reply", context)
            XCTAssertNotNil(render.element(identifier: "skim-stats"), context)
            XCTAssertNil(render.element(identifier: "skim-full-reply"), context)
            XCTAssertNil(render.element(identifier: "skim-pending"), context)

            // Sentence, caveat, chip, then the next step as the last line above the footer.
            XCTAssertLessThanOrEqual(sentence.frame.maxY, caveat.frame.minY, context)
            XCTAssertLessThanOrEqual(caveat.frame.maxY, chip.frame.minY, context)
            XCTAssertLessThanOrEqual(chip.frame.maxY, next.frame.minY, context)
            XCTAssertLessThanOrEqual(next.frame.maxY, toggle.frame.minY, context)
            XCTAssertGreaterThanOrEqual(toggle.frame.height, 43.5, context)
            XCTAssertGreaterThanOrEqual(chip.frame.height, 43.5, context)
            assertInsideRender(render, context: context)
        }
    }

    func testBubbleSkimRemainsDarkUnderLightEnvironment() async throws {
        let message = SkimFixture.checkoutMessage(skim: SkimFixture.checkoutSkim())
        let render = await harness.render(
            bubble(message)
                .padding(20)
                .background(FirstMatePalette(scheme: .light).background)
                .environment(\.colorScheme, .light),
            width: width,
            dynamicType: .defaultSize
        )
        try save(render, name: "first-mate-skim-light")
        XCTAssertNotNil(render.element(identifier: "skim-sentence"))
        XCTAssertNotNil(render.element(identifier: "skim-next-step-0"))
    }

    func testPendingSkimShowsSkimmingAndTheFullReply() async throws {
        let message = SkimFixture.checkoutMessage(skim: SkimFixture.checkoutSkim(.pending))
        let render = await harness.render(
            bubble(message).padding(20),
            width: width,
            dynamicType: .defaultSize
        )
        try save(render, name: "first-mate-pending")

        XCTAssertEqual(render.element(identifier: "skim-pending")?.label, "Skimming…")
        XCTAssertNotNil(render.element(identifier: "skim-full-reply"))
        XCTAssertNil(render.element(identifier: "skim-sentence"))
        XCTAssertNil(render.element(identifier: "skim-toggle"))
    }

    func testFailedOrMismatchedSkimShowsOnlyTheFullReply() async throws {
        let failed = SkimFixture.checkoutMessage(skim: SkimFixture.checkoutSkim(.failed))
        var edited = SkimFixture.checkoutMessage(skim: SkimFixture.checkoutSkim())
        edited.text += "\n\nOne more synthetic line."
        for (name, message) in [("failed", failed), ("mismatched", edited)] {
            let render = await harness.render(
                bubble(message).padding(20),
                width: width,
                dynamicType: .defaultSize
            )
            XCTAssertNotNil(render.element(identifier: "skim-full-reply"), name)
            XCTAssertNil(render.element(identifier: "skim-pending"), name)
            XCTAssertNil(render.element(identifier: "skim-toggle"), name)
            XCTAssertNil(render.element(identifier: "skim-sentence"), name)
        }
    }

    func testFullReplyModeKeepsTheToggleAndShowInReplyHighlights() async throws {
        let message = SkimFixture.checkoutMessage(skim: SkimFixture.checkoutSkim())
        let state = SkimReadingState()
        state.toggleFullReply(message.id)
        let full = await harness.render(
            bubble(message, state: state).padding(20),
            width: width,
            dynamicType: .defaultSize
        )
        try save(full, name: "first-mate-full-reply")
        XCTAssertEqual(full.element(identifier: "skim-toggle")?.label, "Skim")
        XCTAssertNotNil(full.element(identifier: "skim-full-reply"))
        XCTAssertNil(full.element(identifier: "skim-sentence"))

        let reader = try XCTUnwrap(SkimFixture.checkoutReader())
        state.showInReply(messageID: message.id, refs: ["s2", "s3"], reader: reader)
        let highlighted = await harness.render(
            bubble(message, state: state).padding(20),
            width: width,
            dynamicType: .defaultSize
        )
        try save(highlighted, name: "first-mate-show-in-reply")
        XCTAssertNotNil(highlighted.element(identifier: "skim-segmented-reply"))
        XCTAssertNil(highlighted.element(identifier: "skim-full-reply"))
        XCTAssertEqual(highlighted.element(identifier: "skim-toggle")?.label, "Skim")
        XCTAssertGreaterThan(highlighted.fittingSize.height, full.fittingSize.height * 0.8)
    }

    func testHudTurnRendersItsSkim() async throws {
        let run = try SkimFixture.uploadRun(skimJSON: SkimFixture.json(SkimFixture.uploadSkim()))
        let render = await harness.render(
            HudChatTurnView(turn: run, skimState: SkimReadingState()).padding(18),
            width: width,
            dynamicType: .defaultSize
        )
        try save(render, name: "hud-turn-skim")

        XCTAssertNotNil(render.element(identifier: "skim-sentence"))
        XCTAssertNotNil(render.element(identifier: "skim-next-step-0"))
        XCTAssertEqual(render.element(identifier: "skim-toggle")?.label, "Full reply")
        XCTAssertNil(render.element(identifier: "skim-rest-chip"), "No unlinked blocks, so no chip")
        XCTAssertNil(render.element(identifier: "skim-full-reply"))
        assertInsideRender(render, context: "HUD turn")

        let pending = try SkimFixture.uploadRun(skimJSON: ["status": "pending"])
        let pendingRender = await harness.render(
            HudChatTurnView(turn: pending, skimState: SkimReadingState()).padding(18),
            width: width,
            dynamicType: .defaultSize
        )
        XCTAssertEqual(pendingRender.element(identifier: "skim-pending")?.label, "Skimming…")
        XCTAssertNotNil(pendingRender.element(identifier: "skim-full-reply"))
    }

    func testExcerptSheetShowsOriginalHeaderAndARealCodeBlock() async throws {
        let reader = try XCTUnwrap(SkimFixture.checkoutReader())
        let render = await harness.render(
            SkimExcerptView(
                reader: reader, refs: ["s2", "s3"], title: "a declined card", style: .firstMate(.dark),
                showInReply: {}, close: {}
            )
            .frame(height: 620),
            width: width,
            dynamicType: .defaultSize
        )
        try save(render, name: "excerpt-code")

        XCTAssertEqual(render.element(identifier: "skim-excerpt-original")?.label, "Original")
        XCTAssertEqual(render.element(identifier: "skim-excerpt-lines")?.label, "Lines 3–15")
        XCTAssertEqual(render.element(identifier: "skim-code-header")?.label, "JavaScript, 9 lines")
        for identifier in ["skim-code-copy", "skim-excerpt-copy", "skim-excerpt-show-in-reply"] {
            let control = try XCTUnwrap(render.element(identifier: identifier), identifier)
            XCTAssertGreaterThanOrEqual(control.frame.height, 43.5, identifier)
        }
        XCTAssertEqual(render.element(identifier: "skim-code-copy")?.label, "Copy code")
        // The longest line is wider than the sheet: it scrolls sideways instead of wrapping.
        let body = try XCTUnwrap(render.element(identifier: "skim-code-body"))
        XCTAssertLessThanOrEqual(body.frame.maxX, width + 0.5)
        XCTAssertLessThan(body.frame.height, 9 * 26)
        XCTAssertNil(render.element(identifier: "skim-excerpt-gap"))
        assertInsideRender(render, context: "Excerpt")

        let large = await harness.render(
            SkimExcerptView(
                reader: reader, refs: ["s2", "s3"], title: "a declined card", style: .firstMate(.dark),
                showInReply: {}, close: {}
            )
            .frame(height: 900),
            width: width,
            dynamicType: .accessibility3
        )
        try save(large, name: "excerpt-code-accessibility3")
        let copy = try XCTUnwrap(large.element(identifier: "skim-excerpt-copy"))
        let show = try XCTUnwrap(large.element(identifier: "skim-excerpt-show-in-reply"))
        XCTAssertLessThanOrEqual(copy.frame.maxY, show.frame.minY + 0.5, "Actions stack at accessibility sizes")
        assertInsideRender(large, context: "Excerpt, accessibility3")
    }

    func testExcerptMarksSkippedBlocksAndTintsDiffsAndTestOutput() async throws {
        let checkout = try XCTUnwrap(SkimFixture.checkoutReader())
        let gap = await harness.render(
            SkimExcerptView(
                reader: checkout, refs: ["s1", "s6"], title: "Rest of the original", style: .firstMate(.dark),
                showInReply: {}, close: {}
            )
            .frame(height: 420),
            width: width,
            dynamicType: .defaultSize
        )
        try save(gap, name: "excerpt-gap")
        XCTAssertEqual(gap.element(identifier: "skim-excerpt-gap")?.label, "4 blocks skipped")
        XCTAssertEqual(gap.element(identifier: "skim-excerpt-lines")?.label, "Lines 1–20")

        let upload = try XCTUnwrap(FirstMateSkimReader(skim: SkimFixture.uploadSkim(), reply: SkimFixture.uploadReply))
        let hud = await harness.render(
            SkimExcerptView(
                reader: upload, refs: ["s2", "s3", "s4"], title: "a timer per test", style: .hud,
                showInReply: {}, close: {}
            )
            .frame(height: 560),
            width: width,
            dynamicType: .defaultSize
        )
        try save(hud, name: "excerpt-diff-and-output")
        XCTAssertNotNil(hud.element(identifier: "skim-code-header"))
        XCTAssertNil(hud.element(identifier: "skim-excerpt-gap"))
    }

    // MARK: - Helpers

    private func assertInsideRender(_ render: IOSNativeRenderHarness.HostedRender, context: String) {
        for measurement in render.measurements where measurement.identifier != "skim-code-body" {
            XCTAssertLessThanOrEqual(measurement.frame.maxX, render.bounds.maxX + 0.5, "\(context): \(measurement.identifier ?? "")")
            XCTAssertGreaterThanOrEqual(measurement.frame.minX, render.bounds.minX - 0.5, "\(context): \(measurement.identifier ?? "")")
        }
    }

    private func save(_ render: IOSNativeRenderHarness.HostedRender, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/herdr-ios-skim-render", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appending(path: "\(name).png")
        try XCTUnwrap(render.image.pngData()).write(to: artifact)
        print("HERDR_IOS_SKIM_RENDER_DIR=\(directory.path)")
        let attachment = XCTAttachment(image: render.image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
