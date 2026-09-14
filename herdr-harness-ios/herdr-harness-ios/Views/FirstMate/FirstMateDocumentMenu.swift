import SwiftUI

struct FirstMateDocumentMenu: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let visit: FirstMateVisit
    @Environment(\.colorScheme) private var scheme

    private var documents: [FirstMateDocument] { snapshot.documents(for: visit.id) }
    private var countTitle: String { "\(documents.count) \(documents.count == 1 ? "document" : "documents")" }

    var body: some View {
        Menu {
            Section(visit.title) {
                ForEach(documents) { document in
                    Button {
                        Task { await store.open(.document(document)) }
                    } label: {
                        Label(document.title, systemImage: "doc.text")
                    }
                }
            }
        } label: {
            Label(countTitle, systemImage: "doc.text")
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(FirstMatePalette(scheme: scheme).accent.opacity(0.08), in: .rect(cornerRadius: 12))
        }
        .disabled(documents.isEmpty)
        .accessibilityLabel("\(countTitle) for \(visit.title)")
        .accessibilityHint("Choose a document attached to this workflow step")
        .accessibilityIdentifier("first-mate-visit-documents-\(visit.id)")
    }
}
