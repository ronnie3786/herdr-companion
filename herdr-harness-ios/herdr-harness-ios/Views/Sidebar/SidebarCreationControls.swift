import SwiftUI

struct SidebarCreationControls: View {
    @Bindable var model: HerdrAppModel
    let showsMachineChrome: Bool
    let scopedMachineID: String?
    let presentCreateWorkspace: (String?) -> Void
    let dismissSidebar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsMachineChrome {
                machineScopedMenus
            } else {
                directActions
            }
        }
        .font(.subheadline.bold())
    }

    private var machineScopedMenus: some View {
        Group {
            Menu {
                ForEach(model.machines) { machine in
                    Button(machine.name) {
                        presentCreateWorkspace(machine.id)
                    }
                    .disabled(!model.canControl(machineID: machine.id))
                }
            } label: {
                actionLabel("New workspace", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-new-workspace")

            Menu {
                ForEach(model.machines) { machine in
                    Button(machine.name) {
                        Task { await model.createQuickPiSession(machineID: machine.id) }
                    }
                    .disabled(!model.canControl(machineID: machine.id))
                }
            } label: {
                actionLabel("New Pi session", systemImage: "bolt")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-new-pi-session")

            Menu {
                ForEach(model.machines) { machine in
                    Button(machine.name) {
                        model.presentAgent(machineID: machine.id)
                        dismissSidebar()
                    }
                    .disabled(!model.canControl(machineID: machine.id))
                }
            } label: {
                actionLabel("Run agent", systemImage: "sparkles")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-run-agent")
        }
    }

    private var directActions: some View {
        Group {
            Button("New workspace", systemImage: "folder.badge.plus") {
                presentCreateWorkspace(resolvedMachineID)
            }
            .sidebarCreationActionStyle()
            .disabled(!canControlResolvedMachine)
            .accessibilityIdentifier("sidebar-new-workspace")

            Button("New Pi session", systemImage: "bolt") {
                Task { await model.createQuickPiSession(machineID: resolvedMachineID) }
            }
            .sidebarCreationActionStyle()
            .disabled(!canControlResolvedMachine)
            .accessibilityIdentifier("sidebar-new-pi-session")

            Button("Run agent", systemImage: "sparkles") {
                model.presentAgent(machineID: resolvedMachineID)
                dismissSidebar()
            }
            .sidebarCreationActionStyle()
            .disabled(!canControlResolvedMachine)
            .accessibilityIdentifier("sidebar-run-agent")
        }
    }

    private var resolvedMachineID: String? {
        scopedMachineID ?? (model.machines.count == 1 ? model.machines.first?.id : nil)
    }

    private var canControlResolvedMachine: Bool {
        resolvedMachineID.map { model.canControl(machineID: $0) } ?? false
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(HerdrTheme.accent)
            .frame(maxWidth: .infinity, minHeight: SidebarMetrics.controlHeight, alignment: .leading)
            .contentShape(.rect)
    }
}

private extension View {
    func sidebarCreationActionStyle() -> some View {
        foregroundStyle(HerdrTheme.accent)
            .frame(maxWidth: .infinity, minHeight: SidebarMetrics.controlHeight, alignment: .leading)
            .contentShape(.rect)
            .buttonStyle(.plain)
    }
}
