import SwiftUI

struct FirstMateWorkflowView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Feature journal").font(.title2).bold().accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("first-mate-workflow")
                Text("Every step keeps its crew, documents, and decisions together.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Picker("Workflow presentation", selection: $store.graphMode) {
                Text("Timeline").tag(false)
                Text("Graph").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("first-mate-workflow-mode")

            if snapshot.visits.isEmpty {
                ContentUnavailableView("The journey starts with a plan", systemImage: "point.topleft.down.to.point.bottomright.curvepath", description: Text("Tell your First Mate the outcome you want to work toward."))
            } else if store.graphMode {
                FirstMateGraphView(store: store, snapshot: snapshot)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshot.visits.enumerated()), id: \.element.id) { index, visit in
                        FirstMateTimelineVisit(store: store, snapshot: snapshot, visit: visit,
                                               index: index, isLast: index == snapshot.visits.count - 1)
                    }
                }
            }

            if !snapshot.events.isEmpty {
                DisclosureGroup {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(snapshot.events.sorted { $0.sequence > $1.sequence }) { event in
                            FirstMateJournalRow(event: event)
                        }
                    }
                    .padding(.top, 16)
                } label: {
                    Text("Activity log · \(snapshot.events.count) \(snapshot.events.count == 1 ? "update" : "updates")")
                        .accessibilityIdentifier("first-mate-activity-log")
                }
                .font(.subheadline.weight(.medium))
                .padding(.vertical, 8)
            }
        }
    }
}
