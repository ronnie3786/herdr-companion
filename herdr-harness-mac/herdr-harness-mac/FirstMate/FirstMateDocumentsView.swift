import SwiftUI

struct FirstMateDocumentsView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            FirstMatePullRequestsSection(store: store, snapshot: snapshot, surface: .documents)
            Picker("Documents and links", selection: $store.documentsMode) {
                ForEach(FirstMateDocumentsMode.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("first-mate-documents-picker")
            switch store.documentsMode {
            case .documents:
                documents
            case .links:
                FirstMateLinksView(store: store, snapshot: snapshot)
            }
        }
    }

    @ViewBuilder
    private var documents: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Feature documents").herdrFont(.title2, weight: .semibold)
            Text("Evidence stays connected to the visit and agent that produced it.")
                .herdrFont(.subheadline).foregroundStyle(.secondary)
            ForEach(snapshot.documents) { document in
                Button { Task { await store.open(.document(document)) } } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "doc.text").herdrFont(.title3)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(document.title).herdrFont(.subheadline, weight: .medium)
                            Text(snapshot.author(of: document)?.title ?? "Source retained with document")
                                .herdrFont(.caption2).foregroundStyle(.secondary)
                            if let visit = snapshot.visits.first(where: { $0.id == document.visitID }) {
                                Text(visit.title).herdrFont(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").herdrFont(.caption)
                    }.padding(.vertical, 10).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityIdentifier("first-mate-document-\(document.id)")
                Divider()
            }
            if snapshot.documents.isEmpty { ContentUnavailableView("No documents yet", systemImage: "doc.text") }
        }
    }
}
