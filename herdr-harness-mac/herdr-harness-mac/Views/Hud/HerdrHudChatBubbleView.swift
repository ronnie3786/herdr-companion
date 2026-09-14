import SwiftUI

struct HerdrHudChatBubbleView: View {
    let chat: HerdrHudChats.Chat
    let model: HerdrAppModel
    let controller: HerdrHudController
    @State private var dismissalError: String?
    @State private var showsDismissalError = false

    private var isReady: Bool {
        chat.session.hasUnseenAnswer && !chat.session.isRunning
            && chat.session.exchanges.last?.status == .completed
    }

    var body: some View {
        Button { controller.openChat(chat.id) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("HUD chat", systemImage: "bubble.left.and.bubble.right")
                        .herdrFont(.caption2, weight: .semibold)
                        .foregroundStyle(HerdrTheme.accent)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .herdrFont(.caption2)
                        .foregroundStyle(HerdrTheme.muted)
                }
                if model.showSessionTitles {
                    Text(chat.displayTitle)
                        .herdrFont(.caption, weight: .semibold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    HerdrHudChatStatusView(session: chat.session)
                    Spacer(minLength: 4)
                    if let machine = model.machines.first(where: { $0.id == chat.session.selectedMachineID }) {
                        Text(machine.name)
                            .herdrFont(.caption2)
                            .foregroundStyle(HerdrTheme.muted)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(width: HerdrHudPlacement.chipWidth, alignment: .leading)
            .background(HerdrTheme.graphite.opacity(0.96), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isReady ? HerdrTheme.success : HerdrTheme.accent.opacity(0.45), lineWidth: 1)
            }
            .shadow(color: isReady ? HerdrTheme.success.opacity(0.3) : .clear, radius: 7)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(model.showSessionTitles ? "Open HUD chat: \(chat.displayTitle)" : "Open HUD chat")
        .accessibilityIdentifier("hud-chat-bubble-\(chat.id)")
        .contextMenu {
            Button("Open chat", systemImage: "bubble.left") { controller.openChat(chat.id) }
            Button("Remove from HUD", systemImage: "xmark.circle") {
                Task {
                    do { try await controller.chats?.dismiss(chat.id, model: model) }
                    catch {
                        dismissalError = error.localizedDescription
                        showsDismissalError = true
                    }
                }
            }
            .disabled(chat.session.isRunning || chat.session.isLoadingHistory || chat.session.needsHistoryRefresh
                      || !chat.session.promotingExchangeIDs.isEmpty)
        }
        .alert("Couldn’t remove chat", isPresented: $showsDismissalError) {
            Button("OK") { dismissalError = nil }
        } message: {
            Text(dismissalError ?? "")
        }
    }
}
