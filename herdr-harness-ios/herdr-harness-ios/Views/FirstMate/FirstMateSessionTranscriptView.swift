import SwiftUI
import UIKit

/// Saved Pi messages as a read-only conversation, as on the Mac: your
/// prompts in bubbles, the agent's replies as Markdown under an "Agent"
/// label, and tool results folded. Older companions supply only plain text.
struct FirstMateSessionTranscriptView: View {
    let messages: [FirstMateSessionMessage]?
    let fallbackText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let messages {
                if messages.isEmpty {
                    ContentUnavailableView("No saved messages yet", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("This session has no recorded conversation."))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in row(message) }
                }
            } else {
                Text(fallbackText).font(HerdrProse.font(.bubble)).lineSpacing(6).foregroundStyle(HerdrTheme.proseText)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("first-mate-session-transcript")
    }

    @ViewBuilder private func row(_ message: FirstMateSessionMessage) -> some View {
        switch message.role {
        case "user", "human":
            Text(message.text).font(HerdrProse.font(.bubble)).lineSpacing(5).foregroundStyle(HerdrTheme.primaryText)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(HerdrTheme.accent.opacity(0.20), in: .rect(cornerRadius: 18, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(HerdrTheme.accent.opacity(0.26)) }
                .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text } }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("You: \(message.text)")
        case "assistant":
            VStack(alignment: .leading, spacing: 8) {
                Label("Agent", systemImage: "sparkle")
                    .herdrFont(.footnote, weight: .semibold).foregroundStyle(HerdrTheme.secondaryText)
                FirstMateDocumentContentView(source: message.text)
                    .foregroundStyle(HerdrTheme.proseText)
            }
            .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text } }
        case "toolResult":
            FirstMateToolResultCard(text: message.text)
        default:
            Text(message.text).herdrFont(.body).foregroundStyle(HerdrTheme.proseText).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A saved tool result, folded behind a chevron row.
private struct FirstMateToolResultCard: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Label("Tool result", systemImage: "wrench.and.screwdriver")
                        .herdrFont(.subheadline, weight: .medium).foregroundStyle(HerdrTheme.secondaryText)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HerdrTheme.iconTint).rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(minHeight: 44).contentShape(.rect)
            }
            .buttonStyle(.herdrPlain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                Text(text.isEmpty ? "No text output" : text)
                    .herdrFont(.footnote, monospaced: true).foregroundStyle(HerdrTheme.primaryText)
                    .textSelection(.enabled).padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 12)
        .background(HerdrTheme.codeFill, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(HerdrTheme.hairline) }
    }
}
