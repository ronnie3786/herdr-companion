import SwiftUI

struct HudChatsView: View {
    struct PromotedPaneNavigationTarget: Equatable {
        let machineID: String
        let rootRunID: String
        let promotedPaneID: String
        let scopedPaneID: String

        init?(machineID: String, rootRunID: String?, promotedPaneID: String?) {
            guard !machineID.isEmpty, let rootRunID, let promotedPaneID else { return nil }
            self.machineID = machineID
            self.rootRunID = rootRunID
            self.promotedPaneID = promotedPaneID
            if let scope = MachineScopedID.split(promotedPaneID) {
                guard scope.machineID == machineID else { return nil }
                scopedPaneID = promotedPaneID
            } else {
                scopedPaneID = MachineScopedID.compose(machineID: machineID, rawID: promotedPaneID)
            }
        }

        func matches(
            isShowingConversation: Bool,
            machineID: String,
            rootRunID: String?,
            promotedPaneID: String?
        ) -> Bool {
            isShowingConversation
                && machineID == self.machineID
                && rootRunID == self.rootRunID
                && promotedPaneID == self.promotedPaneID
        }
    }

    @Bindable var model: HerdrAppModel
    let openPane: (String) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedMachineID = ""
    @State private var searchText = ""
    @State private var thinkingLevel = PiThinkingLevel.max

    var body: some View {
        let store = model.hudChats
        ZStack {
            HerdrBackground()
            if store.isShowingConversation {
                HudChatConversationView(
                    model: model,
                    store: store,
                    thinkingLevel: $thinkingLevel,
                    openPromotedPane: openPromotedPane
                )
            } else {
                HudChatCatalogView(
                    model: model,
                    store: store,
                    selectedMachineID: $selectedMachineID,
                    searchText: $searchText
                )
            }
        }
        .navigationTitle(store.isShowingConversation ? "HUD Chat" : "HUD Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HerdrTheme.graphite, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if store.isShowingConversation {
                ToolbarItem(placement: .topBarLeading) {
                    Button("All HUD chats", systemImage: "chevron.left") {
                        store.showCatalog()
                    }
                    .accessibilityIdentifier("hud-chats-back")
                }
            }
        }
        .task {
            if selectedMachineID.isEmpty {
                selectedMachineID = store.machineID.isEmpty ? (model.machines.first?.id ?? "") : store.machineID
            }
        }
        .task(id: loadContext) {
            guard !selectedMachineID.isEmpty, !store.isShowingConversation else { return }
            if !searchText.isEmpty {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
            await store.load(machineID: selectedMachineID, query: searchText, transport: model)
        }
        .task(id: observationContext) {
            guard scenePhase == .active, store.isShowingConversation, store.rootRunID != nil else { return }
            await store.observe(transport: model)
        }
        .task(id: catalogObservationContext) {
            guard scenePhase == .active, !store.isShowingConversation, !store.machineID.isEmpty else { return }
            await store.observeCatalog(transport: model)
        }
        .onChange(of: store.isShowingConversation) { _, isShowing in
            if isShowing { searchText = "" }
        }
    }

    private var loadContext: String {
        "\(selectedMachineID)\u{0}\(searchText)\u{0}\(model.hudChats.isShowingConversation)"
    }

    private var observationContext: String {
        let store = model.hudChats
        return "\(scenePhase == .active)\u{0}\(store.isShowingConversation)\u{0}\(store.machineID)\u{0}\(store.rootRunID ?? "")"
    }

    private var catalogObservationContext: String {
        let store = model.hudChats
        return "\(scenePhase == .active)\u{0}\(store.isShowingConversation)\u{0}\(store.machineID)\u{0}\(store.query)"
    }

    private func openPromotedPane() {
        let store = model.hudChats
        guard let target = PromotedPaneNavigationTarget(
            machineID: store.machineID,
            rootRunID: store.rootRunID,
            promotedPaneID: store.promotedPaneID
        ) else { return }
        Task {
            await model.refresh()
            guard target.matches(
                isShowingConversation: store.isShowingConversation,
                machineID: store.machineID,
                rootRunID: store.rootRunID,
                promotedPaneID: store.promotedPaneID
            ) else { return }
            guard model.pane(id: target.scopedPaneID) != nil else {
                model.toastMessage = "That promoted pane is unavailable on this machine."
                return
            }
            openPane(target.scopedPaneID)
        }
    }
}
