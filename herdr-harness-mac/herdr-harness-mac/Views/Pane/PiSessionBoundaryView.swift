import AppKit
import SwiftUI

struct PiSessionBoundaryView: View {
    let previousSessionID: String
    let currentSessionID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Previous session")
                    .herdrFont(.caption, weight: .semibold)
                Text(previousSessionID)
                    .herdrFont(.caption, monospaced: true).textSelection(.enabled)
                Button("Copy previous session ID", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(previousSessionID, forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.plain).help("Copy the session ID of the chat just closed")
            }
            .foregroundStyle(HerdrTheme.mist)
            HStack(spacing: 12) {
                Rectangle().fill(HerdrTheme.separator).frame(height: 1)
                Label("New conversation", systemImage: "sparkle")
                    .herdrFont(.subheadline, weight: .semibold).fixedSize()
                    .foregroundStyle(HerdrTheme.accent)
                Rectangle().fill(HerdrTheme.separator).frame(height: 1)
            }
            Text("Fresh context for Pi. Your previous chat stays above for reference.")
                .herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
            if let currentSessionID {
                Text(currentSessionID).herdrFont(.caption2, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted).textSelection(.enabled)
            }
        }
        .padding(.vertical, 24)
        .environment(\.saveChatQuote, nil)
        .accessibilityIdentifier("pi-new-session-divider")
    }
}
