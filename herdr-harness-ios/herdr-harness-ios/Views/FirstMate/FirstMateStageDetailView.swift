import SwiftUI

struct FirstMateStageDetailView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let visit: FirstMateVisit

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !snapshot.agents(for: visit.id).isEmpty {
                Text("Assigned crew").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                ForEach(snapshot.agents(for: visit.id)) { agent in
                    FirstMateAgentRow(store: store, agent: agent)
                }
            }
            if !snapshot.documents(for: visit.id).isEmpty {
                Text("Attached documents").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                ForEach(snapshot.documents(for: visit.id)) { document in
                    FirstMateDocumentRow(store: store, snapshot: snapshot, document: document, showsVisit: false)
                }
            }
            if snapshot.agents(for: visit.id).isEmpty && snapshot.documents(for: visit.id).isEmpty {
                Text("Agents and documents will appear when this step begins.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
