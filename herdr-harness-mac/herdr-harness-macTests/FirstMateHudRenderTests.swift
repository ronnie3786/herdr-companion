import SwiftUI
import Testing
@testable import herdr_harness_mac

/// The First Mate HUD over the chat window's demo, resized to 6, 10, and 14
/// features, rendered offscreen on Herdr's dusk. PNGs land where
/// `HerdrRenderHarness.directory` says.
@Suite("First Mate HUD renders", .serialized)
@MainActor
struct FirstMateHudRenderTests {
    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    static let face = CGPoint(x: 900, y: 790)
    static let receipts = FirstMateFleetFeatureID(machineID: "demo", featureID: "demo-receipts")
    /// The HUD holds its model and shell weakly, like the app's; the renders
    /// keep them alive for the lead chat, which reads them after setup.
    private static var retained: [AnyObject] = []

    private func controller(count: Int?, expanded: Bool, face: CGPoint = Self.face) async throws -> FirstMateHudController {
        let model = HerdrRenderFixtures.demoModel()
        let shell = HerdrShellState(userDefaults: try #require(UserDefaults(suiteName: "FirstMateHudRender.\(UUID().uuidString)")))
        await shell.firstMateChatDemo.store.refresh()
        let defaults = try #require(UserDefaults(suiteName: "FirstMateHudRender.hud.\(UUID().uuidString)"))
        defaults.set(expanded, forKey: FirstMateHudPreferences.expandedKey)
        let controller = FirstMateHudController(defaults: defaults, isInert: true)
        controller.demoCount = count
        controller.prepareForRendering(model: model, shell: shell, visibleFrame: Self.screen, face: face)
        Self.retained = [model, shell]
        return controller
    }

    private func render(_ name: String, _ controller: FirstMateHudController) async throws {
        let size = controller.layout.panelFrame.size
        let result = try await HerdrRenderHarness.renderWindow(name, size: size) {
            ZStack {
                HerdrDuskBackdrop()
                FirstMateHudRootView(controller: controller)
            }
            .environment(\.herdrFontScale, .medium)
        }
        result.expectSubstantial()
    }

    @Test("Collapsed: seven features, First Mate's latest line")
    func collapsedSeven() async throws {
        let hud = try await controller(count: 7, expanded: false)
        #expect(hud.items.count == 7)
        #expect(hud.collapsed.orbs.count == 5 && hud.collapsed.tucked.count == 2)
        #expect(hud.visibleCard == .latestLine)
        try await render("fmhud-collapsed-7.png", hud)
    }

    @Test("Collapsed: six features all fit")
    func collapsedSix() async throws {
        let hud = try await controller(count: 6, expanded: false)
        hud.clearLatestLine()
        #expect(!hud.collapsed.hasMore)
        try await render("fmhud-collapsed-6.png", hud)
    }

    @Test("Collapsed overflow at 10 and 14 features", arguments: [10, 14])
    func collapsedOverflow(_ count: Int) async throws {
        let hud = try await controller(count: count, expanded: false)
        hud.clearLatestLine()
        #expect(hud.collapsed.hasMore)
        try await render("fmhud-collapsed-\(count).png", hud)
    }

    @Test("Expanded at 6, 10, and 14 features", arguments: [6, 10, 14])
    func expanded(_ count: Int) async throws {
        let hud = try await controller(count: count, expanded: true)
        hud.clearLatestLine()
        try await render("fmhud-expanded-\(count).png", hud)
    }

    @Test("Expanded at 14 with every moving row showing, compact")
    func expandedAll() async throws {
        let hud = try await controller(count: 14, expanded: true)
        hud.clearLatestLine()
        hud.toggleShowAllRows()
        #expect(hud.expanded.rowsAreCompact)
        try await render("fmhud-expanded-14-all.png", hud)
    }

    @Test("Near the right edge the list opens leading")
    func leading() async throws {
        let hud = try await controller(count: nil, expanded: true, face: CGPoint(x: 1370, y: 790))
        hud.clearLatestLine()
        #expect(hud.layout.listSide == .leading)
        try await render("fmhud-expanded-leading.png", hud)
    }

    @Test("Cards: readout, message, editor, chat, tucked", arguments: ["readout", "message", "editor", "chat", "tucked"])
    func cards(_ kind: String) async throws {
        let hud = try await controller(count: 10, expanded: true)
        hud.clearLatestLine()
        switch kind {
        case "readout":
            hud.hover(.readout(Self.receipts), isInside: true)
            try await Task.sleep(for: .milliseconds(320))
        case "tucked":
            hud.hover(.tucked, isInside: true)
            try await Task.sleep(for: .milliseconds(320))
        case "message": hud.openExplicit(.message(Self.receipts))
        case "editor": hud.openExplicit(.editor(Self.receipts))
        default:
            // The demo's lead First Mate, with the shared composer.
            hud.modelFavorites = ModelFavoritesStore()
            hud.openExplicit(.chat)
            let store = try #require(hud.currentLeadStore())
            #expect(await store.openLead())
            await hud.submit("Which one should I look at first?")
            #expect(store.leadSnapshot?.messages.count == 4)
        }
        #expect(hud.visibleCard != nil)
        try await render("fmhud-card-\(kind).png", hud)
    }

    @Test("Listening: rose face, level meter, and the caption")
    func listening() async throws {
        let hud = try await controller(count: nil, expanded: false)
        hud.setVoicePhaseForRendering(.listening)
        try await render("fmhud-listening.png", hud)
    }
}
