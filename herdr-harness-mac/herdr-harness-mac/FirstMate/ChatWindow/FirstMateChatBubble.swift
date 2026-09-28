import AppKit
import SwiftUI

/// One message in the chat window: a 17 pt bubble with a 5 pt tail corner on
/// the last bubble of a group, the speaker's name on the first, and the 26 pt
/// avatar beside the last. First Mate's and agents' bubbles are ink 6% with a
/// hairline; yours are accent 20% with an accent edge.
struct FirstMateChatBubbleRow: View {
    let row: FirstMateTranscriptLayout.Row
    /// The crew agent that wrote an agent message, when the snapshot has it.
    let agent: FirstMateAssignment?
    let fileCards: [FirstMateFileCard.Model]
    let maxBubbleWidth: CGFloat
    let feedback: FirstMateResponseFeedbackPresentation?
    let feedbackActions: FirstMateChatFeedbackActions
    let openDocuments: () -> Void

    @State private var hovering = false

    static let avatarSize: CGFloat = 26
    static let avatarGap: CGFloat = 8

    private var message: FirstMateMessage { row.message }
    private var isUser: Bool { row.speaker == .user }

    var body: some View {
        if isUser { userRow } else { themRow }
    }

    // MARK: Yours

    private var userRow: some View {
        let display = FirstMateMessageDisplay.parse(message.text)
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            FirstMateBubbleStack(spacing: 4) {
                if !display.body.isEmpty {
                    PiMarkdownText(display.body, font: .system(size: 13.5 * fontScale.rawValue))
                        .lineSpacing(3.5 * fontScale.rawValue)
                        .environment(\.chatProsePalette, Self.userPalette)
                        .transformEnvironment(\.firstMateMentionCatalog) { $0 = $0?.withoutPlainNames }
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !display.attachments.isEmpty {
                    FirstMateAttachmentChips(paths: display.attachments)
                }
                meta(isVoice: display.isVoice)
            }
            .padding(.top, 8)
            .padding(.horizontal, 13)
            .padding(.bottom, 6)
            .background(shape.fill(HerdrTheme.accent.opacity(0.20)))
            .overlay(shape.strokeBorder(HerdrTheme.accent.opacity(0.26), lineWidth: 1))
            .contextMenu { copyButton }
            .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(display.accessibilityLabel(isQueued: message.status == "queued")
                + (message.status == "sending" ? ", Sending" : message.status == "failed" ? ", Not sent" : message.status == "unconfirmed" ? ", Delivery unconfirmed" : ""))
        }
    }

    // MARK: First Mate and crew

