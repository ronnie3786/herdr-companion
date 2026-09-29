import SwiftUI

struct FirstMateDocumentsView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot

    private var presentedDocuments: [FirstMateDocument] { snapshot.presentedDocuments }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FirstMatePullRequestsSection(store: store, snapshot: snapshot, surface: .documents)
            HerdrTabs(
                selection: $store.documentsMode,
                tabs: FirstMateDocumentsMode.allCases.map { .init(value: $0, title: $0.title) },
                style: .compactSegments,
                accessibilityLabel: "Documents and links"
            )
            .fixedSize()
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Feature documents").herdrFont(size: 15, weight: .semibold)
            Text("Evidence stays connected to the visit and agent that produced it.")
                .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.tertiaryText)
                .padding(.bottom, 6)
            ForEach(presentedDocuments) { document in
                Button { Task { await store.open(.document(document)) } } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "doc.text").herdrFont(size: 13).foregroundStyle(HerdrTheme.iconTint).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.title).herdrFont(size: HerdrTheme.TextSize.body, weight: .medium).foregroundStyle(HerdrTheme.primaryText)
                            Text(snapshot.author(of: document)?.title ?? "Source retained with document")
                                .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
                            if let visit = snapshot.visits.first(where: { $0.id == document.visitID }) {
                                Text(visit.title).herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").herdrFont(size: 12).foregroundStyle(HerdrTheme.iconTint)
                    }.padding(.vertical, 8).frame(minHeight: HerdrTheme.ControlHeight.row).contentShape(.rect)
                }.buttonStyle(.herdrPlain).accessibilityIdentifier("first-mate-document-\(document.id)")
                Rectangle().fill(HerdrTheme.rowDivider).frame(height: 1)
            }
            if presentedDocuments.isEmpty { ContentUnavailableView("No documents yet", systemImage: "doc.text") }
        }
    }
}
