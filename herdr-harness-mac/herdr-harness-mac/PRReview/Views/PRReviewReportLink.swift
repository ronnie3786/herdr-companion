import SwiftUI

struct PRReviewReportLink: View {
    let store: PRReviewStore
    let document: PRReviewDocument
    let documentHost: HerdrAppModel?

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: document.kind == .html ? "globe" : "doc.text")
                Text(document.title).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right.square")
            }
            .herdrFont(.callout)
            .foregroundStyle(HerdrTheme.accent)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HerdrTheme.cardFill, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.herdrPlain)
        .accessibilityLabel("Open \(document.title)")
        .accessibilityIdentifier("pr-review-report-\(document.id)")
    }

    private func open() {
        if document.kind == .html {
            PRReviewDocumentWindow.showHTML(document: document, store: store, host: documentHost)
        } else {
            PRReviewDocumentWindow.showMarkdown(document: document, store: store, host: documentHost)
        }
    }
}
