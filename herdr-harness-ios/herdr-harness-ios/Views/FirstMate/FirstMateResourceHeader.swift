import SwiftUI

struct FirstMateResourceHeader: View {
    @Bindable var store: FirstMateStore
    let resource: FirstMateResource

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(resource.title).font(.title2).bold().textSelection(.enabled)
                .accessibilityIdentifier("first-mate-resource-sheet")
            switch resource {
            case .document(let document):
                Label("Attached evidence", systemImage: "doc.text")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let visit = store.snapshot?.visits.first(where: { $0.id == document.visitID }) {
                    Text(visit.title).font(.subheadline.weight(.medium))
                }
                if let author = store.snapshot?.author(of: document), let sessionID = author.nativeSessionID,
                   sessionID == document.nativeSessionID {
                    Button {
                        Task { await store.open(.session(author)) }
                    } label: {
                        Label("Produced by \(author.title)", systemImage: "person.crop.circle")
                            .frame(minHeight: 44)
                    }
                    .font(.subheadline)
                    .accessibilityIdentifier("first-mate-document-author")
                } else if let source = store.snapshot?.sessions.first(where: { $0.nativeSessionID == document.nativeSessionID }) {
                    Button("Open producing session", systemImage: "person.crop.circle") {
                        Task { await store.open(.history(source)) }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("first-mate-document-author")
                }
                FirstMateResourceMetadataView(resource: resource)
            case .session(let agent):
                Text("\(agent.role) · generation \(agent.generation)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                FirstMateStatusLabel(status: agent.status)
                FirstMateSessionHistoryView(store: store, resource: resource)
                FirstMateResourceMetadataView(resource: resource)
            case .history(let session):
                Text("\(session.kindDisplayName) · \(session.role.replacingOccurrences(of: "_", with: " ").capitalized) · generation \(session.generation)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                FirstMateStatusLabel(status: session.status)
                FirstMateSessionHistoryView(store: store, resource: resource)
                FirstMateResourceMetadataView(resource: resource)
            }
        }
    }
}
