import SwiftUI
import UIKit

struct FirstMateChatBubble: View {
    let row: FirstMateTranscriptLayout.Row
    let snapshot: FirstMateSnapshot
    let maximumWidth: CGFloat
    let skimState: SkimReadingState
    let catalog: FirstMateMentionCatalog
    var replies: [String] = []
    var choice: String? = nil
    var canReply = false
    let sendReply: (String) -> Void
    let presentationChanged: (String, Bool) -> Void
    var readoutConversations: [FirstMateConversation] = []
    var showReadout: (FirstMateConversation) -> Void = { _ in }

    var feedback: FirstMateFeedback?
    var rate: ((FirstMateFeedbackRating?) -> Void)?
    private var human: Bool { row.speaker == .user }
    private var shape: UnevenRoundedRectangle {
        .init(topLeadingRadius: 18, bottomLeadingRadius: !human && row.isLastInGroup ? 5 : 18,
              bottomTrailingRadius: human && row.isLastInGroup ? 5 : 18, topTrailingRadius: 18, style: .continuous)
    }
    var body: some View {
        #if DEBUG
        let _ = FirstMateTranscriptPerformanceProbe.evaluated(row.id)
        #endif
        let message = row.message
        let display = FirstMateMessageDisplay.parse(message.text)
        let reader = human ? nil : FirstMateSkimReader.cached(skim: message.skim, reply: message.text, owner: message.id)
        VStack(alignment: .leading, spacing: 8) {
            if case .agent(let id) = row.speaker, row.isFirstInGroup,
               let agent = snapshot.assignments.first(where: { $0.id == id && $0.featureID == snapshot.feature.id }) {
                HStack(spacing: 8) {
                    FirstMateEmojiDisc(emoji: FirstMateCrewStyle.emoji(forRole: agent.role), size: 24,
                        edge: FirstMateChatStatusStyle.tintColor(for: FirstMateCrewStyle.status(forAssignment: agent.status)))
                    Text(agent.title).herdrFont(.footnote, weight: .semibold).foregroundStyle(HerdrTheme.secondaryText)
                    Text(agent.role).herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
            if row.isPendingDecision {
                Label("Decision needed", systemImage: "hand.raised").herdrFont(.footnote)
                    .foregroundStyle(HerdrTheme.warning)
                    .accessibilityIdentifier("first-mate-pending-decision-\(message.id)")
            }
            if human {
                Text(FirstMateMentionText.render(display.body, catalog: catalog.withoutPlainNames))
                    .font(HerdrProse.font(.bubble)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                SkimmableReply(messageID: message.id, reader: reader, style: .bubble, state: skimState,
                               presentationChanged: { presentationChanged(message.id, $0) }) {
                    FirstMateDocumentContentView(source: display.body)
                        .environment(\.firstMateMentionCatalog, catalog)
                }
                .environment(\.firstMateMentionCatalog, catalog)
            }
            if !display.attachments.isEmpty {
                FirstMateWrappingLayout {
                    ForEach(display.attachments, id: \.self) { path in
                        Label(FirstMateMessageDisplay.fileName(of: path), systemImage: "paperclip")
                            .herdrFont(.caption).padding(8).background(HerdrTheme.codeFill, in: .capsule)
                    }
                }
            }
            if let choice {
                Text("You chose: \(choice)").herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !replies.isEmpty {
                // The Mac's suggested-reply chips: accent outline capsules.
                FirstMateWrappingLayout(spacing: 6) {
                    ForEach(Array(replies.enumerated()), id: \.offset) { index, reply in
                        Button { sendReply(reply) } label: {
                            Text(reply).fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(FirstMateReplyChipStyle())
                        .disabled(!canReply).accessibilityLabel("Reply: \(reply)")
                        .accessibilityIdentifier("first-mate-reply-\(index)")
                    }
                }
                .padding(.top, 2)
            }
            if let feedback, let rating = feedback.rating {
                Button { rate?(nil) } label: {
                    Text(rating == .up ? "👍" : "👎").font(.system(size: 13))
                        .frame(width: 22, height: 22).background(HerdrTheme.chipFill, in: .capsule)
                        .frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                }.buttonStyle(.plain)
                    .accessibilityLabel(rating == .up ? "Rated helpful. Edit feedback" : "Feedback saved. Edit feedback")
                    .accessibilityIdentifier("first-mate-reaction-\(message.id)")
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if message.skim?.status == .pending && !human {
                    Text("Skimming…").composerLayoutMeasurement(id: "skim-pending", label: "Skimming…")
                }
                if ["queued", "processing", "sending", "failed", "unconfirmed"].contains(message.status) {
                    Text(message.status.capitalized)
                }
                if display.isVoice { Text("Sent by voice").foregroundStyle(HerdrTheme.accent) }
                if let date = HerdrTimestamp.date(from: message.createdAt) { Text(FirstMateChatTime.clock(for: date, calendar: .current)) }
            }
            .herdrFont(.caption2).foregroundStyle(HerdrTheme.tertiaryText)
        }
        .foregroundStyle(HerdrTheme.proseText)
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
        .frame(maxWidth: maximumWidth, alignment: .leading)
        .background(human ? HerdrTheme.accent.opacity(0.20) : HerdrTheme.codeFill, in: shape)
        .overlay(shape.strokeBorder(human ? HerdrTheme.accent.opacity(0.26) : HerdrTheme.subtleSeparator))
        .frame(maxWidth: .infinity, alignment: human ? .trailing : .leading)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
            if let rate {
                Button("Rate helpful", systemImage: "hand.thumbsup") { rate(.up) }
                Button("Give feedback", systemImage: "hand.thumbsdown") { rate(.down) }
            }
            ForEach(mentionedConversations(in: display.body)) { conversation in
                Button("Readout: \(conversation.name)", systemImage: "info.circle") { showReadout(conversation) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-message-\(message.id)")
        #if DEBUG
        .onAppear { FirstMateTranscriptPerformanceProbe.appeared(row.id) }
        .onDisappear { FirstMateTranscriptPerformanceProbe.disappeared(row.id) }
        #endif
    }

    private func mentionedConversations(in text: String) -> [FirstMateConversation] {
        guard !readoutConversations.isEmpty else { return [] }
        let linked = FirstMateMentionText.render(text, catalog: human ? catalog.withoutPlainNames : catalog)
        let targets = Set(linked.runs[\.link].compactMap { url, _ -> FirstMateMentionTarget? in
            guard let url, let request = FirstMateMobileOpenRequest(url: url), request.origin == nil,
                  request.assignmentID == nil, case .feature(let id) = request.destination else { return nil }
            return .feature(featureID: id)
        })
        // The host supplies only its captured owner's catalog and rows.
        return readoutConversations.filter { targets.contains(.feature(featureID: $0.featureID)) }
    }
}

/// A suggested reply inside First Mate's bubble: accent text in an accent
/// outline capsule, 34 pt visual height in a 44 pt hit target.
private struct FirstMateReplyChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .herdrFont(size: 14, weight: .semibold, relativeTo: .subheadline)
            .foregroundStyle(HerdrTheme.accent)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .frame(minHeight: 34)
            .background(configuration.isPressed && enabled ? HerdrTheme.accent.opacity(0.16) : HerdrTheme.accent.opacity(0.06), in: .capsule)
            .overlay { Capsule().strokeBorder(HerdrTheme.accent.opacity(0.45), lineWidth: 1) }
            .padding(.vertical, 5)
            .contentShape(.rect)
            .opacity(enabled ? 1 : 0.42)
    }
}
