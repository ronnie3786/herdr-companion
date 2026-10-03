import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Each snapshot is built solely from the synthetic locked-design world.
@Suite("First Mate Home native renders", .serialized)
@MainActor
struct HomeRenderTests {
    @Test("All Home states at the three supported reference sizes",
          arguments: HomeFixtures.Moment.allCases, [1600, 1280, 1000])
    func moments(moment: HomeFixtures.Moment, width: Int) async throws {
        let size = CGSize(width: width, height: width == 1600 ? 1000 : width == 1280 ? 900 : 680)
        let snapshot = HomeFixtures.snapshot(moment)
        let render = try await HerdrRenderHarness.renderWindow("home-\(moment.rawValue)-\(width).png", size: size) {
            HomeRenderScene(snapshot: snapshot)
        }
        render.expectSubstantial(minimumBytes: 24_000)
    }

    @Test("Morning and trouble respect motion and transparency preferences", arguments: [HomeFixtures.Moment.morning, .trouble])
    func accessibility(moment: HomeFixtures.Moment) async throws {
        let render = try await HerdrRenderHarness.renderWindow("home-\(moment.rawValue)-accessibility.png",
                                                              size: CGSize(width: 1280, height: 900)) {
            HomeRenderScene(snapshot: HomeFixtures.snapshot(moment))
                .environment(\.homeReduceMotion, true)
                .environment(\.homeReduceTransparency, true)
        }
        render.expectSubstantial(minimumBytes: 24_000)
    }

    @Test("Expanded recap and scaled actions remain available at the minimum width")
    func recapAndScaledActions() async throws {
        let render = try await HerdrRenderHarness.renderWindow("home-morning-expanded.png", size: CGSize(width: 1000, height: 1500)) {
            HomeRenderScene(snapshot: HomeFixtures.snapshot(.morning), recapExpanded: true)
                .environment(\.herdrFontScale, .large)
        }
        render.expectSubstantial(minimumBytes: 40_000)
    }

    @Test("Chips preserve punctuation, multiple spaces, and paragraph breaks")
    func richTextPreservesSource() {
        let chip = HomeChip(id: "scoped", title: "Docs search", route: .firstMate(machineID: "alpha", featureID: "shared"))
        let text = HomeText(runs: [.text("  Open ("), .chip(chip), .text("), then wait.\n\nNext\tstep.\n")])
        let tokens = HomeInlineToken.tokenize(text)
        #expect(tokens.map(\.sourceText).joined() == text.plainText)
        #expect(tokens.contains(.text("),")))
        #expect(tokens.contains(.space("  ")))
        #expect(tokens.filter { if case .lineBreak = $0 { true } else { false } }.count == 3)
        #expect(tokens.contains(.chip(chip)))
    }

    @Test("Reference geometry preserves both chat columns at the supported minimum")
    func geometry() {
        let minimum = HomeGeometry.grid(width: 1000)
        #expect(minimum.content == 662)
        #expect(minimum.content >= HomeGeometry.chatMinimum * 2 + 10)
        #expect(HomeGeometry.grid(width: 1280).column == 250)
        #expect(HomeGeometry.grid(width: 1600).column == 290)
        #expect(HomeGeometry.grid(width: 1600).content == 780)
        #expect(HomeGeometry.topInset == 92)
    }

    @Test("Loading and missing sources never render synthetic completion")
    func unavailableStates() {
        let loading = HomeFixtures.snapshot(.loading)
        let disconnected = HomeFixtures.snapshot(.disconnected)
        let stale = HomeFixtures.snapshot(.stale)
        #expect(loading.isLoading)
        #expect(loading.focus.isEmpty)
        #expect(!disconnected.notices.isEmpty)
        #expect(disconnected.focusCount > 0)
        #expect(stale.focus.allSatisfy { $0.isStale })
        #expect(stale.chats.allSatisfy { $0.isStale })
    }
}

private struct HomeRenderScene: View {
    let snapshot: HomeSnapshot
    var recapExpanded = false

    var body: some View {
        HomeContentView(snapshot: snapshot, selectedFocusID: snapshot.focus.first?.id,
                        recapExpanded: .constant(recapExpanded), onSelectFocus: { _ in }, onCommand: { _ in }, isVisible: false)
            .overlay(alignment: .top) {
                HomeTabStrip(selection: .home, snapshot: snapshot, query: .constant(""), isSearching: .constant(false),
                             isActive: false, onSelect: { _ in }, onSearch: {})
            }
            .environment(\.homeActionsEnabled, true)
            .ignoresSafeArea()
    }
}
