import SwiftUI

struct FirstMateWorkspaceView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var scheme
    @State private var path: [FirstMateFeatureTarget] = []

    private var availableMachineIDs: [String] { fleet.hosts.map(\.machineID) }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    featureList
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
                } detail: {
                    if let target = fleet.selectedTarget, let store = fleet.store(for: target) {
                        detail(store: store, target: target)
                    } else {
                        ContentUnavailableView("Your feature, in focus", systemImage: "sailboat", description: Text("Choose a feature to talk with its First Mate and follow the work."))
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack(path: $path) {
                    featureList
                        .navigationDestination(for: FirstMateFeatureTarget.self) { target in
                            if let store = fleet.store(for: target) {
                                detail(store: store, target: target)
                            }
                        }
                }
            }
        }
        .tint(FirstMatePalette(scheme: scheme).accent)
        .sheet(isPresented: $fleet.isCreating) {
            FirstMateCreateSheet(model: model, fleet: fleet, onCreated: openFeature)
        }
        // A replaced connection fences every host store and any open create
        // sheet before the next SwiftUI task can run.
        .onChange(of: model.connectionGeneration) { _, _ in
            path = []
            fleet.isCreating = false
        }
        // Removing or reconfiguring a host invalidates only the navigation and
        // sheets that pointed at it; nothing falls back to another machine.
        .onChange(of: availableMachineIDs) { _, machineIDs in
            path.removeAll { !machineIDs.contains($0.machineID) }
            if let selected = fleet.selectedTarget, !machineIDs.contains(selected.machineID) {
                fleet.selectTarget(nil)
            }
        }
        .onChange(of: fleet.selectedTarget) { _, target in
            if target == nil, !path.isEmpty { path = [] }
        }
        .accessibilityIdentifier("first-mate-workspace")
    }

    private var featureList: some View {
        FirstMateFeatureListView(model: model, fleet: fleet, openFeature: openFeature)
    }

    private func detail(store: FirstMateStore, target: FirstMateFeatureTarget) -> some View {
        FirstMateFeatureDetailView(
            store: store,
            featureID: target.featureID,
            machineName: model.machineName(target.machineID),
            canControl: model.firstMateCanControl(machineID: target.machineID)
        )
        .id("\(target.machineID)-\(target.featureID)")
    }

    private func openFeature(_ target: FirstMateFeatureTarget) {
        guard fleet.open(target) else { return }
        if horizontalSizeClass != .regular { path = [target] }
    }
}
