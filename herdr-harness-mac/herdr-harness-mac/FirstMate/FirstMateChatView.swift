import SwiftUI

struct FirstMateChatView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let canControl: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var followsLatest = true
    @State private var showsModelSettings = false
    private var featureIsClosed: Bool { ["completed", "cancelled"].contains(snapshot.feature.status) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("First Mate").herdrFont(.title2, weight: .semibold)
                    Text(snapshot.feature.title).herdrFont(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Pause feature", systemImage: "pause") { Task { await store.perform("pause") } }
                    Button("Resume feature", systemImage: "play") { Task { await store.perform("resume") } }
                } label: { FirstMateStatusLabel(status: snapshot.feature.status) }
                .menuStyle(.borderlessButton).fixedSize().disabled(!canControl || store.isSending || featureIsClosed)
            }
            .padding(22)
            Divider()
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .herdrFont(.caption).foregroundStyle(.orange).padding(12)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(snapshot.messages.filter { ["user", "human", "assistant"].contains($0.role) }) { message in
                            FirstMateMessageView(message: message)
                        }
                        Color.clear.frame(height: 1).id("first-mate-chat-end")
                    }.padding(22)
                }
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
                } action: { _, nearBottom in followsLatest = nearBottom }
                .onChange(of: snapshot.messages.last?.id) { _, _ in
                    if followsLatest { proxy.scrollTo("first-mate-chat-end", anchor: .bottom) }
                }
                .onChange(of: snapshot.feature.id) { followsLatest = true }
                .id(snapshot.feature.id)
            }
            if featureIsClosed {
                Label("This feature is closed. Its conversation and evidence remain available.", systemImage: "archivebox")
                    .herdrFont(.caption).foregroundStyle(.secondary).padding(16)
            } else if snapshot.feature.status == "awaiting_direction" {
                Label(snapshot.currentVisit?.status == "completed" ? "Stage complete. Waiting for your direction." : "Waiting for your direction before work continues.", systemImage: "hand.raised")
                    .herdrFont(.caption).foregroundStyle(.orange).padding(.horizontal, 20).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.05))
            } else if ["running", "coordinating", "recovering"].contains(snapshot.feature.status) {
                Label("Work continues in the background. You can talk here.", systemImage: "waveform.path")
                    .herdrFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
            }
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    showsModelSettings = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                        Text(snapshot.feature.modelDisplayName).lineLimit(1).truncationMode(.middle)
                        if let effort = snapshot.feature.coordinatorThinking, !effort.isEmpty {
                            Text(effort.capitalized).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.down").font(.caption2)
                    }.herdrFont(.caption)
                }
                .buttonStyle(.plain)
                .disabled(!canControl || featureIsClosed || store.isDemo)
                .help(store.isDemo ? "Connect to live work to configure your First Mate." : "Model and thinking effort for this feature's next First Mate turn")
                .accessibilityIdentifier("first-mate-model-settings")
                .popover(isPresented: $showsModelSettings, arrowEdge: .top) {
                    FirstMateModelSettingsView(store: store, feature: snapshot.feature, context: store.operationContext)
                }
                .onChange(of: store.operationContext) { showsModelSettings = false }
                TextField("Give direction, ask a question, or change the plan…", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(3...7).herdrFont(.body)
                    .disabled(!canControl || featureIsClosed)
                    .accessibilityIdentifier("first-mate-composer")
                HStack {
                    Text("One conversation for this feature").herdrFont(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Send", systemImage: "arrow.up") { Task { await store.send() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canControl || featureIsClosed || store.isSending || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("first-mate-send")
                }
            }
            .padding(16)
            .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(FirstMatePalette(scheme: scheme).line))
            .padding(16)
        }
        .background(FirstMatePalette(scheme: scheme).background)
    }
}
