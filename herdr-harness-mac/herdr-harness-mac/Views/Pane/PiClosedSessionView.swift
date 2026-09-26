import AppKit
import SwiftUI

struct PiClosedSessionView: View {
    let session: PiClosedSession
    var initiallyExpanded = false
    @State private var isExpanded = false
    @State private var visibleCount = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(isExpanded ? "Previous chat" : "Show previous chat", systemImage: isExpanded ? "chevron.down" : "chevron.right")
                        .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                        .foregroundStyle(HerdrTheme.primaryText)
                        .herdrHitTarget(minWidth: 0)
                }.buttonStyle(.plain)
                Spacer()
                Text(session.closedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
            }
            HStack(spacing: 8) {
                Text(session.id).herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true).textSelection(.enabled)
                Button("Copy session ID", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.id, forType: .string)
                }
                .buttonStyle(HerdrIconButtonStyle(visualSize: HerdrTheme.ControlHeight.small))
                .help("Copy closed Pi session ID")
            }.foregroundStyle(HerdrTheme.tertiaryText)
            if isExpanded {
                if session.wasTruncated {
                    Text("Pi had omitted older context from this transcript.").herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.tertiaryText)
                }
                if session.entries.count > visibleCount {
                    Button("Show earlier messages") { visibleCount += 80 }.buttonStyle(.plain)
                }
                ForEach(session.entries.suffix(visibleCount)) { entry in
                    PiClosedSessionEntryView(entry: entry, sessionID: session.id)
                }
            }
        }
        .environment(\.chatQuoteSource, "Pi session \(session.id)")
        .environment(\.saveChatQuote, nil)
        .padding(.vertical, 18)
        .onAppear { isExpanded = initiallyExpanded }
        .accessibilityIdentifier("pi-closed-session-\(session.id)")
    }
}

private struct PiClosedSessionEntryView: View {
    let entry: PiClosedSession.Entry
    let sessionID: String
    @State private var isExpanded = false

    var body: some View {
        if entry.role == "You" || entry.role == "Pi" {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.role).herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold).foregroundStyle(HerdrTheme.tertiaryText)
                PiMarkdownMessageView(source: entry.text, isStreaming: false, id: "closed-\(sessionID)-\(entry.id)", detectsPaneLinks: entry.role == "Pi")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(entry.role == "You" ? HerdrTheme.selectedFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.card))
        } else {
            // A plain disclosure card: up to 36 of these can mount at once,
            // and `DisclosureGroup` is too expensive in the transcript.
            PiDisclosureCard(isExpanded: $isExpanded, chevronColor: HerdrTheme.iconTint) {
                PiMarkdownMessageView(source: entry.text, isStreaming: false, id: "closed-\(sessionID)-\(entry.id)", detectsPaneLinks: false)
                    .padding(.top, 4)
            } label: {
                Text(entry.role)
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
        }
    }
}
