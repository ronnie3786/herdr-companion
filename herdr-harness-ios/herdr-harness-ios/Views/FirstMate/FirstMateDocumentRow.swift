import SwiftUI

struct FirstMateDocumentRow: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let document: FirstMateDocument
    var showsVisit = true
    @Environment(\.colorScheme) private var scheme

    /// "Device QA · QA": the producing agent, then its step, on one line.
    private var detail: String {
        let author = snapshot.author(of: document)?.title ?? "Source retained with document"
        guard showsVisit, let visit = snapshot.visits.first(where: { $0.id == document.visitID }) else { return author }
        return "\(author) · \(visit.title)"
    }

    var body: some View {
        Button {
            Task { await store.open(.document(document)) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(HerdrTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(HerdrTheme.accent.opacity(0.12), in: .rect(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title).herdrFont(.body, weight: .medium).foregroundStyle(HerdrTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HerdrTheme.iconTint)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .accessibilityHint("Opens this document and the session that produced it")
        .accessibilityIdentifier("first-mate-document-\(document.id)")
    }
}
