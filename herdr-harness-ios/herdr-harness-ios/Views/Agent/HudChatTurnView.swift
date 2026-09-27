import SwiftUI

struct HudChatTurnView: View {
    let turn: HeadlessAgentRun
    /// The conversation's skim choices: Skim or Full reply per turn, and "Show in reply".
    let skimState: SkimReadingState

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
                let reader = Self.skimReader(skim: turn.skim, response: response)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("AGENT")
                            .font(.subheadline.monospaced().bold())
                            .foregroundStyle(HerdrTheme.accent)
                        if reader == nil, turn.skim?.status == .pending {
                            Text("Skimming…")
                                .font(.caption)
                                .foregroundStyle(HerdrTheme.muted)
                                .composerLayoutMeasurement(id: "skim-pending", label: "Skimming…")
                        }
                    }
                    SkimmableReply(messageID: turn.id, reader: reader, style: .hud, state: skimState) {
                        PiMarkdownMessageView(source: response, isStreaming: false)
                            .textSelection(.enabled)
                    }
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

    /// A ready skim that is valid for this exact response, or nil (full response).
    private static func skimReader(skim: FirstMateSkim?, response: String) -> FirstMateSkimReader? {
        guard let reader = FirstMateSkimReader(skim: skim, reply: response) else { return nil }
        return SkimDisplay.hasContent(reader) ? reader : nil
    }
}
