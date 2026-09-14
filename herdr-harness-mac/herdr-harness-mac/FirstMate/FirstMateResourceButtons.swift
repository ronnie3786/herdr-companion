import SwiftUI

struct FirstMateResourceButtons: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let visit: FirstMateVisit
    var body: some View {
        HStack(spacing: 9) {
            Menu {
                ForEach(snapshot.agents(for: visit.id)) { agent in
                    Button { Task { await store.open(.session(agent)) } } label: {
                        Label("\(agent.title) · \(agent.status)", systemImage: "person.crop.circle")
                    }.disabled(agent.nativeSessionID == nil)
                }
            } label: {
                Label("\(snapshot.agents(for: visit.id).count) agents", systemImage: "person.2")
            }
            .disabled(snapshot.agents(for: visit.id).isEmpty)
            .accessibilityIdentifier("first-mate-visit-agents-\(visit.id)")
            Menu {
                ForEach(snapshot.documents(for: visit.id)) { document in
                    Button { Task { await store.open(.document(document)) } } label: {
                        Label(document.title, systemImage: "doc.text")
                    }
                }
            } label: {
                Label("\(snapshot.documents(for: visit.id).count) documents", systemImage: "doc.text")
            }
            .disabled(snapshot.documents(for: visit.id).isEmpty)
            .accessibilityIdentifier("first-mate-visit-documents-\(visit.id)")
        }
        .herdrFont(.caption).menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
    }
}
