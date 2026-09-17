import SwiftUI

struct HudChatTurnView: View {
    let turn: HeadlessAgentRun

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOU")
                    .font(.subheadline.monospaced().bold())
                    .foregroundStyle(HerdrTheme.muted)
                Text(turn.prompt)
                    .font(.body)
                    .foregroundStyle(HerdrTheme.text)
                    .textSelection(.enabled)
            }
            .padding(HerdrTheme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HerdrTheme.elevated.opacity(0.55))
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))

            if let response = turn.response, !response.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AGENT")
                        .font(.subheadline.monospaced().bold())
                        .foregroundStyle(HerdrTheme.accent)
                    PiMarkdownMessageView(source: response, isStreaming: false)
                        .textSelection(.enabled)
                }
                .padding(HerdrTheme.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HerdrTheme.graphite)
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                        .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                }
                .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
            } else if turn.status == .queued || turn.status == .running {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(HerdrTheme.accent)
                    Text(turn.status == .queued ? "Queued on the machine…" : "Agent is working in the background…")
                        .font(.subheadline)
                        .foregroundStyle(HerdrTheme.mist)
                }
                .frame(minHeight: 44)
            }

            if let error = turn.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(HerdrTheme.alert)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("hud-chat-turn-\(turn.id)")
    }
}