    private var themRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: Self.avatarGap) {
                Group {
                    if row.isLastInGroup { avatar } else { Color.clear }
                }
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                themBubble
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            if showsFooter {
                footer
                    .padding(.leading, Self.avatarSize + Self.avatarGap)
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(speakerName)
    }

    private var themBubble: some View {
        FirstMateBubbleStack(spacing: 2) {
            if row.isFirstInGroup { speakerLine.padding(.bottom, 2) }
            if row.isPendingDecision {
                Label("Decision needed", systemImage: "hand.raised")
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                    .foregroundStyle(HerdrTheme.warning)
                    .padding(.bottom, 2)
                    .accessibilityIdentifier("first-mate-window-pending-decision-\(message.id)")
            }
            // A long reply shows its skim; the full reply is one click away and
            // stays what Copy and feedback act on. The text is passed exactly
            // as sent: skim offsets point into it.
            SkimmableReply(messageID: message.id, reply: message.text, skim: message.skim, style: .bubble) {
                PiMarkdownMessageView(
                    source: message.text,
                    isStreaming: false,
                    id: "first-mate-window-\(message.featureID)-\(message.id)",
                    detectsPaneLinks: false
                )
            }
            if !fileCards.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(fileCards) { card in
                        FirstMateFileCard(model: card, open: openDocuments)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 3)
            }
            meta(isVoice: false)
        }
        .padding(.top, 8)
        .padding(.horizontal, 13)
        .padding(.bottom, 6)
        .background(shape.fill(HerdrTheme.inkFill(0.06)))
        .overlay(shape.strokeBorder(HerdrTheme.hairline, lineWidth: 1))
        .contextMenu { copyButton }
    }

    @ViewBuilder private var speakerLine: some View {
        if let agentTitle {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(agentTitle)
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
                    .foregroundStyle(HerdrTheme.secondaryText)
                if let role = agent?.role, !role.isEmpty {
                    Text(role)
                        .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
            .lineLimit(1)
        } else {
            Text("First Mate")
                .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.accent)
        }
    }

    @ViewBuilder private var avatar: some View {
        if case .agent = row.speaker {
            let status = agent.map { FirstMateCrewStyle.status(forAssignment: $0.status) } ?? .unknown
            FirstMateEmojiDisc(
                emoji: FirstMateCrewStyle.emoji(forRole: agent?.role ?? ""),
                size: Self.avatarSize,
                edge: FirstMateChatStatusStyle.dotColor(for: status)
            )
        } else {
            FirstMateFaceOrb(size: Self.avatarSize)
        }
    }

    private var agentTitle: String? {
        guard case .agent = row.speaker else { return nil }
        return agent?.title ?? "Crew agent"
    }

    private var speakerName: String { agentTitle ?? "First Mate" }

    // MARK: Meta, footer, copy

    private func meta(isVoice: Bool) -> some View {
        HStack(spacing: 6) {
            SkimPendingLabel(skim: message.skim)
            if ["queued", "sending", "failed", "unconfirmed"].contains(message.status) {
                Text(message.status == "sending" ? "Sending…" : message.status == "queued" ? "Queued" : message.status == "failed" ? "Not sent" : "Delivery unconfirmed")
                    .foregroundStyle(["failed", "unconfirmed"].contains(message.status) ? HerdrTheme.alert : HerdrTheme.tertiaryText)
                    .accessibilityIdentifier("first-mate-send-status-\(message.id)")
            }
            if isVoice {
                Text("Sent by voice")
                    .foregroundStyle(HerdrTheme.accent)
            }
            if let date = HerdrTimestamp.date(from: message.createdAt) {
                Text(FirstMateChatTime.clock(for: date, calendar: .current))
                    .monospacedDigit()
            }
        }
        .herdrFont(size: HerdrTheme.TextSize.micro)
        .foregroundStyle(HerdrTheme.tertiaryText)
        .lineLimit(1)
        .padding(.top, 2)
    }

    /// Rating and Copy show on hover, and stay while a rating is saved or
    /// needs attention.
    private var showsFooter: Bool {
        if hovering { return true }
        guard let feedback else { return false }
        return feedback.hasSavedRating || feedback.saveErrorMessage != nil || feedback.hasConflict || feedback.isSaving
    }

    @ViewBuilder private var footer: some View {
        if let feedback {
            FirstMateResponseFeedbackFooter(
                messageID: message.id,
                presentation: feedback,
                copyText: message.text,
                onRateUp: { feedbackActions.rate(.up) },
                onEditFeedback: feedbackActions.edit,
                onRemoveRating: feedbackActions.remove,
                onRetry: feedbackActions.retry,
                onResolveConflict: feedbackActions.resolveConflict
            )
        } else {
            PiCopyButton(text: message.text, label: "Copy response", accessibilityIdentifier: "first-mate-copy-\(message.id)")
        }
    }

    private var copyButton: some View {
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
        }
    }

    // MARK: Shape

    @Environment(\.herdrFontScale) private var fontScale

    private var shape: UnevenRoundedRectangle {
        Self.shape(isUser: isUser, hasTail: row.isLastInGroup)
    }

    static func shape(isUser: Bool, hasTail: Bool) -> UnevenRoundedRectangle {
        let radius: CGFloat = 17
        let tail: CGFloat = hasTail ? 5 : radius
        return UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: isUser ? radius : tail,
            bottomTrailingRadius: isUser ? tail : radius,
            topTrailingRadius: radius,
            style: .continuous
        )
    }

    /// Your words read in full ink on the accent fill.
    static let userPalette: ChatProsePalette = {
        var palette = ChatProsePalette.firstMate(FirstMatePalette(scheme: .dark))
        palette.text = HerdrTheme.primaryText
        return palette
    }()
}

/// A bubble's stack: every child leads except the last (the meta row), which
/// trails. Unlike a `VStack` with a flexible frame it hugs its widest child,
/// so a short message keeps a short bubble.
struct FirstMateBubbleStack: Layout {
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let child = ProposedViewSize(width: proposal.width, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(child) }
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        let child = ProposedViewSize(width: bounds.width, height: nil)
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(child)
            let isLast = index == subviews.count - 1 && subviews.count > 1
            let x = isLast ? bounds.maxX - size.width : bounds.minX
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: isLast ? size.width : bounds.width, height: size.height))
            y += size.height + spacing
        }
    }
}

