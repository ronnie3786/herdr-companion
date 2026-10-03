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
        let render = try render("home-\(moment.rawValue)-\(width).png", size: size) {
            HomeRenderScene(snapshot: snapshot, size: size)
        }
        render.expectSubstantial(minimumBytes: 24_000)
    }

    @Test("Morning and trouble respect motion and transparency preferences", arguments: [HomeFixtures.Moment.morning, .trouble])
    func accessibility(moment: HomeFixtures.Moment) async throws {
        let render = try render("home-\(moment.rawValue)-accessibility.png",
                                                              size: CGSize(width: 1280, height: 900)) {
            HomeRenderScene(snapshot: HomeFixtures.snapshot(moment), size: CGSize(width: 1280, height: 900))
                .environment(\.homeReduceMotion, true)
                .environment(\.homeReduceTransparency, true)
        }
        render.expectSubstantial(minimumBytes: 24_000)
    }

    @Test("Expanded recap and scaled actions remain available at the minimum width")
    func recapAndScaledActions() async throws {
        let render = try render("home-morning-expanded.png", size: CGSize(width: 1000, height: 1500)) {
            HomeRenderScene(snapshot: HomeFixtures.snapshot(.morning), size: CGSize(width: 1000, height: 1500), recapExpanded: true)
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
    @Test("Synthetic moments do not inherit conflicting morning status")
    func coherentMomentStatus() {
        let clear = HomeFixtures.snapshot(.clear)
        #expect(clear.focusCount == 0)
        #expect(clear.focus.allSatisfy { $0.isIdea })
        #expect(!clear.firstMateStatus.contains("need"))
        #expect(!clear.moving.plainText.contains("Snapshot test flakes"),
                "The evening recap says Snapshot test flakes merged; it cannot still be in QA")
        let afternoon = HomeFixtures.snapshot(.afternoon)
        #expect(afternoon.focusCount == 1)
        #expect(afternoon.firstMateStatus.contains("1 needs you"))
        #expect(!afternoon.moving.plainText.contains(afternoon.focus[0].title),
                "The retry project is awaiting the user’s answer, not independently building")
        #expect(afternoon.moving.plainText.contains("Docs search has its PR open"))
    }

    /// AppKit's frame-view cache omits the layer-backed Home scroll surface and
    /// distorts its glows. Render the shared SwiftUI grid at an explicit viewport
    /// instead. Window controls, resizing and scrolling are covered by HomeUITests.
    private func render(_ name: String, size: CGSize, @ViewBuilder content: () -> some View) throws -> HerdrRenderHarness.RenderResult {
        let renderer = ImageRenderer(content: content()
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .environment(\.homeReduceMotion, true))
        renderer.scale = HerdrRenderHarness.scale
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = HerdrRenderHarness.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try data.write(to: url, options: .atomic)
        return HerdrRenderHarness.RenderResult(name: name, url: url, byteCount: data.count,
                                              pixelSize: CGSize(width: image.width, height: image.height), pointSize: size)
    }

}

private struct HomeRenderScene: View {
    let snapshot: HomeSnapshot
    let size: CGSize
    var recapExpanded = false

    var body: some View {
        HomeContentLayout(snapshot: snapshot, selectedFocusID: snapshot.focus.first?.id,
                          recapExpanded: .constant(recapExpanded), width: size.width,
                          onSelectFocus: { _ in }, onCommand: { _ in }, isVisible: false)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
            .background(HomeBackground())
            .overlay(alignment: .top) {
                HomeTabStrip(selection: .home, snapshot: snapshot, query: .constant(""), isSearching: .constant(false),
                             isActive: false, onSelect: { _ in }, onSearch: {})
            }
            .environment(\.homeActionsEnabled, true)
            .ignoresSafeArea()
    }
}
