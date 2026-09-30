import SwiftUI

struct FirstMateLeadMachineMenu: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    private var capable: [FirstMateFleetHost] { fleet.chat.hosts(fleet: fleet).filter(\.supportsLead) }
    var body: some View {
        Menu {
            Button {
                guard fleet.chat.pinnedMachineID != nil else { return }
                model.beginAppNavigation(); fleet.chat.pin(nil)
            } label: {
                Label("Automatic", systemImage: fleet.chat.pinnedMachineID == nil ? "checkmark" : "circle")
            }
            .accessibilityIdentifier("first-mate-lead-automatic")
            ForEach(capable) { host in
                Button {
                    guard fleet.chat.pinnedMachineID != host.machineID else { return }
                    model.beginAppNavigation(); fleet.chat.pin(host.machineID)
                } label: {
                    Label(host.machineName, systemImage: fleet.chat.pinnedMachineID == host.machineID ? "checkmark" : "desktopcomputer")
                }.accessibilityIdentifier("first-mate-lead-machine-\(host.machineID)")
            }
        } label: {
            HStack(spacing: 7) {
                FirstMateFaceOrb(size: 28)
                Text("My First Mate").herdrFont(.body, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(HerdrTheme.iconTint)
            }
            .padding(.leading, 8).padding(.trailing, 14).frame(minHeight: 44).frame(maxWidth: .infinity)
            .herdrControlGlass(in: .capsule)
        }
        .buttonStyle(.plain).accessibilityIdentifier("first-mate-lead-machine-menu")
        .composerLayoutMeasurement(id: "lead-machine-control")
    }
}
