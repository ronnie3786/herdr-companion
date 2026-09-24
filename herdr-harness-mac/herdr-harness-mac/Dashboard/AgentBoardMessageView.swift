import SwiftUI

struct AgentBoardMessageView: View {
    let message: FirstMateMessage
    let openFullView: () -> Void
    private var isHuman: Bool { ["user", "human"].contains(message.role) }

    var body: some View {
        let content = AgentBoardMessageContent.parse(message.text)
        HStack(alignment: .top, spacing: 0) {
            if isHuman { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(isHuman ? "You" : "First Mate")
                    if message.status == "queued" { Text("· Queued") }
                }
                .herdrFont(.caption, weight: .medium)
                .foregroundStyle(HerdrTheme.muted)
                if isHuman {
                    if !content.text.isEmpty {
                        Text(content.text)
                            .herdrFont(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(content.attachments) { attachment in
                        Button(action: openFullView) {
                            Label(attachment.filename, systemImage: "paperclip")
                                .herdrFont(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(HerdrTheme.surface, in: .rect(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(HerdrTheme.accent)
                        .help("Open the full First Mate conversation for this attachment")
                        .accessibilityLabel("Attachment \(attachment.filename), open full First Mate view")
                        .accessibilityHint("Shows this feature's conversation and resources on its owning machine")
                    }
                } else {
                    PiMarkdownMessageView(source: message.text, isStreaming: false,
                                          id: "agent-board:\(message.featureID):\(message.id)", detectsPaneLinks: false)
                        .environment(\.chatProsePalette, ChatProsePalette(
                            text: HerdrTheme.text, secondaryText: HerdrTheme.muted,
                            accent: HerdrTheme.accent, separator: HerdrTheme.separator))
                }
            }
            .padding(12)
            .background(isHuman ? HerdrTheme.selection : HerdrTheme.graphite.opacity(0.6), in: .rect(cornerRadius: 9))
            if !isHuman { Spacer(minLength: 16) }
        }
    }
}
