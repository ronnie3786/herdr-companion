import SwiftUI
import UniformTypeIdentifiers

struct HerdrHudCardView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    @Bindable var session: HerdrHudSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HerdrHudHeaderView(model: model, controller: controller, session: session)
            if let chat = controller.chats?.selectedChat {
                VStack(alignment: .leading, spacing: 5) {
                    Text(chat.displayTitle)
                        .herdrFont(.subheadline, weight: .semibold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(2)
                    HStack {
                        HerdrHudChatStatusView(session: session)
                        Spacer(minLength: 8)
                        HerdrHudEndChatButton(chat: chat, controller: controller, model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HerdrTheme.cardPadding)
                .padding(.bottom, 10)
            }
            Divider().overlay { HerdrTheme.separator }
            HerdrHudTranscriptView(
                model: model,
                session: session,
                openPaneInMainWindow: openPaneInMainWindow,
                collapse: controller.collapse
            )
            Divider().overlay { HerdrTheme.separator }
            if session.exchanges.contains(where: { $0.promotedPaneID != nil }) {
                VStack(spacing: 8) {
                    Text("This chat now continues in its workspace. Open the terminal session above to reply.")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                    Button("New HUD chat", systemImage: "square.and.pencil", action: controller.summon)
                        .buttonStyle(.bordered)
                }
                .padding(HerdrTheme.cardPadding)
            } else {
                HerdrHudComposerView(model: model, controller: controller, session: session)
                    .disabled(session.isEnding)
            }
            HStack {
                HerdrHudChatResizeHandle(controller: controller)
                Spacer()
            }
        }
        .frame(width: controller.chatCardSize.width, height: controller.chatCardSize.height)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.separator, lineWidth: 1)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                    .strokeBorder(HerdrTheme.accent, lineWidth: 2)
            }
        }
        // A light ambient shadow plus a close contact shadow gives separation
        // without the dense, wide halo of a single high-opacity shadow.
        .shadow(color: HerdrTheme.ink.opacity(0.16), radius: 18, y: 6)
        .shadow(color: HerdrTheme.ink.opacity(0.10), radius: 3, y: 2)
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            session.acceptAttachmentDrop(providers)
        }
        .task(id: session.selectedMachineID) {
            if session.needsHistoryRefresh { await session.refreshSavedHistory(model: model) }
            updateResponseAudioAvailability()
            session.responseAudioPlayer.stop()
            await session.loadAudioCapabilities(model: model)
            await session.loadModels(model: model)
        }
        .onChange(of: session.exchangesRevision) { _, _ in
            updateResponseAudioAvailability()
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.24),
            value: model.unopenedResultArtifacts.map(\.id)
        )
        .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: isDropTargeted)
    }

    private func updateResponseAudioAvailability() {
        let hasResponse = session.exchanges.last(where: { exchange in
            exchange.response?.isEmpty == false
                && (exchange.status == .completed || exchange.status == .promoted)
        }) != nil
        session.responseAudioPlayer.responseDidChange(hasResponse: hasResponse)
    }

    private func openPaneInMainWindow(_ paneID: String) {
        HerdrMacAppDelegate.openPaneURLWithFallback(paneID)
    }
}
