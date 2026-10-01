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
    var openFeature: (FirstMateFeatureTarget) -> Void = { _ in }
    var embedded = false
    @State private var lease = FirstMateWorkspaceControlLease()
    @State private var appeared = false
    private var controls: Bool {
        fleet.store(for: target) === store && fleet.selectedTarget == target && store.selectedFeatureID == target.featureID
            && store.snapshots[target.featureID] != nil && model.firstMateCanControl(machineID: target.machineID)
    }
    private var isLead: Bool { store.snapshots[target.featureID]?.feature.isLead == true }
    /// The feature's own name, as the Mac chat header shows it; "Feature
    /// info" only while the snapshot is still loading.
    private var title: String {
        if isLead { return "My First Mate" }
        let conversation = fleet.chat.conversation(for: target, fleet: fleet)
        return conversation?.name ?? store.snapshots[target.featureID]?.feature.title ?? "Feature info"
    }
    private var subtitle: String {
        let machine = model.machineName(target.machineID)
        guard !isLead, let snapshot = store.snapshots[target.featureID] else { return machine }
        let status = FirstMateMobileTranscriptPolicy.statusWord(snapshot: snapshot, conversation: fleet.chat.conversation(for: target, fleet: fleet))
        return "\(status) · \(machine)"
    }

    var body: some View {
        // On iPad the chat bar beside this panel already names the feature, so
        // the panel starts with its tabs (and Pin/Close when it floats).
        VStack(spacing: 0) {
            if let snapshot = store.snapshots[target.featureID] {
                if snapshot.feature.isLead {
                    FirstMateLeadOverview(fleet: fleet, snapshot: snapshot, openFeature: openFeature)
                } else {
                    FirstMateInspectorView(store: store, snapshot: snapshot)
                        .environment(\.firstMateHighlightedAssignment, assignmentID.flatMap { id in
                            snapshot.assignments.contains { $0.id == id && $0.featureID == target.featureID } ? id : nil
                        })
                }
            } else { ProgressView("Opening feature info…") }
        }
        .herdrFirstMateChrome().navigationTitle(title).navigationSubtitle(subtitle).navigationBarTitleDisplayMode(.inline)
        .toolbar(embedded ? .hidden : .visible, for: .navigationBar).toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarVisibility(embedded ? .visible : .hidden, for: .tabBar)
        .onAppear { appeared = true; updateLease() }
        .onDisappear { appeared = false; lease.release() }
        .onChange(of: controls) { _, _ in if appeared { updateLease() } }
        .onChange(of: store.lifecycle) { _, _ in if appeared { updateLease() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-info-screen")
    }
    private func updateLease() {
        // Inline Info shares the visible chat's lease. Acquiring another lease
        // would let an inspector dismissal revoke control from that chat.
        if appeared && !embedded { lease.update(store: store, available: controls) }
        else { lease.release() }
    }
}
