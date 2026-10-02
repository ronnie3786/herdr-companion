import SwiftUI

struct AgentRolesHeader: View {
    let store: AgentRolesStore
    let selectMachine: (String) -> Void
    let reload: () -> Void
    let showSources: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent Roles").herdrFont(size: SettingsDesign.pageTitle, weight: .semibold)
                    Text("Shape how First Mate and its team work.")
                        .herdrFont(.callout)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer(minLength: 0)
                if store.isSaving || store.catalog.isLoading {
                    ProgressView().controlSize(.small).accessibilityLabel("Updating Agent Roles")
                }
                Button("Reload", systemImage: "arrow.clockwise", action: reload)
                    .labelStyle(.iconOnly)
                    .help("Reload roles and refresh skills from this Mac")
                    .disabled(store.isSaving || store.isLoading || store.catalog.isLoading)
                    .accessibilityIdentifier("agent-roles-reload")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { machineMenu; Spacer(minLength: 0); sourceButton }
                VStack(alignment: .leading, spacing: 8) { machineMenu; sourceButton }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var machineMenu: some View {
        Menu {
            ForEach(store.machines) { machine in
                Button { selectMachine(machine.id) } label: {
                    if store.selectedMachineID == machine.id { Label(machine.name, systemImage: "checkmark") }
                    else { Text(machine.name) }
                }
            }
        } label: {
            Label("Runs on: \(store.selectedMachine?.name ?? "No machine")", systemImage: "desktopcomputer")
                .lineLimit(1)
        }
        .fixedSize()
        .disabled(store.isSaving || store.machines.isEmpty)
        .accessibilityIdentifier("agent-roles-machine")
    }

    private var sourceButton: some View {
        Button("Skills from this Mac", systemImage: "folder", action: showSources)
            .buttonStyle(.borderless)
            .herdrFont(.callout)
            .help("Choose local skill folders. Selected skill packages are copied to the execution computer when you save.")
            .disabled(store.isSaving)
            .accessibilityIdentifier("agent-roles-sources")
    }
}
