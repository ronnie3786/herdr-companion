import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("HUD session refinements", .serialized)
@MainActor
struct HudSessionRefinementTests {
    @Test("One-line bubble titles are shorter than two-line titles", arguments: [HerdrFontScale.medium, .xxxLarge])
    func naturalTitleHeight(scale: HerdrFontScale) async throws {
        func height(_ title: String) async throws -> CGFloat {
            let host = NSHostingView(rootView: HerdrHudSessionBubbleLabel(chip: chip(title: title)).environment(\.herdrFontScale, scale))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            return host.fittingSize.height
        }
        let short = try await height("Garden")
        let long = try await height("Planning the next season of the herb garden")
        #expect(long > short + 5)
        #expect(short >= 40)
    }

    @Test("Panel and scroll budgets use the natural measured session stack")
    func measuredPanelBudget() {
        let content: CGFloat = 126
        #expect(HerdrHudPlacement.sessionStackContentHeight(chipCount: 2, measuredContentHeight: content) == content)
        let size = HerdrHudPlacement.collapsedContentSize(chipCount: 2, measuredContentHeight: content)
        #expect(size.height == HerdrHudPlacement.collapsedSize.height + HerdrHudPlacement.chipSpacing + content)
        let frame = HerdrHudPlacement.frame(isExpanded: false, visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                                           topRightOffset: .zero, chipCount: 2, measuredContentHeight: content)
        #expect(frame.height == size.height + HerdrHudPlacement.shadowMargin * 2)
        let mismatch = HerdrHudSessionStackMeasurement(height: content, chipCount: 2, overflow: 0, fontScale: 1)
        #expect(!mismatch.matches(chipCount: 3, overflow: 0, fontScale: 1))
        #expect(!mismatch.matches(chipCount: 2, overflow: 0, fontScale: 1.5))
    }

    @Test("Metadata alternates only when both model and cost exist")
    func metadataPolicy() {
        let both = HerdrHudSessionMetadata(modelName: "Sonnet 4.5", cost: "$0.37")
        #expect(both.alternates)
        #expect(both.label(showsModel: true) == "Sonnet 4.5")
        #expect(both.label(showsModel: false) == "$0.37")
        let modelOnly = HerdrHudSessionMetadata(modelName: "Sonnet 4.5")
        #expect(!modelOnly.alternates)
        #expect(modelOnly.label(showsModel: false) == "Sonnet 4.5")
        #expect(HerdrHudSessionMetadata(cost: "$0.37").label(showsModel: true) == "$0.37")
        #expect(both.accessibilitySummary.contains("model Sonnet 4.5"))
        #expect(both.accessibilitySummary.contains("session cost $0.37"))
    }

    @Test("HUD bubble renders model first and cost after five seconds")
    func metadataProof() async throws {
        for showsCost in [false, true] {
            let render = try await HerdrRenderHarness.render(showsCost ? "proof-hud-cost.png" : "proof-hud-model.png", size: CGSize(width: 280, height: 235),
                afterSettling: { if showsCost { try await Task.sleep(for: .milliseconds(5500)) } }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(showsCost ? "Five seconds later" : "Model beside Running").herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
                    HerdrHudSessionBubbleLabel(chip: chip(title: "Garden"), metadata: .init(modelName: "Sonnet 4.5", cost: "$0.37"))
                    HerdrHudSessionBubbleLabel(chip: chip(title: "Planning the herb garden for next season"), metadata: .init(modelName: "Opus 4.5", cost: "$1.24"))
                }
                .padding(20)
            }
            render.expectSubstantial()
        }
    }

    private func chip(title: String) -> HerdrHudSessionChips.Chip {
        .init(id: title, title: title, status: .working, isMuted: false, since: nil, emoji: "🌱", activity: "Preparing a planting plan")
    }
}
