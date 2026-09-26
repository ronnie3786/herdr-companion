import SwiftUI

/// New-chat-only control that starts the submitted conversation directly in
/// the user's remembered main workspace. The toggle is deliberately absent
/// from existing, restored, and continued conversations, and nothing is
/// created until Send.
struct HerdrHudWorkspaceCreationView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var session: HerdrHudSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $session.createsInMainWorkspace) {
                Label("Create in main workspace", systemImage: "sidebar.left")
                    .herdrFont(.caption)
            }
            .toggleStyle(.checkbox)
            .foregroundStyle(HerdrTheme.mist)
            .help("Create this new chat directly in the main workspace on the selected machine instead of a standalone HUD chat.")
            .accessibilityLabel("Create in main workspace")
            .accessibilityIdentifier("hud-create-in-main-workspace")

            if session.createsInMainWorkspace {
                destinationRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: session.mainWorkspaceTopologyKey(in: model)) {
            guard session.createsInMainWorkspace else { return }
            session.applyLocalMachineDefaultIfNeeded(in: model)
            await session.loadMainWorkspaces(model: model)
        }
    }

    @ViewBuilder
    private var destinationRow: some View {
        let machine = session.selectedMachine(in: model)
        if session.mainWorkspaceUnsupported {
            statusLabel(
                "Update \(machine?.name ?? "this companion")'s companion server to create chats in a workspace, then try again.",
                symbol: "exclamationmark.triangle.fill",
                isWarning: true
            )
            .accessibilityIdentifier("hud-main-workspace-upgrade")
        } else if session.isLoadingMainWorkspaces {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading \(machine?.name ?? "machine") workspaces…")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
            }
            .accessibilityIdentifier("hud-main-workspace-loading")
        } else if let error = session.mainWorkspaceErrorMessage {
            VStack(alignment: .leading, spacing: 4) {
                statusLabel(error, symbol: "exclamationmark.triangle.fill", isWarning: true)
                Button("Retry") {
                    Task { await session.loadMainWorkspaces(model: model, force: true) }
                }
                .buttonStyle(.borderless)
                .herdrFont(.caption)
                .accessibilityIdentifier("hud-main-workspace-retry")
            }
            .accessibilityIdentifier("hud-main-workspace-error")
        } else if machine == nil {
            statusLabel(
                "Choose a machine above before choosing its main workspace.",
                symbol: "arrow.up",
                isWarning: true
            )
            .accessibilityIdentifier("hud-main-workspace-no-machine")
        } else if session.currentMainWorkspaces(in: model).isEmpty {
            statusLabel(
                "This machine has no workspaces to create a chat in.",
                symbol: "rectangle.slash",
                isWarning: true
            )
            .accessibilityIdentifier("hud-main-workspace-empty")
        } else if let workspace = session.mainWorkspace(in: model) {
            HStack(spacing: 6) {
                Text("Main workspace:")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                workspaceMenu(selected: workspace)
            }
            .accessibilityIdentifier("hud-main-workspace-selected")
        } else if session.mainWorkspaceDestination(in: model) != nil {
            VStack(alignment: .leading, spacing: 4) {
                statusLabel(
                    "The saved main workspace is no longer on this machine. Choose another one.",
                    symbol: "exclamationmark.triangle.fill",
                    isWarning: true
                )
                HStack(spacing: 6) {
                    Text("Main workspace:")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                    workspaceMenu(selected: nil)
                }
            }
            .accessibilityIdentifier("hud-main-workspace-missing")
        } else {
            HStack(spacing: 6) {
                Text("Main workspace:")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                workspaceMenu(selected: nil)
            }
            .accessibilityIdentifier("hud-main-workspace-first-use")
        }
    }

    private func workspaceMenu(selected: HerdrWorkspace?) -> some View {
        Menu {
            ForEach(session.currentMainWorkspaces(in: model), id: \.workspaceID) { workspace in
                Button {
                    session.selectMainWorkspace(workspace, in: model)
                } label: {
                    if workspace.workspaceID == selected?.workspaceID {
                        Label(workspaceChoiceTitle(workspace), systemImage: "checkmark")
                    } else {
                        Text(workspaceChoiceTitle(workspace))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selected.map(workspaceChoiceTitle) ?? "Choose…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .herdrFont(.caption2, weight: .bold)
            }
            .herdrFont(.caption)
            .foregroundStyle(HerdrTheme.accent)
            .frame(minHeight: HerdrTheme.minHitTarget)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(selected.map { "Main workspace: \(workspaceChoiceTitle($0))" } ?? "Main workspace: choose")
        .accessibilityIdentifier("hud-main-workspace-picker")
    }

    private func statusLabel(_ text: String, symbol: String, isWarning: Bool = false) -> some View {
        Label(text, systemImage: symbol)
            .herdrFont(.caption)
            .foregroundStyle(isWarning ? HerdrTheme.alert : HerdrTheme.mist)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func workspaceChoiceTitle(_ workspace: HerdrWorkspace) -> String {
        HerdrHudWorkspaceChoiceText.title(for: workspace)
    }
}