/// "Today", centered between days.
struct FirstMateDayPill: View {
    let label: String

    var body: some View {
        Text(label)
            .herdrFont(size: HerdrTheme.TextSize.caption)
            .foregroundStyle(HerdrTheme.tertiaryText)
            .padding(.vertical, 3)
            .padding(.horizontal, 11)
            .background(HerdrTheme.inkFill(0.05), in: .rect(cornerRadius: 10))
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

/// First Mate working on a reply: three dots that rise in turn every 1.1 s,
/// still under Reduce Motion.
struct FirstMateTypingRow: View {
    let startsGroup: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let period: TimeInterval = 1.1

    var body: some View {
        HStack(alignment: .bottom, spacing: FirstMateChatBubbleRow.avatarGap) {
            FirstMateFaceOrb(size: FirstMateChatBubbleRow.avatarSize)
            VStack(alignment: .leading, spacing: 4) {
                if startsGroup {
                    Text("First Mate")
                        .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
                        .foregroundStyle(HerdrTheme.accent)
                }
                dots
            }
            .padding(.vertical, startsGroup ? 9 : 13)
            .padding(.horizontal, 14)
            .background(FirstMateChatBubbleRow.shape(isUser: false, hasTail: true).fill(HerdrTheme.inkFill(0.06)))
            .overlay(FirstMateChatBubbleRow.shape(isUser: false, hasTail: true).strokeBorder(HerdrTheme.hairline, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("First Mate is working on a reply")
    }

    @ViewBuilder private var dots: some View {
        if reduceMotion {
            dotRow(at: nil)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                dotRow(at: context.date)
            }
        }
    }

    private func dotRow(at date: Date?) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                let lift = date.map { Self.lift(at: $0, delay: Double(index) * 0.15) } ?? 0
                Circle()
                    .fill(HerdrTheme.tertiaryText)
                    .frame(width: 6, height: 6)
                    .opacity(date == nil ? 0.6 : 0.3 + 0.7 * lift)
                    .offset(y: -2 * lift)
            }
        }
    }

    /// 0 at rest, 1 at the peak (30% into the cycle).
    static func lift(at date: Date, delay: TimeInterval) -> Double {
        let time = date.timeIntervalSinceReferenceDate - delay
        let phase = (time.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period
        if phase < 0.3 { return phase / 0.3 }
        if phase < 0.6 { return (0.6 - phase) / 0.3 }
        return 0
    }
}

/// A document named in a reply. Opens the inspector on Documents.
struct FirstMateFileCard: View {
    struct Model: Identifiable, Equatable {
        var document: FirstMateDocument
        /// The agent that wrote it.
        var from: String?
        var id: String { document.id }
    }

    let model: Model
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .herdrFont(size: 15)
                    .foregroundStyle(HerdrTheme.accent)
                    .frame(width: 30, height: 36)
                    .background(HerdrTheme.accent.opacity(0.13), in: .rect(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(HerdrTheme.accent.opacity(0.32), lineWidth: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.document.title)
                        .herdrFont(size: 12.5, weight: .semibold)
                        .foregroundStyle(HerdrTheme.primaryText)
                    if let from = model.from {
                        Text("From \(from)")
                            .herdrFont(size: HerdrTheme.TextSize.caption)
                            .foregroundStyle(HerdrTheme.tertiaryText)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .herdrFont(size: 10, weight: .semibold)
                    .foregroundStyle(HerdrTheme.iconTint)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HerdrTheme.windowBackground.opacity(0.45), in: .rect(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(hovering ? HerdrTheme.accent.opacity(0.55) : HerdrTheme.hairline, lineWidth: 1))
            .contentShape(.rect(cornerRadius: 11))
        }
        .buttonStyle(.herdrPlain)
        .onHover { hovering = $0 }
        .help("Show in Documents")
        .accessibilityLabel("\(model.document.title)\(model.from.map { ", from \($0)" } ?? ""). Shows it in Documents.")
    }
}

/// Files you attached, as small chips in your bubble.
struct FirstMateAttachmentChips: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                Label(FirstMateMessageDisplay.fileName(of: path), systemImage: "paperclip")
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(HerdrTheme.inkFill(0.08), in: .capsule)
                    .help(path)
            }
        }
    }
}
