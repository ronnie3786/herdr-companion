import SwiftUI

struct FirstMateDocumentsView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @State private var query = ""

    private var presentedDocuments: [FirstMateDocument] { snapshot.presentedDocuments }
    private var documents: [FirstMateDocument] {
        presentedDocuments.filter { document in
            query.isEmpty || document.title.localizedCaseInsensitiveContains(query)
                || snapshot.author(of: document)?.title.localizedCaseInsensitiveContains(query) == true
                || snapshot.visits.first(where: { $0.id == document.visitID })?.title.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FirstMateInspectorHeading(title: "Feature documents",
                detail: "Evidence stays connected to the step and agent that produced it.")
                .accessibilityIdentifier("first-mate-documents")
            if !presentedDocuments.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(HerdrTheme.iconTint).accessibilityHidden(true)
                    TextField("", text: $query, prompt: Text("Find a document, agent, or step").foregroundStyle(HerdrTheme.tertiaryText))
                        .herdrFont(.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("first-mate-document-search")
                    if !query.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(HerdrTheme.secondaryText)
                    }
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 14)
                .background(HerdrTheme.fieldFill, in: .capsule)
                .overlay { Capsule().strokeBorder(HerdrTheme.outline) }
            }
            LazyVStack(spacing: 0) {
                ForEach(documents) { document in
                    FirstMateDocumentRow(store: store, snapshot: snapshot, document: document)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(HerdrTheme.rowDivider).frame(height: 1).padding(.leading, 46)
                        }
                }
            }
            if presentedDocuments.isEmpty {
                ContentUnavailableView("No documents yet", systemImage: "doc.text", description: Text("Plans, reviews, and evidence will appear here as your crew works."))
            } else if documents.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}
