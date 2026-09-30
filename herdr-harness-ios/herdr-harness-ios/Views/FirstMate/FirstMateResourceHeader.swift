import SwiftUI

struct FirstMateResourceHeader: View {
    @Bindable var store: FirstMateStore
    let resource: FirstMateResource

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(resource.title).herdrFont(size: 22, weight: .semibold, relativeTo: .title2)
                .foregroundStyle(HerdrTheme.primaryText).textSelection(.enabled)
                .accessibilityIdentifier("first-mate-resource-sheet")
            switch resource {
            case .document(let document):
                let visit = store.snapshot?.visits.first(where: { $0.id == document.visitID })
                Label(visit.map { "Attached evidence · \($0.title)" } ?? "Attached evidence", systemImage: "doc.text")
                    .herdrFont(.subheadline)
                    .foregroundStyle(HerdrTheme.secondaryText)
                if let author = store.snapshot?.author(of: document), let sessionID = author.nativeSessionID,
                   sessionID == document.nativeSessionID {
                    Button {
                        Task { await store.open(.session(author)) }
                    } label: {
                        Label("Produced by \(author.title)", systemImage: "person.crop.circle")
                            .frame(minHeight: 44).contentShape(.rect)
                    }
                    .buttonStyle(.herdrPlain)
                    .herdrFont(.subheadline, weight: .medium).foregroundStyle(HerdrTheme.accent)
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
                HStack(spacing: 10) {
                    Text("\(agent.role.replacingOccurrences(of: "_", with: " ").capitalized) · generation \(agent.generation)")
                        .herdrFont(.subheadline).foregroundStyle(HerdrTheme.secondaryText)
                    FirstMateStatusLabel(status: agent.status)
                }
                FirstMateSessionHistoryView(store: store, resource: resource)
                FirstMateResourceMetadataView(resource: resource)
            case .history(let session):
                Text("\(session.kindDisplayName) · \(session.role.replacingOccurrences(of: "_", with: " ").capitalized) · generation \(session.generation)")
                    .herdrFont(.subheadline).foregroundStyle(HerdrTheme.secondaryText)
                FirstMateStatusLabel(status: session.status)
                FirstMateSessionHistoryView(store: store, resource: resource)
                FirstMateResourceMetadataView(resource: resource)
            }
        }
    }
}
