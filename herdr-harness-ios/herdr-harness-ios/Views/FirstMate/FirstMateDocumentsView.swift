import SwiftUI

struct FirstMateDocumentsView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @State private var query = ""

    private var documents: [FirstMateDocument] {
        snapshot.documents.filter { document in
            query.isEmpty || document.title.localizedCaseInsensitiveContains(query)
                || snapshot.author(of: document)?.title.localizedCaseInsensitiveContains(query) == true
                || snapshot.visits.first(where: { $0.id == document.visitID })?.title.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Feature documents").font(.title2).bold().accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("first-mate-documents")
                Text("Evidence stays connected to the step and agent that produced it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !snapshot.documents.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Find a document, agent, or step", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("first-mate-document-search")
                    if !query.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
            }
            LazyVStack(spacing: 0) {
                ForEach(documents) { document in
                    FirstMateDocumentRow(store: store, snapshot: snapshot, document: document)
                    Divider()
                }
            }
            if snapshot.documents.isEmpty {
                ContentUnavailableView("No documents yet", systemImage: "doc.text", description: Text("Plans, reviews, and evidence will appear here as your crew works."))
            } else if documents.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}
