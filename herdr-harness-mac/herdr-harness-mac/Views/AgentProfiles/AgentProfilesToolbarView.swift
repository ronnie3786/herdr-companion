import SwiftUI

struct AgentProfilesToolbarView: View {
    @Bindable var store: AgentProfilesStore
    let selectMachine: (String) -> Void
    let reload: () -> Void
    let sync: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Label("Agent Profiles", systemImage: "person.text.rectangle")
                .herdrFont(.headline, weight: .semibold)

            Menu {
                ForEach(store.machines) { machine in
                    Button(machine.name) { selectMachine(machine.id) }
                }
            } label: {
                Label(store.selectedMachine?.name ?? "Choose data machine", systemImage: "server.rack")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.isLoading || store.isSaving)
            .accessibilityIdentifier("agent-profiles-machine-menu")

            if let effective = store.overview?.effective {
                Label(effective.syncStatus.capitalized, systemImage: syncSymbol(effective.syncStatus))
                    .herdrFont(.caption, monospaced: true, weight: .medium)
                    .foregroundStyle(effective.error == nil ? HerdrTheme.mist : HerdrTheme.alert)
            }

            Spacer()

            if store.isSaving || store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Agent Profiles activity")
            }

            Button("Reload", systemImage: "arrow.clockwise", action: reload)
                .buttonStyle(.bordered)
                .disabled(store.isLoading || store.isSaving || store.hasPendingMutation)

            Button("Sync now", systemImage: "arrow.triangle.2.circlepath", action: sync)
                .buttonStyle(.borderedProminent)
                .disabled(store.overview == nil || store.isLoading || store.isSaving || store.hasPendingMutation)
                .accessibilityIdentifier("agent-profiles-sync")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(HerdrTheme.graphite.opacity(0.9))
    }

    private func syncSymbol(_ status: String) -> String {
        switch status {
        case "current": "checkmark.circle"
        case "unavailable": "exclamationmark.triangle"
        case "cached": "externaldrive"
        case "local": "desktopcomputer"
        default: "minus.circle"
        }
    }
}
