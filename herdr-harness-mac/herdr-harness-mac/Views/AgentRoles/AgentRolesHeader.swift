import SwiftUI

struct AgentRolesHeader: View {
    let store: AgentRolesStore
    let selectMachine: (String) -> Void
    let reload: () -> Void
    let showSources: () -> Void
    var exportRoles: () -> Void = {}
    var importRoles: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent Roles").herdrFont(size: SettingsDesign.pageTitle, weight: .semibold)
                    Text("Shape your First Mate team and PR review agents.")
                        .herdrFont(.callout)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer(minLength: 0)
                if store.isSaving || store.isImporting || store.catalog.isLoading {
                    ProgressView().controlSize(.small).accessibilityLabel("Updating Agent Roles")
                }
                Button("Reload", systemImage: "arrow.clockwise", action: reload)
                    .labelStyle(.iconOnly)
                    .help("Reload roles and refresh skills from this Mac")
                    .disabled(store.isSaving || store.isImporting || store.isLoading || store.catalog.isLoading)
                    .accessibilityIdentifier("agent-roles-reload")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { machineMenu; Spacer(minLength: 0); shareMenu; sourceButton }
                VStack(alignment: .leading, spacing: 8) {
                    machineMenu
                    HStack(spacing: 12) { shareMenu; sourceButton }
                }
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
        .disabled(store.isSaving || store.isImporting || store.machines.isEmpty)
        .accessibilityIdentifier("agent-roles-machine")
    }

    private var shareMenu: some View {
        Menu {
            Button("Export Roles…", systemImage: "square.and.arrow.up", action: exportRoles)
                .disabled(!store.canShareRoles)
                .accessibilityIdentifier("agent-roles-export")
            Button("Import Roles…", systemImage: "square.and.arrow.down", action: importRoles)
                .disabled(!store.canShareRoles)
                .accessibilityIdentifier("agent-roles-import")
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .herdrFont(.callout)
        .fixedSize()
        .help(store.canOpenShareMenu && !store.supportsSharing
              ? "Update the companion on \(store.selectedMachine?.name ?? "this computer") to share roles."
              : "Export roles and PR review agents to a file, or import a teammate's file.")
        .disabled(!store.canOpenShareMenu)
        .accessibilityIdentifier("agent-roles-share")
    }

    private var sourceButton: some View {
        Button("Skills from this Mac", systemImage: "folder", action: showSources)
            .buttonStyle(.borderless)
            .herdrFont(.callout)
            .help("Choose local skill folders. Selected skill packages are copied to the execution computer when you save.")
            .disabled(store.isSaving || store.isImporting)
            .accessibilityIdentifier("agent-roles-sources")
    }
}
