import AppKit
import SwiftUI

struct PiSessionBoundaryView: View {
    let previousSessionID: String
    let currentSessionID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Previous session")
                    .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                    .foregroundStyle(HerdrTheme.secondaryText)
                Text(previousSessionID)
                    .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true).textSelection(.enabled)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                Button("Copy previous session ID", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(previousSessionID, forType: .string)
                }
                .buttonStyle(HerdrIconButtonStyle())
                .help("Copy the session ID of the chat just closed")
            }
            HStack(spacing: 10) {
                Rectangle().fill(HerdrTheme.inkFill(0.12)).frame(height: 1)
                Label("New conversation", systemImage: "sparkle")
                    .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium).fixedSize()
                    .foregroundStyle(HerdrTheme.accent)
                Rectangle().fill(HerdrTheme.inkFill(0.12)).frame(height: 1)
            }
            Text("Fresh context for Pi. Your previous chat stays above for reference.")
                .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.tertiaryText)
            if let currentSessionID {
                Text(currentSessionID).herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.tertiaryText).textSelection(.enabled)
            }
        }
        .padding(.vertical, 20)
        .environment(\.saveChatQuote, nil)
        .accessibilityIdentifier("pi-new-session-divider")
    }
}
