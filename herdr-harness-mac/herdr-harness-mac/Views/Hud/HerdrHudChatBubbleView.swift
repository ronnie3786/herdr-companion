import SwiftUI

struct HerdrHudChatBubbleView: View {
    let chat: HerdrHudChats.Chat
    let model: HerdrAppModel
    let controller: HerdrHudController
    @State private var dismissalError: String?
    @State private var showsDismissalError = false
    @State private var renameError: String?
    @State private var showsRenameError = false

    private var isReady: Bool {
        chat.session.hasUnseenAnswer && !chat.session.isRunning
            && chat.session.exchanges.last?.status == .completed
    }

    private var isSmartRenaming: Bool {
        controller.chats?.smartRenamingChatIDs.contains(chat.id) == true
    }

    var body: some View {
        Button { controller.openChat(chat.id) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("HUD chat", systemImage: "bubble.left.and.bubble.right")
                        .herdrFont(.caption2, weight: .semibold)
                        .foregroundStyle(HerdrTheme.accent)
                    Spacer(minLength: 4)
                    if isSmartRenaming {
                        ProgressView()
                            .controlSize(.small)
                            .tint(HerdrTheme.accent)
                            .accessibilityLabel("Renaming HUD chat")
                    } else {
                        Image(systemName: "chevron.down")
                            .herdrFont(.caption2)
                            .foregroundStyle(HerdrTheme.muted)
                    }
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
                    .strokeBorder(outlineColor, lineWidth: 1)
            }
            .shadow(color: shadowColor, radius: chat.session.isRunning ? 4 : 7)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(model.showSessionTitles ? "Open HUD chat: \(chat.displayTitle)" : "Open HUD chat")
        .accessibilityIdentifier("hud-chat-bubble-\(chat.id)")
        .contextMenu {
            Button("Open chat", systemImage: "bubble.left") { controller.openChat(chat.id) }
            Button(isSmartRenaming ? "Renaming…" : "Smart Rename", systemImage: "sparkles") {
                smartRename()
            }
            .disabled(isSmartRenaming || chat.session.exchanges.isEmpty || chat.session.isLoadingHistory
                      || chat.session.needsHistoryRefresh || chat.session.isEnding || chat.session.hasEnded
                      || chat.session.selectedMachineID == nil)
            Button("Remove from HUD", systemImage: "xmark.circle") {
                Task {
                    do { try await controller.chats?.dismiss(chat.id, model: model) }
                    catch {
                        dismissalError = error.localizedDescription
                        showsDismissalError = true
                    }
                }
            }
            .disabled(chat.session.isEnding || chat.session.isRunning || chat.session.isLoadingHistory || chat.session.needsHistoryRefresh
                      || !chat.session.promotingExchangeIDs.isEmpty)
        }
        .alert("Couldn’t remove chat", isPresented: $showsDismissalError) {
            Button("OK") { dismissalError = nil }
        } message: {
            Text(dismissalError ?? "")
        }
        .alert("Couldn’t rename chat", isPresented: $showsRenameError) {
            Button("OK") { renameError = nil }
        } message: {
            Text(renameError ?? "")
        }
    }

    private var outlineColor: Color {
        if chat.session.isRunning {
            return HerdrHudNotificationPresentation.outlineColor(for: AgentStatus.working).opacity(0.25)
        }
        return isReady ? HerdrTheme.success : HerdrTheme.accent.opacity(0.45)
    }

    private var shadowColor: Color {
        if chat.session.isRunning { return AgentStatus.working.color.opacity(0.16) }
        return isReady ? HerdrTheme.success.opacity(0.3) : .clear
    }

    private func smartRename() {
        Task {
            do {
                // A successful rename returns no notice under the strict
                // selection policy; every failure surfaces here instead.
                _ = try await controller.chats?.smartRename(chat.id, model: model)
            } catch is CancellationError {
                return
            } catch {
                renameError = error.localizedDescription
                showsRenameError = true
            }
        }
    }
}
