import SwiftUI

struct FirstMateWorkflowView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Feature journal").herdrFont(.title2, weight: .semibold)
                Spacer()
                Picker("Workflow presentation", selection: $store.graphMode) {
                    Text("Timeline").tag(false)
                    Text("Graph").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 155)
                    .accessibilityLabel("Workflow presentation")
                    .accessibilityIdentifier("first-mate-workflow-mode")
            }
            Text("Every visit retains its agents and evidence. Revisions keep earlier work available.")
                .herdrFont(.subheadline).foregroundStyle(.secondary)
            if store.graphMode {
                FirstMateGraphView(store: store, snapshot: snapshot)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshot.visits.enumerated()), id: \.element.id) { index, visit in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                Image(systemName: visit.status == "completed" ? "checkmark.circle.fill" : "circle")
                                    .herdrFont(.body).foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                                Rectangle().fill(FirstMatePalette(scheme: scheme).line).frame(width: 1)
                            }.frame(width: 20)
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top) {
                                    Text(visit.title).herdrFont(.headline)
                                    Spacer(minLength: 4)
                                    FirstMateStatusLabel(status: visit.status)
                                }
                                Text("Visit \(index + 1) · revision \(visit.revision)").herdrFont(.caption2).foregroundStyle(.secondary)
                                FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
                            }.padding(.bottom, 27).frame(maxWidth: .infinity, alignment: .leading)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            FirstMateReliabilityView(health: store.runtimeHealth, snapshot: snapshot)
            ForEach(snapshot.events.filter { $0.featureID == snapshot.feature.id && $0.recoveryCheckpoint?.workspacePath != nil }.suffix(10)) { event in
                if let checkpoint = event.recoveryCheckpoint {
                    DisclosureGroup("Recovery checkpoint · \(event.createdAt)") {
                        FirstMateRecoveryFactsView(store: store, snapshot: snapshot, checkpoint: checkpoint)
                            .padding(.top, 8)
                    }
                    .herdrFont(.subheadline)
                }
            }
            if snapshot.visits.isEmpty {
                ContentUnavailableView("The journey starts with a plan", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
        }
    }
}
