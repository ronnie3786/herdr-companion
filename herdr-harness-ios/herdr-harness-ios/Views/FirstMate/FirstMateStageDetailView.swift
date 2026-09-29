import SwiftUI

struct FirstMateStageDetailView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let visit: FirstMateVisit

    var body: some View {
        let agents = snapshot.agents(for: visit.id)
        let documents = snapshot.presentedDocuments(for: visit.id)
        VStack(alignment: .leading, spacing: 14) {
            if !agents.isEmpty {
                Text("Assigned crew").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                ForEach(agents) { agent in
                    FirstMateAgentRow(store: store, agent: agent)
                }
            }
            if !documents.isEmpty {
                Text("Attached documents").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                ForEach(documents) { document in
                    FirstMateDocumentRow(store: store, snapshot: snapshot, document: document, showsVisit: false)
                }
            }
            if agents.isEmpty && documents.isEmpty {
                Text("Agents and documents will appear when this step begins.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
