import SwiftUI

/// Saved native Pi messages use the same rows and Clanking groups as Chat.
/// No composer or mutation controls are mounted in this viewer.
struct FirstMateSessionTranscriptView: View {
    let messages: [FirstMateSessionMessage]?
    let fallbackText: String
    let sessionID: String
    var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let messages {
                let turns = FirstMateSessionTimeline.turns(messages, sessionID: sessionID, isRunning: isRunning)
                let rows = PiTimelineRow.rows(for: turns, groupAllActivity: true)
                if rows.isEmpty && !isRunning {
                    ContentUnavailableView("No saved messages yet", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("This session has no recorded conversation."))
                        .frame(maxWidth: .infinity)
                }
                ForEach(rows) { row in
                    PiTimelineRowView(row: row).equatable()
                }
                if isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the agent’s next saved response…")
                            .herdrFont(size: HerdrTheme.TextSize.caption)
                            .foregroundStyle(HerdrTheme.secondaryText)
                    }
                    .padding(.top, 16)
                    .accessibilityIdentifier("first-mate-session-waiting")
                }
            } else {
                Text(fallbackText).herdrFont(size: HerdrTheme.TextSize.body).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: HerdrTheme.readingWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("first-mate-session-transcript")
    }
}
