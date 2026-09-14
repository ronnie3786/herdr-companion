import SwiftUI

struct FirstMateDocumentRow: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let document: FirstMateDocument
    var showsVisit = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            Task { await store.open(.document(document)) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(document.title).font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(snapshot.author(of: document)?.title ?? "Source retained with document")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if showsVisit, let visit = snapshot.visits.first(where: { $0.id == document.visitID }) {
                        Text(visit.title).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 14)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this document and the session that produced it")
        .accessibilityIdentifier("first-mate-document-\(document.id)")
    }
}
