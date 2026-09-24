import SwiftUI

struct DashboardNewFeatureCard: View {
    let model: HerdrAppModel
    let shell: HerdrShellState
    private var machines: [HerdrMachine] {
        model.machines.filter { model.firstMateConfiguration(machineID: $0.id) != nil }
    }
    var body: some View {
        Group {
            if model.isDemoMode {
                Button("New feature", systemImage: "plus") { create("demo") }
            } else if machines.count == 1, let machine = machines.first {
                Button("New feature", systemImage: "plus") { create(machine.id) }
            } else {
                Menu("New feature", systemImage: "plus") {
                    ForEach(machines) { machine in Button(machine.name) { create(machine.id) } }
                }.menuStyle(.borderlessButton).disabled(machines.isEmpty)
            }
        }
        .herdrFont(.body).buttonStyle(.plain).foregroundStyle(HerdrTheme.accent)
        .frame(width: 180, height: 256)
        .background(HerdrTheme.elevated.opacity(0.35), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(HerdrTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 5])) }
        .accessibilityIdentifier("dashboard-new-feature")
        .help(machines.isEmpty && !model.isDemoMode ? "Connect a machine in Settings to create a feature" : "Start a new First Mate feature")
    }
    private func create(_ machineID: String) {
        shell.createFirstMateFeature(on: machineID)
        shell.show(.firstMate, model: model)
    }
}
