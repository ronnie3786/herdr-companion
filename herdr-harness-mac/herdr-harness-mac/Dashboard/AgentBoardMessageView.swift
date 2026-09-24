import SwiftUI

struct AgentBoardMessageView: View {
    let message: AgentBoardContent.MessageRow
    let openFullView: () -> Void
    @State private var isExpanded = false

    /// Long replies fold after roughly fourteen lines of a column's width.
    private static let foldCharacterBudget = 900

    var body: some View {
        if message.isHuman { human } else { assistant }
    }

    private var human: some View {
        VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                if !message.blocks.isEmpty {
                    AgentBoardProseView(blocks: message.blocks)
                }
                ForEach(message.attachments) { attachment in
                    Button(action: openFullView) {
                        Label(attachment.filename, systemImage: "paperclip")
                            .herdrFont(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .overlay { RoundedRectangle(cornerRadius: 7).stroke(HerdrTheme.selection) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HerdrTheme.accent)
                    .help("Open the full First Mate conversation for this attachment")
                    .accessibilityLabel("Attachment \(attachment.filename), open full First Mate view")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(HerdrTheme.surface, in: .rect(cornerRadius: HerdrTheme.bubbleRadius))
            .overlay { RoundedRectangle(cornerRadius: HerdrTheme.bubbleRadius).stroke(HerdrTheme.accent.opacity(0.16)) }
            if message.isQueued {
                Text("Queued").herdrFont(.subheadline).foregroundStyle(HerdrTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 36)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(plainText)")
    }

    private var assistant: some View {
        let folds = !isExpanded && characterCount > Self.foldCharacterBudget
        return VStack(alignment: .leading, spacing: 6) {
            AgentBoardProseView(blocks: folds ? foldedBlocks : message.blocks)
            if characterCount > Self.foldCharacterBudget {
                Button(isExpanded ? "Show less" : "Show more") { isExpanded.toggle() }
                    .buttonStyle(.plain)
                    .herdrFont(.subheadline)
                    .foregroundStyle(HerdrTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("First Mate: \(plainText)")
    }

    private var characterCount: Int {
        message.blocks.reduce(0) { $0 + $1.characterCount }
    }

    /// Whole blocks up to the budget; always at least the first block.
    private var foldedBlocks: [AgentBoardProseBlock] {
        var total = 0
        var result: [AgentBoardProseBlock] = []
        for block in message.blocks {
            if !result.isEmpty, total + block.characterCount > Self.foldCharacterBudget { break }
            result.append(block)
            total += block.characterCount
        }
        return result
    }

    private var plainText: String {
        message.blocks.map(\.plainText).joined(separator: " ")
    }
}

/// Compact rendering of a First Mate reply: column-sized type, no nested cards.
struct AgentBoardProseView: View {
    let blocks: [AgentBoardProseBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .paragraph(_, let text):
                    Text(text).herdrFont(.body).lineSpacing(3)
                case .heading(_, let text):
                    Text(text).herdrFont(.body, weight: .semibold).padding(.top, 2)
                case .quote(_, let text):
                    Text(text).herdrFont(.body).lineSpacing(3)
                        .foregroundStyle(HerdrTheme.mist)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(HerdrTheme.separator).frame(width: 2)
                        }
                case .listItem(_, let marker, let depth, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(HerdrTheme.muted).monospacedDigit()
                            .frame(minWidth: 12, alignment: .trailing)
                        Text(text).lineSpacing(3)
                    }
                    .herdrFont(.body)
                    .padding(.leading, CGFloat(min(depth, 4)) * 14)
                case .code(_, let code):
                    Text(code)
                        .herdrFont(.callout, monospaced: true)
                        .foregroundStyle(HerdrTheme.code)
                        .lineLimit(14)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HerdrTheme.graphite, in: .rect(cornerRadius: 6))
                case .notice(_, let text):
                    Text(text).herdrFont(.subheadline).foregroundStyle(HerdrTheme.muted)
                }
            }
        }
        .foregroundStyle(HerdrTheme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

extension AgentBoardProseBlock {
    var plainText: String {
        switch self {
        case .paragraph(_, let text), .heading(_, let text), .quote(_, let text), .listItem(_, _, _, let text):
            String(text.characters)
        case .code(_, let text), .notice(_, let text):
            text
        }
    }

    var characterCount: Int {
        switch self {
        case .paragraph(_, let text), .heading(_, let text), .quote(_, let text), .listItem(_, _, _, let text):
            text.characters.count
        case .code(_, let text), .notice(_, let text):
            text.count
        }
    }
}
