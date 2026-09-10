import SwiftUI

struct ChatQuotePreview: View {
    let quote: ChatQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Quoted chat", systemImage: "quote.bubble").herdrFont(.headline)
            Text(quote.source).herdrFont(.caption2).foregroundStyle(HerdrTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(quote.text).textSelection(.enabled)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(HerdrTheme.accent).frame(width: 2) }
                    Divider()
                    Text(quote.comment).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
        }
        .herdrFont(.callout).padding(16).frame(width: 360)
        .foregroundStyle(HerdrTheme.text).background(HerdrTheme.graphite)
        .preferredColorScheme(.dark)
    }
}

private struct ChatQuotePreviewModifier: ViewModifier {
    let quote: ChatQuote?
    @State private var isHovering = false
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .task(id: isHovering) {
                guard quote != nil else { return }
                do { try await Task.sleep(for: .milliseconds(isHovering ? 550 : 350)) }
                catch { return }
                isPresented = isHovering
            }
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                if let quote { ChatQuotePreview(quote: quote).onHover { isHovering = $0 } }
            }
            .contextMenu {
                if quote != nil { Button("Preview quote", systemImage: "quote.bubble") { isPresented = true } }
            }
            .accessibilityAction(named: "Preview quote") { if quote != nil { isPresented = true } }
    }
}

extension View {
    func chatQuotePreview(_ quote: ChatQuote?) -> some View { modifier(ChatQuotePreviewModifier(quote: quote)) }
}
