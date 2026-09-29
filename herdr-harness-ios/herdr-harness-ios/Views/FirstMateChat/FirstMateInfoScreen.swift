import SwiftUI

extension EnvironmentValues {
    @Entry var firstMateHighlightedAssignment: String? = nil
}

/// Pushed inspector host. Its documents and saved sessions remain sheets,
/// never a second inspector sheet layered over a chat sheet.
struct FirstMateInfoScreen: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    @Bindable var store: FirstMateStore
    let target: FirstMateFeatureTarget
    var assignmentID: String? = nil
    @State private var lease = FirstMateWorkspaceControlLease()
    @State private var appeared = false
    private var controls: Bool {
        fleet.store(for: target) === store && fleet.selectedTarget == target && store.selectedFeatureID == target.featureID
            && store.snapshots[target.featureID] != nil && model.firstMateCanControl(machineID: target.machineID)
    }
    var body: some View {
        Group {
            if let snapshot = store.snapshots[target.featureID] {
                FirstMateInspectorView(store: store, snapshot: snapshot)
                    .environment(\.firstMateHighlightedAssignment, assignmentID.flatMap { id in
                        snapshot.assignments.contains { $0.id == id && $0.featureID == target.featureID } ? id : nil
                    })
            } else { ProgressView("Opening feature info…") }
        }
        .herdrFirstMateChrome().navigationTitle("Feature info").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar).toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .onAppear { appeared = true; lease.update(store: store, available: controls) }
        .onDisappear { appeared = false; lease.release() }
        .onChange(of: controls) { _, _ in if appeared { lease.update(store: store, available: controls) } }
        .onChange(of: store.lifecycle) { _, _ in if appeared { lease.update(store: store, available: controls) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-info-screen")
    }
}
