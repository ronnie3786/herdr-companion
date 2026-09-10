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
                        .herdrFont(.subheadline, weight: .semibold)
                }.buttonStyle(.plain)
                Spacer()
                Text(session.closedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
            }
            HStack(spacing: 8) {
                Text(session.id).herdrFont(.caption2, monospaced: true).textSelection(.enabled)
                Button("Copy session ID", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.id, forType: .string)
                }.labelStyle(.iconOnly).buttonStyle(.plain).help("Copy closed Pi session ID")
            }.foregroundStyle(HerdrTheme.muted)
            if isExpanded {
                if session.wasTruncated {
                    Text("Pi had omitted older context from this transcript.").herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
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
        .padding(.vertical, 18)
        .onAppear { isExpanded = initiallyExpanded }
        .accessibilityIdentifier("pi-closed-session-\(session.id)")
    }
}

private struct PiClosedSessionEntryView: View {
    let entry: PiClosedSession.Entry
    let sessionID: String
    var body: some View {
        if entry.role == "You" || entry.role == "Pi" {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.role).herdrFont(.caption, weight: .semibold).foregroundStyle(HerdrTheme.muted)
                PiMarkdownMessageView(source: entry.text, isStreaming: false, id: "closed-\(sessionID)-\(entry.id)")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(entry.role == "You" ? HerdrTheme.elevated : .clear, in: .rect(cornerRadius: 10))
        } else {
            DisclosureGroup(entry.role) {
                PiMarkdownMessageView(source: entry.text, isStreaming: false, id: "closed-\(sessionID)-\(entry.id)")
            }.herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
        }
    }
}
