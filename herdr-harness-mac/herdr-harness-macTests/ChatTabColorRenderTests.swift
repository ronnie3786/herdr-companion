import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Chat color presentation", .serialized) @MainActor
struct ChatTabColorRenderTests {
    @Test("Larger six-color Recents key keeps the conversation background neutral")
    func rendersPaletteAndChat() async throws {
        let suite = "ChatTabColorRenderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrDemoMode"], userDefaults: defaults, configuredMachines: [])
        model.sidebarRecency = .recents
        model.machineScope = .all
        let tabIDs = model.workspaces.flatMap(\.tabs).map(\.id).sorted()
        for (tab, color) in zip(tabIDs, ChatTabColor.allCases) {
            model.chatTabColors.assign(color, to: tab)
        }
        model.chatTabColors.rename(.lavender, to: "GARDEN-42 Irrigation")
        let pane = try HerdrRenderFixtures.piCapablePane().stamped(machineID: "demo1")
        let workspace = try #require(model.workspace(id: "demo1|w1"))
        model.selectedPaneID = pane.id
        let store = try await HerdrRenderFixtures.populatedPiStore()
        let image = try await HerdrRenderHarness.render("chat-tab-colors-recents.png", size: CGSize(width: 1180, height: 900)) {
            HStack(spacing: 0) {
                HerdrSidebarView(model: model, openPane: { _ in }, openWorkspace: { _ in })
                    .frame(width: 300)
                VStack(spacing: 0) {
                    PaneSessionHeader(model: model, pane: pane, store: store)
                        .padding(20)
                        .background(HerdrTheme.graphite)
                    PiChatView(
                        model: model, store: store, paneID: pane.id, interactionResponseAvailable: false,
                        composerPane: pane, workspace: workspace, draft: .constant(""), attachments: .constant([]),
                        focusRequest: 0, interactionResponder: PiInteractionResponder(), modelFavorites: ModelFavoritesStore()
                    )
                }
            }
        }
        image.expectSubstantial()
        #expect(ChatColorLegendRow.rowHeight == CGFloat(HerdrTheme.minHitTarget * 2))
        #expect(ChatColorLegendRow.titleSize == 15)
    }
}
