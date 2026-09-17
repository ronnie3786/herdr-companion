import SwiftUI

struct HudChatCatalogView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var store: HudChatStore
    @Binding var selectedMachineID: String
    @Binding var searchText: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HerdrTheme.rowSpacing) {
                controls
                errorBanner

                if store.isLoadingCatalog, store.chats.isEmpty {
                    ProgressView("Loading saved chats…")
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .tint(HerdrTheme.accent)
                } else if store.chats.isEmpty {
                    if store.query.isEmpty {
                        ContentUnavailableView(
                            "No saved HUD chats",
                            systemImage: "bubble.left.and.text.bubble.right",
                            description: Text("Start one here or from the Mac HUD. It stays on the selected machine.")
                        )
                    } else {
                        ContentUnavailableView.search
                    }
                } else {
                    ForEach(store.chats) { chat in
                        Button {
                            Task { await store.open(chat, transport: model) }
                        } label: {
                            HudChatSummaryRow(chat: chat, machineID: store.machineID)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("hud-chat-\(chat.scopedID(machineID: store.machineID))")
                    }

                    if store.nextCatalogOffset != nil {
                        Button {
                            Task { await store.loadMore(transport: model) }
                        } label: {
                            if store.isLoadingCatalog {
                                ProgressView()
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            } else {
                                Label("Load more chats", systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(HerdrTheme.accent)
                        .disabled(store.isLoadingCatalog)
                        .accessibilityIdentifier("hud-chats-load-more")
                    }
                }
            }
            .padding(.horizontal, HerdrTheme.pagePadding)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search saved HUD chats"
        )
        .refreshable {
            await store.load(machineID: selectedMachineID, query: store.query, transport: model)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Machine", selection: $selectedMachineID) {
                ForEach(model.machines) { machine in
                    Text(machine.name).tag(machine.id)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            .accessibilityIdentifier("hud-chats-machine")

            Button {
                store.beginNewChat()
            } label: {
                Label("New saved HUD chat", systemImage: "square.and.pencil")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(HerdrTheme.accent)
            .disabled(selectedMachineID.isEmpty || store.capabilities?.supportsHudChats != true)
            .accessibilityIdentifier("hud-chat-new")
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = store.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dismiss", systemImage: "xmark") {
                    store.clearError()
                }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
            }
            .font(.subheadline)
            .foregroundStyle(HerdrTheme.alert)
            .padding(12)
            .background(HerdrTheme.alert.opacity(0.1))
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .accessibilityIdentifier("hud-chat-error")
        }
    }
}
