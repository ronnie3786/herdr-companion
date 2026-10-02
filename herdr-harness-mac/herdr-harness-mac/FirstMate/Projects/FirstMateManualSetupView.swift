import SwiftUI

struct FirstMateManualSetupView: View {
    @Bindable var model: FirstMateStartSessionModel
    @Bindable var index: FirstMateProjectIndex
    let browse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Session name").herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                TextField("e.g. Improve search suggestions", text: $model.manualTitle)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Session name")
                    .accessibilityIdentifier("first-mate-start-title")
            }
            Picker("Machine", selection: $model.manualMachineID) {
                Text("Choose a machine").tag(nil as String?)
                ForEach(index.hosts) { host in
                    Text("\(host.machineName) · \(host.availabilityLabel)").tag(Optional(host.machineID))
                }
                if let machineID = model.manualMachineID, index.host(machineID) == nil {
                    Text("Machine unavailable").tag(Optional(machineID))
                }
            }
            .onChange(of: model.manualMachineID) { model.changeManualMachine() }
            .accessibilityIdentifier("first-mate-start-machine")
            VStack(alignment: .leading, spacing: 7) {
                Text("Folder on this machine").herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                HStack(spacing: 8) {
                    TextField("Absolute folder path", text: $model.manualPath)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Folder on this machine")
                        .accessibilityIdentifier("first-mate-start-folder")
                    Button("Browse…", action: browse)
                        .disabled(index.host(model.manualMachineID)?.supportsDirectoryBrowser != true || index.host(model.manualMachineID)?.isReachable != true)
                        .accessibilityIdentifier("first-mate-start-browse")
                }
                FirstMateProjectHostNotice(host: index.host(model.manualMachineID), manual: true)
                if model.manualMachineID != nil && index.host(model.manualMachineID) == nil {
                    FirstMateProjectNotice(text: "This machine is no longer configured. Choose a connected machine to continue.", warning: true)
                }
                if !model.manualPath.isEmpty && !model.manualPath.hasPrefix("/") {
                    Text("Use the full absolute path, or Browse to choose a folder.")
                        .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.warning)
                }
            }
        }
    }
}
