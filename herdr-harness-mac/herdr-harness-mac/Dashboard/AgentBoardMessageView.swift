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
                    AgentBoardProseView(blocks: message.blocks, textColor: HerdrTheme.primaryText)
                }
                ForEach(message.attachments) { attachment in
                    Button(action: openFullView) {
                        Label(attachment.filename, systemImage: "paperclip")
                            .herdrFont(size: HerdrTheme.TextSize.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 22)
                            .background(HerdrTheme.chipFill, in: .rect(cornerRadius: HerdrTheme.Radius.control))
                            .frame(minHeight: HerdrTheme.minHitTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HerdrTheme.accent)
                    .help("Open the full First Mate conversation for this attachment")
                    .accessibilityLabel("Attachment \(attachment.filename), open full First Mate view")
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(HerdrTheme.selectedFill, in: .rect(cornerRadius: HerdrTheme.bubbleRadius))
            if message.isQueued {
                Text("Queued").herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(plainText)")
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 6) {
            SkimPendingLabel(skim: message.skim)
            // A ready skim replaces the folded prose; Full reply unfolds it.
            SkimmableReply(messageID: message.id, reply: message.source, skim: message.skim, style: .column) {
                foldedProse
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("First Mate")
    }

    private var foldedProse: some View {
        let folds = !isExpanded && characterCount > Self.foldCharacterBudget
        return VStack(alignment: .leading, spacing: 6) {
            AgentBoardProseView(blocks: folds ? foldedBlocks : message.blocks, codeLineLimit: isExpanded ? nil : 14)
            if characterCount > Self.foldCharacterBudget {
                Button(isExpanded ? "Show less" : "Show more") { isExpanded.toggle() }
                    .buttonStyle(.plain)
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                    .foregroundStyle(HerdrTheme.accent)
                    .frame(minHeight: HerdrTheme.minHitTarget)
                    .contentShape(.rect)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("First Mate: \(plainText)")
    }

    /// Code counts by lines too, so a short but tall block still folds.
    private var characterCount: Int {
        message.blocks.reduce(0) { total, block in
            if case .code(_, let code) = block {
                return total + max(block.characterCount, code.split(separator: "\n", omittingEmptySubsequences: false).count * 70)
            }
            return total + block.characterCount
        }
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
    var codeLineLimit: Int? = 14
    /// Replies read in prose ink; the person's own bubble in full ink.
    var textColor: Color = HerdrTheme.proseText

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .paragraph(_, let text):
                    Text(text).herdrFont(size: HerdrTheme.TextSize.body).lineSpacing(4)
                case .heading(_, let text):
                    Text(text).herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                        .foregroundStyle(HerdrTheme.primaryText)
                        .padding(.top, 2)
                case .quote(_, let text):
                    Text(text).herdrFont(size: HerdrTheme.TextSize.body).lineSpacing(4)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(HerdrTheme.outline).frame(width: 2)
                        }
                case .listItem(_, let marker, let depth, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(HerdrTheme.tertiaryText).monospacedDigit()
                            .frame(minWidth: 12, alignment: .trailing)
                        Text(text).lineSpacing(4)
                    }
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .padding(.leading, CGFloat(min(depth, 4)) * 14)
                case .code(_, let code):
                    Text(code)
                        .herdrFont(size: HerdrTheme.TextSize.small, monospaced: true)
                        .foregroundStyle(HerdrTheme.primaryText)
                        .lineLimit(codeLineLimit)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HerdrTheme.codeFill, in: .rect(cornerRadius: HerdrTheme.Radius.composer))
                        .overlay {
                            RoundedRectangle(cornerRadius: HerdrTheme.Radius.composer).strokeBorder(HerdrTheme.outline)
                        }
                case .notice(_, let text):
                    Text(text).herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
        }
        .foregroundStyle(textColor)
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
