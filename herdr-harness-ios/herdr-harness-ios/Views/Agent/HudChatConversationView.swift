import SwiftUI

struct HudChatConversationView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var store: HudChatStore
    @Binding var thinkingLevel: PiThinkingLevel
    let openPromotedPane: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HerdrTheme.rowSpacing) {
                    contextCard
                    errorBanner

                    if store.isLoadingHistory, store.turns.isEmpty, !store.isNewChat {
                        ProgressView("Loading the full transcript…")
                            .frame(maxWidth: .infinity, minHeight: 160)
                            .tint(HerdrTheme.accent)
                    } else if store.isNewChat {
                        newChatHelp
                    } else {
                        ForEach(store.turns) { turn in
                            HudChatTurnView(turn: turn)
                        }
                    }
                }
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await store.refreshConversation(transport: model)
            }

            if store.promotedPaneID == nil {
                HudChatComposerView(
                    model: model,
                    store: store,
                    thinkingLevel: $thinkingLevel
                )
            } else {
                promotedAction
            }
        }
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(machineName, systemImage: "desktopcomputer")
                Spacer(minLength: 8)
                if let latest = store.latestRun {
                    Label(latest.status.label, systemImage: statusSymbol(latest.status))
                        .foregroundStyle(statusColor(latest.status))
                }
            }
            .font(.headline)

            Label(workingDirectory, systemImage: "folder")
                .font(.subheadline)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(2)
                .truncationMode(.middle)

            if store.isObserving {
                Label("Watching this saved chat for updates", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(HerdrTheme.muted)
            }
        }
        .foregroundStyle(HerdrTheme.text)
        .padding(HerdrTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.elevated.opacity(0.55))
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
    }

    private var newChatHelp: some View {
        ContentUnavailableView(
            "New saved HUD chat",
            systemImage: "sparkles",
            description: Text("Choose the machine folder, model, and thinking level below. Closing this screen never cancels or deletes the chat after it starts.")
        )
    }

    private var promotedAction: some View {
        VStack(spacing: 8) {
            Text("This HUD chat continued in a terminal. Replies stay disabled here so the conversation cannot fork.")
                .font(.subheadline)
                .foregroundStyle(HerdrTheme.mist)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: openPromotedPane) {
                Label("Open existing pane", systemImage: "rectangle.and.arrow.up.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(HerdrTheme.accent)
            .accessibilityIdentifier("hud-chat-open-pane")
        }
        .padding(HerdrTheme.pagePadding)
        .background(HerdrTheme.graphite)
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

    private var machineName: String {
        model.machines.first(where: { $0.id == store.machineID })?.name ?? store.machineID
    }

    private var workingDirectory: String {
        if store.isNewChat {
            return store.usesCustomWorkingDirectory
                ? (store.newWorkingDirectory.isEmpty ? "Custom path" : store.newWorkingDirectory)
                : "Home (~)"
        }
        return store.turns.lazy.compactMap(\.cwd).first ?? "Home (~)"
    }

    private func statusSymbol(_ status: HeadlessAgentRunStatus) -> String {
        switch status {
        case .queued: "clock"
        case .running: "sparkles"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .promoted: "rectangle.and.arrow.up.right"
        }
    }

    private func statusColor(_ status: HeadlessAgentRunStatus) -> Color {
        switch status {
        case .queued, .running: HerdrTheme.working
        case .completed, .promoted: HerdrTheme.success
        case .failed: HerdrTheme.alert
        case .cancelled: HerdrTheme.mist
        }
    }
}
