import SwiftUI

struct FirstMateGraphView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @State private var expandedVisitID: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(snapshot.visits.enumerated()), id: \.element.id) { index, visit in
                if index > 0 {
                    VStack(spacing: 0) {
                        Rectangle().fill(FirstMatePalette(scheme: scheme).accent.opacity(0.4))
                            .frame(width: 2, height: 16)
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.footnote)
                            .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
                }
                FirstMateGraphNode(store: store, snapshot: snapshot, visit: visit,
                                   isExpanded: expandedVisitID == visit.id) {
                    expandedVisitID = expandedVisitID == visit.id ? nil : visit.id
                    store.selectedVisitID = visit.id
                }
            }
            Text("Recorded step order. Open a step to see its crew and evidence.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .accessibilityIdentifier("first-mate-graph")
        }
    }
}
